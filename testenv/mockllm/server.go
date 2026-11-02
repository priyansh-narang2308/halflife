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
// whitespace); anything else gets a fixed echo reply. Response IDs are derived
// from the request body, so identical requests produce byte-identical bodies.
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
}

// Server is an http.Handler. Safe for concurrent use.
type Server struct {
	cfg Config
	mux *http.ServeMux

	mu      sync.Mutex
	total   int
	byModel map[string]int
}

// New returns a Server for cfg.
func New(cfg Config) *Server {
	s := &Server{cfg: cfg, mux: http.NewServeMux(), byModel: map[string]int{}}
	s.mux.HandleFunc("POST /v1/chat/completions", s.chatCompletions)
	s.mux.HandleFunc("POST /v1/embeddings", s.embeddings)
	s.mux.HandleFunc("GET /v1/models", s.models)
	s.mux.HandleFunc("GET /_mock/requests", s.requests)
	s.mux.HandleFunc("POST /_mock/reset", s.reset)
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

	b := parseModel(req.Model)
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

func (s *Server) requests(w http.ResponseWriter, _ *http.Request) {
	total, byModel := s.Counts()
	writeJSON(w, http.StatusOK, map[string]any{"total": total, "by_model": byModel})
}

func (s *Server) reset(w http.ResponseWriter, _ *http.Request) {
	s.mu.Lock()
	s.total = 0
	s.byModel = map[string]int{}
	s.mu.Unlock()
	w.WriteHeader(http.StatusNoContent)
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
