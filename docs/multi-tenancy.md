# Multi-Tenancy in Enterprise Observability: Access Control, Data Isolation, and Alerting

In a shared internal observability platform, multiple engineering teams (e.g., **Team Payments** and **Team Search**) share the same infrastructure. Multi-tenancy must enforce three non-negotiable boundaries:

1. **Security & Privacy:** Team Payments must never see or query Team Search's logs, metrics, or traces in Grafana.
2. **Alerting Isolation:** If Search services break at 2 AM, the on-call pager must wake up only the Search engineer, never the Payments engineer.
3. **FinOps & Cluster Stability:** A runaway service emitting 100,000 logs/second must never crash the cluster or degrade performance for other teams ("noisy neighbor" protection).

---

## 1. High-Level Architecture Flow

The multi-tenant lifecycle flows through four decoupled stages:

```text
[ Application Pod ]
    │ (Emits resource attribute: team = payments)
    ▼
[ OTel Gateway Fleet ]
    │ (Injects HTTP Header: X-Scope-OrgID = payments)
    ▼
[ Multi-Tenant Storage (S3 / AMP) ]
    │ (Partitions data under /payments/ prefix)
    ▼
[ Grafana UI & Alertmanager ]
    │ (Payments Org with locked datasource -> Alert routed to Payments On-Call)
```

---

## 2. Ingestion: Automated Tenant Tagging & Header Injection

Application developers should never have to manually configure authentication tokens or HTTP headers in their code.

1. **Standard Resource Attributes:** Applications declare ownership in standard OTel attributes:
   ```yaml
   OTEL_RESOURCE_ATTRIBUTES="service.name=checkout,team=payments,tenant.id=payments"
   ```
2. **Gateway Header Injection:** The central OpenTelemetry Gateway reads `tenant.id` or `team` and uses the `routing` connector (see `observability-platform/gateway-policies/otel-gateway-multitenant.yaml`) to inject the tenant header before sending data to backends:
   - For Payments: `X-Scope-OrgID: payments`
   - For Search: `X-Scope-OrgID: search`

---

## 3. Storage Isolation: Physical Partitioning in S3 & AMP

### Grafana Loki, Tempo, and Mimir (`auth_enabled: true`)
When multi-tenancy is enabled on LGTM backends:
* Every write (push) and read (query) **must** provide the `X-Scope-OrgID: <tenant-name>` header.
* **Physical S3 Prefix Partitioning:** Chunks and index files are strictly stored under tenant prefixes:
  ```text
  s3://observability-loki-bucket/payments/chunks/...
  s3://observability-loki-bucket/search/chunks/...
  ```
* **Zero Data Bleed:** When a user or ruler queries with `X-Scope-OrgID: payments`, the storage engine only scans the `payments/` key prefix. It is mathematically impossible for queries to scan chunks belonging to `search`.

### Amazon Managed Service for Prometheus (AMP)
If using AWS native AMP for metrics:
* Deploy independent **AMP Workspaces** per department or environment (`aws_prometheus_workspace.payments_amp` vs `search_amp`).
* Control query and remote-write access via IAM Pod Identity and IAM policies scoped to specific workspace ARNs (`aps:QueryMetrics`, `aps:RemoteWrite`).

---

## 4. Visualization Access Control: Restricting Users in Grafana

To prevent engineers from querying or viewing other teams' telemetry in Grafana:

### The Production Standard: Grafana Organizations (Orgs)
Grafana has built-in **Organizations** (Orgs), which act as completely isolated logical workspaces with independent users, dashboards, and Data Sources.

```text
[ Corporate SSO / IdP ]
    │
    ├── User in group 'payments-devs' ──> [ Grafana Org: Payments ]
    │                                         └── Locked DataSource (X-Scope-OrgID: payments)
    │
    └── User in group 'search-devs'   ──> [ Grafana Org: Search ]
                                              └── Locked DataSource (X-Scope-OrgID: search)
```

1. **Create Grafana Orgs:** Provision an Org for each team (`Payments`, `Search`).
2. **Configure Scoped Data Sources:**
   * Inside the **Payments Org**, the Loki and Prometheus data sources are configured with a **locked, hidden HTTP header**:
     ```yaml
     jsonData:
       httpHeaderName1: 'X-Scope-OrgID'
     secureJsonData:
       httpHeaderValue1: 'payments'
     ```
   * Inside the **Search Org**, the data sources are locked to `httpHeaderValue1: 'search'`.
3. **Automate via SSO / OIDC Group Mapping:**
   In `grafana.ini`, map identity provider security groups directly to Grafana Orgs:
   ```ini
   [auth.generic_oauth.group_mapping]
   org_mapping = payments-engineering:Payments:Editor, search-engineering:Search:Editor, platform-admins:Main:Admin
   ```
*Result:* When an engineer logs in via Okta or Azure AD, they land directly inside their team's Org. They have no permission to view other teams' dashboards, and every query they run automatically executes with their own tenant ID under the hood.

---

## 5. Multi-Tenant Alerting & Escalation (No Cross-Paging)

Alerting multi-tenancy requires two isolated components: **Rule Evaluation** and **Notification Routing**.

### Step A: Isolated Rule Evaluation (Mimir Ruler)
Alert rules are maintained in Git and stored in tenant directories:
```text
/rules/
  ├── payments/
  │   └── slo-burn-rates.yaml
  └── search/
      └── latency-rules.yaml
```
The Mimir Ruler evaluates `/rules/payments/` **strictly against the `payments` tenant metric partition**. Tenant A's rules cannot see Tenant B's data, eliminating false positives caused by other teams' outages.

### Step B: Notification Routing (Alertmanager)
When an alert triggers, Alertmanager matches the `team` label and routes the payload to the corresponding escalation receiver:

```yaml
route:
  receiver: default-sink
  routes:
    - matchers:
        - team = payments
      receiver: payments-pager
      continue: false
    - matchers:
        - team = search
      receiver: search-pager
      continue: false

receivers:
  - name: payments-pager
    webhook_configs:
      - url: 'http://goalert:8080/api/v2/generic/webhook?token=PAYMENTS_GOALERT_KEY'

  - name: search-pager
    webhook_configs:
      - url: 'http://goalert:8080/api/v2/generic/webhook?token=SEARCH_GOALERT_KEY'
```

### Step C: Escalation Schedules (GoAlert / PagerDuty)
In GoAlert:
* Create a **"Payments Service"** linked to the Payments on-call rotation with API key `PAYMENTS_GOALERT_KEY`.
* Create a **"Search Service"** linked to the Search on-call rotation with API key `SEARCH_GOALERT_KEY`.

When an alert triggers, only the on-call engineer for the affected team receives SMS, phone calls, or push notifications.

---

## 6. FinOps Quotas: Preventing "Noisy Neighbors"

In multi-tenant environments, one misconfigured application logging excessively could saturate network bandwidth or run up massive storage bills.

Protect the platform with per-tenant rate limits and cardinality guards:

| Layer | FinOps Control | Mechanism & Configuration |
|---|---|---|
| **Gateway** | Tail-Sampling Budgets | Drop 99% of healthy traces for high-volume, non-critical tenants while keeping 100% of errors |
| **Loki Logs** | Ingestion Rate Limits | `limits_config.ingestion_rate_mb: 15` (caps each tenant at 15 MB/sec; rejects excess with HTTP 429) |
| **Loki Logs** | Stream Limits | `limits_config.max_streams_per_user: 10000` (prevents label cardinality explosion) |
| **Mimir Metrics** | Active Series Caps | `limits.max_global_series_per_user: 150000` (prevents high-cardinality metric attacks) |
| **Query Protection** | Query Length Limits | `limits_config.max_query_length: 721h` (blocks accidental multi-month historical scans) |

If a tenant exceeds their quota, only their excess telemetry is rate-limited. All other tenants continue processing without degradation.

---

## 7. Summary Comparison Matrix

| Multi-Tenancy Layer | Enforcement Point | Failure Mode Prevented |
|---|---|---|
| **Identity Tagging** | Workload Pods + Downward API | Missing ownership tags on telemetry |
| **Ingestion Routing** | OTel Gateway `routing` connector | Developers hardcoding credentials in apps |
| **Storage Separation** | Loki/Tempo/Mimir `auth_enabled: true` | Data leakage across tenant S3 folders |
| **Query Restriction** | Grafana Orgs + SSO Group Mapping | Developers browsing other teams' logs/traces |
| **Alert Isolation** | Mimir Ruler per-tenant rule folders | Paging the wrong team for an outage |
| **FinOps Protection** | Backend `limits_config` rate limits | One noisy team crashing the cluster |
