.PHONY: up down status build test smoke bench cache relay budget tenants verify m1

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

cache:   ## Semantic cache on Redis, alone and with Halflife (needs Docker, ports 8090 and 9101 free)
	testenv/cache-baseline.sh
	testenv/cache-halflife.sh

relay:   ## Tavily relay contract against mock Tavily (ports 8090, 9101 and 9102 free)
	testenv/relay-tavily.sh

budget:  ## Relay grants and budgets against mock Tavily (ports 8090, 9101 and 9102 free)
	testenv/relay-budget.sh

tenants: ## Which budget each tenant's verification charges, two key layouts (ports 8090, 9101 and 9102 free)
	testenv/tenant-attribution.sh

verify:  ## Minimal verifier and report endpoint through the gateway (ports 8090, 9101 and 9102 free)
	testenv/verify-report.sh

m1:      ## M1 end-to-end proof: request -> capture -> Tavily relay -> report (LIVE=1: OpenRouter + real Tavily, at most 4 credits)
	testenv/m1-proof.sh
