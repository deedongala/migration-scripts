#!/usr/bin/env python3
"""
Lightweight local server that runs kubectl and serves live pod counts
to the migration dashboard. Run this in your terminal:

    python3 drain-server.py                          # default context
    python3 drain-server.py --context prod-vultr-mi325  # specific context
    python3 drain-server.py --port 8787              # custom port

The dashboard auto-connects to http://localhost:8787
"""

import argparse
import json
import subprocess
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler


def get_namespaces(context_args):
    """Get all arc-* and tenant namespaces."""
    cmd = ["kubectl"] + context_args + [
        "get", "namespaces", "-o", "jsonpath={.items[*].metadata.name}"
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
    if result.returncode != 0:
        return []
    all_ns = result.stdout.strip().split()
    return [
        ns for ns in all_ns
        if ns.startswith("arc-") or ns in (
            "iree-dev", "aims-dev", "buildkite-vllm", "jax-framework-dev"
        )
    ]


def get_pod_counts(context_args, namespaces):
    """Get pod status counts per namespace in a single kubectl call."""
    results = []
    for ns in namespaces:
        cmd = ["kubectl"] + context_args + [
            "get", "pods", "-n", ns,
            "-o", "json", "--field-selector=status.phase!=Succeeded,status.phase!=Failed"
        ]
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            if proc.returncode != 0:
                results.append({
                    "namespace": ns, "running": 0, "pending": 0,
                    "terminating": 0, "total": 0, "error": proc.stderr.strip()
                })
                continue

            data = json.loads(proc.stdout)
            pods = data.get("items", [])
            running = pending = terminating = 0
            for pod in pods:
                deletion = pod.get("metadata", {}).get("deletionTimestamp")
                phase = pod.get("status", {}).get("phase", "")
                if deletion:
                    terminating += 1
                elif phase == "Running":
                    running += 1
                elif phase == "Pending":
                    pending += 1

            results.append({
                "namespace": ns,
                "running": running,
                "pending": pending,
                "terminating": terminating,
                "total": running + pending + terminating,
            })
        except subprocess.TimeoutExpired:
            results.append({
                "namespace": ns, "running": 0, "pending": 0,
                "terminating": 0, "total": 0, "error": "kubectl timed out"
            })
        except Exception as e:
            results.append({
                "namespace": ns, "running": 0, "pending": 0,
                "terminating": 0, "total": 0, "error": str(e)
            })
    return results


def get_runner_sets(context_args, namespaces):
    """Get AutoScalingRunnerSet status for each namespace."""
    results = []
    for ns in namespaces:
        cmd = ["kubectl"] + context_args + [
            "get", "autoscalingrunnerset", "-n", ns,
            "-o", "json"
        ]
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            if proc.returncode != 0:
                continue
            data = json.loads(proc.stdout)
            for item in data.get("items", []):
                name = item.get("metadata", {}).get("name", "?")
                spec = item.get("spec", {})
                results.append({
                    "namespace": ns,
                    "name": name,
                    "minRunners": spec.get("minRunners", 0),
                    "maxRunners": spec.get("maxRunners", 0),
                })
        except Exception:
            pass
    return results


class DrainHandler(BaseHTTPRequestHandler):
    context_args = []
    cached_namespaces = None

    def do_GET(self):
        if self.path == "/health":
            self._json_response({"status": "ok"})
            return

        if self.path.startswith("/pods"):
            ns_list = DrainHandler.cached_namespaces
            if ns_list is None:
                ns_list = get_namespaces(DrainHandler.context_args)
                DrainHandler.cached_namespaces = ns_list

            ns_filter = self._param("ns")
            if ns_filter:
                ns_list = [n for n in ns_filter.split(",") if n in ns_list]

            pods = get_pod_counts(DrainHandler.context_args, ns_list)
            runners = get_runner_sets(DrainHandler.context_args, ns_list)
            self._json_response({
                "cluster": self._get_context_name(),
                "namespaces": pods,
                "runnerSets": runners,
            })
            return

        if self.path == "/namespaces":
            DrainHandler.cached_namespaces = get_namespaces(DrainHandler.context_args)
            self._json_response({"namespaces": DrainHandler.cached_namespaces})
            return

        if self.path == "/refresh-ns":
            DrainHandler.cached_namespaces = get_namespaces(DrainHandler.context_args)
            self._json_response({"namespaces": DrainHandler.cached_namespaces, "refreshed": True})
            return

        self._json_response({"error": "Not found"}, 404)

    def _param(self, key):
        if "?" not in self.path:
            return None
        query = self.path.split("?", 1)[1]
        for part in query.split("&"):
            if "=" in part:
                k, v = part.split("=", 1)
                if k == key:
                    return v
        return None

    def _get_context_name(self):
        for i, arg in enumerate(DrainHandler.context_args):
            if arg == "--context" and i + 1 < len(DrainHandler.context_args):
                return DrainHandler.context_args[i + 1]
        cmd = ["kubectl", "config", "current-context"]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
            return result.stdout.strip()
        except Exception:
            return "unknown"

    def _json_response(self, data, code=200):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        status = args[1] if len(args) > 1 else ""
        print(f"  {args[0]} -> {status}")


def main():
    parser = argparse.ArgumentParser(description="Drain monitor server for migration dashboard")
    parser.add_argument("--port", type=int, default=8787, help="Port to listen on (default: 8787)")
    parser.add_argument("--context", type=str, help="kubectl context to use")
    args = parser.parse_args()

    if args.context:
        DrainHandler.context_args = ["--context", args.context]

    server = HTTPServer(("127.0.0.1", args.port), DrainHandler)
    ctx = args.context or "(current context)"
    print(f"\n  Drain Monitor Server")
    print(f"  ────────────────────")
    print(f"  URL:      http://localhost:{args.port}")
    print(f"  Context:  {ctx}")
    print(f"  Endpoints:")
    print(f"    GET /pods          - pod counts per namespace")
    print(f"    GET /pods?ns=X,Y   - filter to specific namespaces")
    print(f"    GET /namespaces    - list namespaces")
    print(f"    GET /health        - health check")
    print(f"\n  Open the migration dashboard in your browser.")
    print(f"  Press Ctrl+C to stop.\n")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n  Server stopped.")
        server.server_close()


if __name__ == "__main__":
    main()
