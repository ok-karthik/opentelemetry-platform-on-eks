# Meta-Monitoring: "Monitoring the Monitoring"

If the observability stack goes down, you are completely blind. This is why enterprise platforms require **Meta-Monitoring**—monitoring the OpenTelemetry pipeline itself for data flow (processing issues) and infrastructure health (silent failures).

This document outlines the **3 Pillars of Meta-Monitoring** implemented in this architecture.

---

## 1. Catching Processing Issues (Data Flow & Backpressure)

The OpenTelemetry Collector exposes its own internal health and performance metrics in standard Prometheus format on port `8888`. We configure our collectors (both Gateway Tiers and the DaemonSet Agents) to scrape their own endpoints using the `prometheus` receiver, forwarding these metrics directly to Mimir.

We alert on the following key metrics:

* **The "Pushback" Alert (Warning):** `otelcol_receiver_refused_spans`
  * *What it means:* The Gateway or Agent is actively throwing HTTP 429s. The system is stressed due to memory pressure or downstream latency, but no data is permanently lost *yet* (the Agents are buffering).
* **The "Data Loss" Alert (Critical):** `otelcol_processor_dropped_spans` or `otelcol_exporter_send_failed_spans`
  * *What it means:* The Collector's memory limiter kicked in, or the queue filled up completely, and it is actively throwing data into the trash. Immediate scaling or mitigation is required.

---

## 2. Catching Silent Failures (Nodes or Gateways Dying)

If a Kubernetes worker node completely crashes, the OTel Agent on that node dies instantly. The Gateway won't throw any errors, because it simply stops receiving data. **This is a silent failure.**

To catch this, you do not look for error metrics; you look for the *absence* of metrics.

* **The `up` Metric (Pod Down):**
  * `up{job=~"otel-collector.*"} == 0` for more than 3 minutes.
  * *What it means:* The Prometheus scrape job cannot reach the collector. The pod is dead or the node is gone.
* **The "Dead Silence" Alert (Ingestion Flatline):**
  * `absent(sum(rate(otelcol_receiver_accepted_spans[5m]))) == 1`
  * *What it means:* "I am receiving literally zero telemetry from the entire cluster." If the platform processes a billion events a month, there should never be a 3-minute window with zero data. If there is, the global observability network is broken.

---

## 3. The "Watch the Watcher" Rule (Architectural Isolation)

If your primary observability stack lives *inside* the same Kubernetes cluster as your applications, and that entire GKE/EKS cluster goes down... who pages you?

Your internal Mimir, Prometheus, and Alertmanager will die with the cluster.

**The Lead Architect Answer:**
> *"To truly monitor the monitoring stack, we cannot rely entirely on tools running inside the same failure domain. I would implement an 'External Watcher' pattern. We use an external, decoupled mechanism—like AWS CloudWatch, Route53 Health Checks, or a Dead Man's Snitch—to monitor the health endpoints of the Kubernetes OTel Gateways from the outside. If the internal cluster completely melts down, the external watcher detects the network timeout and fires the page."*

### Implementation in this repository:
- **Mimir Heartbeat:** An `ObservabilityPipelineWatchdogHeartbeat` rule (always firing `vector(1)`) runs in the Mimir Ruler.
- **Terraform Out-of-Band Alarms:** `terraform/observability-cluster/meta-monitoring.tf` provisions an isolated AWS SNS Topic (`emergency-pager`) and a CloudWatch Metric Alarm. If the EKS NLB reports zero healthy targets, CloudWatch bypasses Kubernetes completely and fires to SNS.

---

### 🎤 Quick Summary for SRE Interviews

If asked how to monitor an OpenTelemetry pipeline, answer with these 3 pillars:
1. **Scrape Internal OTel Metrics:** Scrape the collector's port `8888` to monitor `otelcol_processor_dropped_spans` to catch memory limiters and backpressure instantly.
2. **Alert on Silence:** Use PromQL `up == 0` and `absent()` functions to detect if an Agent pod or node silently dies and stops sending data.
3. **Decoupled Alerting:** Ensure the system that alerts on the observability pipeline's health runs *outside* the target cluster (using CloudWatch, Route53, or an external Watchdog) so a total cluster failure doesn't silence the alarms.
