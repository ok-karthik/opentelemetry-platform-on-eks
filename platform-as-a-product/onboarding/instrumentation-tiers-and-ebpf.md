# The 4 Levels of Instrumentation & eBPF vs. Application SDKs

In enterprise observability, no single instrumentation technique provides 100% visibility. High-performing engineering teams combine **kernel-level telemetry (eBPF)** with **application-level code instrumentation (OpenTelemetry SDKs and Auto-Instrumentation)**.

---

## 1. The 4 Levels of Telemetry Instrumentation

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│ LEVEL 4: Commercial Proprietary Agents (Datadog, Dynatrace, New Relic)      │
│  • Vendor-locked agents, continuous profiling, closed-source SaaS protocols │
├─────────────────────────────────────────────────────────────────────────────┤
│ LEVEL 3: Programmatic SDK Custom Instrumentation (OTel SDK API)             │
│  • Hand-written code spans, business metrics (revenue, cart value), baggage │
├─────────────────────────────────────────────────────────────────────────────┤
│ LEVEL 2: Runtime Auto-Instrumentation (OTel Operator Bytecode Injection)    │
│  • Zero code changes in app, framework spans (HTTP/ORM), log trace_id inject│
├─────────────────────────────────────────────────────────────────────────────┤
│ LEVEL 1: Kernel & Network Baseline (eBPF)                                   │
│  • Non-invasive Linux kernel probes, TCP drops, OOMKills, proxy/mesh metrics │
└─────────────────────────────────────────────────────────────────────────────┘
```

| Level | Mechanism | Developer Effort | Runtime Overhead | What It Excels At | Major Drawback |
|---|---|:---:|:---:|---|---|
| **Level 1: eBPF (Kernel)** | Kernel probes (`kprobe`, `uprobe`, socket buffers) via DaemonSet | **Zero** (no pod restarts) | **< 1%** (kernel-space) | 100% baseline coverage, third-party binaries (Nginx, Envoy, CoreDNS), TCP drops, kernel OOMKills. | Cannot see in-process variables, SQL query strings, or exception stack traces. |
| **Level 2: OTel Auto-Instrumentation** | Bytecode / AST injection via OTel Operator (`javaagent`, Python site-packages, Node monkey-patching) | **Zero code** (1 pod annotation) | **3 – 8%** (in-memory span objects) | Web framework route handlers, HTTP client calls, database queries, automatic `trace_id` injection into app logs. | Limited to supported runtimes (Python, Java, Node, .NET). Fails to catch hard kernel crashes (OOMKill). |
| **Level 3: OTel Custom SDK** | Explicit Go, Rust, or Python code calling OpenTelemetry API | **High** (code changes & PR reviews) | **1 – 3%** (efficient SDK) | Critical business metrics (e.g. `order.total_amount`), custom baggage, multi-step batch algorithms. | Requires engineering maintenance and code refactoring. |
| **Level 4: Commercial Agents** | Proprietary vendor daemon (`datadog-agent`, `oneagent`) | **Low to Medium** | **5 – 15%** (heavy agent) | Out-of-the-box UI magic, proprietary continuous profilers, automated root-cause AI engines. | **Massive vendor lock-in** and exponential ingest/license bills ($100k-$1M+/year). |

---

## 2. Complementary Strengths: Auto-Instrumentation vs. eBPF

Why running **both** is the gold standard:

| Telemetry Dimension | Auto-Instrumentation (User Space / App) | eBPF (Linux Kernel Space) | Why Both Are Needed |
|---|:---:|:---:|---|
| **Application Exceptions & Stack Traces** | ✅ **Full Stack Trace**<br/>(File, line number, `KeyError`, error message) | ❌ **Blind**<br/>(Only sees a generic HTTP 500 response code) | Auto-instrumentation pinpoints the exact line of bad code for developers. |
| **Database & ORM Queries** | ✅ **Exact Query**<br/>(`SELECT * FROM products WHERE id = ?`) | ❌ **Blind**<br/>(Encrypted TLS stream or raw TCP bytes to port 5432) | Auto-instrumentation reveals slow database queries and N+1 query loops. |
| **Log-to-Trace Correlation** | ✅ **Injects `trace_id`**<br/>(Automatically adds `trace_id` to Python/Java logs) | ❌ **Blind**<br/>(Cannot modify log files inside container filesystems) | Clicking a trace in Grafana jumps directly to matching container logs. |
| **Instant Pod Deaths (`OOMKilled` Exit 137)** | ❌ **Blind**<br/>(Kernel kills runtime in 0ms; no time to emit spans/logs) | ✅ **Catches `oom_kill_process()`**<br/>(Records container, limit, and exact timestamp) | When a pod dies abruptly without logging, only eBPF knows it was killed by the OS. |
| **TCP Drops, Retransmits & Latency** | ❌ **Blind**<br/>(Only measures total wall-clock request time) | ✅ **Full Network Insight**<br/>(Detects cross-AZ packet loss and SYN queue drops) | Differentiates between slow application code vs. degraded AWS network. |
| **Uninstrumented & Legacy Binaries** | ❌ **Unsupported**<br/>(Cannot instrument Envoy, CoreDNS, Nginx, C/C++) | ✅ **100% Coverage**<br/>(Inspects socket calls across every process on the node) | Captures ingress and service mesh telemetry without injecting code. |
| **CPU CFS Quota Throttling** | ❌ **Blind**<br/>(Assumes slow execution is due to application code) | ✅ **Measures Run-Queue Latency**<br/>(Proves thread spent 80% time paused by K8s CPU limits) | Prevents developers from refactoring code when the real fix is raising CPU limits. |

---

## 3. How and Where Are They Linked Together?

A critical engineering question: *"When eBPF and application auto-instrumentation collect telemetry separately, how do we correlate them into a single coherent picture?"*

### The 2 Correlation Mechanisms:

#### A. W3C Distributed Trace Context (`traceparent` HTTP Header)
* When an auto-instrumented service (e.g., Python FastAPI) makes an HTTP request, its OTel SDK injects the standard W3C header:
  `traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01`
* Modern eBPF agents (such as Grafana Beyla or OpenTelemetry eBPF profiler) inspect the Linux kernel socket buffers (`sk_buff`) on the network interface and **extract that exact same `trace_id`**.
* The eBPF agent generates kernel network spans using the **same trace context**, nesting the network hop directly inside the application trace waterfall.

#### B. Kubernetes Metadata Stitching (`k8sattributes`)
* For events that have no HTTP header (like an `OOMKilled` crash or TCP SYN drop):
* The Linux kernel provides the `tgid`/`pid` and the cgroup path (`/kubepods/burstable/pod<UUID>`).
* The local OTel Collector agent enriches both the eBPF kernel event and the application traces with identical resource attributes:
  `k8s.pod.name`, `k8s.namespace.name`, `k8s.node.name`, `service.name`, `deployment.environment`.

---

### Where Do You View the Correlated Telemetry?

#### 1. In Grafana (LGTM Stack):
* **Grafana Tempo (Trace Waterfall)**:
  * You open an incident trace:
    ```text
    ├── FastAPI: /checkout (Auto-instrumentation span: 350ms)
    │    ├── TCP connect & TLS handshake (eBPF kernel span: 45ms)
    │    ├── SQLAlchemy: SELECT * FROM inventory (Auto-instrumentation span: 12ms)
    │    └── Outbound HTTP to payment-service (eBPF socket span: 180ms)
    ```
* **Grafana Dashboards (Metrics + Event Overlay)**:
  * An eBPF metric panel (e.g., `k8s_container_oom_kills_total` or `node_tcp_retransmits`) is plotted alongside application Golden Signals (p99 latency, 5xx errors).
  * Grafana overlays **Kernel Crash Annotations** directly over application latency spikes, allowing you to instantly see: *"Latency jumped because container X was OOMKilled at 14:02"*.
* **Grafana Loki (Derived Fields)**:
  * Clicking `trace_id` in Python logs takes you to the Tempo trace; clicking the Tempo trace shows all matching Loki logs.

#### 2. In AWS X-Ray & CloudWatch Application Signals:
* The OpenTelemetry Gateway's `awsxray` exporter maps both eBPF network spans and application SDK spans into AWS X-Ray segment/subsegment trees.
* In the **CloudWatch Service Map**, eBPF detects intermediate network hops and uninstrumented proxies, while auto-instrumentation provides deep node-level service names and exception icons.
