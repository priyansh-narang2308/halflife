// Package replay is a recording proxy for the two paid upstreams, OpenRouter
// and Tavily, so an evaluation can be re-run without keys, credits or network
// and give the same result (audit §6.6).
//
// A response is stored under a hash of the method, path and body, with dates
// removed because prompts carry today's date. In record mode a stored 200 is
// served without a call, so a re-run spends nothing twice; anything else goes
// upstream, up to a hard call limit. In replay mode a miss is a 599.
//
// Credentials live only in the proxy: it replaces any Authorization it is
// sent, and stores responses alone, never a request header.
package replay

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

const (
	missStatus  = 599 // not a status any upstream sends
	maxBodySize = 16 << 20
)

var dateRe = regexp.MustCompile(`\b\d{4}-\d{2}-\d{2}\b`)

// Upstream is where a path prefix goes in record mode.
type Upstream struct {
	Prefix string
	Base   string
	Key    string
	Limit  int // calls allowed in this run
}

// Config controls a Proxy.
type Config struct {
	Dir       string
	Record    bool
	Upstreams []Upstream
	Client    *http.Client
}

// Proxy is an http.Handler. Safe for concurrent use.
type Proxy struct {
	cfg Config

	mu    sync.Mutex
	calls map[string]int
	hits  int
	miss  int
}

// New returns a Proxy that stores recordings in cfg.Dir.
func New(cfg Config) (*Proxy, error) {
	if err := os.MkdirAll(cfg.Dir, 0o755); err != nil {
		return nil, err
	}
	if cfg.Client == nil {
		cfg.Client = &http.Client{Timeout: 120 * time.Second}
	}
	return &Proxy{cfg: cfg, calls: map[string]int{}}, nil
}

type recording struct {
	Path   string          `json:"path"`
	Status int             `json:"status"`
	Body   json.RawMessage `json:"body,omitempty"`
	Text   string          `json:"text,omitempty"` // a body that isn't JSON
}

// Key is the name a request is stored under.
func Key(method, path string, body []byte) string {
	h := sha256.Sum256(append([]byte(method+" "+path+"\n"), dateRe.ReplaceAll(body, []byte("DATE"))...))
	return hex.EncodeToString(h[:])[:32]
}

func (p *Proxy) load(key string) (recording, bool) {
	b, err := os.ReadFile(filepath.Join(p.cfg.Dir, key+".json"))
	if err != nil {
		return recording{}, false
	}
	var r recording
	if json.Unmarshal(b, &r) != nil {
		return recording{}, false
	}
	return r, true
}

// save keeps a success over anything, and a failure only if there is nothing
// better, so a rate-limited retry can't overwrite the answer that followed it.
func (p *Proxy) save(key string, r recording) error {
	if old, ok := p.load(key); ok && old.Status == http.StatusOK && r.Status != http.StatusOK {
		return nil
	}
	b, err := json.Marshal(r)
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(p.cfg.Dir, key+".json"), append(b, '\n'), 0o644)
}

func write(w http.ResponseWriter, r recording) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(r.Status)
	if r.Body != nil {
		w.Write(r.Body)
	} else {
		io.WriteString(w, r.Text)
	}
}

func fail(w http.ResponseWriter, status int, msg string) {
	write(w, recording{Status: status, Text: fmt.Sprintf(`{"error":{"message":%q}}`, msg)})
}

func (p *Proxy) route(path string) (Upstream, bool) {
	for _, u := range p.cfg.Upstreams {
		if strings.HasPrefix(path, u.Prefix) {
			return u, true
		}
	}
	return Upstream{}, false
}

// spend counts one call against the upstream's limit.
func (p *Proxy) spend(u Upstream) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.calls[u.Prefix] >= u.Limit {
		return false
	}
	p.calls[u.Prefix]++
	return true
}

func (p *Proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/_replay/stats" {
		p.mu.Lock()
		defer p.mu.Unlock()
		json.NewEncoder(w).Encode(map[string]any{"record": p.cfg.Record, "upstream_calls": p.calls, "hits": p.hits, "misses": p.miss})
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, maxBodySize))
	if err != nil {
		fail(w, http.StatusBadRequest, "replay: unreadable body")
		return
	}
	key := Key(r.Method, r.URL.Path, body)
	stored, ok := p.load(key)
	if ok && (stored.Status == http.StatusOK || !p.cfg.Record) {
		p.mu.Lock()
		p.hits++
		p.mu.Unlock()
		write(w, stored)
		return
	}
	if !p.cfg.Record {
		p.mu.Lock()
		p.miss++
		p.mu.Unlock()
		fail(w, missStatus, "replay: no recording for "+r.URL.Path)
		return
	}
	u, found := p.route(r.URL.Path)
	if !found {
		fail(w, http.StatusNotFound, "replay: no upstream for "+r.URL.Path)
		return
	}
	if evidence(r.URL.Path) && !p.spend(u) {
		fail(w, http.StatusTooManyRequests, "replay: call limit reached for "+u.Prefix)
		return
	}
	got, err := p.forward(r, u, body)
	if err != nil {
		fail(w, http.StatusBadGateway, "replay: upstream unreachable")
		return
	}
	if evidence(r.URL.Path) {
		if err := p.save(key, got); err != nil {
			fail(w, http.StatusInternalServerError, "replay: cannot store the recording")
			return
		}
	}
	write(w, got)
}

// evidence reports whether a response belongs in a recording. Anything else,
// such as a provider's key or model listing, says something about the account
// and nothing about the run, so it is passed through and not kept.
func evidence(path string) bool {
	for _, suffix := range []string{"/chat/completions", "/embeddings", "/search", "/extract"} {
		if strings.HasSuffix(path, suffix) {
			return true
		}
	}
	return false
}

func (p *Proxy) forward(r *http.Request, u Upstream, body []byte) (recording, error) {
	req, err := http.NewRequestWithContext(r.Context(), r.Method, u.Base+r.URL.Path, bytes.NewReader(body))
	if err != nil {
		return recording{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+u.Key)
	resp, err := p.cfg.Client.Do(req)
	if err != nil {
		return recording{}, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxBodySize))
	if err != nil {
		return recording{}, err
	}
	out := recording{Path: r.URL.Path, Status: resp.StatusCode}
	if json.Valid(data) {
		out.Body = data
	} else {
		out.Text = string(data)
	}
	return out, nil
}
