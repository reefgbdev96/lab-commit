// Command loadgen replays a request-rate ramp against TARGET_URL in a loop, so the
// frontend autoscaler can be watched scaling up to four pods and back down.
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"syscall"
	"time"
)

// defaultStages yields 2, 3 and then 4 frontend pods at 10 rps per pod, then idles back to 1.
const defaultStages = "15:3m,25:3m,35:4m,0:5m"

var version = "dev" // set at build time: -ldflags "-X main.version=..."

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))
	if err := run(); err != nil {
		slog.Error("fatal", "err", err)
		os.Exit(1)
	}
}

func run() error {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	target := os.Getenv("TARGET_URL")
	if u, err := url.Parse(target); err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") {
		return fmt.Errorf("TARGET_URL must be an absolute http(s) URL, got %q", target)
	}

	spec := os.Getenv("STAGES")
	if spec == "" {
		spec = defaultStages
	}
	stages, err := parseStages(spec)
	if err != nil {
		return err
	}

	client, err := newClient(os.Getenv("CA_FILE"))
	if err != nil {
		return err
	}

	slog.Info("starting", "version", version, "target", target, "stages", spec)
	for ctx.Err() == nil {
		for _, st := range stages {
			ok, failed := runStage(ctx, client, target, st)
			if ctx.Err() != nil {
				return nil
			}
			slog.Info("stage done", "rps", st.rps, "duration", st.dur.String(), "ok", ok, "failed", failed)
		}
	}
	return nil
}

// newClient trusts the system roots plus, optionally, the lab's self-signed
// certificate, so TLS to the internal ALB is verified rather than skipped.
func newClient(caFile string) (*http.Client, error) {
	roots, err := x509.SystemCertPool()
	if err != nil {
		return nil, fmt.Errorf("load system roots: %w", err)
	}
	if caFile != "" {
		pem, err := os.ReadFile(caFile)
		if err != nil {
			return nil, fmt.Errorf("read CA_FILE: %w", err)
		}
		if !roots.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("CA_FILE %s holds no PEM certificates", caFile)
		}
	}

	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.TLSClientConfig = &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}
	transport.MaxIdleConnsPerHost = 64 // reuse connections instead of a TLS handshake per request
	return &http.Client{Timeout: 5 * time.Second, Transport: transport}, nil
}
