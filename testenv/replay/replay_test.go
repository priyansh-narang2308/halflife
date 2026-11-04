package replay

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

type fixture struct {
	upstream *httptest.Server
	calls    atomic.Int32
	status   atomic.Int32
	auth     atomic.Value
}

func newFixture(t *testing.T) *fixture {
	f := &fixture{}
	f.status.Store(200)
	f.upstream = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.calls.Add(1)
		f.auth.Store(r.Header.Get("Authorization"))
		w.WriteHeader(int(f.status.Load()))
		io.WriteString(w, `{"answer":1}`)
	}))
	t.Cleanup(f.upstream.Close)
	return f
}

func serve(t *testing.T, cfg Config) *httptest.Server {
	p, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(p)
	t.Cleanup(ts.Close)
	return ts
}

func post(t *testing.T, ts *httptest.Server, path, body string) (int, string) {
	req, _ := http.NewRequest("POST", ts.URL+path, strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer client-value")
	resp, err := ts.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

func TestRecordThenReplay(t *testing.T) {
	f := newFixture(t)
	dir := t.TempDir()
	rec := serve(t, Config{Dir: dir, Record: true, Upstreams: []Upstream{{Prefix: "/search", Base: f.upstream.URL, Key: "the-key", Limit: 5}}})
	if code, body := post(t, rec, "/search", `{"q":"a"}`); code != 200 || body != `{"answer":1}` {
		t.Fatalf("record: %d %s", code, body)
	}
	if f.auth.Load() != "Bearer the-key" {
		t.Errorf("upstream saw %v", f.auth.Load())
	}
	post(t, rec, "/search", `{"q":"a"}`)
	if f.calls.Load() != 1 {
		t.Errorf("a recorded success was bought again: %d calls", f.calls.Load())
	}
	stored, _ := filepath.Glob(filepath.Join(dir, "*.json"))
	for _, path := range stored {
		b, _ := os.ReadFile(path)
		if strings.Contains(string(b), "the-key") || strings.Contains(string(b), "client-value") {
			t.Errorf("a credential reached %s", path)
		}
	}

	rep := serve(t, Config{Dir: dir})
	if code, body := post(t, rep, "/search", `{"q":"a"}`); code != 200 || body != `{"answer":1}` {
		t.Errorf("replay: %d %s", code, body)
	}
	if code, _ := post(t, rep, "/search", `{"q":"b"}`); code != missStatus {
		t.Errorf("replay miss: %d", code)
	}
	if f.calls.Load() != 1 {
		t.Error("replay called upstream")
	}
}

func TestKeyIgnoresTheDate(t *testing.T) {
	if Key("POST", "/x", []byte("Today is 2026-11-04.")) != Key("POST", "/x", []byte("Today is 2027-01-01.")) {
		t.Error("a re-run on another day would miss")
	}
	if Key("POST", "/x", []byte("a")) == Key("POST", "/y", []byte("a")) {
		t.Error("paths collide")
	}
}

func TestCallLimit(t *testing.T) {
	f := newFixture(t)
	rec := serve(t, Config{Dir: t.TempDir(), Record: true, Upstreams: []Upstream{{Prefix: "/search", Base: f.upstream.URL, Limit: 1}}})
	post(t, rec, "/search", `{"q":"a"}`)
	if code, _ := post(t, rec, "/search", `{"q":"b"}`); code != 429 || f.calls.Load() != 1 {
		t.Errorf("past the limit: %d, %d calls", code, f.calls.Load())
	}
}

func TestFailureDoesNotReplaceASuccess(t *testing.T) {
	f := newFixture(t)
	dir := t.TempDir()
	cfg := Config{Dir: dir, Record: true, Upstreams: []Upstream{{Prefix: "/v1", Base: f.upstream.URL, Limit: 9}}}
	f.status.Store(429)
	rec := serve(t, cfg)
	post(t, rec, "/v1/chat/completions", `{}`)
	f.status.Store(200)
	if code, _ := post(t, rec, "/v1/chat/completions", `{}`); code != 200 || f.calls.Load() != 2 {
		t.Fatalf("a stored failure must be retried while recording: %d, %d calls", code, f.calls.Load())
	}
	f.status.Store(429)
	p, _ := New(cfg)
	if err := p.save(Key("POST", "/v1/chat/completions", []byte(`{}`)), recording{Status: 429}); err != nil {
		t.Fatal(err)
	}
	rep := serve(t, Config{Dir: dir})
	if code, _ := post(t, rep, "/v1/chat/completions", `{}`); code != 200 {
		t.Errorf("replay: %d", code)
	}
}

func TestAccountResponsesAreNotRecorded(t *testing.T) {
	f := newFixture(t)
	dir := t.TempDir()
	rec := serve(t, Config{Dir: dir, Record: true, Upstreams: []Upstream{{Prefix: "/v1/", Base: f.upstream.URL, Key: "the-key", Limit: 5}}})
	if code, _ := post(t, rec, "/v1/auth/key", `{}`); code != 200 {
		t.Fatalf("status %d: an account response is still passed through", code)
	}
	if files, _ := os.ReadDir(dir); len(files) != 0 {
		t.Errorf("recorded %d files for an account response", len(files))
	}
}
