.PHONY: up down status build test smoke bench cache

up:      ## Start Redis, mock LLM, mock Tavily and the gateway
	scripts/dev-stack.sh up

down:    ## Stop the local stack
	scripts/dev-stack.sh down

status:  ## Health of each stack service
	scripts/dev-stack.sh status

build:   ## Build the Bifrost gateway from bifrost/
	scripts/build-gateway.sh

test:    ## Unit tests for the mocks and the benchmark tool
	cd testenv && go test -race ./...

smoke:   ## Gateway smoke tests (need port 8090 free: run "make down" first)
	testenv/smoke-mock-llm.sh
	testenv/smoke-halflife.sh
	testenv/fallback-halflife.sh

bench:   ## Halflife on/off latency and body integrity (needs ports 8090-8091 free)
	testenv/bench-halflife.sh

cache:   ## Semantic cache baseline on Redis: miss, write, direct and semantic hit (needs Docker, ports 8090 and 9101 free)
	testenv/cache-baseline.sh
