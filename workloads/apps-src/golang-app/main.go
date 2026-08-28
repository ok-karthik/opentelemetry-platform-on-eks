package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel/trace"
)

func main() {
	// Initialize OTel Telemetry (Traces & Metrics)
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
			log.Printf("Error shutting down telemetry: %v", err)
		}
	}()

	// Route handler wrapped with OTel middleware to set the http.route attribute
	http.Handle("/product", otelhttp.NewHandler(http.HandlerFunc(handleProduct), "GET /product"))

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	log.Printf("Go application listening on port %s...", port)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatal(err)
	}
}

func handleProduct(w http.ResponseWriter, r *http.Request) {
	spanCtx := trace.SpanFromContext(r.Context()).SpanContext()
	traceID := spanCtx.TraceID().String()
	spanID := spanCtx.SpanID().String()

	log.Printf("trace_id=%s span_id=%s [Go App] Fetching product info...", traceID, spanID)
	time.Sleep(50 * time.Millisecond) // Simulate some work

	// Call the Python product-info service
	pythonAppURL := os.Getenv("PRODUCT_INFO_SERVICE_URL")
	if pythonAppURL == "" {
		pythonAppURL = "http://python-app:8001"
	}

	// We use otelhttp.Get to send a GET request with context propagation.
	log.Printf("trace_id=%s span_id=%s [Go App] Calling product-info service: %s/product-info", traceID, spanID, pythonAppURL)
	resp, err := otelhttp.Get(r.Context(), pythonAppURL+"/product-info")
	if err != nil {
		log.Printf("trace_id=%s span_id=%s [Go App] product-info call failed: %v", traceID, spanID, err)
		http.Error(w, fmt.Sprintf("product-info call failed: %v", err), http.StatusInternalServerError)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		http.Error(w, "product-info service failed", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(`{"status": "success", "product_id": "prod_123", "name": "OTel Observe Book", "payment_status": "captured"}`))
}
