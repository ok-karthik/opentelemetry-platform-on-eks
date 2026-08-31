package main

import (
	"context"
	"fmt"
	"log"
	"log/slog"
	"os"
	"strings"

	"go.opentelemetry.io/contrib/bridges/otelslog"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploggrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/log/global"
	"go.opentelemetry.io/otel/propagation"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

// InitTelemetry initializes OpenTelemetry tracing, metrics, and logs.
// It returns a shutdown function to be deferred in main.
func InitTelemetry(ctx context.Context) (func(context.Context) error, error) {
	// 1. Resolve collector endpoint
	collectorAddr := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
	if collectorAddr == "" {
		collectorAddr = "otel-collector:4317"
	}

	// Clean up scheme prefixes (http:// or https://) for gRPC connection
	collectorAddr = strings.TrimPrefix(collectorAddr, "http://")
	collectorAddr = strings.TrimPrefix(collectorAddr, "https://")

	// 2. Define shared Resource Attributes (Service Name & Version)
	//
	// WithFromEnv is what makes OTEL_RESOURCE_ATTRIBUTES take effect. resource.New
	// applies only the detectors it is handed, so without it the
	// service.namespace / deployment.environment / team attributes set on the
	// Deployment are silently dropped, and the gateway's routing and the
	// dashboards' team filters see nothing. Explicit attributes are listed last
	// so they win over anything supplied through the environment.
	res, err := resource.New(ctx,
		resource.WithFromEnv(),
		resource.WithTelemetrySDK(),
		resource.WithAttributes(
			semconv.ServiceNameKey.String("golang-product-service"),
			semconv.ServiceVersionKey.String("1.0.0"),
		),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create resource: %w", err)
	}

	// ==================== TRACING SETUP ====================
	traceExporter, err := otlptracegrpc.New(ctx,
		otlptracegrpc.WithInsecure(),
		otlptracegrpc.WithEndpoint(collectorAddr),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create trace exporter: %w", err)
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(traceExporter),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(tp)

	// Ensure W3C Trace Context headers propagate transparently in HTTP calls
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))

	// ==================== METRICS SETUP ====================
	metricExporter, err := otlpmetricgrpc.New(ctx,
		otlpmetricgrpc.WithInsecure(),
		otlpmetricgrpc.WithEndpoint(collectorAddr),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create metric exporter: %w", err)
	}

	mp := sdkmetric.NewMeterProvider(
		sdkmetric.WithReader(sdkmetric.NewPeriodicReader(metricExporter)),
		sdkmetric.WithResource(res),
	)
	otel.SetMeterProvider(mp)

	// ==================== LOGGING SETUP ====================
	logExporter, err := otlploggrpc.New(ctx,
		otlploggrpc.WithInsecure(),
		otlploggrpc.WithEndpoint(collectorAddr),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create log exporter: %w", err)
	}

	lp := sdklog.NewLoggerProvider(
		sdklog.WithProcessor(sdklog.NewBatchProcessor(logExporter)),
		sdklog.WithResource(res),
	)
	global.SetLoggerProvider(lp)

	// Configure slog default logger to bridge directly to OpenTelemetry Log SDK
	slogLogger := otelslog.NewLogger("golang-product-service")
	slog.SetDefault(slogLogger)

	// ==================== SHUTDOWN HANDLER ====================
	shutdown := func(shutdownCtx context.Context) error {
		var shutdownErrors []string

		log.Println("[Telemetry] Flushing and shutting down Logger Provider...")
		if err := lp.Shutdown(shutdownCtx); err != nil {
			shutdownErrors = append(shutdownErrors, fmt.Sprintf("logger provider shutdown error: %v", err))
		}

		log.Println("[Telemetry] Flushing and shutting down Meter Provider...")
		if err := mp.Shutdown(shutdownCtx); err != nil {
			shutdownErrors = append(shutdownErrors, fmt.Sprintf("meter provider shutdown error: %v", err))
		}

		log.Println("[Telemetry] Flushing and shutting down Tracer Provider...")
		if err := tp.Shutdown(shutdownCtx); err != nil {
			shutdownErrors = append(shutdownErrors, fmt.Sprintf("tracer provider shutdown error: %v", err))
		}

		if len(shutdownErrors) > 0 {
			return fmt.Errorf("errors during telemetry shutdown: %s", strings.Join(shutdownErrors, "; "))
		}
		return nil
	}

	return shutdown, nil
}
