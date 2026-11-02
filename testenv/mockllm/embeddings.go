package mockllm

import (
	"encoding/json"
	"hash/fnv"
	"math"
	"net/http"
	"strings"
	"unicode"
)

// EmbeddingDimension is the length of every mock embedding.
const EmbeddingDimension = 64

// stopWords carry no topic, so they are left out of embeddings. Without this,
// "How much does X cost?" and "What does X cost?" would differ mostly by
// function words.
var stopWords = map[string]bool{
	"a": true, "an": true, "and": true, "are": true, "as": true, "at": true, "be": true, "by": true,
	"do": true, "does": true, "for": true, "from": true, "has": true, "have": true, "how": true,
	"in": true, "is": true, "it": true, "its": true, "much": true, "of": true, "on": true, "or": true,
	"the": true, "this": true, "to": true, "was": true, "what": true, "when": true, "which": true,
	"who": true, "why": true, "with": true,
}

// Embed returns a deterministic unit vector for text: a hashed bag of its
// content words. Texts sharing most content words have high cosine similarity
// ("How much does the Acme Cloud Pro plan cost?" vs "What does Acme Cloud Pro
// cost?" ≈ 0.89); texts sharing few have low similarity. It stands in for a
// real embedding model so semantic caching can be tested offline. Text with
// no content words embeds to a fixed vector rather than to zero, because a
// zero vector has no cosine similarity.
func Embed(text string) []float32 {
	v := make([]float64, EmbeddingDimension)
	words := strings.FieldsFunc(strings.ToLower(text), func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsDigit(r) })
	for _, w := range words {
		if stopWords[w] {
			continue
		}
		h := fnv.New64a()
		h.Write([]byte(w))
		sum := h.Sum64()
		sign := 1.0
		if sum>>63 == 1 {
			sign = -1
		}
		v[sum%EmbeddingDimension] += sign
	}
	var norm float64
	for _, x := range v {
		norm += x * x
	}
	out := make([]float32, EmbeddingDimension)
	if norm == 0 {
		out[0] = 1
		return out
	}
	norm = math.Sqrt(norm)
	for i, x := range v {
		out[i] = float32(x / norm)
	}
	return out
}

type embeddingRequest struct {
	Model string          `json:"model"`
	Input json.RawMessage `json:"input"`
}

// embeddings serves POST /v1/embeddings for a string or an array of strings.
// Any model name is accepted; the model name decides failures and latency
// exactly as for chat.
func (s *Server) embeddings(w http.ResponseWriter, r *http.Request) {
	if s.cfg.APIKey != "" && r.Header.Get("Authorization") != "Bearer "+s.cfg.APIKey {
		writeError(w, http.StatusUnauthorized, "invalid_api_key", "mock: missing or invalid API key")
		return
	}
	body, err := readBody(w, r)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", "mock: unreadable body")
		return
	}
	var req embeddingRequest
	var inputs []string
	if err := json.Unmarshal(body, &req); err == nil && req.Model != "" {
		var one string
		if json.Unmarshal(req.Input, &one) == nil {
			inputs = []string{one}
		} else {
			_ = json.Unmarshal(req.Input, &inputs)
		}
	}
	if len(inputs) == 0 {
		writeError(w, http.StatusBadRequest, "invalid_request", "mock: body must have model and a string or string-array input")
		return
	}
	s.count(req.Model)
	if b := parseModel(req.Model); b.failStatus != 0 {
		writeError(w, b.failStatus, "mock_injected_failure", "mock: injected failure for model "+req.Model)
		return
	}

	data := make([]any, len(inputs))
	tokens := 0
	for i, in := range inputs {
		data[i] = map[string]any{"object": "embedding", "index": i, "embedding": Embed(in)}
		tokens += wordCount(in)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"object": "list",
		"data":   data,
		"model":  req.Model,
		"usage":  map[string]int{"prompt_tokens": tokens, "total_tokens": tokens},
	})
}
