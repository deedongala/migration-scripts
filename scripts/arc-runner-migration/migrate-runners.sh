#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLUSTERS_DIR="$REPO_ROOT/clusters"

# ─── Defaults ────────────────────────────────────────────────────────────────
PHASE=""
SOURCE_CLUSTER=""
DEST_CLUSTER=""
NAMESPACES=""
DRY_RUN=false

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ─── Usage ───────────────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage: migrate-runners.sh --phase <phase> --source <cluster> --dest <cluster> [--namespaces <ns1,ns2,...>] [--dry-run]

Phases:
  shadow          Deploy shadow/canary runners on destination cluster with .test release names
  drain           Set minRunners=0, maxRunners=0 on source cluster runners
  delete-source   Remove runners, namespaces, and ESO config from source cluster
  promote         Move canaryApps entries to ghaRunners on destination (remove .test suffix)
  verify          Read-only check that migration landed correctly on main

Options:
  --phase         Migration phase (required)
  --source        Source cluster name, e.g. prod-vultr-mi325 (required)
  --dest          Destination cluster name, e.g. tw-mia1-mi355-public (required)
  --namespaces    Comma-separated namespace list, or "all" to auto-detect (default: all)
  --dry-run       Preview changes without modifying files

Examples:
  # Auto-detect namespaces and deploy shadow runners
  ./migrate-runners.sh --phase shadow --source prod-vultr-mi325 --dest tw-mia1-mi355-public

  # Migrate specific namespaces
  ./migrate-runners.sh --phase shadow --source prod-vultr-mi325 --dest tw-mia1-mi355-public --namespaces arc-sglang,arc-pytorch-mi325-gpu-1
EOF
    exit 1
}

# ─── Argument Parsing ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --phase)      PHASE="$2"; shift 2 ;;
        --source)     SOURCE_CLUSTER="$2"; shift 2 ;;
        --dest)       DEST_CLUSTER="$2"; shift 2 ;;
        --namespaces) NAMESPACES="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        -h|--help)    usage ;;
        *)            log_error "Unknown argument: $1"; usage ;;
    esac
done

[[ -z "$PHASE" ]] && { log_error "--phase is required"; usage; }
[[ -z "$SOURCE_CLUSTER" ]] && { log_error "--source is required"; usage; }
[[ -z "$DEST_CLUSTER" ]] && { log_error "--dest is required"; usage; }

# ─── Validate prerequisites ─────────────────────────────────────────────────
if ! command -v yq &> /dev/null; then
    log_error "yq (v4+) is required but not found. Install from https://github.com/mikefarah/yq"
    exit 1
fi

SOURCE_DIR="$CLUSTERS_DIR/$SOURCE_CLUSTER"
DEST_DIR="$CLUSTERS_DIR/$DEST_CLUSTER"
SOURCE_VALUES="$SOURCE_DIR/cluster-package-values.yaml"
DEST_VALUES="$DEST_DIR/cluster-package-values.yaml"
SOURCE_ESO="$SOURCE_DIR/external-secrets/values.yaml"
DEST_ESO="$DEST_DIR/external-secrets/values.yaml"

[[ -d "$SOURCE_DIR" ]] || { log_error "Source cluster directory not found: $SOURCE_DIR"; exit 1; }
[[ -d "$DEST_DIR" ]]   || { log_error "Destination cluster directory not found: $DEST_DIR"; exit 1; }
[[ -f "$SOURCE_VALUES" ]] || { log_error "Source cluster-package-values.yaml not found"; exit 1; }
[[ -f "$DEST_VALUES" ]]   || { log_error "Destination cluster-package-values.yaml not found"; exit 1; }

# ─── Auto-detect namespaces ─────────────────────────────────────────────────
autodetect_namespaces() {
    local values_file="$1"
    local ns_list=()

    # Collect unique namespaces from ghaRunners entries (buildkite runners not supported)
    while IFS= read -r ns; do
        [[ -n "$ns" ]] && ns_list+=("$ns")
    done < <(yq eval '.argocdApplications.ghaRunners.[] | .namespace' "$values_file" 2>/dev/null | sort -u)

    # Deduplicate and exclude system namespaces (arc controller, ossci-gitops canary)
    printf '%s\n' "${ns_list[@]}" | sort -u | grep -v '^arc$' | grep -v '^arc-ossci-gitops$' | grep -v '^arc-ossci$'
}

resolve_namespaces() {
    if [[ -z "$NAMESPACES" || "$NAMESPACES" == "all" ]]; then
        log_info "Auto-detecting runner namespaces from $SOURCE_CLUSTER..."
        NAMESPACE_ARRAY=()
        while IFS= read -r ns; do
            [[ -n "$ns" ]] && NAMESPACE_ARRAY+=("$ns")
        done < <(autodetect_namespaces "$SOURCE_VALUES")

        if [[ ${#NAMESPACE_ARRAY[@]} -eq 0 ]]; then
            log_error "No runner namespaces found on source cluster"
            exit 1
        fi
        log_info "Detected namespaces: ${NAMESPACE_ARRAY[*]}"
    else
        IFS=',' read -ra NAMESPACE_ARRAY <<< "$NAMESPACES"
    fi
}

# ─── Helper: preserve blank lines during yq edits ───────────────────────────
# yq strips blank lines; this preserves them using sentinel comments
yq_edit() {
    local file="$1"
    shift
    sed -i 's/^$/ #BLANK_LINE/' "$file"
    yq eval "$@" -i "$file"
    sed -i 's/ *#BLANK_LINE//g' "$file"
}

# ─── Helper: get runner entries for a namespace ──────────────────────────────
get_runner_keys_for_namespace() {
    local values_file="$1"
    local section="$2"  # ghaRunners or buildkite
    local namespace="$3"
    yq eval ".argocdApplications.${section} | to_entries | .[] | select(.value.namespace == \"${namespace}\") | .key" "$values_file" 2>/dev/null
}

# ─── Helper: create namespace directory and manifest ─────────────────────────
create_namespace_dir() {
    local cluster_dir="$1"
    local ns="$2"
    local ns_dir="$cluster_dir/namespaces/$ns"

    if [[ -d "$ns_dir" ]]; then
        log_warn "Namespace directory already exists: $ns_dir (skipping creation)"
        return 0
    fi

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would create: $ns_dir/namespace.yaml"
        return 0
    fi

    mkdir -p "$ns_dir"
    cat > "$ns_dir/namespace.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $ns
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
  labels:
    platform.amd.com/namespace-type: arc-runner
EOF
    log_ok "Created $ns_dir/namespace.yaml"
}

# ─── Helper: copy runner value files ─────────────────────────────────────────
copy_runner_value_files() {
    local src_values_file="$1"
    local section="$2"
    local ns="$3"
    local runner_key="$4"

    local value_path
    value_path=$(yq eval ".argocdApplications.${section}.\"${runner_key}\".helm.valueFiles" "$src_values_file")

    # Handle both string and array valueFiles
    if [[ "$value_path" == "["* ]] || [[ "$value_path" == "- "* ]]; then
        value_path=$(yq eval ".argocdApplications.${section}.\"${runner_key}\".helm.valueFiles[0]" "$src_values_file")
    fi

    [[ -z "$value_path" || "$value_path" == "null" ]] && return 0

    # If it's a shared package path, no copy needed
    if [[ "$value_path" == packages/* ]]; then
        log_info "  Value file uses shared path: $value_path (no copy needed)"
        return 0
    fi

    # It's a cluster-specific path — copy to destination
    local src_file="$REPO_ROOT/$value_path"
    if [[ ! -f "$src_file" ]]; then
        log_warn "  Source value file not found: $src_file"
        return 0
    fi

    # Rewrite path: clusters/<source>/... → clusters/<dest>/...
    local dest_value_path="${value_path/$SOURCE_CLUSTER/$DEST_CLUSTER}"
    local dest_file="$REPO_ROOT/$dest_value_path"
    local dest_file_dir
    dest_file_dir=$(dirname "$dest_file")

    if $DRY_RUN; then
        log_info "  [DRY-RUN] Would copy: $value_path → $dest_value_path"
        return 0
    fi

    mkdir -p "$dest_file_dir"
    cp "$src_file" "$dest_file"
    log_ok "  Copied value file: $dest_value_path"
}

# ─── Helper: get the rewritten valueFiles path for destination ───────────────
get_dest_value_path() {
    local src_values_file="$1"
    local section="$2"
    local runner_key="$3"

    local value_path
    value_path=$(yq eval ".argocdApplications.${section}.\"${runner_key}\".helm.valueFiles" "$src_values_file")

    if [[ "$value_path" == "["* ]] || [[ "$value_path" == "- "* ]]; then
        value_path=$(yq eval ".argocdApplications.${section}.\"${runner_key}\".helm.valueFiles[0]" "$src_values_file")
    fi

    if [[ "$value_path" == packages/* ]]; then
        echo "$value_path"
    else
        echo "${value_path/$SOURCE_CLUSTER/$DEST_CLUSTER}"
    fi
}

# ─── Helper: copy ESO secrets for a namespace ───────────────────────────────
copy_eso_secrets() {
    local ns="$1"

    if [[ ! -f "$SOURCE_ESO" ]]; then
        log_warn "Source external-secrets/values.yaml not found, skipping ESO copy for $ns"
        return 0
    fi

    local has_secrets
    has_secrets=$(yq eval ".clusterSecrets.\"${ns}\" | length" "$SOURCE_ESO" 2>/dev/null)
    if [[ "$has_secrets" == "0" || "$has_secrets" == "null" ]]; then
        log_warn "No ESO secrets found for namespace $ns on source cluster"
        return 0
    fi

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would copy ESO secrets for $ns to $DEST_ESO"
        return 0
    fi

    # Ensure dest ESO file exists with basic structure
    if [[ ! -f "$DEST_ESO" ]]; then
        mkdir -p "$(dirname "$DEST_ESO")"
        cat > "$DEST_ESO" <<EOF
clusterName: $DEST_CLUSTER
secretStoreRef: aws-secrets-manager

clusterSecrets: {}
EOF
        log_ok "Created $DEST_ESO"
    fi

    # Check if namespace already exists in dest ESO
    local dest_has_secrets
    dest_has_secrets=$(yq eval ".clusterSecrets.\"${ns}\" | length" "$DEST_ESO" 2>/dev/null)
    if [[ "$dest_has_secrets" != "0" && "$dest_has_secrets" != "null" ]]; then
        log_warn "ESO secrets for $ns already exist on destination, skipping"
        return 0
    fi

    # Extract the secrets block from source to a temp file, then merge into dest
    local tmp_secrets
    tmp_secrets=$(mktemp)
    yq eval ".clusterSecrets.\"${ns}\"" "$SOURCE_ESO" > "$tmp_secrets"

    sed -i 's/^$/ #BLANK_LINE/' "$DEST_ESO"
    yq eval -i ".clusterSecrets.\"${ns}\" = load(\"${tmp_secrets}\")" "$DEST_ESO"
    sed -i 's/ *#BLANK_LINE//g' "$DEST_ESO"
    rm -f "$tmp_secrets"
    log_ok "Copied ESO secrets for $ns to destination"
}

# ─── PHASE: shadow ───────────────────────────────────────────────────────────
phase_shadow() {
    log_info "=== Phase: SHADOW DEPLOY ==="
    log_info "Source: $SOURCE_CLUSTER → Destination: $DEST_CLUSTER"
    log_info "Namespaces: ${NAMESPACE_ARRAY[*]}"
    echo ""

    for ns in "${NAMESPACE_ARRAY[@]}"; do
        log_info "── Processing namespace: $ns ──"

        # 1. Create namespace directory on destination
        create_namespace_dir "$DEST_DIR" "$ns"

        # 2. Copy runner value files and build canaryApps runner entries
        local runner_keys
        runner_keys=$(get_runner_keys_for_namespace "$SOURCE_VALUES" "ghaRunners" "$ns")

        if [[ -n "$runner_keys" ]]; then
            while IFS= read -r key; do
                [[ -z "$key" ]] && continue
                log_info "  Processing ghaRunners runner: $key"

                # Copy value files
                copy_runner_value_files "$SOURCE_VALUES" "ghaRunners" "$ns" "$key"

                local dest_value_path
                dest_value_path=$(get_dest_value_path "$SOURCE_VALUES" "ghaRunners" "$key")

                local release_name
                release_name=$(yq eval ".argocdApplications.ghaRunners.\"${key}\".helm.releaseName" "$SOURCE_VALUES")

                if $DRY_RUN; then
                    log_info "  [DRY-RUN] Would add to canaryApps.ghaRunners: $key (releaseName: ${release_name}.test)"
                    continue
                fi

                # Ensure canaryApps structure exists
                local has_canary
                has_canary=$(yq eval '.argocdApplications.canaryApps' "$DEST_VALUES")
                if [[ "$has_canary" == "null" ]]; then
                    yq_edit "$DEST_VALUES" '.argocdApplications.canaryApps.enabled = true | .argocdApplications.canaryApps.targetRevision = "staging"'
                fi

                # Add the runner entry with .test suffix on releaseName
                yq_edit "$DEST_VALUES" "
                    .argocdApplications.canaryApps.ghaRunners.\"${key}\" = {
                        \"autoSync\": true,
                        \"enabled\": true,
                        \"name\": \"${key}\",
                        \"namespace\": \"${ns}\",
                        \"helm\": {
                            \"releaseName\": \"${release_name}.test\",
                            \"valueFiles\": \"${dest_value_path}\"
                        }
                    }
                "
                log_ok "  Added canaryApps.ghaRunners.$key (releaseName: ${release_name}.test)"
            done <<< "$runner_keys"
        fi

        # 3. Add namespace to canaryApps.namespaces
        if ! $DRY_RUN; then
            local already_in_canary_ns
            already_in_canary_ns=$(yq eval ".argocdApplications.canaryApps.namespaces[] | select(. == \"$ns\")" "$DEST_VALUES" 2>/dev/null)
            if [[ -z "$already_in_canary_ns" ]]; then
                yq_edit "$DEST_VALUES" ".argocdApplications.canaryApps.namespaces += [\"$ns\"]"
                log_ok "Added $ns to canaryApps.namespaces"
            else
                log_warn "$ns already in canaryApps.namespaces"
            fi
        else
            log_info "[DRY-RUN] Would add $ns to canaryApps.namespaces"
        fi

        # 4. Add namespace to canaryApps.externalSecrets
        if ! $DRY_RUN; then
            local already_in_canary_es
            already_in_canary_es=$(yq eval ".argocdApplications.canaryApps.externalSecrets[] | select(. == \"$ns\")" "$DEST_VALUES" 2>/dev/null)
            if [[ -z "$already_in_canary_es" ]]; then
                yq_edit "$DEST_VALUES" ".argocdApplications.canaryApps.externalSecrets += [\"$ns\"]"
                log_ok "Added $ns to canaryApps.externalSecrets"
            else
                log_warn "$ns already in canaryApps.externalSecrets"
            fi
        else
            log_info "[DRY-RUN] Would add $ns to canaryApps.externalSecrets"
        fi

        # 5. Copy ESO secret definitions
        copy_eso_secrets "$ns"

        echo ""
    done

    log_ok "=== Shadow deploy complete ==="
}

# ─── PHASE: drain ────────────────────────────────────────────────────────────
phase_drain() {
    log_info "=== Phase: DRAIN SOURCE ==="
    log_info "Source: $SOURCE_CLUSTER"
    log_info "Namespaces: ${NAMESPACE_ARRAY[*]}"
    echo ""

    for ns in "${NAMESPACE_ARRAY[@]}"; do
        log_info "── Draining namespace: $ns ──"

        local runner_keys
        runner_keys=$(get_runner_keys_for_namespace "$SOURCE_VALUES" "ghaRunners" "$ns")
        [[ -z "$runner_keys" ]] && { echo ""; continue; }

        while IFS= read -r key; do
            [[ -z "$key" ]] && continue

            local value_path
            value_path=$(yq eval ".argocdApplications.ghaRunners.\"${key}\".helm.valueFiles" "$SOURCE_VALUES")
            if [[ "$value_path" == "["* ]] || [[ "$value_path" == "- "* ]]; then
                value_path=$(yq eval ".argocdApplications.ghaRunners.\"${key}\".helm.valueFiles[0]" "$SOURCE_VALUES")
            fi

            local value_file="$REPO_ROOT/$value_path"

            if [[ ! -f "$value_file" ]]; then
                log_warn "  Value file not found: $value_path (skipping drain for $key)"
                continue
            fi

            if $DRY_RUN; then
                log_info "  [DRY-RUN] Would set minRunners=0, maxRunners=0 in $value_path"
            else
                yq eval '.minRunners = 0 | .maxRunners = 0' -i "$value_file"
                log_ok "  Set minRunners=0, maxRunners=0 in $value_path"
            fi
        done <<< "$runner_keys"
        echo ""
    done

    log_ok "=== Drain complete ==="
}

# ─── PHASE: delete-source ────────────────────────────────────────────────────
phase_delete_source() {
    log_info "=== Phase: DELETE SOURCE ==="
    log_info "Source: $SOURCE_CLUSTER"
    log_info "Namespaces: ${NAMESPACE_ARRAY[*]}"
    echo ""

    for ns in "${NAMESPACE_ARRAY[@]}"; do
        log_info "── Deleting from source: $ns ──"

        # 1. Remove runner entries from ghaRunners
        local runner_keys
        runner_keys=$(get_runner_keys_for_namespace "$SOURCE_VALUES" "ghaRunners" "$ns")

        if [[ -n "$runner_keys" ]]; then
            while IFS= read -r key; do
                [[ -z "$key" ]] && continue

                if $DRY_RUN; then
                    log_info "  [DRY-RUN] Would remove ghaRunners.$key"
                    continue
                fi

                yq_edit "$SOURCE_VALUES" "del(.argocdApplications.ghaRunners.\"${key}\")"
                log_ok "  Removed ghaRunners.$key"
            done <<< "$runner_keys"
        fi

        # 2. Remove from namespaceManager.namespaces
        if $DRY_RUN; then
            log_info "  [DRY-RUN] Would remove $ns from namespaceManager.namespaces"
        else
            yq_edit "$SOURCE_VALUES" "del(.argocdApplications.namespaceManager.namespaces[] | select(. == \"$ns\"))"
            log_ok "  Removed $ns from namespaceManager.namespaces"
        fi

        # 3. Remove from externalSecrets.namespaces
        if $DRY_RUN; then
            log_info "  [DRY-RUN] Would remove $ns from externalSecrets.namespaces"
        else
            yq_edit "$SOURCE_VALUES" "del(.argocdApplications.externalSecrets.namespaces[] | select(. == \"$ns\"))"
            log_ok "  Removed $ns from externalSecrets.namespaces"
        fi

        # 4. Remove ESO secret definitions
        if [[ -f "$SOURCE_ESO" ]]; then
            local has_secrets
            has_secrets=$(yq eval ".clusterSecrets.\"${ns}\" | length" "$SOURCE_ESO" 2>/dev/null)
            if [[ "$has_secrets" != "0" && "$has_secrets" != "null" ]]; then
                if $DRY_RUN; then
                    log_info "  [DRY-RUN] Would remove clusterSecrets.$ns from source ESO"
                else
                    yq_edit "$SOURCE_ESO" "del(.clusterSecrets.\"${ns}\")"
                    log_ok "  Removed clusterSecrets.$ns from source ESO"
                fi
            fi
        fi

        echo ""
    done

    log_ok "=== Delete source complete ==="
}

# ─── PHASE: promote ──────────────────────────────────────────────────────────
phase_promote() {
    log_info "=== Phase: PROMOTE CANARY TO PRODUCTION ==="
    log_info "Destination: $DEST_CLUSTER"
    log_info "Namespaces: ${NAMESPACE_ARRAY[*]}"
    echo ""

    for ns in "${NAMESPACE_ARRAY[@]}"; do
        log_info "── Promoting namespace: $ns ──"

        # 1. Move runner entries from canaryApps.ghaRunners to ghaRunners
        local canary_keys
        canary_keys=$(yq eval ".argocdApplications.canaryApps.ghaRunners | to_entries | .[] | select(.value.namespace == \"${ns}\") | .key" "$DEST_VALUES" 2>/dev/null)

        if [[ -n "$canary_keys" ]]; then
            while IFS= read -r key; do
                [[ -z "$key" ]] && continue

                local release_name
                release_name=$(yq eval ".argocdApplications.canaryApps.ghaRunners.\"${key}\".helm.releaseName" "$DEST_VALUES")
                # Remove .test suffix
                local prod_release_name="${release_name%.test}"

                local runner_entry
                runner_entry=$(yq eval ".argocdApplications.canaryApps.ghaRunners.\"${key}\"" "$DEST_VALUES")

                if $DRY_RUN; then
                    log_info "  [DRY-RUN] Would move canaryApps.ghaRunners.$key → ghaRunners.$key (releaseName: $prod_release_name)"
                    continue
                fi

                # Copy entry to ghaRunners with corrected releaseName
                yq_edit "$DEST_VALUES" ".argocdApplications.ghaRunners.\"${key}\" = .argocdApplications.canaryApps.ghaRunners.\"${key}\""
                yq_edit "$DEST_VALUES" ".argocdApplications.ghaRunners.\"${key}\".helm.releaseName = \"${prod_release_name}\""

                # Remove from canaryApps
                yq_edit "$DEST_VALUES" "del(.argocdApplications.canaryApps.ghaRunners.\"${key}\")"

                log_ok "  Moved $key to ghaRunners (releaseName: $prod_release_name)"
            done <<< "$canary_keys"
        fi

        # 2. Move namespace from canaryApps.namespaces to namespaceManager.namespaces
        if $DRY_RUN; then
            log_info "  [DRY-RUN] Would move $ns from canaryApps.namespaces → namespaceManager.namespaces"
        else
            local in_canary_ns
            in_canary_ns=$(yq eval ".argocdApplications.canaryApps.namespaces[] | select(. == \"$ns\")" "$DEST_VALUES" 2>/dev/null)
            if [[ -n "$in_canary_ns" ]]; then
                yq_edit "$DEST_VALUES" "del(.argocdApplications.canaryApps.namespaces[] | select(. == \"$ns\"))"

                local already_in_ns_mgr
                already_in_ns_mgr=$(yq eval ".argocdApplications.namespaceManager.namespaces[] | select(. == \"$ns\")" "$DEST_VALUES" 2>/dev/null)
                if [[ -z "$already_in_ns_mgr" ]]; then
                    yq_edit "$DEST_VALUES" ".argocdApplications.namespaceManager.namespaces += [\"$ns\"]"
                    yq_edit "$DEST_VALUES" '.argocdApplications.namespaceManager.namespaces |= sort'
                fi
                log_ok "  Moved $ns to namespaceManager.namespaces"
            fi
        fi

        # 3. Move namespace from canaryApps.externalSecrets to externalSecrets.namespaces
        if $DRY_RUN; then
            log_info "  [DRY-RUN] Would move $ns from canaryApps.externalSecrets → externalSecrets.namespaces"
        else
            local in_canary_es
            in_canary_es=$(yq eval ".argocdApplications.canaryApps.externalSecrets[] | select(. == \"$ns\")" "$DEST_VALUES" 2>/dev/null)
            if [[ -n "$in_canary_es" ]]; then
                yq_edit "$DEST_VALUES" "del(.argocdApplications.canaryApps.externalSecrets[] | select(. == \"$ns\"))"

                local already_in_es
                already_in_es=$(yq eval ".argocdApplications.externalSecrets.namespaces[] | select(. == \"$ns\")" "$DEST_VALUES" 2>/dev/null)
                if [[ -z "$already_in_es" ]]; then
                    yq_edit "$DEST_VALUES" ".argocdApplications.externalSecrets.namespaces += [\"$ns\"]"
                    yq_edit "$DEST_VALUES" '.argocdApplications.externalSecrets.namespaces |= sort'
                fi
                log_ok "  Moved $ns to externalSecrets.namespaces"
            fi
        fi

        echo ""
    done

    log_ok "=== Promote complete ==="
}

# ─── PHASE: verify ────────────────────────────────────────────────────────
phase_verify() {
    log_info "=== Phase: VERIFY MIGRATION ==="
    log_info "Source: $SOURCE_CLUSTER"
    log_info "Destination: $DEST_CLUSTER"
    log_info "Namespaces: ${NAMESPACE_ARRAY[*]}"
    echo ""

    local errors=0

    for ns in "${NAMESPACE_ARRAY[@]}"; do
        log_info "── Verifying namespace: $ns ──"

        # 1. Check ghaRunners entries exist on destination (without .test suffix)
        local dest_runners
        dest_runners=$(get_runner_keys_for_namespace "$DEST_VALUES" "ghaRunners" "$ns")
        if [[ -n "$dest_runners" ]]; then
            while IFS= read -r key; do
                [[ -z "$key" ]] && continue
                local rn
                rn=$(yq eval ".argocdApplications.ghaRunners.\"${key}\".helm.releaseName" "$DEST_VALUES")
                if [[ "$rn" == *".test" ]]; then
                    log_error "  FAIL: Destination ghaRunners.$key still has .test suffix (releaseName: $rn)"
                    ((errors++))
                else
                    log_ok "  Destination ghaRunners.$key exists (releaseName: $rn)"
                fi
            done <<< "$dest_runners"
        else
            log_error "  FAIL: No ghaRunners entries found for namespace $ns on destination cluster"
            ((errors++))
        fi

        # 2. Check namespace is in destination namespaceManager
        local in_dest_ns
        in_dest_ns=$(yq eval ".argocdApplications.namespaceManager.namespaces[] | select(. == \"$ns\")" "$DEST_VALUES" 2>/dev/null)
        if [[ -n "$in_dest_ns" ]]; then
            log_ok "  Destination namespaceManager includes $ns"
        else
            log_error "  FAIL: $ns not in destination namespaceManager.namespaces"
            ((errors++))
        fi

        # 3. Check namespace is in destination externalSecrets
        local in_dest_es
        in_dest_es=$(yq eval ".argocdApplications.externalSecrets.namespaces[] | select(. == \"$ns\")" "$DEST_VALUES" 2>/dev/null)
        if [[ -n "$in_dest_es" ]]; then
            log_ok "  Destination externalSecrets includes $ns"
        else
            log_error "  FAIL: $ns not in destination externalSecrets.namespaces"
            ((errors++))
        fi

        # 4. Check ESO secrets exist on destination
        if [[ -f "$DEST_ESO" ]]; then
            local dest_secrets
            dest_secrets=$(yq eval ".clusterSecrets.\"${ns}\" | length" "$DEST_ESO" 2>/dev/null)
            if [[ "$dest_secrets" != "0" && "$dest_secrets" != "null" ]]; then
                log_ok "  Destination ESO has secrets for $ns"
            else
                log_warn "  Destination ESO has no secrets for $ns (may be expected if namespace uses no secrets)"
            fi
        fi

        # 5. Check ghaRunners entries are GONE from source
        local source_runners
        source_runners=$(get_runner_keys_for_namespace "$SOURCE_VALUES" "ghaRunners" "$ns")
        if [[ -z "$source_runners" ]]; then
            log_ok "  Source ghaRunners has no entries for $ns"
        else
            log_error "  FAIL: Source still has ghaRunners entries for $ns: $source_runners"
            ((errors++))
        fi

        # 6. Check namespace is NOT in source namespaceManager
        local in_src_ns
        in_src_ns=$(yq eval ".argocdApplications.namespaceManager.namespaces[] | select(. == \"$ns\")" "$SOURCE_VALUES" 2>/dev/null)
        if [[ -z "$in_src_ns" ]]; then
            log_ok "  Source namespaceManager does not include $ns"
        else
            log_error "  FAIL: $ns still in source namespaceManager.namespaces"
            ((errors++))
        fi

        # 7. Check namespace is NOT in source externalSecrets
        local in_src_es
        in_src_es=$(yq eval ".argocdApplications.externalSecrets.namespaces[] | select(. == \"$ns\")" "$SOURCE_VALUES" 2>/dev/null)
        if [[ -z "$in_src_es" ]]; then
            log_ok "  Source externalSecrets does not include $ns"
        else
            log_error "  FAIL: $ns still in source externalSecrets.namespaces"
            ((errors++))
        fi

        # 8. Check no leftover canaryApps entries on destination
        local canary_runners
        canary_runners=$(yq eval ".argocdApplications.canaryApps.ghaRunners | to_entries | .[] | select(.value.namespace == \"${ns}\") | .key" "$DEST_VALUES" 2>/dev/null)
        if [[ -z "$canary_runners" ]]; then
            log_ok "  No leftover canaryApps entries for $ns on destination"
        else
            log_error "  FAIL: Destination still has canaryApps.ghaRunners entries for $ns: $canary_runners"
            ((errors++))
        fi

        echo ""
    done

    if [[ $errors -eq 0 ]]; then
        log_ok "=== Verification PASSED — migration complete ==="
    else
        log_error "=== Verification FAILED — $errors issue(s) found ==="
        exit 1
    fi
}

# ─── Main ────────────────────────────────────────────────────────────────────
resolve_namespaces

if $DRY_RUN; then
    log_warn "DRY-RUN mode — no files will be modified"
    echo ""
fi

case "$PHASE" in
    shadow)        phase_shadow ;;
    drain)         phase_drain ;;
    delete-source) phase_delete_source ;;
    promote)       phase_promote ;;
    verify)        phase_verify ;;
    *)             log_error "Unknown phase: $PHASE"; usage ;;
esac
