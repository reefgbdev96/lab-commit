package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"sync"
	"time"
)

// poller keeps a cached copy of the backend's value so request handling never
// blocks on the backend or the database.
type poller struct {
	client   *http.Client
	url      string
	interval time.Duration

	mu    sync.RWMutex
	value string
}

func newPoller(endpoint string, interval time.Duration) *poller {
	return &poller{
		client:   &http.Client{Timeout: 3 * time.Second},
		url:      endpoint,
		interval: interval,
	}
}

// run polls until ctx is cancelled, refreshing the cached value every interval.
func (p *poller) run(ctx context.Context) {
	ticker := time.NewTicker(p.interval)
	defer ticker.Stop()

	p.poll(ctx)
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			p.poll(ctx)
		}
	}
}

func (p *poller) poll(ctx context.Context) {
	value, err := p.fetch(ctx)
	if err != nil {
		// Keep serving the last good value.
		slog.Warn("poll backend", "err", err)
		return
	}

	p.mu.Lock()
	defer p.mu.Unlock()
	p.value = value
}

func (p *poller) fetch(ctx context.Context) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, p.url, nil)
	if err != nil {
		return "", err
	}

	resp, err := p.client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close() //nolint:errcheck // read-only body

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("backend returned %s", resp.Status)
	}

	var body struct {
		Value string `json:"value"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return "", err
	}
	if body.Value == "" {
		// Treat a blank value as a failed poll, so the cache keeps the last good value.
		return "", errors.New("backend returned an empty value")
	}
	return body.Value, nil
}

// current returns the cached value, or an error if no poll has ever succeeded.
func (p *poller) current() (string, error) {
	p.mu.RLock()
	defer p.mu.RUnlock()
	if p.value == "" {
		return "", errors.New("no successful poll yet")
	}
	return p.value, nil
}
