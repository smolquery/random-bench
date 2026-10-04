// cbquery runs the ClickBench queries against one smolquery node, -tries
// times each, back to back, and writes every timing as JSON. It runs on the
// in-region load generator and posts straight to a query pod's IP, so a wall
// time carries no operator uplink and no edge. Each line of -queries is one
// statement with %{ref} where the table goes. The authorization header value
// comes from the AUTH environment variable, never from the command line.
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"maps"
	"net/http"
	"os"
	"strings"
	"time"
)

type try struct {
	WallMs     float64         `json:"wall_ms"`
	DurationMs *float64        `json:"duration_ms"`
	TotalRows  *int64          `json:"total_rows"`
	FileCache  *string         `json:"file_cache"`
	Scatter    json.RawMessage `json:"scatter"`
	Status     int             `json:"status"`
	Error      string          `json:"error,omitempty"`
}

type result struct {
	N       int     `json:"n"`
	SQL     string  `json:"sql"`
	Tries   []try   `json:"tries"`
	FirstMs float64 `json:"first_ms"`
	HotMs   float64 `json:"hot_ms"`
	Errors  int     `json:"errors"`
}

type response struct {
	TotalRows *int64 `json:"totalRows"`
	Job       struct {
		DurationMs *float64        `json:"durationMs"`
		FileCache  *string         `json:"fileCache"`
		Scatter    json.RawMessage `json:"scatter"`
	} `json:"job"`
}

func run(client *http.Client, url, auth string, body []byte) try {
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return try{Error: err.Error()}
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", auth)
	started := time.Now()
	resp, err := client.Do(req)
	if err != nil {
		return try{WallMs: msSince(started), Error: err.Error()}
	}
	raw, err := io.ReadAll(resp.Body)
	resp.Body.Close()
	t := try{WallMs: msSince(started), Status: resp.StatusCode}
	if err != nil {
		t.Error = err.Error()
		return t
	}
	if resp.StatusCode/100 != 2 {
		t.Error = fmt.Sprintf("HTTP %d: %s", resp.StatusCode, truncate(string(raw), 300))
		return t
	}
	var parsed response
	if err := json.Unmarshal(raw, &parsed); err != nil {
		t.Error = "decode: " + err.Error()
		return t
	}
	t.DurationMs = parsed.Job.DurationMs
	t.TotalRows = parsed.TotalRows
	t.FileCache = parsed.Job.FileCache
	t.Scatter = parsed.Job.Scatter
	return t
}

func msSince(t time.Time) float64 {
	return float64(time.Since(t).Microseconds()) / 1000
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

func readQueries(path, ref string, only map[int]bool) ([][2]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var out [][2]string
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 1<<20), 1<<20)
	n := 0
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		n++
		if len(only) > 0 && !only[n] {
			continue
		}
		out = append(out, [2]string{fmt.Sprint(n), strings.ReplaceAll(line, "%{ref}", ref)})
	}
	return out, scanner.Err()
}

func main() {
	url := flag.String("url", "", "the query endpoint, e.g. http://10.0.0.1:4000/v1/queries (required)")
	queries := flag.String("queries", "scripts/clickbench/queries.sql", "one query per line, %{ref} for the table")
	ref := flag.String("ref", "bench.hits_v2", "dataset.table")
	tries := flag.Int("tries", 3, "runs per query")
	timeoutMs := flag.Int("timeout-ms", 600_000, "timeoutMs sent with every job")
	options := flag.String("options", `{"fileCache":true}`, "extra JSON fields merged into every request body")
	onlyList := flag.String("only", "", "comma-separated query numbers to run (default: all)")
	out := flag.String("out", "", "result JSON path (required)")
	flag.Parse()

	if *url == "" || *out == "" {
		log.Fatal("-url and -out are required")
	}
	only := map[int]bool{}
	for part := range strings.SplitSeq(*onlyList, ",") {
		var n int
		if _, err := fmt.Sscan(strings.TrimSpace(part), &n); err == nil {
			only[n] = true
		}
	}
	list, err := readQueries(*queries, *ref, only)
	if err != nil {
		log.Fatal(err)
	}
	extra := map[string]any{}
	if err := json.Unmarshal([]byte(*options), &extra); err != nil {
		log.Fatalf("-options: %v", err)
	}

	auth := os.Getenv("AUTH")
	client := &http.Client{Timeout: time.Duration(*timeoutMs+60_000) * time.Millisecond}
	started := time.Now().UTC()
	var results []result
	for _, q := range list {
		body := map[string]any{"query": q[1], "timeoutMs": *timeoutMs, "maxResults": 1}
		maps.Copy(body, extra)
		encoded, _ := json.Marshal(body)
		r := result{SQL: q[1]}
		fmt.Sscan(q[0], &r.N)
		for i := 0; i < *tries; i++ {
			t := run(client, *url, auth, encoded)
			if t.Error != "" {
				r.Errors++
			}
			r.Tries = append(r.Tries, t)
		}
		if r.Tries[0].Error == "" {
			r.FirstMs = r.Tries[0].WallMs
		}
		for _, t := range r.Tries[1:] {
			if t.Error == "" && (r.HotMs == 0 || t.WallMs < r.HotMs) {
				r.HotMs = t.WallMs
			}
		}
		fileCache := ""
		if r.Tries[len(r.Tries)-1].FileCache != nil {
			fileCache = *r.Tries[len(r.Tries)-1].FileCache
		}
		fmt.Fprintf(os.Stderr, "Q%d: first %.0f ms, hot %.0f ms, errors %d, cache %s, scatter %s\n",
			r.N, r.FirstMs, r.HotMs, r.Errors, fileCache, string(r.Tries[len(r.Tries)-1].Scatter))
		results = append(results, r)
	}

	summary := map[string]any{
		"started_at":  started.Format(time.RFC3339),
		"inserted_at": time.Now().UTC().Format(time.RFC3339),
		"url":         *url,
		"ref":         *ref,
		"tries":       *tries,
		"options":     extra,
		"queries":     results,
	}
	encoded, _ := json.Marshal(summary)
	if err := os.WriteFile(*out, append(encoded, '\n'), 0o644); err != nil {
		log.Fatal(err)
	}
}
