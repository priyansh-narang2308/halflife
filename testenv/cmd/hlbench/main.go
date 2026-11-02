// Command hlbench measures what Halflife adds to the request path: the same
// requests go to a gateway without Halflife (-off) and one with it (-on), in
// pairs, and the latencies and response bodies are compared.
//
//	hlbench -off http://127.0.0.1:8090 -on http://127.0.0.1:8091 -n 1000 -c 1 -out result.json
//
// Each pair sends one prompt to both gateways back to back, alternating which
// goes first so neither side always gets the warmer cache. Latency runs from
// sending the request to reading the last byte of the body. Bodies are
// compared byte for byte after zeroing the gateway's own timing fields.
// The exit status is 1 if any response is not 200 or any pair differs.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"regexp"
	"slices"
	"sync"
	"time"
)

// prompts are the scripted questions in fixtures/llm.json.
var prompts = []string{
	"How much does the Acme Cloud Pro plan cost?",
	"What is the latest version of the Acme SDK?",
	"Who is the CEO of Acme Cloud?",
}

// timing matches the latency fields the gateway writes into extra_fields.
// They differ between identical requests with or without Halflife.
var timing = regexp.MustCompile(`"(upstream_)?latency":[0-9.]+`)

func normalize(body []byte) []byte { return timing.ReplaceAll(body, []byte(`"${1}latency":0`)) }

type result struct {
	latency time.Duration
	status  int
	hash    string
	audit   string // X-Halflife-Status
}

type sample struct{ off, on result }

// Summary is one gateway's latency distribution, in microseconds.
type Summary struct {
	N    int     `json:"n"`
	Min  float64 `json:"min_us"`
	Mean float64 `json:"mean_us"`
	P50  float64 `json:"p50_us"`
	P95  float64 `json:"p95_us"`
	P99  float64 `json:"p99_us"`
	Max  float64 `json:"max_us"`
}

// Report is the JSON written to -out.
type Report struct {
	Started     time.Time      `json:"started"`
	Requests    int            `json:"requests_per_gateway"`
	Warmup      int            `json:"warmup_pairs"`
	Concurrency int            `json:"concurrency"`
	Off         Summary        `json:"off"`
	On          Summary        `json:"on"`
	Overhead    map[string]any `json:"overhead_us"` // on minus off, per statistic
	// PairedMedianDelta is the median of (on - off) over pairs: less
	// sensitive to load drifting during the run than differences of
	// percentiles.
	PairedMedianDelta float64        `json:"paired_median_delta_us"`
	BodiesIdentical   int            `json:"bodies_identical"`
	BodiesDifferent   int            `json:"bodies_different"`
	DistinctBodies    int            `json:"distinct_bodies"`
	NonOK             int            `json:"non_200"`
	AuditStatus       map[string]int `json:"halflife_status_on"`  // X-Halflife-Status values from -on
	AuditStatusOff    int            `json:"halflife_status_off"` // responses from -off carrying the header (want 0)
}

func main() {
	off := flag.String("off", "http://127.0.0.1:8090", "gateway without Halflife")
	on := flag.String("on", "http://127.0.0.1:8091", "gateway with Halflife")
	vk := flag.String("vk", "sk-bf-halflife-smoke", "virtual key (synthetic)")
	n := flag.Int("n", 1000, "measured request pairs")
	warmup := flag.Int("warmup", 100, "unmeasured pairs sent first")
	c := flag.Int("c", 1, "concurrent pairs in flight")
	out := flag.String("out", "", "write the JSON report here")
	flag.Parse()
	if *n < 1 || *c < 1 || *warmup < 0 {
		log.Fatal("n and c must be at least 1, warmup at least 0")
	}

	client := &http.Client{
		Timeout:   30 * time.Second,
		Transport: &http.Transport{MaxIdleConnsPerHost: 2 * *c, MaxConnsPerHost: 2 * *c},
	}
	send := func(base string, i int) result {
		body, _ := json.Marshal(map[string]any{
			"model":    "openai/ok",
			"messages": []map[string]string{{"role": "user", "content": prompts[i%len(prompts)]}},
		})
		req, _ := http.NewRequest(http.MethodPost, base+"/v1/chat/completions", bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("x-bf-vk", *vk)
		begin := time.Now()
		resp, err := client.Do(req)
		if err != nil {
			return result{latency: time.Since(begin)}
		}
		b, err := io.ReadAll(resp.Body)
		lat := time.Since(begin)
		resp.Body.Close()
		if err != nil {
			return result{latency: lat}
		}
		sum := sha256.Sum256(normalize(b))
		return result{latency: lat, status: resp.StatusCode, hash: hex.EncodeToString(sum[:]), audit: resp.Header.Get("X-Halflife-Status")}
	}
	pair := func(i int) sample {
		if i%2 == 0 {
			o := send(*off, i)
			return sample{off: o, on: send(*on, i)}
		}
		h := send(*on, i)
		return sample{off: send(*off, i), on: h}
	}
	run := func(count int) []sample {
		samples := make([]sample, count)
		next := make(chan int)
		var wg sync.WaitGroup
		for range *c {
			wg.Add(1)
			go func() {
				defer wg.Done()
				for i := range next {
					samples[i] = pair(i)
				}
			}()
		}
		for i := range count {
			next <- i
		}
		close(next)
		wg.Wait()
		return samples
	}

	run(*warmup)
	r := Report{Started: time.Now().UTC(), Requests: *n, Warmup: *warmup, Concurrency: *c, AuditStatus: map[string]int{}}
	samples := run(*n)

	var offLat, onLat, delta []time.Duration
	distinct := map[string]bool{}
	for _, s := range samples {
		offLat, onLat = append(offLat, s.off.latency), append(onLat, s.on.latency)
		delta = append(delta, s.on.latency-s.off.latency)
		if s.off.status != 200 || s.on.status != 200 {
			r.NonOK++
		}
		if s.off.hash != "" && s.off.hash == s.on.hash {
			r.BodiesIdentical++
		} else {
			r.BodiesDifferent++
		}
		distinct[s.off.hash], distinct[s.on.hash] = true, true
		r.AuditStatus[s.on.audit]++
		if s.off.audit != "" {
			r.AuditStatusOff++
		}
	}
	r.DistinctBodies = len(distinct)
	r.Off, r.On = summarize(offLat), summarize(onLat)
	r.Overhead = map[string]any{
		"mean": round(r.On.Mean - r.Off.Mean),
		"p50":  round(r.On.P50 - r.Off.P50),
		"p95":  round(r.On.P95 - r.Off.P95),
		"p99":  round(r.On.P99 - r.Off.P99),
	}
	r.PairedMedianDelta = us(percentile(delta, 50))

	enc, _ := json.MarshalIndent(r, "", "  ")
	if *out != "" {
		if err := os.WriteFile(*out, append(enc, '\n'), 0o644); err != nil {
			log.Fatal(err)
		}
	}
	fmt.Printf("pairs=%d concurrency=%d warmup=%d\n", r.Requests, r.Concurrency, r.Warmup)
	fmt.Printf("  %-4s p50=%8.1fus p95=%8.1fus p99=%8.1fus mean=%8.1fus\n", "off", r.Off.P50, r.Off.P95, r.Off.P99, r.Off.Mean)
	fmt.Printf("  %-4s p50=%8.1fus p95=%8.1fus p99=%8.1fus mean=%8.1fus\n", "on", r.On.P50, r.On.P95, r.On.P99, r.On.Mean)
	fmt.Printf("  overhead p50=%+.1fus p95=%+.1fus p99=%+.1fus; paired median %+.1fus\n",
		r.On.P50-r.Off.P50, r.On.P95-r.Off.P95, r.On.P99-r.Off.P99, r.PairedMedianDelta)
	fmt.Printf("  bodies identical=%d different=%d distinct=%d non_200=%d status_on=%v status_off=%d\n",
		r.BodiesIdentical, r.BodiesDifferent, r.DistinctBodies, r.NonOK, r.AuditStatus, r.AuditStatusOff)
	if r.NonOK > 0 || r.BodiesDifferent > 0 {
		os.Exit(1)
	}
}

func summarize(d []time.Duration) Summary {
	var total time.Duration
	for _, v := range d {
		total += v
	}
	return Summary{
		N:    len(d),
		Min:  us(slices.Min(d)),
		Mean: round(float64(total.Nanoseconds()) / float64(len(d)) / 1e3),
		P50:  us(percentile(d, 50)),
		P95:  us(percentile(d, 95)),
		P99:  us(percentile(d, 99)),
		Max:  us(slices.Max(d)),
	}
}

// percentile returns the nearest-rank percentile of d (d is not modified).
func percentile(d []time.Duration, p float64) time.Duration {
	s := slices.Clone(d)
	slices.Sort(s)
	rank := int(float64(len(s))*p/100+0.999999999) - 1
	return s[max(0, min(rank, len(s)-1))]
}

func us(d time.Duration) float64 { return round(float64(d.Nanoseconds()) / 1e3) }
func round(v float64) float64    { return float64(int64(v*10+copysign(0.5, v))) / 10 }

func copysign(a, b float64) float64 {
	if b < 0 {
		return -a
	}
	return a
}
