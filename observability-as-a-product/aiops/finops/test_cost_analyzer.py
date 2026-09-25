#!/usr/bin/env python3
"""
Test suite for FinOps Cost Analyzer (cost-analyzer.py).
Validates:
1. Live PromQL vector response parsing with tenant mapping.
2. Anomaly detection logic on real metrics.
3. Fallback behavior when Mimir endpoint fails.
4. --simulate flag behavior.
"""

import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading

class MockPrometheusHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        data = {
            "status": "success",
            "data": {
                "resultType": "vector",
                "result": [
                    {"metric": {"tenant_id": "payments"}, "value": [1710000000, "4500.5"]},
                    {"metric": {"tenant_id": "product"}, "value": [1710000000, "820.0"]}
                ]
            }
        }
        self.wfile.write(json.dumps(data).encode("utf-8"))

    def log_message(self, format, *args):
        pass

def run_tests():
    server = http.server.HTTPServer(("127.0.0.1", 19191), MockPrometheusHandler)
    t = threading.Thread(target=server.serve_forever)
    t.daemon = True
    t.start()

    with tempfile.NamedTemporaryFile(suffix=".md", delete=False) as tmp:
        tmp_report = tmp.name

    try:
        # Test 1: Live Mock PromQL query
        res = subprocess.run(
            [sys.executable, "observability-as-a-product/aiops/finops/cost-analyzer.py",
             "--prometheus-url", "http://127.0.0.1:19191",
             "--output", tmp_report],
            capture_output=True, text=True
        )
        assert res.returncode == 0, f"Expected 0, got {res.returncode}: {res.stderr}"
        assert "Successfully queried live Mimir telemetry for 2 tenants" in res.stderr
        with open(tmp_report, "r") as f:
            content = f.read()
        assert "Live Mimir/Prometheus Ingestion Vectors" in content
        assert "| `payments` | 4,500.5 | 4,500.5 | 4,500.5 |" in content
        assert "🚨 **ANOMALOUS**" in content
        print("✓ Test 1: Live vector query and parsing succeeded.")

        # Test 2: Fallback on unreachable URL
        res_fail = subprocess.run(
            [sys.executable, "observability-as-a-product/aiops/finops/cost-analyzer.py",
             "--prometheus-url", "http://127.0.0.1:19999",
             "--output", tmp_report],
            capture_output=True, text=True
        )
        assert res_fail.returncode == 0
        assert "Falling back to operational baseline data" in res_fail.stderr
        with open(tmp_report, "r") as f:
            content_fail = f.read()
        assert "Simulated Baseline Dataset" in content_fail
        print("✓ Test 2: Fallback on connection failure succeeded.")

        # Test 3: Explicit --simulate flag
        res_sim = subprocess.run(
            [sys.executable, "observability-as-a-product/aiops/finops/cost-analyzer.py",
             "--simulate",
             "--output", tmp_report],
            capture_output=True, text=True
        )
        assert res_sim.returncode == 0
        assert "--simulate flag passed" in res_sim.stderr
        print("✓ Test 3: --simulate flag succeeded.")

    finally:
        server.shutdown()
        if os.path.exists(tmp_report):
            os.remove(tmp_report)

    print("\nAll FinOps agent tests passed successfully!")

if __name__ == "__main__":
    run_tests()
