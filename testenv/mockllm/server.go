// Package mockllm is a deterministic OpenAI-compatible chat and embeddings
// provider for exercising Bifrost's real provider path: attempts, failures,
// fallbacks, latency, streaming and (via /v1/embeddings, see Embed) semantic
// caching.
//
// Behaviour is selected by the model name the gateway forwards:
//
//	ok, or any unrecognised name   200 with a scripted reply
//	slow-<ms>                      200 after <ms> milliseconds
//	fail-<status>                  error response with that HTTP status
//
// Replies are looked up by the last user message (exact match after trimming
// whitespace). A request whose response_format names a JSON schema listed in
// SchemaReplies gets the reply of the longest key its last user message
// contains, so a structured prompt need not be copied whole. Anything else
// gets a fixed echo reply. Response IDs are derived
// from the request body, so identical requests produce byte-identical bodies.
//
// POST /_mock/outage {"model":"m","status":503} makes every request for model m
// fail with that status until a status of 0 clears it, as a provider going down
// mid-run would.
package mockllm

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Created is the fixed "created" timestamp in every response.
const Created = 1793491200 // 2026-11-01T00:00:00Z

// Config controls a Server.
type Config struct {
	// APIKey, when set, must arrive as "Authorization: Bearer <APIKey>".
	APIKey string
	// Replies maps a trimmed last user message to the assistant reply.
	Replies map[string]string
	// SchemaReplies maps a json_schema name to replies keyed by a substring
	// of the last user message.
	SchemaReplies map[string]map[string]string
}

// Server is an http.Handler. Safe for concurrent use.
type Server struct {
	cfg Config
	mux *http.ServeMux

	mu         sync.Mutex
	total      int
	byModel    map[string]int
	lastFormat string // response_format of the last request: "", "json_object" or "json_schema:<name>[:strict]"
	outages    map[string]int // model -> status it fails with
}

// New returns a Server for cfg.
func New(cfg Config) *Server {
	s := &Server{cfg: cfg, mux: http.NewServeMux(), byModel: map[string]int{}, outages: map[string]int{}}
	s.mux.HandleFunc("POST /v1/chat/completions", s.chatCompletions)
	s.mux.HandleFunc("POST /v1/embeddings", s.embeddings)
	s.mux.HandleFunc("GET /v1/models", s.models)
	s.mux.HandleFunc("GET /_mock/requests", s.requests)
	s.mux.HandleFunc("POST /_mock/reset", s.reset)
	s.mux.HandleFunc("POST /_mock/outage", s.outage)
	return s
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) { s.mux.ServeHTTP(w, r) }

type message struct {
	Role    string          `json:"role"`
	Content json.RawMessage `json:"content"`
}

type chatRequest struct {
	Model         string    `json:"model"`
	Messages      []message `json:"messages"`
	Stream        bool      `json:"stream"`
	StreamOptions *struct {
		IncludeUsage bool `json:"include_usage"`
	} `json:"stream_options"`
	ResponseFormat *struct {
		Type       string `json:"type"`
		JSONSchema *struct {
			Name   string `json:"name"`
			Strict bool   `json:"strict"`
		} `json:"json_schema"`
	} `json:"response_format"`
}

// behaviour is what a model name asks the mock to do.
type behaviour struct {
	failStatus int
	latency    time.Duration
}

func parseModel(model string) behaviour {
	if code, ok := strings.CutPrefix(model, "fail-"); ok {
		if n, err := strconv.Atoi(code); err == nil && n >= 400 && n <= 599 {
			return behaviour{failStatus: n}
		}
	}
	if ms, ok := strings.CutPrefix(model, "slow-"); ok {
		if n, err := strconv.Atoi(ms); err == nil && n >= 0 {
			return behaviour{latency: time.Duration(n) * time.Millisecond}
		}
	}
	return behaviour{}
}

func (s *Server) chatCompletions(w http.ResponseWriter, r *http.Request) {
	if s.cfg.APIKey != "" && r.Header.Get("Authorization") != "Bearer "+s.cfg.APIKey {
		writeError(w, http.StatusUnauthorized, "invalid_api_key", "mock: missing or invalid API key")
		return
	}
	body, err := readBody(w, r)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", "mock: unreadable body")
		return
	}
	var req chatRequest
	if err := json.Unmarshal(body, &req); err != nil || req.Model == "" || len(req.Messages) == 0 {
		writeError(w, http.StatusBadRequest, "invalid_request", "mock: body must have model and messages")
		return
	}
	s.count(req.Model)
	s.setFormat(formatLabel(req))

	b := parseModel(req.Model)
	s.mu.Lock()
	if status := s.outages[req.Model]; status != 0 {
		b.failStatus = status
	}
	s.mu.Unlock()
	if b.latency > 0 {
		select {
		case <-time.After(b.latency):
		case <-r.Context().Done():
			return
		}
	}
	if b.failStatus != 0 {
		if b.failStatus == http.StatusTooManyRequests {
			w.Header().Set("Retry-After", "1")
		}
		writeError(w, b.failStatus, "mock_injected_failure", fmt.Sprintf("mock: injected %d for model %s", b.failStatus, req.Model))
		return
	}

	prompt := lastUserText(req.Messages)
	reply, ok := s.cfg.Replies[strings.TrimSpace(prompt)]
	if f := req.ResponseFormat; f != nil && f.JSONSchema != nil {
		if r, found := containedReply(s.cfg.SchemaReplies[f.JSONSchema.Name], prompt); found {
			reply, ok = r, true
		}
	}
	if !ok {
		reply = "Mock reply to: " + strings.TrimSpace(prompt)
	}
	id := "chatcmpl-mock-" + digest(body)
	usage := map[string]int{
		"prompt_tokens":     promptTokens(req.Messages),
		"completion_tokens": wordCount(reply),
	}
	usage["total_tokens"] = usage["prompt_tokens"] + usage["completion_tokens"]

	if req.Stream {
		includeUsage := req.StreamOptions != nil && req.StreamOptions.IncludeUsage
		streamReply(w, id, req.Model, reply, usage, includeUsage)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"id":      id,
		"object":  "chat.completion",
		"created": Created,
		"model":   req.Model,
		"choices": []any{map[string]any{
			"index":         0,
			"message":       map[string]any{"role": "assistant", "content": reply},
			"finish_reason": "stop",
		}},
		"usage": usage,
	})
}

func streamReply(w http.ResponseWriter, id, model, reply string, usage map[string]int, includeUsage bool) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.WriteHeader(http.StatusOK)
	flusher, _ := w.(http.Flusher)
	send := func(v any) {
		b, _ := json.Marshal(v)
		fmt.Fprintf(w, "data: %s\n\n", b)
		if flusher != nil {
			flusher.Flush()
		}
	}
	chunk := func(delta map[string]any, finish any) map[string]any {
		return map[string]any{
			"id": id, "object": "chat.completion.chunk", "created": Created, "model": model,
			"choices": []any{map[string]any{"index": 0, "delta": delta, "finish_reason": finish}},
		}
	}

	send(chunk(map[string]any{"role": "assistant", "content": ""}, nil))
	for i, word := range strings.Fields(reply) {
		if i > 0 {
			word = " " + word
		}
		send(chunk(map[string]any{"content": word}, nil))
	}
	send(chunk(map[string]any{}, "stop"))
	if includeUsage {
		send(map[string]any{
			"id": id, "object": "chat.completion.chunk", "created": Created, "model": model,
			"choices": []any{}, "usage": usage,
		})
	}
	fmt.Fprint(w, "data: [DONE]\n\n")
	if flusher != nil {
		flusher.Flush()
	}
}

func (s *Server) models(w http.ResponseWriter, _ *http.Request) {
	ids := []string{"ok", "slow-250", "fail-500", "fail-503", "fail-429", "mock-embed"}
	data := make([]any, len(ids))
	for i, id := range ids {
		data[i] = map[string]any{"id": id, "object": "model", "created": Created, "owned_by": "halflife-mock"}
	}
	writeJSON(w, http.StatusOK, map[string]any{"object": "list", "data": data})
}

// Counts reports requests received since the last reset.
func (s *Server) Counts() (total int, byModel map[string]int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	byModel = make(map[string]int, len(s.byModel))
	for k, v := range s.byModel {
		byModel[k] = v
	}
	return s.total, byModel
}

func (s *Server) count(model string) {
	s.mu.Lock()
	s.total++
	s.byModel[model]++
	s.mu.Unlock()
}

func (s *Server) setFormat(format string) {
	s.mu.Lock()
	s.lastFormat = format
	s.mu.Unlock()
}

// formatLabel summarises a request's response_format; the provider is what
// enforces it, so the mock only records what the gateway forwarded.
func formatLabel(req chatRequest) string {
	f := req.ResponseFormat
	if f == nil {
		return ""
	}
	if f.Type != "json_schema" || f.JSONSchema == nil {
		return f.Type
	}
	label := "json_schema:" + f.JSONSchema.Name
	if f.JSONSchema.Strict {
		label += ":strict"
	}
	return label
}

// LastResponseFormat reports the response_format label of the last request.
func (s *Server) LastResponseFormat() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.lastFormat
}

func (s *Server) requests(w http.ResponseWriter, _ *http.Request) {
	total, byModel := s.Counts()
	writeJSON(w, http.StatusOK, map[string]any{"total": total, "by_model": byModel, "last_response_format": s.LastResponseFormat()})
}

func (s *Server) outage(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Model  string `json:"model"`
		Status int    `json:"status"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Model == "" || (req.Status != 0 && (req.Status < 400 || req.Status > 599)) {
		writeError(w, http.StatusBadRequest, "invalid_request", "mock: outage needs a model and a status of 0 or 400-599")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if req.Status == 0 {
		delete(s.outages, req.Model)
	} else {
		s.outages[req.Model] = req.Status
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) reset(w http.ResponseWriter, _ *http.Request) {
	s.mu.Lock()
	s.total = 0
	s.byModel = map[string]int{}
	s.outages = map[string]int{}
	s.lastFormat = ""
	s.mu.Unlock()
	w.WriteHeader(http.StatusNoContent)
}

// containedReply returns the reply of the longest key prompt contains.
func containedReply(replies map[string]string, prompt string) (string, bool) {
	best, reply := "", ""
	for key, r := range replies {
		if strings.Contains(prompt, key) && len(key) > len(best) {
			best, reply = key, r
		}
	}
	return reply, best != ""
}

// lastUserText returns the text of the last user message. Content may be a
// string or an array of {type:"text", text:...} parts.
func lastUserText(msgs []message) string {
	for i := len(msgs) - 1; i >= 0; i-- {
		if msgs[i].Role == "user" {
			return contentText(msgs[i].Content)
		}
	}
	return ""
}

func contentText(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var parts []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if json.Unmarshal(raw, &parts) == nil {
		texts := make([]string, 0, len(parts))
		for _, p := range parts {
			if p.Type == "text" {
				texts = append(texts, p.Text)
			}
		}
		return strings.Join(texts, "\n")
	}
	return ""
}

func promptTokens(msgs []message) int {
	n := 0
	for _, m := range msgs {
		n += wordCount(contentText(m.Content))
	}
	return n
}

func wordCount(s string) int { return len(strings.Fields(s)) }

func digest(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:8])
}

func readBody(w http.ResponseWriter, r *http.Request) ([]byte, error) {
	return io.ReadAll(http.MaxBytesReader(w, r.Body, 4<<20))
}

func writeError(w http.ResponseWriter, status int, code, msg string) {
	errType := "server_error"
	if status < 500 {
		errType = "invalid_request_error"
	}
	writeJSON(w, status, map[string]any{"error": map[string]any{"message": msg, "type": errType, "code": code}})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
