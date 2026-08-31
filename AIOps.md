To seamlessly map the open-source alternative stack into your Amazon EKS Topology, you can overlay them directly onto your existing data pipeline.
Your architecture is already excellently set up for this because it uses standardized open protocols (OTLP/gRPC, PromQL, LogQL, and TraceQL) and separates your App Workloads from your Observability Pool.
Here is exactly where and how to inject Keep, Coroot, and Aurora/HolmesGPT into this architecture:
------------------------------
## 1. Coroot (Topology Mapping & Smartscape Replacement)

* Where it sits: Inside the Worker Nodes (App Pool) alongside your Odigos eBPF Agent.
* How it integrates: You don't need to change your existing application code. Coroot can ingest the metrics already being scraped/emitted by your Odigos agent and OpenTelemetry collector setup. Alternatively, you can deploy a lightweight Coroot agent daemonset alongside Odigos to automatically analyze container network interactions.
* The Result: It captures the raw connections between your Go Product Service and Python Info Service, building the live dependency map that an open-source AI engine requires.

## 2. Keep (The Alert Management & Workflow Engine)

* Where it sits: Directly attached to your Grafana UI / Storage Backends as an orchestration engine.
* How it integrates: You configure Grafana Alerting to send Webhook alerts to Keep whenever thresholds are crossed in Amazon Managed Prometheus, Loki, or Tempo.
* The Result: Keep acts as the central router. Instead of simply blasting an alert to Slack, Keep catches the Grafana alert and automatically initiates your AIOps troubleshooting sequence.

## 3. Aurora or HolmesGPT (The RCA & Postmortem AI Investigators)

* Where it sits: Deployed as a scalable workload within your Worker Nodes (Observability Pool), right alongside your Tier 1 Router (deploy) and Tier 2 Processor (sts).
* How it integrates:
1. An alert fires in Grafana → passes to Keep.
   2. Keep executes a workflow step that invokes Aurora or HolmesGPT via an internal API/Webhook call.
   3. The AI Engine connects natively to your Storage Backends (querying AMP via PromQL, Loki via LogQL, and Tempo via TraceQL) to pull logs, metrics, and traces surrounding the timeframe of the alert.
   4. Simultaneously, because it lives in the cluster, it talks directly to the Kubernetes API to inspect event streams or failing pods.
* The Result: The AI agent analyzes the correlated telemetry from your storage layer, identifies the underlying issue, and outputs a complete Postmortem Markdown document back to your engineers.

------------------------------
## The New Operational Data Flow

[ App Nodes: Go/Python Pods ] ──(Telemetry)──> [ Observability Pool: Routers/Processors ] 
                                                           │
                                                           ▼
[ Grafana UI / Storage (AMP/Loki/Tempo) ] <──── [ Storage Backends (S3 & Serverless) ]
               │
               ▼ (Anomaly/Alert Trigger)
     [ Keep Workflow Engine ]
               │
               ▼ (Triggers Automated Investigation)
 [ Aurora / HolmesGPT AI Agents ] ──(Queries Telemetry Backends via PromQL/LogQL/TraceQL)
               │
               ▼
[ Output: Auto-Generated Postmortem & RCA ]

If you'd like to sketch out the migration:

* Do you want to see a sample Keep workflow YAML configuration showing how to intercept a Grafana alert and pass it to an AI investigator?
* Or would you prefer a breakdown of how HolmesGPT/Aurora authentication handles securely querying your AWS-managed backend (AMP)?


