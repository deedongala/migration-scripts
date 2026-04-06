# CI Runner Migration Scripts

Automation toolkit for migrating GitHub Actions Runner Controller (ARC) runners between Kubernetes clusters (CSPs).

## Overview

These scripts automate the multi-phase migration process:

```
Shadow Deploy → Tenant Testing → Drain Source → Delete Source → Promote to Production
```

## Components

### 1. GitHub Actions Workflow (`.github/workflows/migrate-runners.yaml`)

Point-and-click migration from the GitHub UI with dropdown menus:

| Input | Type | Description |
|---|---|---|
| Tenant | Dropdown | sglang, vllm, pytorch, hf, jax, rad, iree, aims, aiter, triton |
| Phase | Dropdown | shadow, drain, delete-source, promote, verify |
| Source Cluster | Dropdown | All available clusters |
| Destination Cluster | Dropdown | All available clusters |
| Namespaces | Text | Auto-detected from tenant, or comma-separated override |
| maxRunners | Text | Capacity override (e.g. `runner-key=48`) |
| Include RBAC | Checkbox | Auto-creates RoleBinding + ClusterRoleBinding |
| Dry-run | Checkbox | Preview mode, no file changes |

### 2. Migration Script (`scripts/arc-runner-migration/migrate-runners.sh`)

Core automation that handles all phases:

```bash
# Shadow deploy (creates .test runners on destination)
./migrate-runners.sh --phase shadow --source prod-vultr-mi325 --dest do-atl1-vm-public --namespaces arc-sglang

# Drain source (sets min/maxRunners to 0)
./migrate-runners.sh --phase drain --source prod-vultr-mi325 --dest do-atl1-vm-public --namespaces arc-sglang

# Delete source configs
./migrate-runners.sh --phase delete-source --source prod-vultr-mi325 --dest do-atl1-vm-public --namespaces arc-sglang

# Promote canary to production (removes .test suffix)
./migrate-runners.sh --phase promote --source prod-vultr-mi325 --dest do-atl1-vm-public --namespaces arc-sglang

# Verify migration
./migrate-runners.sh --phase verify --source prod-vultr-mi325 --dest do-atl1-vm-public --namespaces arc-sglang

# Dry-run any phase
./migrate-runners.sh --phase shadow --source prod-vultr-mi325 --dest do-atl1-vm-public --dry-run
```

### 3. Interactive Wizard (`scripts/arc-runner-migration/migration-wizard.sh`)

Terminal-based interactive wizard with menus for tenant, cluster, mode, capacity, and RBAC selection:

```bash
./scripts/arc-runner-migration/migration-wizard.sh
```

### 4. Test Suite (`scripts/arc-runner-migration/test-migration.sh`)

End-to-end test that runs all phases on a throwaway git branch with assertions:

```bash
./scripts/arc-runner-migration/test-migration.sh
```

## Prerequisites

- `yq` v4+ — [Install](https://github.com/mikefarah/yq)
- `git`
- `gh` (GitHub CLI) — for PR creation

## Migration Flow

```
                Old Cluster              New Cluster
                ───────────              ───────────
  Shadow:       prod labels active       .test labels deployed
  Test:         tenants test on .test    tenants approve
  Soak:         prod labels active       prod labels ALSO active (24-48h)
  Drain:        maxRunners=0             sole serving cluster
  Delete:       configs removed          fully operational
  Promote:      decommissioned           .test → prod labels
```

## AD Security Group Mapping

| Group | Tenant | Namespaces |
|---|---|---|
| `sglang_ci_runner` | SGLang | arc-sglang |
| `frameworks-devops` | vLLM | arc-vllm, buildkite-vllm |
| `AIG-TheRock-OSSCI-Infra` | PyTorch/ROCm | arc-rocm, arc-meta-pytorch |
| `dl-automation` | HuggingFace | arc-hf |
| `dl.sec-JAX` | JAX/XLA | arc-jax, arc-rocm-jax, arc-xla |
| `dsg.RAD_CI` | RAD | arc-rad |
| `iree-dev` | IREE | iree-dev |
| `aimsdevgroup` | AIMS | aims-dev |
