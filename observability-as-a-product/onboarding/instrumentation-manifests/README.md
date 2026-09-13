# Language Instrumentation Templates

These templates are platform-owned defaults for the OpenTelemetry Operator.

Application teams opt in by adding the matching annotation to their workload pod template. The platform keeps exporter endpoint, propagators, and default language settings consistent across clusters.

Go is intentionally documented separately because Go usually needs SDK setup at build time instead of runtime injection.
