#!/usr/bin/env python3
"""
Scan the ossci-gitops repo and auto-generate tools/config/tenants.json.
Can run locally or in GitHub Actions.

Usage:
    python3 tools/sync-config.py                        # scan local repo
    python3 tools/sync-config.py --repo nod-ai/ossci-gitops --token ghp_...  # scan via GitHub API
"""

import argparse
import base64
import json
import os
import re
import sys
from pathlib import Path

try:
    import urllib.request
except ImportError:
    pass


KNOWN_CLUSTERS = [
    "prod-vultr-mi325", "tw-mia1-mi355-public", "do-atl1-vm-public",
    "ccs-aus-bm-pvt-prd", "vultr-ord-bm-public2", "aks-saiscale-linux",
    "aks-win-runner-large", "stg-vultr-mi325", "prod-conductor",
    "prod-conductor-mi355", "prod-oci", "aws-usea1-eks-pvt-prd",
    "aws-dev-usea1", "aws-stg-usea1",
]

NS_TO_TENANT = {
    "arc-rocm": "rocm", "arc-rocm-gpu-1": "rocm",
    "arc-meta-pytorch": "meta-pytorch",
    "arc-pytorch": "pytorch",
    "arc-pytorch-mi325-gpu-1": "pytorch", "arc-pytorch-mi325-gpu-2": "pytorch",
    "arc-pytorch-mi325-gpu-4": "pytorch", "arc-pytorch-mi325-gpu-8": "pytorch",
    "arc-sglang": "sglang",
    "arc-vllm": "vllm", "buildkite-vllm": "vllm",
    "arc-hf": "hf",
    "arc-jax": "jax", "arc-rocm-jax": "jax", "arc-xla": "jax", "jax-framework-dev": "jax",
    "arc-rad": "rad",
    "iree-dev": "iree", "arc-iree": "iree",
    "arc-iree-mi325-gpu-1": "iree", "arc-iree-mi325-gpu-2": "iree",
    "aims-dev": "aims",
    "arc-aiter": "aiter",
    "arc-triton": "triton", "arc-triton-gpu-1": "triton", "arc-triton-distributed-gpu-8": "triton",
    "arc-nod-ai": "nod-ai",
    "arc-nod-ai-mi325-gpu-1": "nod-ai", "arc-nod-ai-mi325-gpu-2": "nod-ai",
    "arc-nod-ai-mi325-gpu-8": "nod-ai",
    "arc-llvm": "llvm",
    "arc-ossci": "ossci", "arc-ossci-gitops": "ossci-gitops",
}

TENANT_LABELS = {
    "rocm": "ROCm", "meta-pytorch": "Meta PyTorch", "pytorch": "PyTorch",
    "sglang": "SGLang", "vllm": "vLLM", "hf": "HuggingFace",
    "jax": "JAX / XLA", "rad": "RAD", "iree": "IREE", "aims": "AIMS",
    "aiter": "AIter", "triton": "Triton", "nod-ai": "Nod AI", "llvm": "LLVM",
    "ossci": "OSSCI", "ossci-gitops": "OSSCI GitOps",
}

TENANT_GROUPS = {
    "rocm": "AIG-TheRock-OSSCI-Infra", "sglang": "sglang_ci_runner",
    "vllm": "frameworks-devops", "hf": "dl-automation",
    "jax": "dl.sec-JAX", "rad": "dsg.RAD_CI", "iree": "iree-dev",
    "aims": "aimsdevgroup",
}


def guess_gpu(name):
    if "mi325" in name: return "MI325X"
    if "mi355" in name: return "MI355X"
    if "mi300" in name: return "MI300X"
    if "mi350" in name: return "MI350"
    if "win" in name or "aks" in name: return "CPU"
    if "do-" in name: return "MI300X/MI350"
    if "aws" in name or "eks" in name or "conductor" in name or "oci" in name: return "Infra"
    return "GPU"


def parse_gha_runners_from_yaml(content):
    """Extract ghaRunners entries from cluster-package-values.yaml content."""
    runners = []
    in_gha = False
    in_canary = False
    current_key = None
    current_ns = None
    current_release = None

    for line in content.split("\n"):
        stripped = line.strip()

        if re.match(r"^ghaRunners:\s*$", stripped):
            in_gha = True
            in_canary = False
            continue

        if re.match(r"^canaryApps:\s*$", stripped):
            in_canary = True
            continue

        if in_gha or in_canary:
            if re.match(r"^\S", line) and not re.match(r"^(ghaRunners|canaryApps)", stripped):
                in_gha = False
                in_canary = False
                if current_key:
                    runners.append({"key": current_key, "namespace": current_ns, "label": current_release, "canary": in_canary})
                    current_key = None
                continue

            key_match = re.match(r"^\s{4,8}(\S+):\s*$", line)
            if key_match and not key_match.group(1) in ("autoSync", "enabled", "name", "namespace", "helm", "releaseName", "valueFiles", "ghaRunners"):
                if current_key and current_ns and current_release:
                    runners.append({"key": current_key, "namespace": current_ns, "label": current_release, "canary": in_canary})
                current_key = key_match.group(1)
                current_ns = None
                current_release = None

            ns_match = re.match(r"^\s+namespace:\s+(\S+)", line)
            if ns_match:
                current_ns = ns_match.group(1)

            rel_match = re.match(r"^\s+releaseName:\s+(\S+)", line)
            if rel_match:
                current_release = rel_match.group(1)

    if current_key and current_ns and current_release:
        runners.append({"key": current_key, "namespace": current_ns, "label": current_release, "canary": in_canary})

    return runners


def parse_alerts_yaml(content):
    """Extract clusterName from gha-runner-alerts values.yaml."""
    match = re.search(r'clusterName:\s*"?([^"\n]+)"?', content)
    return match.group(1) if match else None


def scan_local(repo_path):
    """Scan local repo for clusters and runners."""
    clusters_dir = Path(repo_path) / "clusters"
    config = {"clusters": {}, "tenants": {}}

    for cluster_dir in sorted(clusters_dir.iterdir()):
        if not cluster_dir.is_dir():
            continue
        cpv = cluster_dir / "cluster-package-values.yaml"
        if not cpv.exists():
            continue

        name = cluster_dir.name
        alert_name = None
        alerts_file = cluster_dir / "gha-runner-alerts" / "values.yaml"
        if alerts_file.exists():
            alert_name = parse_alerts_yaml(alerts_file.read_text(encoding="utf-8", errors="replace"))

        config["clusters"][name] = {
            "label": name.replace("-", " ").title(),
            "gpu": guess_gpu(name),
            "alertClusterName": alert_name,
        }

        content = cpv.read_text(encoding="utf-8", errors="replace")
        runners = parse_gha_runners_from_yaml(content)

        for r in runners:
            if r.get("canary"):
                continue
            ns = r["namespace"]
            tenant_id = NS_TO_TENANT.get(ns)
            if not tenant_id:
                prefix = ns.replace("arc-", "")
                tenant_id = prefix
                NS_TO_TENANT[ns] = tenant_id

            if tenant_id not in config["tenants"]:
                config["tenants"][tenant_id] = {
                    "label": TENANT_LABELS.get(tenant_id, tenant_id.replace("-", " ").title()),
                    "group": TENANT_GROUPS.get(tenant_id, ""),
                    "namespaces": [],
                    "clusters": {},
                }

            t = config["tenants"][tenant_id]
            if ns not in t["namespaces"]:
                t["namespaces"].append(ns)

            if name not in t["clusters"]:
                t["clusters"][name] = {"runners": []}

            base_label = r["label"]
            if base_label.endswith(".test"):
                base_label = base_label[:-5]

            t["clusters"][name]["runners"].append({
                "key": r["key"],
                "namespace": ns,
                "label": base_label,
            })

    # Sort tenants alphabetically
    config["tenants"] = dict(sorted(config["tenants"].items()))

    return config


def scan_github(repo, token):
    """Scan GitHub repo for clusters and runners via API."""
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github.v3+json",
    }

    def api_get(path):
        url = f"https://api.github.com/repos/{repo}/contents/{path}"
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                return json.loads(resp.read())
        except Exception as e:
            print(f"  WARN: Failed to fetch {path}: {e}", file=sys.stderr)
            return None

    def get_file_content(path):
        data = api_get(path)
        if data and "content" in data:
            return base64.b64decode(data["content"]).decode("utf-8", errors="replace")
        return None

    config = {"clusters": {}, "tenants": {}}

    items = api_get("clusters")
    if not items:
        print("ERROR: Could not list clusters directory", file=sys.stderr)
        return config

    cluster_dirs = sorted([i["name"] for i in items if i["type"] == "dir"])

    for name in cluster_dirs:
        print(f"  Scanning {name}...")

        content = get_file_content(f"clusters/{name}/cluster-package-values.yaml")
        if not content:
            continue

        alert_name = None
        alert_content = get_file_content(f"clusters/{name}/gha-runner-alerts/values.yaml")
        if alert_content:
            alert_name = parse_alerts_yaml(alert_content)

        config["clusters"][name] = {
            "label": name.replace("-", " ").title(),
            "gpu": guess_gpu(name),
            "alertClusterName": alert_name,
        }

        runners = parse_gha_runners_from_yaml(content)

        for r in runners:
            if r.get("canary"):
                continue
            ns = r["namespace"]
            tenant_id = NS_TO_TENANT.get(ns)
            if not tenant_id:
                prefix = ns.replace("arc-", "")
                tenant_id = prefix
                NS_TO_TENANT[ns] = tenant_id

            if tenant_id not in config["tenants"]:
                config["tenants"][tenant_id] = {
                    "label": TENANT_LABELS.get(tenant_id, tenant_id.replace("-", " ").title()),
                    "group": TENANT_GROUPS.get(tenant_id, ""),
                    "namespaces": [],
                    "clusters": {},
                }

            t = config["tenants"][tenant_id]
            if ns not in t["namespaces"]:
                t["namespaces"].append(ns)

            if name not in t["clusters"]:
                t["clusters"][name] = {"runners": []}

            base_label = r["label"]
            if base_label.endswith(".test"):
                base_label = base_label[:-5]

            t["clusters"][name]["runners"].append({
                "key": r["key"],
                "namespace": ns,
                "label": base_label,
            })

    config["tenants"] = dict(sorted(config["tenants"].items()))
    return config


def main():
    parser = argparse.ArgumentParser(description="Sync tenants.json from ossci-gitops repo")
    parser.add_argument("--repo", type=str, help="GitHub repo (e.g., nod-ai/ossci-gitops)")
    parser.add_argument("--token", type=str, help="GitHub token")
    parser.add_argument("--local", type=str, help="Path to local repo clone")
    parser.add_argument("--output", type=str, default=None, help="Output path (default: tools/config/tenants.json)")
    args = parser.parse_args()

    if not args.output:
        script_dir = Path(__file__).parent
        args.output = str(script_dir / "config" / "tenants.json")

    if args.repo and args.token:
        print(f"Scanning GitHub repo: {args.repo}")
        config = scan_github(args.repo, args.token)
    elif args.local:
        print(f"Scanning local repo: {args.local}")
        config = scan_local(args.local)
    else:
        repo_root = Path(__file__).parent.parent
        if (repo_root / "clusters").exists():
            print(f"Scanning local repo: {repo_root}")
            config = scan_local(str(repo_root))
        else:
            print("ERROR: Provide --repo/--token or --local, or run from the repo root", file=sys.stderr)
            sys.exit(1)

    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, "w") as f:
        json.dump(config, f, indent=2)

    n_clusters = len(config["clusters"])
    n_tenants = len(config["tenants"])
    n_runners = sum(
        len(r["runners"])
        for t in config["tenants"].values()
        for r in t["clusters"].values()
    )
    print(f"\nDone: {n_clusters} clusters, {n_tenants} tenants, {n_runners} runners")
    print(f"Written to: {args.output}")


if __name__ == "__main__":
    main()
