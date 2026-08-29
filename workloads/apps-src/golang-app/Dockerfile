FROM golang:1.25-alpine AS builder

WORKDIR /app

# Copy dependency definitions first for Docker layer caching
COPY go.mod go.sum ./
RUN go mod download

# Copy application source files
COPY main.go telemetry.go ./

RUN CGO_ENABLED=0 GOOS=linux go build -o main .

# Final runner container
FROM alpine:latest  
RUN apk --no-cache add ca-certificates

WORKDIR /root/

COPY --from=builder /app/main .

EXPOSE 8080
ENV PORT=8080

CMD ["./main"]
