.PHONY: up down status build test smoke

up:      ## Start Redis, mock LLM, mock Tavily and the gateway
	scripts/dev-stack.sh up

down:    ## Stop the local stack
	scripts/dev-stack.sh down

status:  ## Health of each stack service
	scripts/dev-stack.sh status

build:   ## Build the Bifrost gateway from bifrost/
	scripts/build-gateway.sh

test:    ## Unit tests for the mocks
	cd testenv && go test -race ./...

smoke:   ## Gateway smoke tests (need port 8090 free: run "make down" first)
	testenv/smoke-mock-llm.sh
	testenv/smoke-halflife.sh
