FROM golang:1.22-alpine AS builder

WORKDIR /app

# Copy the go.mod first
COPY go.mod ./
# Copy source files so go mod tidy can detect dependencies and build the binary
COPY main.go telemetry.go ./

# Run go mod tidy to dynamically resolve dependencies and write a complete go.sum
RUN go mod tidy

RUN CGO_ENABLED=0 GOOS=linux go build -o main .

# Final runner container
FROM alpine:latest  
RUN apk --no-cache add ca-certificates

WORKDIR /root/

COPY --from=builder /app/main .

EXPOSE 8080
ENV PORT=8080

CMD ["./main"]
