package mockllm

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
)

func newTestServer(t *testing.T, cfg Config) (*Server, *httptest.Server) {
	t.Helper()
	s := New(cfg)
	ts := httptest.NewServer(s)
	t.Cleanup(ts.Close)
	return s, ts
}

func post(t *testing.T, ts *httptest.Server, body string, header map[string]string) (*http.Response, []byte) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	for k, v := range header {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp, b
}

func chat(model, prompt string) string {
	b, _ := json.Marshal(map[string]any{
		"model":    model,
		"messages": []any{map[string]any{"role": "system", "content": "be brief"}, map[string]any{"role": "user", "content": prompt}},
	})
	return string(b)
}

type completion struct {
	ID      string `json:"id"`
	Created int64  `json:"created"`
	Model   string `json:"model"`
	Choices []struct {
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
		FinishReason string `json:"finish_reason"`
	} `json:"choices"`
	Usage struct {
		PromptTokens     int `json:"prompt_tokens"`
		CompletionTokens int `json:"completion_tokens"`
		TotalTokens      int `json:"total_tokens"`
	} `json:"usage"`
}

func decode(t *testing.T, b []byte) completion {
	t.Helper()
	var c completion
	if err := json.Unmarshal(b, &c); err != nil {
		t.Fatalf("decode %s: %v", b, err)
	}
	return c
}

func TestScriptedAndDefaultReplies(t *testing.T) {
	_, ts := newTestServer(t, Config{Replies: map[string]string{"What is X?": "X is 42."}})

	resp, b := post(t, ts, chat("ok", "  What is X?  "), nil)
	if resp.StatusCode != 200 {
		t.Fatalf("status %d: %s", resp.StatusCode, b)
	}
	c := decode(t, b)
	if got := c.Choices[0].Message.Content; got != "X is 42." {
		t.Errorf("scripted reply = %q", got)
	}
	if c.Choices[0].FinishReason != "stop" || c.Created != Created || c.Model != "ok" {
		t.Errorf("unexpected envelope: %+v", c)
	}
	if c.Usage.CompletionTokens != 3 || c.Usage.TotalTokens != c.Usage.PromptTokens+3 {
		t.Errorf("usage = %+v", c.Usage)
	}

	_, b = post(t, ts, chat("anything-else", "Unscripted question"), nil)
	if got := decode(t, b).Choices[0].Message.Content; got != "Mock reply to: Unscripted question" {
		t.Errorf("default reply = %q", got)
	}
}

func TestDeterministicBodies(t *testing.T) {
	_, ts := newTestServer(t, Config{})
	_, a := post(t, ts, chat("ok", "same"), nil)
	_, b := post(t, ts, chat("ok", "same"), nil)
	_, c := post(t, ts, chat("ok", "different"), nil)
	if !bytes.Equal(a, b) {
		t.Errorf("identical requests gave different bodies:\n%s\n%s", a, b)
	}
	if decode(t, a).ID == decode(t, c).ID {
		t.Error("different requests share an id")
	}
}

func TestContentParts(t *testing.T) {
	_, ts := newTestServer(t, Config{Replies: map[string]string{"part one\npart two": "joined"}})
	body := `{"model":"ok","messages":[{"role":"user","content":[{"type":"text","text":"part one"},{"type":"image_url","image_url":{"url":"x"}},{"type":"text","text":"part two"}]}]}`
	_, b := post(t, ts, body, nil)
	if got := decode(t, b).Choices[0].Message.Content; got != "joined" {
		t.Errorf("content parts reply = %q", got)
	}
}

func TestInjectedFailures(t *testing.T) {
	_, ts := newTestServer(t, Config{})
	for _, status := range []int{400, 429, 500, 503} {
		model := "fail-" + strconv.Itoa(status)
		resp, b := post(t, ts, chat(model, "q"), nil)
		if resp.StatusCode != status {
			t.Errorf("%s: status %d", model, resp.StatusCode)
		}
		var e struct {
			Error struct{ Message, Type, Code string } `json:"error"`
		}
		if json.Unmarshal(b, &e) != nil || e.Error.Code != "mock_injected_failure" {
			t.Errorf("%s: error body %s", model, b)
		}
		if status == 429 && resp.Header.Get("Retry-After") != "1" {
			t.Errorf("429 without Retry-After")
		}
	}
}

func TestLatency(t *testing.T) {
	_, ts := newTestServer(t, Config{})
	start := time.Now()
	resp, _ := post(t, ts, chat("slow-120", "q"), nil)
	if elapsed := time.Since(start); resp.StatusCode != 200 || elapsed < 120*time.Millisecond {
		t.Errorf("slow-120: status %d after %v", resp.StatusCode, elapsed)
	}
}

func TestStreaming(t *testing.T) {
	_, ts := newTestServer(t, Config{Replies: map[string]string{"q": "one two three"}})
	body := `{"model":"ok","stream":true,"stream_options":{"include_usage":true},"messages":[{"role":"user","content":"q"}]}`
	resp, b := post(t, ts, body, nil)
	if resp.StatusCode != 200 || !strings.HasPrefix(resp.Header.Get("Content-Type"), "text/event-stream") {
		t.Fatalf("status %d type %q", resp.StatusCode, resp.Header.Get("Content-Type"))
	}
	var text strings.Builder
	var sawStop, sawUsage, sawDone bool
	sc := bufio.NewScanner(bytes.NewReader(b))
	for sc.Scan() {
		data, ok := strings.CutPrefix(sc.Text(), "data: ")
		if !ok {
			continue
		}
		if data == "[DONE]" {
			sawDone = true
			continue
		}
		var chunk struct {
			Choices []struct {
				Delta        struct{ Content string } `json:"delta"`
				FinishReason *string                  `json:"finish_reason"`
			} `json:"choices"`
			Usage *struct {
				CompletionTokens int `json:"completion_tokens"`
			} `json:"usage"`
		}
		if err := json.Unmarshal([]byte(data), &chunk); err != nil {
			t.Fatalf("bad chunk %q: %v", data, err)
		}
		for _, c := range chunk.Choices {
			text.WriteString(c.Delta.Content)
			if c.FinishReason != nil && *c.FinishReason == "stop" {
				sawStop = true
			}
		}
		if chunk.Usage != nil && chunk.Usage.CompletionTokens == 3 {
			sawUsage = true
		}
	}
	if text.String() != "one two three" || !sawStop || !sawUsage || !sawDone {
		t.Errorf("stream text=%q stop=%t usage=%t done=%t", text.String(), sawStop, sawUsage, sawDone)
	}
}

func TestAuthAndValidation(t *testing.T) {
	_, ts := newTestServer(t, Config{APIKey: "sk-mock"})
	if resp, _ := post(t, ts, chat("ok", "q"), nil); resp.StatusCode != 401 {
		t.Errorf("no key: status %d", resp.StatusCode)
	}
	if resp, _ := post(t, ts, chat("ok", "q"), map[string]string{"Authorization": "Bearer wrong"}); resp.StatusCode != 401 {
		t.Errorf("wrong key: status %d", resp.StatusCode)
	}
	auth := map[string]string{"Authorization": "Bearer sk-mock"}
	if resp, _ := post(t, ts, chat("ok", "q"), auth); resp.StatusCode != 200 {
		t.Errorf("right key: status %d", resp.StatusCode)
	}
	if resp, _ := post(t, ts, `{"model":"ok","messages":[]}`, auth); resp.StatusCode != 400 {
		t.Errorf("empty messages: status %d", resp.StatusCode)
	}
}

func TestCountsAndReset(t *testing.T) {
	s, ts := newTestServer(t, Config{})
	post(t, ts, chat("ok", "a"), nil)
	post(t, ts, chat("fail-500", "a"), nil)
	post(t, ts, chat("fail-500", "b"), nil)
	if total, by := s.Counts(); total != 3 || by["ok"] != 1 || by["fail-500"] != 2 {
		t.Errorf("counts total=%d by=%v", total, by)
	}
	resp, err := http.Post(ts.URL+"/_mock/reset", "", nil)
	if err != nil || resp.StatusCode != 204 {
		t.Fatalf("reset: %v %v", err, resp)
	}
	if total, _ := s.Counts(); total != 0 {
		t.Errorf("after reset total=%d", total)
	}
}

func TestModelsList(t *testing.T) {
	_, ts := newTestServer(t, Config{})
	resp, err := http.Get(ts.URL + "/v1/models")
	if err != nil || resp.StatusCode != 200 {
		t.Fatalf("models: %v %v", err, resp)
	}
	var list struct {
		Data []struct{ ID string } `json:"data"`
	}
	json.NewDecoder(resp.Body).Decode(&list)
	if len(list.Data) == 0 || list.Data[0].ID != "ok" {
		t.Errorf("models = %+v", list)
	}
}
