// Package mocktavily is a deterministic stand-in for Tavily's Search and
// Extract APIs, used until live behaviour is recorded (Task 21).
//
// Shapes, defaults, costs and error texts follow Tavily's OpenAPI spec and
// docs as read on 2026-11-02 (see research/tavily-api-notes.md). Live calls on
// 2026-11-03 (testenv/results/tavily-live.json) confirmed: credits per depth,
// a repeated query billed again, a single-URL Extract at 0 credits, and the
// 401 message. They corrected max_results (values over 20 are accepted).
// Behaviour not yet observed live is marked as an assumption.
//
// Errors are injected by putting a marker in the search query:
//
//	[mock:400] [mock:429] [mock:432] [mock:433] [mock:434] [mock:500]
//
// and latency with [mock:slow-N], which delays the reply N ms (at most 5000);
// live searches took 1.1-2.8 s. /_mock/requests reports credits per X-Project-ID.
//
// A missing or wrong bearer key returns 401. Extract URLs containing
// "mock-fail" land in failed_results.
package mocktavily

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Config controls a Server.
type Config struct {
	// APIKey must arrive as "Authorization: Bearer <APIKey>". Required.
	APIKey string
	// Fixtures supplies canned results; nil means defaults only.
	Fixtures *Fixtures
}

// Fixtures holds canned results.
type Fixtures struct {
	// Search maps a normalised query (lowercase, trimmed) to its results.
	Search map[string][]Result `json:"search"`
	// Extract maps a URL to its raw_content.
	Extract map[string]string `json:"extract"`
}

// Result is one Search result.
type Result struct {
	Title         string  `json:"title"`
	URL           string  `json:"url"`
	Content       string  `json:"content"`
	Score         float64 `json:"score"`
	PublishedDate string  `json:"published_date,omitempty"`
}

// Server is an http.Handler. Safe for concurrent use.
type Server struct {
	cfg Config
	mux *http.ServeMux

	mu       sync.Mutex
	searches int
	extracts int
	credits  int
	// extracted counts successful URL extractions. Tavily bills Extract per 5
	// successful URLs across requests, so a single request can cost 0.
	extracted int
	// byProject sums credits per X-Project-ID ("" when absent), the tag Tavily
	// attributes usage to.
	byProject map[string]int
	// last is what the most recent authenticated request carried, so a test
	// can check what a relay forwards. Credential values are never kept.
	last Seen
}

// Seen describes the last authenticated request: the attribution headers
// Tavily reads, and whether caller credentials leaked through a relay.
type Seen struct {
	Path         string `json:"path"`
	ProjectID    string `json:"x_project_id"`
	SessionID    string `json:"x_session_id"`
	VirtualKey   bool   `json:"x_bf_vk_present"`   // a Bifrost virtual key reached the upstream
	APIKeyHeader bool   `json:"x_api_key_present"` // an X-Api-Key header reached the upstream
	IncludeUsage bool   `json:"include_usage"`
}

// New returns a Server for cfg.
func New(cfg Config) *Server {
	if cfg.Fixtures == nil {
		cfg.Fixtures = &Fixtures{}
	}
	s := &Server{cfg: cfg, mux: http.NewServeMux()}
	s.mux.HandleFunc("POST /search", s.authed(s.search))
	s.mux.HandleFunc("POST /extract", s.authed(s.extract))
	s.mux.HandleFunc("GET /usage", s.authed(s.usage))
	s.mux.HandleFunc("GET /_mock/requests", s.requests)
	s.mux.HandleFunc("POST /_mock/reset", s.reset)
	return s
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) { s.mux.ServeHTTP(w, r) }

func (s *Server) authed(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.cfg.APIKey == "" || r.Header.Get("Authorization") != "Bearer "+s.cfg.APIKey {
			writeError(w, http.StatusUnauthorized, "Unauthorized: missing or invalid API key.")
			return
		}
		s.mu.Lock()
		s.last = Seen{Path: r.URL.Path, ProjectID: r.Header.Get("X-Project-ID"), SessionID: r.Header.Get("X-Session-Id"),
			VirtualKey: r.Header.Get("x-bf-vk") != "", APIKeyHeader: r.Header.Get("X-Api-Key") != ""}
		s.mu.Unlock()
		next(w, r)
	}
}

// injected maps a query marker to the status and message Tavily documents.
var injected = map[string]struct {
	status int
	msg    string
}{
	"[mock:400]": {400, "Invalid request parameters."},
	"[mock:429]": {429, "Your request has been blocked due to excessive requests. Please reduce the rate of requests."},
	"[mock:432]": {432, "This request exceeds your plan's set usage limit. Please upgrade your plan or contact support."},
	"[mock:433]": {433, "This request exceeds the pay-as-you-go limit. You can increase your limit on the Tavily dashboard."},
	"[mock:434]": {434, "Live content fetching is temporarily unavailable on your plan due to high demand. Retry shortly, or omit max_age_hours/fetch_timeout to be served from cache."},
	"[mock:500]": {500, "Internal server error."},
}

var slowRe = regexp.MustCompile(`\[mock:slow-(\d{1,4})\]`)

// slowMarker returns the delay a [mock:slow-N] marker asks for, capped at 5 s.
func slowMarker(query string) time.Duration {
	m := slowRe.FindStringSubmatch(query)
	if m == nil {
		return 0
	}
	ms, _ := strconv.Atoi(m[1])
	return time.Duration(min(ms, 5000)) * time.Millisecond
}

var depthCredits = map[string]int{"basic": 1, "fast": 1, "ultra-fast": 1, "advanced": 2}

type searchRequest struct {
	Query              string   `json:"query"`
	SearchDepth        string   `json:"search_depth"`
	MaxResults         *int     `json:"max_results"`
	IncludeAnswer      any      `json:"include_answer"`
	IncludeUsage       bool     `json:"include_usage"`
	IncludeDomains     []string `json:"include_domains"`
	IncludeDomainsMode string   `json:"include_domains_mode"`
}

func (s *Server) search(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<20))
	if err != nil {
		writeError(w, http.StatusBadRequest, "Invalid request body.")
		return
	}
	var req searchRequest
	if err := json.Unmarshal(body, &req); err != nil {
		writeDecodeError(w, err)
		return
	}
	s.noteUsage(req.IncludeUsage)
	if d := slowMarker(req.Query); d > 0 {
		select {
		case <-time.After(d):
		case <-r.Context().Done():
			return
		}
	}
	if strings.TrimSpace(req.Query) == "" {
		writeError(w, http.StatusBadRequest, "Query is missing.")
		return
	}
	for marker, e := range injected {
		if strings.Contains(req.Query, marker) {
			if e.status == http.StatusTooManyRequests {
				w.Header().Set("Retry-After", "2")
			}
			writeError(w, e.status, e.msg)
			return
		}
	}
	depth := req.SearchDepth
	if depth == "" {
		depth = "basic"
	}
	credits, ok := depthCredits[depth]
	if !ok {
		writeError(w, http.StatusBadRequest, fmt.Sprintf("Invalid search_depth %q.", depth))
		return
	}
	if req.IncludeDomainsMode != "" && len(req.IncludeDomains) == 0 {
		writeError(w, http.StatusBadRequest, "include_domains_mode requires include_domains.")
		return
	}
	maxResults := 10 // OpenAPI default; the best-practices page says 5
	if req.MaxResults != nil {
		// The spec says 0-20, but live Tavily accepted 50 and returned 50
		// results for 1 credit (testenv/results/tavily-live.json, 3 Nov 2026),
		// so only a negative value is refused here (message assumed).
		if *req.MaxResults < 0 {
			writeError(w, http.StatusBadRequest, "max_results must not be negative.")
			return
		}
		maxResults = *req.MaxResults
	}

	results, ok := s.cfg.Fixtures.Search[normalise(req.Query)]
	if !ok {
		results = defaultResults(req.Query)
	}
	if len(results) > maxResults {
		results = results[:maxResults]
	}
	var answer any
	if b, isBool := req.IncludeAnswer.(bool); (isBool && b) || req.IncludeAnswer == "basic" || req.IncludeAnswer == "advanced" {
		answer = "Mock answer for: " + req.Query
	}

	s.record(r, &s.searches, credits)
	resp := map[string]any{
		"query":               req.Query,
		"follow_up_questions": nil,
		"answer":              answer,
		"images":              []any{},
		"results":             results,
		"response_time":       0.42,
		"request_id":          "mock-" + digest(body),
	}
	if req.IncludeUsage {
		resp["usage"] = map[string]int{"credits": credits}
	}
	writeJSON(w, http.StatusOK, resp)
}

type extractRequest struct {
	URLs         json.RawMessage `json:"urls"`
	ExtractDepth string          `json:"extract_depth"`
	IncludeUsage bool            `json:"include_usage"`
}

func (s *Server) extract(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<20))
	if err != nil {
		writeError(w, http.StatusBadRequest, "Invalid request body.")
		return
	}
	var req extractRequest
	if err := json.Unmarshal(body, &req); err != nil {
		writeDecodeError(w, err)
		return
	}
	s.noteUsage(req.IncludeUsage)
	urls, err := parseURLs(req.URLs)
	if err != nil || len(urls) == 0 || len(urls) > 20 {
		writeError(w, http.StatusBadRequest, "urls must be a URL or a list of 1 to 20 URLs.")
		return
	}
	perBlock := 1
	switch req.ExtractDepth {
	case "", "basic":
	case "advanced":
		perBlock = 2
	default:
		writeError(w, http.StatusBadRequest, fmt.Sprintf("Invalid extract_depth %q.", req.ExtractDepth))
		return
	}

	results := []any{}
	failed := []any{}
	for _, u := range urls {
		if strings.Contains(u, "mock-fail") {
			failed = append(failed, map[string]any{"url": u, "error": "Failed to fetch url"})
			continue
		}
		content, ok := s.cfg.Fixtures.Extract[u]
		if !ok {
			content = "Mock page content for " + u
		}
		results = append(results, map[string]any{"url": u, "raw_content": content, "images": []any{}})
	}
	// Per the docs, every 5 successful extractions cost one block, accrued
	// across requests. Assumption until observed live: accrual is per key.
	s.mu.Lock()
	before := s.extracted
	s.extracted += len(results)
	credits := (s.extracted/5 - before/5) * perBlock
	s.mu.Unlock()

	s.record(r, &s.extracts, credits)
	resp := map[string]any{
		"results":        results,
		"failed_results": failed,
		"response_time":  0.42,
		"request_id":     "mock-" + digest(body),
	}
	if req.IncludeUsage {
		resp["usage"] = map[string]int{"credits": credits}
	}
	writeJSON(w, http.StatusOK, resp)
}

func parseURLs(raw json.RawMessage) ([]string, error) {
	var one string
	if json.Unmarshal(raw, &one) == nil {
		if one == "" {
			return nil, nil
		}
		return []string{one}, nil
	}
	var many []string
	err := json.Unmarshal(raw, &many)
	return many, err
}

func defaultResults(query string) []Result {
	slug := digest([]byte(normalise(query)))
	return []Result{
		{Title: "Mock source A", URL: "https://example.com/a/" + slug, Content: "Mock evidence A about: " + query, Score: 0.81},
		{Title: "Mock source B", URL: "https://example.org/b/" + slug, Content: "Mock evidence B about: " + query, Score: 0.64},
	}
}

// Stats reports requests and credits since the last reset.
func (s *Server) Stats() (searches, extracts, credits int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.searches, s.extracts, s.credits
}

func (s *Server) record(r *http.Request, counter *int, credits int) {
	s.mu.Lock()
	*counter++
	s.credits += credits
	if s.byProject == nil {
		s.byProject = map[string]int{}
	}
	s.byProject[r.Header.Get("X-Project-ID")] += credits
	s.mu.Unlock()
}

// CreditsByProject reports credits per X-Project-ID since the last reset.
func (s *Server) CreditsByProject() map[string]int {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make(map[string]int, len(s.byProject))
	for k, v := range s.byProject {
		out[k] = v
	}
	return out
}

// usage mirrors GET /usage (free): the key's credits used, by product. The
// mock has one key on one plan, so key and account totals coincide.
func (s *Server) usage(w http.ResponseWriter, _ *http.Request) {
	s.mu.Lock()
	credits := s.credits
	s.mu.Unlock()
	writeJSON(w, http.StatusOK, map[string]any{
		"key":     map[string]any{"usage": credits, "limit": nil},
		"account": map[string]any{"current_plan": "Mock", "plan_usage": credits, "plan_limit": 9000, "paygo_usage": 0, "paygo_limit": nil},
	})
}

func (s *Server) noteUsage(on bool) {
	s.mu.Lock()
	s.last.IncludeUsage = on
	s.mu.Unlock()
}

// Last returns what the most recent authenticated request carried.
func (s *Server) Last() Seen {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.last
}

func (s *Server) requests(w http.ResponseWriter, _ *http.Request) {
	searches, extracts, credits := s.Stats()
	writeJSON(w, http.StatusOK, map[string]any{"searches": searches, "extracts": extracts, "credits": credits,
		"credits_by_project": s.CreditsByProject(), "last": s.Last()})
}

func (s *Server) reset(w http.ResponseWriter, _ *http.Request) {
	s.mu.Lock()
	s.searches, s.extracts, s.credits, s.extracted = 0, 0, 0, 0
	s.byProject = nil
	s.last = Seen{}
	s.mu.Unlock()
	w.WriteHeader(http.StatusNoContent)
}

func normalise(q string) string { return strings.ToLower(strings.TrimSpace(q)) }

func digest(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:8])
}

// writeDecodeError mirrors Tavily: type mismatches are 422 with a detail
// array; malformed JSON is 400.
func writeDecodeError(w http.ResponseWriter, err error) {
	var typeErr *json.UnmarshalTypeError
	if errors.As(err, &typeErr) {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"detail": []any{map[string]any{
			"type": typeErr.Value + "_type", "loc": []string{"body", typeErr.Field}, "msg": "Input should be a valid " + typeErr.Type.String(),
		}}})
		return
	}
	writeError(w, http.StatusBadRequest, "Invalid JSON body.")
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]any{"detail": map[string]string{"error": msg}})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
