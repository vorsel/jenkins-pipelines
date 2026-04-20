FROM golang:1.24-alpine AS builder
RUN apk add --no-cache git
WORKDIR /app
COPY go.mod main.go ./
RUN go mod tidy && go mod download
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /reapi-proxy .

FROM alpine:3.20
COPY --from=builder /reapi-proxy /usr/local/bin/reapi-proxy
ENTRYPOINT ["reapi-proxy"]
