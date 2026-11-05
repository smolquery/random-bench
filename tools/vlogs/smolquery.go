//go:build vlogs

package systems

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync/atomic"
	"time"

	"github.com/VictoriaMetrics/logs-benchmark/internal/source/synthetic"
)

// smolquery sends the workload as NDJSON to the streaming-insert route of a
// smolquery cluster. addr holds one or more base URLs joined by "|", one per
// api pod; requests go round-robin over them. The dataset, table and api key
// come from SMOLQUERY_DATASET, SMOLQUERY_TABLE and SMOLQUERY_API_KEY.
type smolquery struct {
	addrs   []string
	next    atomic.Uint64
	dataset string
	table   string
	auth    string
}

func newSmolquery(addr string) (*smolquery, error) {
	key := os.Getenv("SMOLQUERY_API_KEY")
	if key == "" {
		return nil, fmt.Errorf("SMOLQUERY_API_KEY is not set")
	}
	var addrs []string
	for _, a := range strings.Split(addr, "|") {
		if a = strings.TrimRight(strings.TrimSpace(a), "/"); a != "" {
			addrs = append(addrs, a)
		}
	}
	if len(addrs) == 0 {
		return nil, fmt.Errorf("no smolquery address in %q", addr)
	}
	return &smolquery{
		addrs:   addrs,
		dataset: envOr("SMOLQUERY_DATASET", "bench"),
		table:   envOr("SMOLQUERY_TABLE", "vlogs_v1"),
		auth:    "Bearer " + key,
	}, nil
}

func envOr(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

func (s *smolquery) pick() string {
	return s.addrs[s.next.Add(1)%uint64(len(s.addrs))]
}

func (s *smolquery) WaitReady() error {
	return waitHTTP(s.addrs[0]+"/healthz", status2xx)
}

// PrepareBatch writes the records as NDJSON, the same lines VictoriaLogs gets
// at /insert/jsonline.
func (s *smolquery) PrepareBatch(entries []LogEntry) (Batch, error) {
	buf := make([]byte, 0, len(entries)*1024)
	for _, e := range entries {
		buf = synthetic.AppendJSON(buf, e.Rec, e.Ts)
		buf = append(buf, '\n')
	}
	return Batch{Body: buf, Lines: len(entries)}, nil
}

type smolqueryInsertResponse struct {
	InsertedRows int               `json:"insertedRows"`
	InsertErrors []json.RawMessage `json:"insertErrors"`
}

// Send posts one batch and retries on 429/502/503/504 and transport errors,
// with the same budget and backoff as doReq. A 200 that refused any row is an
// error, because the route reports partial failure in the body.
func (s *smolquery) Send(ctx context.Context, b Batch) (int, error) {
	ctx, cancel := context.WithTimeout(ctx, maxRetryDuration)
	defer cancel()
	backoff := 100 * time.Millisecond
	retries := 0
	status := 0
	for {
		reqURL := fmt.Sprintf("%s/v1/datasets/%s/tables/%s/insert", s.pick(), s.dataset, s.table)
		req, err := http.NewRequestWithContext(ctx, "POST", reqURL, bytes.NewReader(b.Body))
		if err != nil {
			return retries, err
		}
		req.Header.Set("Content-Type", "application/x-ndjson")
		req.Header.Set("Authorization", s.auth)
		resp, err := httpClient.Do(req)
		switch {
		case err == nil:
			rb, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			status = resp.StatusCode
			if status >= 200 && status < 300 {
				var r smolqueryInsertResponse
				if err := json.Unmarshal(rb, &r); err != nil {
					return retries, fmt.Errorf("parse insert response: %w: %s", err, truncate(string(rb), 200))
				}
				if len(r.InsertErrors) > 0 || r.InsertedRows != b.Lines {
					return retries, fmt.Errorf("inserted %d of %d rows, %d errors: %s",
						r.InsertedRows, b.Lines, len(r.InsertErrors), truncate(string(rb), 300))
				}
				return retries, nil
			}
			if status != 429 && status != 502 && status != 503 && status != 504 {
				return retries, fmt.Errorf("POST %s: status %d: %s", reqURL, status, truncate(string(rb), 300))
			}
		case ctx.Err() != nil:
			return retries, fmt.Errorf("POST %s: giving up after %s: %w", reqURL, maxRetryDuration, err)
		}
		retries++
		select {
		case <-time.After(backoff):
		case <-ctx.Done():
			return retries, fmt.Errorf("POST %s: giving up after %s (last status %d)", reqURL, maxRetryDuration, status)
		}
		backoff = min(backoff*2, 5*time.Second)
	}
}

// Queries is empty: this repo reproduces the ingest test only.
func (s *smolquery) Queries(_ QueryParams) []Query {
	return nil
}

// StoredRows counts every row the table holds, hot and sealed, with
// SELECT count(*). A 200 from the insert route means the rows are durable and
// queryable, so the count covers every acknowledged row.
func (s *smolquery) StoredRows(ctx context.Context) (*int64, error) {
	q := fmt.Sprintf(`{"query":"SELECT count(*) AS n FROM %s.%s","maxResults":1}`, s.dataset, s.table)
	req, err := http.NewRequestWithContext(ctx, "POST", s.pick()+"/v1/queries", strings.NewReader(q))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", s.auth)
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("count: status %d: %s", resp.StatusCode, truncate(string(body), 200))
	}
	var r struct {
		Rows []map[string]json.RawMessage `json:"rows"`
	}
	if err := json.Unmarshal(body, &r); err != nil {
		return nil, fmt.Errorf("parse count response: %w: %s", err, truncate(string(body), 200))
	}
	if len(r.Rows) == 0 {
		return nil, fmt.Errorf("count response has no rows: %s", truncate(string(body), 200))
	}
	raw, ok := r.Rows[0]["n"]
	if !ok {
		return nil, fmt.Errorf("count response missing n: %s", truncate(string(body), 200))
	}
	n, err := jsonInt(raw)
	if err != nil {
		return nil, err
	}
	return &n, nil
}
