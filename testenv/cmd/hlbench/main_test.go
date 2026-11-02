package main

import (
	"testing"
	"time"
)

func TestPercentileNearestRank(t *testing.T) {
	var d []time.Duration
	for i := 100; i >= 1; i-- { // unsorted input
		d = append(d, time.Duration(i)*time.Microsecond)
	}
	for p, want := range map[float64]time.Duration{50: 50, 95: 95, 99: 99, 100: 100, 1: 1} {
		if got := percentile(d, p); got != want*time.Microsecond {
			t.Errorf("p%v = %v, want %vus", p, got, int(want))
		}
	}
	if d[0] != 100*time.Microsecond {
		t.Error("percentile sorted its input")
	}
	if got := percentile([]time.Duration{7}, 99); got != 7 {
		t.Errorf("single sample p99 = %v", got)
	}
}

func TestNormalizeZeroesOnlyTiming(t *testing.T) {
	in := `{"x":"latency 5","extra_fields":{"latency":12.5,"upstream_latency":3,"chunk_index":0}}`
	want := `{"x":"latency 5","extra_fields":{"latency":0,"upstream_latency":0,"chunk_index":0}}`
	if got := string(normalize([]byte(in))); got != want {
		t.Errorf("normalize = %s", got)
	}
}

func TestRound(t *testing.T) {
	for in, want := range map[float64]float64{1.24: 1.2, 1.25: 1.3, -1.25: -1.3, 0: 0} {
		if got := round(in); got != want {
			t.Errorf("round(%v) = %v, want %v", in, got, want)
		}
	}
}
