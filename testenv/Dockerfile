# Mock LLM and mock Tavily, for the demo stack (docker-compose.yml). No external calls.
FROM golang:1.27.3-alpine3.24 AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -o /bin/mockllm ./cmd/mockllm && CGO_ENABLED=0 go build -o /bin/mocktavily ./cmd/mocktavily

FROM alpine:3.24
COPY --from=build /bin/mockllm /bin/mocktavily /usr/local/bin/
COPY fixtures/ /fixtures/
USER nobody
