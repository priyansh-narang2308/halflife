package mockllm

import (
	"encoding/json"
	"io"
	"math"
	"net/http"
	"strings"
	"testing"
)

func cosine(a, b []float32) float64 {
	var dot, na, nb float64
	for i := range a {
		dot += float64(a[i]) * float64(b[i])
		na += float64(a[i]) * float64(a[i])
		nb += float64(b[i]) * float64(b[i])
	}
	return dot / math.Sqrt(na*nb)
}

// The similarities the semantic cache tests rely on, at its default 0.8 threshold.
func TestEmbedSimilarity(t *testing.T) {
	q := "How much does the Acme Cloud Pro plan cost?"
	for _, tc := range []struct {
		other    string
		min, max float64
	}{
		{"How much does the Acme Cloud Pro plan cost?", 0.9999, 1.0001},
		{"how much does the acme cloud pro plan cost", 0.9999, 1.0001}, // case and punctuation
		{"What does the Acme Cloud Pro plan cost?", 0.9999, 1.0001},    // only stop words differ
		{"What does Acme Cloud Pro cost?", 0.85, 0.95},                 // paraphrase
		{"Who is the CEO of Acme Cloud?", -1, 0.6},                     // related topic, different question
		{"What is the latest version of the Acme SDK?", -1, 0.5},
	} {
		got := cosine(Embed(q), Embed(tc.other))
		if got < tc.min || got > tc.max {
			t.Errorf("cos(%q) = %.3f, want [%.2f, %.2f]", tc.other, got, tc.min, tc.max)
		}
	}
}

func TestEmbedIsUnitLengthAndDeterministic(t *testing.T) {
	for _, s := range []string{"Acme Cloud", "the of a", ""} {
		v := Embed(s)
		if len(v) != EmbeddingDimension {
			t.Fatalf("len = %d", len(v))
		}
		if n := cosine(v, v); math.Abs(n-1) > 1e-6 {
			t.Errorf("%q: not usable for cosine (%v)", s, n)
		}
		var norm float64
		for _, x := range v {
			norm += float64(x) * float64(x)
		}
		if math.Abs(norm-1) > 1e-5 {
			t.Errorf("%q: |v|² = %v", s, norm)
		}
		if w := Embed(s); cosine(v, w) != cosine(v, v) {
			t.Errorf("%q: not deterministic", s)
		}
	}
}

func embedPost(t *testing.T, url, body, key string) (int, []byte) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, url+"/v1/embeddings", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	if key != "" {
		req.Header.Set("Authorization", "Bearer "+key)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, b
}

func TestEmbeddingsEndpoint(t *testing.T) {
	s, ts := newTestServer(t, Config{APIKey: "k"})
	var got struct {
		Object string `json:"object"`
		Model  string `json:"model"`
		Data   []struct {
			Index     int       `json:"index"`
			Embedding []float32 `json:"embedding"`
		} `json:"data"`
		Usage struct {
			PromptTokens int `json:"prompt_tokens"`
		} `json:"usage"`
	}
	code, b := embedPost(t, ts.URL, `{"model":"mock-embed","input":["Acme Cloud Pro","Acme SDK version"]}`, "k")
	if code != 200 || json.Unmarshal(b, &got) != nil {
		t.Fatalf("%d %s", code, b)
	}
	if got.Object != "list" || got.Model != "mock-embed" || len(got.Data) != 2 || got.Data[1].Index != 1 || got.Usage.PromptTokens != 6 {
		t.Errorf("response = %+v", got)
	}
	if cosine(got.Data[0].Embedding, Embed("Acme Cloud Pro")) < 0.9999 {
		t.Error("endpoint vector differs from Embed")
	}
	if code, _ := embedPost(t, ts.URL, `{"model":"mock-embed","input":"one string"}`, "k"); code != 200 {
		t.Errorf("string input: %d", code)
	}

	for name, tc := range map[string]struct {
		body, key string
		want      int
	}{
		"no key":        {`{"model":"m","input":"x"}`, "", 401},
		"no input":      {`{"model":"m"}`, "k", 400},
		"empty array":   {`{"model":"m","input":[]}`, "k", 400},
		"no model":      {`{"input":"x"}`, "k", 400},
		"injected fail": {`{"model":"fail-503","input":"x"}`, "k", 503},
	} {
		if code, b := embedPost(t, ts.URL, tc.body, tc.key); code != tc.want {
			t.Errorf("%s: %d %s", name, code, b)
		}
	}
	if _, by := s.Counts(); by["mock-embed"] != 2 || by["fail-503"] != 1 {
		t.Errorf("counts = %v", by)
	}
}
