#!/usr/bin/env python3
"""AWS-native (CloudWatch) vs self-hosted LGTM cost model. us-east-1 list prices, Oct 2026.
Rates come from the AWS Price List API (AmazonCloudWatch, AmazonPrometheus, AmazonGrafana)
and aws.amazon.com/devops-agent/pricing. Volume assumptions follow the repo's README:
1 App QPS = 8 spans + 2 logs per second."""
import json, sys

SEC = 2_628_000            # 730 h
GB = 1024 ** 3

# ---- repo cost (infra only, from README.md / cost-calculation-draft.md) ----
TIERS = {
    #  qps     lgtm_total  lgtm_amp  repo_compute  series   dashboards alarms  incidents  DB_vCPU  ops_fte_lgtm ops_fte_aws
    2_000:   dict(lgtm=1_000,  amp=1_150,  compute=800,    series=19_000,    dash=5,   alarms=50,   inc=10,   fte_l=0.25, fte_a=0.05, aws_misc=100),
    20_000:  dict(lgtm=4_660,  amp=6_660,  compute=3_080,  series=280_000,   dash=20,  alarms=300,  inc=80,   fte_l=0.5,  fte_a=0.1,  aws_misc=500),
    50_000:  dict(lgtm=9_710,  amp=15_210, compute=6_160,  series=625_000,   dash=40,  alarms=800,  inc=200,  fte_l=1.0,  fte_a=0.2,  aws_misc=1_000),
    100_000: dict(lgtm=18_320, amp=31_320, compute=12_320, series=955_000,   dash=60,  alarms=1500, inc=500,  fte_l=1.5,  fte_a=0.3,  aws_misc=2_000),
    200_000: dict(lgtm=33_170, amp=49_870, compute=23_170, series=1_600_000, dash=100, alarms=3000, inc=1000, fte_l=2.0,  fte_a=0.5,  aws_misc=4_000),
}
FTE = 15_000  # loaded $/FTE-month (assumption)

# ---- AWS unit prices ----
LOG_STD, LOG_IA, LOG_STORE, LOG_SCAN = 0.50, 0.25, 0.03, 0.005
OTEL_M, OTEL_CI = 0.50, 0.08                      # $/GB ingested
SPAN_TIERS = [(10 * 1024, 0.35), (20 * 1024, 0.20), (float("inf"), 0.15)]
IDX_PER_M = 0.75
ALARM, DASH = 0.10, 3.00
DEVOPS_AGENT_SEC = 0.0083


def tiered(gb, tiers):
    cost, left = 0.0, gb
    for size, rate in tiers:
        take = min(left, size)
        cost += take * rate
        left -= take
        if left <= 0:
            break
    return cost


def volumes(qps, span_b=1024, log_b=512, sample_b=400):
    spans = 8 * qps * SEC
    logs = 2 * qps * SEC
    return dict(span_gb=spans * span_b / GB, log_gb=logs * log_b / GB)


def aws_native(qps, t, tuned, best=False):
    v = volumes(qps, span_b=512 if best else 1024)
    if best:
        trace_frac, log_frac, log_rate, series_frac = 0.02, 0.25, LOG_IA, 0.35
        collectors = 0.40 * t["compute"]
    elif tuned:
        trace_frac, log_frac, log_rate, series_frac = 0.05, 0.5, LOG_IA, 0.5
        collectors = 0.40 * t["compute"]        # tail-sampling / filtering gateway fleet
    else:
        trace_frac, log_frac, log_rate, series_frac = 1.0, 1.0, LOG_STD, 1.0
        collectors = 0.10 * t["compute"]        # DaemonSet + small gateway only
    span_gb = v["span_gb"] * trace_frac
    traces = tiered(span_gb, SPAN_TIERS)
    spans_total = 8 * qps * SEC * trace_frac
    indexed = max(0.0, spans_total * 0.02 - spans_total * 0.01) * IDX_PER_M / 1e6   # 2% indexed, 1% bundled
    log_gb = v["log_gb"] * log_frac
    logs_ingest = log_gb * log_rate
    logs_store = log_gb * 0.2 * (14 / 30) * LOG_STORE          # 14-day retention, ~5:1 compression
    logs_scan = log_gb * LOG_SCAN                             # scan each GB once
    series = t["series"] * series_frac
    metric_gb = series * 86_400 * 400 / GB                    # 30s scrape, 400 B/sample
    infra_gb, app_gb = 0.6 * metric_gb, 0.4 * metric_gb
    metrics = infra_gb * OTEL_CI + app_gb * OTEL_M
    dash_alarm = t["dash"] * DASH + t["alarms"] * ALARM
    net = (log_gb + span_gb + metric_gb) * 0.2 * 0.01         # PrivateLink $0.01/GB on ~compressed bytes
    agent = t["inc"] * 8 * 60 * DEVOPS_AGENT_SEC
    parts = dict(traces=traces + indexed, logs=logs_ingest + logs_store + logs_scan,
                 metrics=metrics, dash_alarms=dash_alarm, collectors=collectors,
                 network=net, aws_services=t["aws_misc"])
    parts["total"] = sum(parts.values())
    parts["devops_agent"] = agent
    parts["labor"] = t["fte_a"] * FTE
    parts["metric_gb"] = metric_gb; parts["log_gb"] = log_gb; parts["span_gb"] = span_gb
    return parts


def lgtm(qps, t):
    base = t["lgtm"]
    grafana_ha = {2_000: 100, 20_000: 150, 50_000: 250, 100_000: 350, 200_000: 500}[qps]
    agent = t["inc"] * 8 * 60 * DEVOPS_AGENT_SEC
    return dict(infra=base, grafana_ha=grafana_ha, devops_agent=agent,
                total=base + grafana_ha, labor=t["fte_l"] * FTE)


def hybrid(qps, t):
    l = lgtm(qps, t)
    aws = t["aws_misc"] + t["dash"] * 0.2 * DASH                # vended AWS signals only
    amg = 9 * 10 + 5 * 40 if qps >= 20_000 else 9 * 3 + 5 * 10  # optional AMG seats
    total = l["total"] + aws
    return dict(lgtm=l["total"], aws_services=aws, devops_agent=l["devops_agent"], total=total,
                labor=t["fte_l"] * FTE * 1.1, amg_alt=amg)


if __name__ == "__main__":
    out = {}
    for q, t in TIERS.items():
        out[q] = dict(a1=aws_native(q, t, False), a2=aws_native(q, t, True), a3=aws_native(q, t, True, True), lgtm=lgtm(q, t), hybrid=hybrid(q, t))
    json.dump(out, sys.stdout, indent=1, default=float)
