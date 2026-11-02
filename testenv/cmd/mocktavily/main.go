// Command mocktavily serves the deterministic Tavily Search/Extract mock.
//
//	MOCK_TAVILY_API_KEY=tvly-mock mocktavily -addr 127.0.0.1:9102 -fixtures fixtures/tavily.json
package main

import (
	"encoding/json"
	"flag"
	"log"
	"net/http"
	"os"

	"github.com/priyansh-narang2308/halflife/testenv/mocktavily"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:9102", "listen address")
	fixtures := flag.String("fixtures", "", "JSON fixtures file (see mocktavily.Fixtures)")
	flag.Parse()

	cfg := mocktavily.Config{APIKey: os.Getenv("MOCK_TAVILY_API_KEY")}
	if cfg.APIKey == "" {
		log.Fatal("MOCK_TAVILY_API_KEY must be set")
	}
	if *fixtures != "" {
		b, err := os.ReadFile(*fixtures)
		if err != nil {
			log.Fatalf("read fixtures: %v", err)
		}
		cfg.Fixtures = &mocktavily.Fixtures{}
		if err := json.Unmarshal(b, cfg.Fixtures); err != nil {
			log.Fatalf("parse fixtures: %v", err)
		}
	}
	n := 0
	if cfg.Fixtures != nil {
		n = len(cfg.Fixtures.Search)
	}
	log.Printf("mocktavily listening on %s (%d search fixtures)", *addr, n)
	log.Fatal(http.ListenAndServe(*addr, mocktavily.New(cfg)))
}
