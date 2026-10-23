package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// maxRPS keeps the ticker interval positive and the tool a lab load generator.
const maxRPS = 1000

type stage struct {
	rps int
	dur time.Duration
}

// parseStages reads "rps:duration" pairs, e.g. "15:3m,0:5m". An rps of 0 is a pause.
func parseStages(spec string) ([]stage, error) {
	var stages []stage
	for _, part := range strings.Split(spec, ",") {
		rpsText, durText, ok := strings.Cut(strings.TrimSpace(part), ":")
		rps, rpsErr := strconv.Atoi(rpsText)
		dur, durErr := time.ParseDuration(durText)
		if !ok || rpsErr != nil || durErr != nil || rps < 0 || rps > maxRPS || dur <= 0 {
			return nil, fmt.Errorf("invalid stage %q: want rps:duration, e.g. 15:3m", part)
		}
		stages = append(stages, stage{rps: rps, dur: dur})
	}
	return stages, nil
}

// runStage sends st.rps GET requests per second to target for st.dur and
// reports how many succeeded. Requests use ctx, not the stage deadline, so a
// stage boundary never cancels one in flight.
func runStage(ctx context.Context, client *http.Client, target string, st stage) (ok, failed int) {
	stageCtx, cancel := context.WithTimeout(ctx, st.dur)
	defer cancel()

	if st.rps == 0 {
		<-stageCtx.Done()
		return 0, 0
	}

	var okN, failedN atomic.Int64
	var wg sync.WaitGroup
	ticker := time.NewTicker(time.Second / time.Duration(st.rps))
	defer ticker.Stop()

	for {
		select {
		case <-stageCtx.Done():
			wg.Wait()
			return int(okN.Load()), int(failedN.Load())
		case <-ticker.C:
			// ponytail: one goroutine per request; in flight is bounded by rps × client timeout.
			wg.Add(1)
			go func() {
				defer wg.Done()
				if get(ctx, client, target) {
					okN.Add(1)
				} else {
					failedN.Add(1)
				}
			}()
		}
	}
}

func get(ctx context.Context, client *http.Client, target string) bool {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return false
	}
	resp, err := client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()               //nolint:errcheck // read-only body
	_, _ = io.Copy(io.Discard, resp.Body) // drain so the connection is reused
	return resp.StatusCode == http.StatusOK
}
