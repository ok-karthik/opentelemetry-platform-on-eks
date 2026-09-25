#!/usr/bin/env python3
"""
Renders the Terraform Helm value templates (*.tftpl) for local portability testing (kind/k3d/MinIO)
using native Terraform templatefile() execution. Zero regex parsing; 100% Terraform syntax fidelity.
"""

import os
import subprocess
import sys

ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
RENDER_DIR = os.path.join(ROOT_DIR, "terraform", "local", "render")
OUTPUT_DIR = os.path.join(ROOT_DIR, ".local-render")

COMPONENTS = ["loki", "tempo", "mimir", "grafana"]

def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # 1. Initialize Terraform in local/render
    init_cmd = ["terraform", f"-chdir={RENDER_DIR}", "init", "-input=false"]
    init_res = subprocess.run(init_cmd, capture_output=True, text=True)
    if init_res.returncode != 0:
        print(f"Error initializing Terraform in {RENDER_DIR}:\n{init_res.stderr}", file=sys.stderr)
        sys.exit(init_res.returncode)

    # 2. Apply to compute outputs
    apply_cmd = ["terraform", f"-chdir={RENDER_DIR}", "apply", "-auto-approve", "-input=false"]
    apply_res = subprocess.run(apply_cmd, capture_output=True, text=True)
    if apply_res.returncode != 0:
        print(f"Error applying Terraform in {RENDER_DIR}:\n{apply_res.stderr}", file=sys.stderr)
        sys.exit(apply_res.returncode)

    # 3. Extract rendered YAML via terraform output
    for comp in COMPONENTS:
        out_cmd = ["terraform", f"-chdir={RENDER_DIR}", "output", "-raw", comp]
        out_res = subprocess.run(out_cmd, capture_output=True, text=True)
        if out_res.returncode != 0:
            print(f"Error fetching output '{comp}':\n{out_res.stderr}", file=sys.stderr)
            sys.exit(out_res.returncode)

        target_path = os.path.join(OUTPUT_DIR, f"{comp}.yaml")
        with open(target_path, "w") as f:
            f.write(out_res.stdout)

        print(f"Rendered {comp}.yaml via native terraform templatefile() -> {target_path}")

if __name__ == "__main__":
    main()
