// Command mockllm serves the deterministic OpenAI-compatible mock provider.
//
//	mockllm -addr 127.0.0.1:9101 -fixtures fixtures/llm.json
//
// MOCK_LLM_API_KEY, when set, is required as the bearer token.
package main

import (
	"encoding/json"
	"flag"
	"log"
	"net/http"
	"os"

	"github.com/priyansh-narang2308/halflife/testenv/mockllm"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:9101", "listen address")
	fixtures := flag.String("fixtures", "", "JSON file: {\"replies\": {\"<prompt>\": \"<reply>\"}, \"schema_replies\": {\"<schema>\": {\"<substring>\": \"<reply>\"}}}")
	flag.Parse()

	cfg := mockllm.Config{APIKey: os.Getenv("MOCK_LLM_API_KEY")}
	if *fixtures != "" {
		b, err := os.ReadFile(*fixtures)
		if err != nil {
			log.Fatalf("read fixtures: %v", err)
		}
		var f struct {
			Replies       map[string]string            `json:"replies"`
			SchemaReplies map[string]map[string]string `json:"schema_replies"`
		}
		if err := json.Unmarshal(b, &f); err != nil {
			log.Fatalf("parse fixtures: %v", err)
		}
		cfg.Replies, cfg.SchemaReplies = f.Replies, f.SchemaReplies
	}
	log.Printf("mockllm listening on %s (%d scripted replies, auth=%t)", *addr, len(cfg.Replies), cfg.APIKey != "")
	log.Fatal(http.ListenAndServe(*addr, mockllm.New(cfg)))
}
