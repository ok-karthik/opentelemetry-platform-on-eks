package main

import (
	"context"
	"fmt"
	"log"
	"log/slog"
	"net/http"
	"os"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel/trace"
)

func main() {
	// Initialize OTel Telemetry (Traces, Metrics & Logs)
	ctx := context.Background()
	shutdown, err := InitTelemetry(ctx)
	if err != nil {
		log.Fatalf("failed to initialize telemetry: %v", err)
	}
	defer func() {
		// Use a separate context for shutdown with a timeout to prevent hanging on exit
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := shutdown(shutdownCtx); err != nil {
			slog.Error("Error shutting down telemetry", "error", err)
		}
	}()

	// Route handler wrapped with OTel middleware to set the http.route attribute
	http.Handle("/product", otelhttp.NewHandler(http.HandlerFunc(handleProduct), "GET /product"))

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	slog.Info("Go application listening on port...", "port", port)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatal(err)
	}
}

func handleProduct(w http.ResponseWriter, r *http.Request) {
	spanCtx := trace.SpanFromContext(r.Context()).SpanContext()
	traceID := spanCtx.TraceID().String()
	spanID := spanCtx.SpanID().String()

	slog.InfoContext(r.Context(), "[Go App] Fetching product info...", "trace_id", traceID, "span_id", spanID)
	time.Sleep(50 * time.Millisecond) // Simulate some work

	// Call the Python product-info service
	pythonAppURL := os.Getenv("PRODUCT_INFO_SERVICE_URL")
	if pythonAppURL == "" {
		pythonAppURL = "http://python-app:8001"
	}

	// We use http.Client with otelhttp.NewTransport to send a GET request with context propagation.
	slog.InfoContext(r.Context(), "[Go App] Calling product-info service", "trace_id", traceID, "span_id", spanID, "url", pythonAppURL+"/product-info")
	httpClient := http.Client{
		Transport: otelhttp.NewTransport(http.DefaultTransport),
		Timeout:   5 * time.Second,
	}
	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, pythonAppURL+"/product-info", nil)
	if err != nil {
		slog.ErrorContext(r.Context(), "[Go App] failed to create product-info request", "trace_id", traceID, "span_id", spanID, "error", err)
		http.Error(w, fmt.Sprintf("failed to create request: %v", err), http.StatusInternalServerError)
		return
	}

	resp, err := httpClient.Do(req)
	if err != nil {
		slog.ErrorContext(r.Context(), "[Go App] product-info call failed", "trace_id", traceID, "span_id", spanID, "error", err)
		http.Error(w, fmt.Sprintf("product-info call failed: %v", err), http.StatusInternalServerError)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		slog.WarnContext(r.Context(), "[Go App] product-info service non-200 response", "trace_id", traceID, "span_id", spanID, "status", resp.StatusCode)
		http.Error(w, "product-info service failed", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(`{"status": "success", "product_id": "prod_123", "name": "OTel Observe Book", "payment_status": "captured"}`))
}
