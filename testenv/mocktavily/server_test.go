package mocktavily

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const key = "tvly-mock"

func newTestServer(t *testing.T, f *Fixtures) (*Server, *httptest.Server) {
	t.Helper()
	s := New(Config{APIKey: key, Fixtures: f})
	ts := httptest.NewServer(s)
	t.Cleanup(ts.Close)
	return s, ts
}

func call(t *testing.T, ts *httptest.Server, path, auth string, body any) (*http.Response, map[string]any) {
	t.Helper()
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, ts.URL+path, strings.NewReader(string(b)))
	req.Header.Set("Content-Type", "application/json")
	if auth != "" {
		req.Header.Set("Authorization", "Bearer "+auth)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("decode %s: %v", raw, err)
	}
	return resp, out
}

func credits(t *testing.T, out map[string]any) (float64, bool) {
	t.Helper()
	u, ok := out["usage"].(map[string]any)
	if !ok {
		return 0, false
	}
	return u["credits"].(float64), true
}

var fixtures = &Fixtures{
	Search: map[string][]Result{"acme price": {
		{Title: "one", URL: "https://a.example/1", Content: "c1", Score: 0.9, PublishedDate: "2026-10-01"},
		{Title: "two", URL: "https://a.example/2", Content: "c2", Score: 0.8},
		{Title: "three", URL: "https://a.example/3", Content: "c3", Score: 0.7},
	}},
	Extract: map[string]string{"https://a.example/1": "full page"},
}

func TestAuth(t *testing.T) {
	_, ts := newTestServer(t, nil)
	for _, auth := range []string{"", "wrong"} {
		resp, out := call(t, ts, "/search", auth, map[string]any{"query": "q"})
		if resp.StatusCode != 401 || out["detail"].(map[string]any)["error"] == "" {
			t.Errorf("auth %q: status %d body %v", auth, resp.StatusCode, out)
		}
	}
	if resp, _ := call(t, ts, "/extract", "", map[string]any{"urls": "https://x.example"}); resp.StatusCode != 401 {
		t.Errorf("extract without key: %d", resp.StatusCode)
	}
}

func TestSearchFixturesAndLimits(t *testing.T) {
	_, ts := newTestServer(t, fixtures)
	resp, out := call(t, ts, "/search", key, map[string]any{"query": "  ACME Price ", "max_results": 2})
	if resp.StatusCode != 200 {
		t.Fatalf("status %d %v", resp.StatusCode, out)
	}
	results := out["results"].([]any)
	if len(results) != 2 || results[0].(map[string]any)["published_date"] != "2026-10-01" {
		t.Errorf("results = %v", results)
	}
	if _, has := results[1].(map[string]any)["published_date"]; has {
		t.Error("published_date should be omitted when unknown")
	}
	if out["answer"] != nil || out["query"] != "  ACME Price " || out["request_id"] == "" {
		t.Errorf("envelope = %v", out)
	}
	if _, has := credits(t, out); has {
		t.Error("usage present without include_usage")
	}

	_, out = call(t, ts, "/search", key, map[string]any{"query": "acme price"})
	if n := len(out["results"].([]any)); n != 3 { // default max_results (10) keeps all 3
		t.Errorf("default max_results kept %d of 3", n)
	}

	_, out = call(t, ts, "/search", key, map[string]any{"query": "unknown topic", "include_answer": true})
	if n := len(out["results"].([]any)); n != 2 || out["answer"] != "Mock answer for: unknown topic" {
		t.Errorf("default results=%d answer=%v", n, out["answer"])
	}
}

func TestSearchCredits(t *testing.T) {
	_, ts := newTestServer(t, nil)
	for depth, want := range map[string]float64{"": 1, "basic": 1, "fast": 1, "ultra-fast": 1, "advanced": 2} {
		_, out := call(t, ts, "/search", key, map[string]any{"query": "q", "search_depth": depth, "include_usage": true})
		if got, ok := credits(t, out); !ok || got != want {
			t.Errorf("depth %q: credits %v (present %t), want %v", depth, got, ok, want)
		}
	}
}

func TestSearchErrors(t *testing.T) {
	_, ts := newTestServer(t, nil)
	cases := map[string]int{"[mock:400]": 400, "[mock:429]": 429, "[mock:432]": 432, "[mock:433]": 433, "[mock:434]": 434, "[mock:500]": 500}
	for marker, status := range cases {
		resp, out := call(t, ts, "/search", key, map[string]any{"query": "price " + marker})
		if resp.StatusCode != status {
			t.Errorf("%s: status %d", marker, resp.StatusCode)
		}
		if msg, _ := out["detail"].(map[string]any)["error"].(string); msg == "" {
			t.Errorf("%s: no detail.error", marker)
		}
		if (resp.Header.Get("Retry-After") != "") != (status == 429) {
			t.Errorf("%s: Retry-After=%q", marker, resp.Header.Get("Retry-After"))
		}
	}
	for name, body := range map[string]any{
		"missing query": map[string]any{},
		"bad depth":     map[string]any{"query": "q", "search_depth": "deep"},
		"bad max":       map[string]any{"query": "q", "max_results": 21},
		"mode only":     map[string]any{"query": "q", "include_domains_mode": "prefer"},
	} {
		if resp, _ := call(t, ts, "/search", key, body); resp.StatusCode != 400 {
			t.Errorf("%s: status %d", name, resp.StatusCode)
		}
	}
	resp, out := call(t, ts, "/search", key, map[string]any{"query": []string{"not", "a", "string"}})
	if detail, ok := out["detail"].([]any); resp.StatusCode != 422 || !ok || len(detail) != 1 {
		t.Errorf("type error: status %d body %v", resp.StatusCode, out)
	}
	resp, _ = call(t, ts, "/search", key, map[string]any{"query": "q", "include_domains": []string{"acme.example"}, "include_domains_mode": "prefer"})
	if resp.StatusCode != 200 {
		t.Errorf("prefer with domains: status %d", resp.StatusCode)
	}
}

func TestExtract(t *testing.T) {
	_, ts := newTestServer(t, fixtures)
	urls := []string{"https://a.example/1", "https://a.example/2", "https://a.example/mock-fail", "https://a.example/4", "https://a.example/5", "https://a.example/6", "https://a.example/7"}
	resp, out := call(t, ts, "/extract", key, map[string]any{"urls": urls, "include_usage": true})
	if resp.StatusCode != 200 {
		t.Fatalf("status %d %v", resp.StatusCode, out)
	}
	results, failed := out["results"].([]any), out["failed_results"].([]any)
	if len(results) != 6 || len(failed) != 1 {
		t.Errorf("results=%d failed=%d", len(results), len(failed))
	}
	if results[0].(map[string]any)["raw_content"] != "full page" {
		t.Errorf("fixture content = %v", results[0])
	}
	if got, _ := credits(t, out); got != 1 { // 6 successes: one full block of 5
		t.Errorf("basic credits = %v", got)
	}
	_, out = call(t, ts, "/extract", key, map[string]any{"urls": urls[:2], "include_usage": true})
	if got, _ := credits(t, out); got != 0 { // 8 total: no new block, reports 0
		t.Errorf("accruing credits = %v", got)
	}
	_, out = call(t, ts, "/extract", key, map[string]any{"urls": urls[:2], "extract_depth": "advanced", "include_usage": true})
	if got, _ := credits(t, out); got != 2 { // 10 total: second block, advanced rate
		t.Errorf("advanced block credits = %v", got)
	}
	_, out = call(t, ts, "/extract", key, map[string]any{"urls": "https://a.example/mock-fail", "include_usage": true})
	if got, _ := credits(t, out); got != 0 {
		t.Errorf("all-failed credits = %v", got)
	}
	for name, body := range map[string]any{
		"no urls":   map[string]any{"urls": []string{}},
		"too many":  map[string]any{"urls": make([]string, 21)},
		"bad depth": map[string]any{"urls": "https://a.example", "extract_depth": "deep"},
	} {
		if resp, _ := call(t, ts, "/extract", key, body); resp.StatusCode != 400 {
			t.Errorf("%s: status %d", name, resp.StatusCode)
		}
	}
}

func TestStatsAndReset(t *testing.T) {
	s, ts := newTestServer(t, nil)
	call(t, ts, "/search", key, map[string]any{"query": "q", "search_depth": "advanced"})
	call(t, ts, "/search", key, map[string]any{"query": "q [mock:500]"})
	call(t, ts, "/extract", key, map[string]any{"urls": "https://x.example"})
	if searches, extracts, credits := s.Stats(); searches != 1 || extracts != 1 || credits != 2 {
		t.Errorf("stats = %d %d %d (failed requests must not count)", searches, extracts, credits)
	}
	if resp, err := http.Post(ts.URL+"/_mock/reset", "", nil); err != nil || resp.StatusCode != 204 {
		t.Fatalf("reset: %v", err)
	}
	if a, b, c := s.Stats(); a+b+c != 0 {
		t.Errorf("after reset: %d %d %d", a, b, c)
	}
}

func TestUsageAndLastSeen(t *testing.T) {
	s := New(Config{APIKey: "k"})
	post := func(path, body string, hdr ...string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("POST", path, strings.NewReader(body))
		r.Header.Set("Authorization", "Bearer k")
		for i := 0; i+1 < len(hdr); i += 2 {
			r.Header.Set(hdr[i], hdr[i+1])
		}
		w := httptest.NewRecorder()
		s.ServeHTTP(w, r)
		return w
	}
	post("/search", `{"query":"q","include_usage":true,"search_depth":"advanced"}`, "X-Project-ID", "vk-a", "X-Session-Id", "hlr_1", "x-bf-vk", "leak")
	if got := s.Last(); got != (Seen{Path: "/search", ProjectID: "vk-a", SessionID: "hlr_1", VirtualKey: true, IncludeUsage: true}) {
		t.Errorf("last = %+v", got)
	}
	r := httptest.NewRequest("GET", "/usage", nil)
	r.Header.Set("Authorization", "Bearer k")
	w := httptest.NewRecorder()
	s.ServeHTTP(w, r)
	var u struct {
		Key struct {
			Usage int `json:"usage"`
		} `json:"key"`
	}
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &u) != nil || u.Key.Usage != 2 {
		t.Errorf("usage: %d %s", w.Code, w.Body)
	}
}
