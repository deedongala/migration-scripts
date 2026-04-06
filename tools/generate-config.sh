#!/usr/bin/env bash
#
# Regenerate tools/config/tenants.json from the GitOps repo.
# Run this whenever a new cluster or tenant is onboarded.
#
# Usage:
#   bash tools/generate-config.sh
#
# Requires: yq, jq

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/tools/config"
OUTPUT="$CONFIG_DIR/tenants.json"
mkdir -p "$CONFIG_DIR"

CLUSTER_DIRS=(
  prod-vultr-mi325
  tw-mia1-mi355-public
  do-atl1-vm-public
  ccs-aus-bm-pvt-prd
  vultr-ord-bm-public2
  aks-saiscale-linux
)

echo '{ "clusters": {}, "tenants": {} }' > "$OUTPUT"

for cluster in "${CLUSTER_DIRS[@]}"; do
  CPV="$REPO_ROOT/clusters/$cluster/cluster-package-values.yaml"
  ALERTS="$REPO_ROOT/clusters/$cluster/gha-runner-alerts/values.yaml"

  if [[ ! -f "$CPV" ]]; then
    echo "SKIP: $cluster (no cluster-package-values.yaml)"
    continue
  fi

  # Get GPU type from directory name heuristic
  GPU="unknown"
  case "$cluster" in
    *mi325*)  GPU="MI325X" ;;
    *mi355*)  GPU="MI355X" ;;
    *mi300*)  GPU="MI300X" ;;
    *aks*)    GPU="CPU" ;;
    *do-*)    GPU="MI300X/MI350" ;;
    *ccs*)    GPU="MI300X" ;;
  esac

  # Get alert cluster name
  ALERT_NAME="null"
  if [[ -f "$ALERTS" ]]; then
    ALERT_NAME=$(yq eval '.clusterName' "$ALERTS" 2>/dev/null || echo "null")
    if [[ "$ALERT_NAME" != "null" ]]; then
      ALERT_NAME="\"$ALERT_NAME\""
    fi
  fi

  # Pretty label from directory name
  LABEL=$(echo "$cluster" | sed 's/-/ /g' | sed 's/\b\(.\)/\u\1/g')

  # Add cluster to config
  jq --arg c "$cluster" --arg l "$LABEL" --arg g "$GPU" --argjson a "$ALERT_NAME" \
    '.clusters[$c] = { label: $l, gpu: $g, alertClusterName: $a }' \
    "$OUTPUT" > "$OUTPUT.tmp" && mv "$OUTPUT.tmp" "$OUTPUT"

  # Extract ghaRunners
  RUNNERS=$(yq eval -o=json '.argocdApplications.ghaRunners // {}' "$CPV" 2>/dev/null)
  if [[ -n "$RUNNERS" && "$RUNNERS" != "{}" && "$RUNNERS" != "null" ]]; then
    echo "$RUNNERS" | jq -r 'to_entries[] | "\(.key)|\(.value.namespace // "")|\(.value.helm.releaseName // "")"' 2>/dev/null | while IFS='|' read -r key ns release; do
      if [[ -n "$ns" && -n "$release" && "$ns" != "null" && "$release" != "null" ]]; then
        echo "  $cluster: $ns -> $release ($key)"
      fi
    done
  fi

  echo "OK: $cluster"
done

echo ""
echo "Config written to: $OUTPUT"
echo ""
echo "NOTE: Tenant groupings (which runners belong to which tenant) must be"
echo "      maintained manually in tenants.json since the repo doesn't encode"
echo "      tenant ownership directly. The cluster list is auto-generated."
echo ""
echo "To add a new cluster, add its directory name to CLUSTER_DIRS in this script."
