// Command replayproxy records or replays OpenRouter and Tavily responses for
// the evaluation. See package replay. Keys come from the environment, and only
// with -record.
package main

import (
	"flag"
	"log"
	"net/http"
	"os"

	"github.com/priyansh-narang2308/halflife/testenv/replay"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:9103", "listen address")
	dir := flag.String("dir", "eval/recordings", "recordings directory")
	record := flag.Bool("record", false, "call upstreams for anything not recorded")
	maxLLM := flag.Int("max-llm", 60, "OpenRouter calls allowed in this run")
	maxTavily := flag.Int("max-tavily", 30, "Tavily calls allowed in this run")
	flag.Parse()

	cfg := replay.Config{Dir: *dir, Record: *record}
	if *record {
		cfg.Upstreams = []replay.Upstream{
			{Prefix: "/v1/", Base: "https://openrouter.ai/api", Key: os.Getenv("OPENROUTER_API_KEY"), Limit: *maxLLM},
			{Prefix: "/search", Base: "https://api.tavily.com", Key: os.Getenv("TAVILY_API_KEY"), Limit: *maxTavily},
			{Prefix: "/extract", Base: "https://api.tavily.com", Key: os.Getenv("TAVILY_API_KEY"), Limit: *maxTavily},
		}
	}
	p, err := replay.New(cfg)
	if err != nil {
		log.Fatal(err)
	}
	log.Fatal(http.ListenAndServe(*addr, p))
}
