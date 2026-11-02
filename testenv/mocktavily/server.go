// Package mocktavily is a deterministic stand-in for Tavily's Search and
// Extract APIs, used until live behaviour is recorded (Task 21).
//
// Response shapes follow Tavily's public API reference. Fields we have not yet
// observed live (notably usage.credits and Extract's per-request credit
// rounding) are assumptions and must be reconciled against real responses.
//
// Errors are injected by putting a marker in the search query:
//
//	[mock:400] [mock:429] [mock:432] [mock:433] [mock:434] [mock:500]
//
// A missing or wrong bearer key returns 401. Extract URLs containing
// "mock-fail" land in failed_results.
package mocktavily

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
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
}

// New returns a Server for cfg.
func New(cfg Config) *Server {
	if cfg.Fixtures == nil {
		cfg.Fixtures = &Fixtures{}
	}
	s := &Server{cfg: cfg, mux: http.NewServeMux()}
	s.mux.HandleFunc("POST /search", s.authed(s.search))
	s.mux.HandleFunc("POST /extract", s.authed(s.extract))
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
	"[mock:434]": {434, "Live fetch capacity is unavailable for your plan right now. Retry without max_age_hours or later."},
	"[mock:500]": {500, "Internal server error."},
}

var depthCredits = map[string]int{"basic": 1, "fast": 1, "ultra-fast": 1, "advanced": 2}

type searchRequest struct {
	Query         string `json:"query"`
	SearchDepth   string `json:"search_depth"`
	MaxResults    *int   `json:"max_results"`
	IncludeAnswer any    `json:"include_answer"`
	IncludeUsage  bool   `json:"include_usage"`
}

func (s *Server) search(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<20))
	if err != nil {
		writeError(w, http.StatusBadRequest, "Invalid request body.")
		return
	}
	var req searchRequest
	if err := json.Unmarshal(body, &req); err != nil {
		writeError(w, http.StatusBadRequest, "Invalid JSON body.")
		return
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
	maxResults := 5
	if req.MaxResults != nil {
		if *req.MaxResults < 0 || *req.MaxResults > 20 {
			writeError(w, http.StatusBadRequest, "max_results must be between 0 and 20.")
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

	s.record(&s.searches, credits)
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
		writeError(w, http.StatusBadRequest, "Invalid JSON body.")
		return
	}
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
	// Assumption until observed live: one credit block per 5 successful URLs, rounded up.
	credits := (len(results) + 4) / 5 * perBlock

	s.record(&s.extracts, credits)
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

func (s *Server) record(counter *int, credits int) {
	s.mu.Lock()
	*counter++
	s.credits += credits
	s.mu.Unlock()
}

func (s *Server) requests(w http.ResponseWriter, _ *http.Request) {
	searches, extracts, credits := s.Stats()
	writeJSON(w, http.StatusOK, map[string]int{"searches": searches, "extracts": extracts, "credits": credits})
}

func (s *Server) reset(w http.ResponseWriter, _ *http.Request) {
	s.mu.Lock()
	s.searches, s.extracts, s.credits = 0, 0, 0
	s.mu.Unlock()
	w.WriteHeader(http.StatusNoContent)
}

func normalise(q string) string { return strings.ToLower(strings.TrimSpace(q)) }

func digest(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:8])
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]any{"detail": map[string]string{"error": msg}})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
