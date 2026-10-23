package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestParseStages(t *testing.T) {
	got, err := parseStages("15:2m, 0:30s")
	want := []stage{{rps: 15, dur: 2 * time.Minute}, {rps: 0, dur: 30 * time.Second}}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("parseStages = %v, %v; want %v", got, err, want)
	}

	for _, bad := range []string{"", "15", "x:2m", "-1:2m", "15:0s", "15:abc", "5000:1m"} {
		if _, err := parseStages(bad); err == nil {
			t.Errorf("parseStages(%q) accepted an invalid stage", bad)
		}
	}
}

// Loose bounds: this checks pacing, not timer precision.
func TestRunStagePacesRequests(t *testing.T) {
	target := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	defer target.Close()

	ok, failed := runStage(context.Background(), target.Client(), target.URL, stage{rps: 20, dur: 500 * time.Millisecond})
	if ok < 5 || ok > 12 || failed != 0 {
		t.Errorf("runStage ok=%d failed=%d; want ~10 ok, 0 failed", ok, failed)
	}
}

func TestNewClientRejectsFileWithoutCertificates(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ca.pem")
	if err := os.WriteFile(path, []byte("not a certificate"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := newClient(path); err == nil {
		t.Error("newClient accepted a CA file with no certificates")
	}
}
