#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLUSTERS_DIR="$REPO_ROOT/clusters"
MIGRATE="$SCRIPT_DIR/migrate-runners.sh"

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

banner() {
    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║           CI Runner Migration Wizard                        ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

prompt_choice() {
    local prompt="$1"
    echo -e -n "${YELLOW}${prompt}${NC} "
    read -r REPLY
    echo "$REPLY"
}

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}  ✓${NC} $*"; }
log_warn()  { echo -e "${YELLOW}  ⚠${NC} $*"; }
log_err()   { echo -e "${RED}  ✗${NC} $*"; }

separator() { echo -e "${DIM}──────────────────────────────────────────────────────────${NC}"; }

# ─── Prerequisites ────────────────────────────────────────────────────────────
check_prereqs() {
    local missing=false
    for cmd in yq git gh; do
        if ! command -v "$cmd" &>/dev/null; then
            log_err "$cmd is required but not found"
            missing=true
        fi
    done
    $missing && exit 1
}

# ─── Tenant database (from RBAC manifests) ────────────────────────────────────
declare -A TENANT_GROUP
declare -A TENANT_NAMESPACES
declare -A TENANT_CLUSTERS

build_tenant_db() {
    TENANT_GROUP[sglang]="sglang_ci_runner"
    TENANT_NAMESPACES[sglang]="arc-sglang"
    TENANT_CLUSTERS[sglang]="prod-vultr-mi325,tw-mia1-mi355-public"

    TENANT_GROUP[vllm]="frameworks-devops"
    TENANT_NAMESPACES[vllm]="arc-vllm,buildkite-vllm"
    TENANT_CLUSTERS[vllm]="prod-vultr-mi325,tw-mia1-mi355-public"

    TENANT_GROUP[pytorch]="AIG-TheRock-OSSCI-Infra"
    TENANT_NAMESPACES[pytorch]="arc-rocm,arc-meta-pytorch,arc-pytorch-mi325-gpu-1,arc-pytorch-mi325-gpu-2,arc-pytorch-mi325-gpu-4,arc-pytorch-mi325-gpu-8"
    TENANT_CLUSTERS[pytorch]="prod-vultr-mi325,ccs-aus-bm-pvt-prd"

    TENANT_GROUP[hf]="dl-automation"
    TENANT_NAMESPACES[hf]="arc-hf"
    TENANT_CLUSTERS[hf]="prod-vultr-mi325"

    TENANT_GROUP[jax]="dl.sec-JAX"
    TENANT_NAMESPACES[jax]="arc-jax,arc-rocm-jax,arc-xla,jax-framework-dev"
    TENANT_CLUSTERS[jax]="do-atl1-vm-public"

    TENANT_GROUP[rad]="dsg.RAD_CI"
    TENANT_NAMESPACES[rad]="arc-rad"
    TENANT_CLUSTERS[rad]="do-atl1-vm-public"

    TENANT_GROUP[iree]="iree-dev"
    TENANT_NAMESPACES[iree]="iree-dev,arc-iree-mi325-gpu-1,arc-iree-mi325-gpu-2"
    TENANT_CLUSTERS[iree]="tw-mia1-mi355-public,prod-vultr-mi325"

    TENANT_GROUP[aims]="aimsdevgroup"
    TENANT_NAMESPACES[aims]="aims-dev"
    TENANT_CLUSTERS[aims]="prod-vultr-mi325"

    TENANT_GROUP[aiter]=""
    TENANT_NAMESPACES[aiter]="arc-aiter"
    TENANT_CLUSTERS[aiter]="prod-vultr-mi325"

    TENANT_GROUP[triton]=""
    TENANT_NAMESPACES[triton]="arc-triton-gpu-1,arc-triton-distributed-gpu-8"
    TENANT_CLUSTERS[triton]="prod-vultr-mi325"
}

# ─── Step 1: Select Tenants ──────────────────────────────────────────────────
select_tenants() {
    echo -e "${BOLD}Step 1: Select tenant(s) to migrate${NC}"
    separator
    local tenants=("sglang" "vllm" "pytorch" "hf" "jax" "rad" "iree" "aims" "aiter" "triton")
    local i=1
    for t in "${tenants[@]}"; do
        local group="${TENANT_GROUP[$t]:-none}"
        local clusters="${TENANT_CLUSTERS[$t]}"
        printf "  ${CYAN}[%2d]${NC} %-12s ${DIM}group=%-25s clusters=%s${NC}\n" "$i" "$t" "$group" "$clusters"
        ((i++))
    done
    echo ""
    local selection
    selection=$(prompt_choice "Enter numbers (comma-separated, e.g. 1,3):")

    SELECTED_TENANTS=()
    IFS=',' read -ra nums <<< "$selection"
    for n in "${nums[@]}"; do
        n=$(echo "$n" | tr -d ' ')
        if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#tenants[@]} )); then
            SELECTED_TENANTS+=("${tenants[$((n-1))]}")
        else
            log_err "Invalid selection: $n"
            exit 1
        fi
    done
    echo ""
    for t in "${SELECTED_TENANTS[@]}"; do
        log_ok "Selected: $t"
    done
    echo ""
}

# ─── Step 2: Select Source Cluster ────────────────────────────────────────────
select_source_cluster() {
    echo -e "${BOLD}Step 2: Select source cluster${NC}"
    separator

    # Auto-detect common clusters across selected tenants
    local all_clusters=()
    for t in "${SELECTED_TENANTS[@]}"; do
        IFS=',' read -ra cls <<< "${TENANT_CLUSTERS[$t]}"
        all_clusters+=("${cls[@]}")
    done

    # Get unique clusters
    local unique_clusters
    unique_clusters=$(printf '%s\n' "${all_clusters[@]}" | sort -u)

    local cluster_array=()
    while IFS= read -r c; do
        [[ -n "$c" ]] && cluster_array+=("$c")
    done <<< "$unique_clusters"

    # Also add all available cluster dirs
    echo -e "  ${DIM}Clusters where selected tenants currently run:${NC}"
    local i=1
    for c in "${cluster_array[@]}"; do
        echo -e "  ${CYAN}[$i]${NC} $c"
        ((i++))
    done

    echo ""
    echo -e "  ${DIM}Or enter a cluster name directly:${NC}"
    local selection
    selection=$(prompt_choice "Select source cluster:")

    if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#cluster_array[@]} )); then
        SOURCE_CLUSTER="${cluster_array[$((selection-1))]}"
    else
        SOURCE_CLUSTER="$selection"
    fi

    [[ -d "$CLUSTERS_DIR/$SOURCE_CLUSTER" ]] || { log_err "Cluster not found: $SOURCE_CLUSTER"; exit 1; }
    log_ok "Source: $SOURCE_CLUSTER"
    echo ""
}

# ─── Step 3: Select Target Cluster ───────────────────────────────────────────
select_target_cluster() {
    echo -e "${BOLD}Step 3: Select target cluster${NC}"
    separator

    local all_clusters=()
    for dir in "$CLUSTERS_DIR"/*/; do
        local name
        name=$(basename "$dir")
        [[ "$name" == "$SOURCE_CLUSTER" ]] && continue
        [[ -f "$dir/cluster-package-values.yaml" ]] && all_clusters+=("$name")
    done

    local i=1
    for c in "${all_clusters[@]}"; do
        echo -e "  ${CYAN}[%2d]${NC} %s\n" "$i" "$c"
        ((i++))
    done | column -t 2>/dev/null || true

    # Simpler listing if column fails
    i=1
    for c in "${all_clusters[@]}"; do
        printf "  ${CYAN}[%2d]${NC} %s\n" "$i" "$c"
        ((i++))
    done

    echo ""
    local selection
    selection=$(prompt_choice "Select target cluster:")

    if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#all_clusters[@]} )); then
        TARGET_CLUSTER="${all_clusters[$((selection-1))]}"
    else
        TARGET_CLUSTER="$selection"
    fi

    [[ -d "$CLUSTERS_DIR/$TARGET_CLUSTER" ]] || { log_err "Cluster not found: $TARGET_CLUSTER"; exit 1; }
    log_ok "Target: $TARGET_CLUSTER"
    echo ""
}

# ─── Step 4: Select Mode ─────────────────────────────────────────────────────
select_mode() {
    echo -e "${BOLD}Step 4: Select migration mode${NC}"
    separator
    echo -e "  ${CYAN}[1]${NC} Shadow mode   ${DIM}(.test label suffix — for tenant testing)${NC}"
    echo -e "  ${CYAN}[2]${NC} Production    ${DIM}(prod labels — skip shadow, direct deploy)${NC}"
    echo -e "  ${CYAN}[3]${NC} Drain only    ${DIM}(set min=0, max=0 on source cluster)${NC}"
    echo -e "  ${CYAN}[4]${NC} Promote       ${DIM}(move shadow → production on target)${NC}"
    echo -e "  ${CYAN}[5]${NC} Full pipeline  ${DIM}(shadow → test → drain → promote)${NC}"
    echo ""
    local selection
    selection=$(prompt_choice "Select mode:")

    case "$selection" in
        1) MODE="shadow" ;;
        2) MODE="promote" ;;
        3) MODE="drain" ;;
        4) MODE="promote" ;;
        5) MODE="full" ;;
        *) log_err "Invalid selection"; exit 1 ;;
    esac
    log_ok "Mode: $MODE"
    echo ""
}

# ─── Step 5: Select Namespaces ────────────────────────────────────────────────
select_namespaces() {
    echo -e "${BOLD}Step 5: Select namespaces to migrate${NC}"
    separator

    # Collect all namespaces for selected tenants
    ALL_NS=()
    for t in "${SELECTED_TENANTS[@]}"; do
        IFS=',' read -ra ns_list <<< "${TENANT_NAMESPACES[$t]}"
        ALL_NS+=("${ns_list[@]}")
    done

    # Filter to namespaces that actually exist on source cluster
    AVAILABLE_NS=()
    local source_values="$CLUSTERS_DIR/$SOURCE_CLUSTER/cluster-package-values.yaml"
    for ns in "${ALL_NS[@]}"; do
        if yq eval ".argocdApplications.ghaRunners.[] | select(.namespace == \"$ns\") | .namespace" "$source_values" 2>/dev/null | grep -q "$ns"; then
            AVAILABLE_NS+=("$ns")
        elif yq eval ".argocdApplications.namespaceManager.namespaces[] | select(. == \"$ns\")" "$source_values" 2>/dev/null | grep -q "$ns"; then
            AVAILABLE_NS+=("$ns")
        fi
    done

    if [[ ${#AVAILABLE_NS[@]} -eq 0 ]]; then
        log_warn "No matching namespaces found on source cluster for selected tenants."
        log_info "Attempting auto-detect from source cluster..."
        while IFS= read -r ns; do
            [[ -n "$ns" ]] && AVAILABLE_NS+=("$ns")
        done < <(yq eval '.argocdApplications.ghaRunners.[] | .namespace' "$source_values" 2>/dev/null | sort -u | grep -v '^arc$' | grep -v '^arc-ossci-gitops$')
    fi

    echo -e "  ${CYAN}[A]${NC} All namespaces (${#AVAILABLE_NS[@]} total)"
    local i=1
    for ns in "${AVAILABLE_NS[@]}"; do
        # Show runner count for each namespace
        local runner_count
        runner_count=$(yq eval ".argocdApplications.ghaRunners | to_entries | .[] | select(.value.namespace == \"$ns\") | .key" "$source_values" 2>/dev/null | wc -l)
        printf "  ${CYAN}[%2d]${NC} %-40s ${DIM}(%d runner(s))${NC}\n" "$i" "$ns" "$runner_count"
        ((i++))
    done

    echo ""
    local selection
    selection=$(prompt_choice "Select namespaces (comma-separated, or A for all):")

    SELECTED_NS=()
    if [[ "${selection,,}" == "a" || "${selection,,}" == "all" ]]; then
        SELECTED_NS=("${AVAILABLE_NS[@]}")
    else
        IFS=',' read -ra nums <<< "$selection"
        for n in "${nums[@]}"; do
            n=$(echo "$n" | tr -d ' ')
            if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#AVAILABLE_NS[@]} )); then
                SELECTED_NS+=("${AVAILABLE_NS[$((n-1))]}")
            fi
        done
    fi

    echo ""
    for ns in "${SELECTED_NS[@]}"; do
        log_ok "Namespace: $ns"
    done
    echo ""
}

# ─── Step 6: Capacity ─────────────────────────────────────────────────────────
configure_capacity() {
    echo -e "${BOLD}Step 6: Configure capacity (maxRunners)${NC}"
    separator

    local source_values="$CLUSTERS_DIR/$SOURCE_CLUSTER/cluster-package-values.yaml"
    CAPACITY_OVERRIDES=()

    for ns in "${SELECTED_NS[@]}"; do
        local runner_keys
        runner_keys=$(yq eval ".argocdApplications.ghaRunners | to_entries | .[] | select(.value.namespace == \"$ns\") | .key" "$source_values" 2>/dev/null)

        [[ -z "$runner_keys" ]] && continue

        while IFS= read -r key; do
            [[ -z "$key" ]] && continue

            local value_path
            value_path=$(yq eval ".argocdApplications.ghaRunners.\"${key}\".helm.valueFiles" "$source_values" 2>/dev/null)
            [[ "$value_path" == "["* ]] && value_path=$(yq eval ".argocdApplications.ghaRunners.\"${key}\".helm.valueFiles[0]" "$source_values")

            local current_max="?"
            if [[ -n "$value_path" && "$value_path" != "null" && -f "$REPO_ROOT/$value_path" ]]; then
                current_max=$(yq eval '.maxRunners' "$REPO_ROOT/$value_path" 2>/dev/null)
            fi

            local release_name
            release_name=$(yq eval ".argocdApplications.ghaRunners.\"${key}\".helm.releaseName" "$source_values" 2>/dev/null)

            echo -e "  Runner: ${BOLD}$key${NC}  ${DIM}(label: $release_name, current maxRunners: $current_max)${NC}"
            local new_max
            new_max=$(prompt_choice "  New maxRunners [$current_max]:")
            [[ -z "$new_max" ]] && new_max="$current_max"
            CAPACITY_OVERRIDES+=("$key=$new_max")
            echo ""
        done <<< "$runner_keys"
    done
}

# ─── Step 7: RBAC ─────────────────────────────────────────────────────────────
configure_rbac() {
    echo -e "${BOLD}Step 7: Include RBAC setup?${NC}"
    separator

    INCLUDE_RBAC=false
    for t in "${SELECTED_TENANTS[@]}"; do
        local group="${TENANT_GROUP[$t]:-}"
        if [[ -n "$group" ]]; then
            echo -e "  $t → AD group: ${BOLD}$group${NC}"
        else
            echo -e "  $t → ${DIM}no AD group configured${NC}"
        fi
    done

    echo ""
    local answer
    answer=$(prompt_choice "Create RBAC manifests (RoleBinding + ClusterRoleBinding)? [Y/n]:")
    if [[ "${answer,,}" != "n" ]]; then
        INCLUDE_RBAC=true
        log_ok "RBAC will be created"
    else
        log_warn "RBAC skipped"
    fi
    echo ""
}

# ─── Step 8: Branch & PR ─────────────────────────────────────────────────────
configure_branch() {
    echo -e "${BOLD}Step 8: Git branch & PR${NC}"
    separator

    local tenants_slug
    tenants_slug=$(printf '%s-' "${SELECTED_TENANTS[@]}" | sed 's/-$//')
    local default_branch="migrate-${tenants_slug}-to-${TARGET_CLUSTER}"

    BRANCH_NAME=$(prompt_choice "Branch name [$default_branch]:")
    [[ -z "$BRANCH_NAME" ]] && BRANCH_NAME="$default_branch"

    CREATE_PR=false
    local answer
    answer=$(prompt_choice "Create PR after generating files? [Y/n]:")
    [[ "${answer,,}" != "n" ]] && CREATE_PR=true

    DRY_RUN=false
    answer=$(prompt_choice "Dry-run mode (preview only, no file changes)? [y/N]:")
    [[ "${answer,,}" == "y" ]] && DRY_RUN=true

    log_ok "Branch: $BRANCH_NAME"
    echo ""
}

# ─── Summary & Confirmation ──────────────────────────────────────────────────
show_summary() {
    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║                    Migration Summary                        ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Tenants:${NC}        ${SELECTED_TENANTS[*]}"
    echo -e "  ${BOLD}Source:${NC}         $SOURCE_CLUSTER"
    echo -e "  ${BOLD}Target:${NC}         $TARGET_CLUSTER"
    echo -e "  ${BOLD}Mode:${NC}           $MODE"
    echo -e "  ${BOLD}Namespaces:${NC}     ${SELECTED_NS[*]}"
    echo -e "  ${BOLD}RBAC:${NC}           $( $INCLUDE_RBAC && echo 'Yes' || echo 'No' )"
    echo -e "  ${BOLD}Branch:${NC}         $BRANCH_NAME"
    echo -e "  ${BOLD}Create PR:${NC}      $( $CREATE_PR && echo 'Yes' || echo 'No' )"
    echo -e "  ${BOLD}Dry-run:${NC}        $( $DRY_RUN && echo 'Yes' || echo 'No' )"

    if [[ ${#CAPACITY_OVERRIDES[@]} -gt 0 ]]; then
        echo -e "  ${BOLD}Capacity:${NC}"
        for override in "${CAPACITY_OVERRIDES[@]}"; do
            echo -e "    $override"
        done
    fi

    echo ""
    separator
    local answer
    answer=$(prompt_choice "Proceed with migration? [Y/n]:")
    [[ "${answer,,}" == "n" ]] && { echo "Aborted."; exit 0; }
}

# ─── Create RBAC manifests ────────────────────────────────────────────────────
create_rbac_for_namespace() {
    local ns="$1"
    local group="$2"
    local dest_dir="$CLUSTERS_DIR/$TARGET_CLUSTER/namespaces/$ns"

    [[ -z "$group" ]] && return 0

    mkdir -p "$dest_dir"

    local rb_file="$dest_dir/rb-viewer-${group}.yaml"
    if [[ ! -f "$rb_file" ]]; then
        cat > "$rb_file" <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: viewer-${group}
  namespace: ${ns}
  annotations:
    argocd.argoproj.io/sync-wave: "0"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: namespace-viewer
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: ${group}
EOF
        log_ok "Created RoleBinding: $rb_file"
    else
        log_warn "RoleBinding already exists: $rb_file"
    fi

    local crb_file="$dest_dir/crb-tenant-${group}.yaml"
    if [[ ! -f "$crb_file" ]]; then
        cat > "$crb_file" <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: tenant-${group}
  annotations:
    argocd.argoproj.io/sync-wave: "0"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-tenant
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: ${group}
EOF
        log_ok "Created ClusterRoleBinding: $crb_file"
    else
        log_warn "ClusterRoleBinding already exists: $crb_file"
    fi
}

# ─── Apply capacity overrides ────────────────────────────────────────────────
apply_capacity_overrides() {
    local dest_values="$CLUSTERS_DIR/$TARGET_CLUSTER/cluster-package-values.yaml"

    for override in "${CAPACITY_OVERRIDES[@]}"; do
        local key="${override%%=*}"
        local max="${override##*=}"

        # Find the value file for this runner on destination
        local section="ghaRunners"
        [[ "$MODE" == "shadow" ]] && section="canaryApps.ghaRunners"

        local value_path
        value_path=$(yq eval ".argocdApplications.${section}.\"${key}\".helm.valueFiles" "$dest_values" 2>/dev/null)
        [[ "$value_path" == "["* ]] && value_path=$(yq eval ".argocdApplications.${section}.\"${key}\".helm.valueFiles[0]" "$dest_values")

        if [[ -n "$value_path" && "$value_path" != "null" && -f "$REPO_ROOT/$value_path" ]]; then
            yq eval ".maxRunners = $max" -i "$REPO_ROOT/$value_path"
            log_ok "Set maxRunners=$max in $value_path"
        fi
    done
}

# ─── Execute Migration ───────────────────────────────────────────────────────
execute() {
    echo ""
    echo -e "${BOLD}Executing migration...${NC}"
    separator

    # Create branch from staging
    local current_branch
    current_branch=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)
    log_info "Current branch: $current_branch"

    if ! $DRY_RUN; then
        git -C "$REPO_ROOT" stash --include-untracked -q 2>/dev/null || true
        git -C "$REPO_ROOT" fetch origin staging 2>/dev/null || true
        git -C "$REPO_ROOT" checkout -b "$BRANCH_NAME" origin/staging 2>/dev/null || \
            git -C "$REPO_ROOT" checkout -b "$BRANCH_NAME" 2>/dev/null || \
            git -C "$REPO_ROOT" checkout "$BRANCH_NAME"
        log_ok "On branch: $BRANCH_NAME"
    fi

    # Build namespace list
    local ns_csv
    ns_csv=$(IFS=','; echo "${SELECTED_NS[*]}")

    # Run migrate-runners.sh
    local dry_flag=""
    $DRY_RUN && dry_flag="--dry-run"

    local phase="$MODE"
    [[ "$MODE" == "full" ]] && phase="shadow"

    log_info "Running: migrate-runners.sh --phase $phase --source $SOURCE_CLUSTER --dest $TARGET_CLUSTER --namespaces $ns_csv $dry_flag"
    echo ""
    "$MIGRATE" --phase "$phase" --source "$SOURCE_CLUSTER" --dest "$TARGET_CLUSTER" --namespaces "$ns_csv" $dry_flag

    # Create RBAC if requested
    if $INCLUDE_RBAC && ! $DRY_RUN; then
        echo ""
        log_info "Creating RBAC manifests..."
        for t in "${SELECTED_TENANTS[@]}"; do
            local group="${TENANT_GROUP[$t]:-}"
            [[ -z "$group" ]] && continue

            IFS=',' read -ra ns_list <<< "${TENANT_NAMESPACES[$t]}"
            for ns in "${ns_list[@]}"; do
                # Only create RBAC for namespaces we're actually migrating
                for sel_ns in "${SELECTED_NS[@]}"; do
                    if [[ "$ns" == "$sel_ns" ]]; then
                        create_rbac_for_namespace "$ns" "$group"
                    fi
                done
            done

            # Also create viewer access to the 'arc' namespace
            local arc_dir="$CLUSTERS_DIR/$TARGET_CLUSTER/namespaces/arc"
            if [[ -d "$arc_dir" ]]; then
                local arc_rb="$arc_dir/rb-viewer-${group}.yaml"
                if [[ ! -f "$arc_rb" ]]; then
                    cat > "$arc_rb" <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: viewer-${group}
  namespace: arc
  annotations:
    argocd.argoproj.io/sync-wave: "0"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: namespace-viewer
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: ${group}
EOF
                    log_ok "Created arc namespace viewer RoleBinding for $group"
                fi
            fi
        done
    fi

    # Apply capacity overrides
    if [[ ${#CAPACITY_OVERRIDES[@]} -gt 0 ]] && ! $DRY_RUN; then
        echo ""
        log_info "Applying capacity overrides..."
        apply_capacity_overrides
    fi

    # Commit and optionally create PR
    if ! $DRY_RUN; then
        echo ""
        log_info "Committing changes..."
        git -C "$REPO_ROOT" add -A

        local tenants_str="${SELECTED_TENANTS[*]}"
        local mode_label="$MODE"
        [[ "$MODE" == "shadow" ]] && mode_label="shadow mode"

        git -C "$REPO_ROOT" commit -m "$(cat <<EOF
Migrate $tenants_str to $TARGET_CLUSTER ($mode_label)

Source: $SOURCE_CLUSTER
Target: $TARGET_CLUSTER
Namespaces: $ns_csv
Mode: $mode_label
RBAC: $( $INCLUDE_RBAC && echo 'included' || echo 'skipped' )

Generated by migration-wizard.sh
EOF
)"
        log_ok "Changes committed"

        if $CREATE_PR; then
            echo ""
            log_info "Pushing and creating PR..."
            git -C "$REPO_ROOT" push -u origin "$BRANCH_NAME"

            local pr_body
            pr_body=$(cat <<EOF
## CI Runner Migration: ${tenants_str// /, }

### Migration Details
| | |
|---|---|
| **Source Cluster** | \`$SOURCE_CLUSTER\` |
| **Target Cluster** | \`$TARGET_CLUSTER\` |
| **Mode** | $mode_label |
| **Tenants** | ${tenants_str// /, } |
| **Namespaces** | \`${ns_csv//,/\`, \`}\` |
| **RBAC** | $( $INCLUDE_RBAC && echo 'Included' || echo 'Skipped' ) |

### Capacity
$(for override in "${CAPACITY_OVERRIDES[@]}"; do echo "- \`${override%%=*}\`: maxRunners=${override##*=}"; done)

### Checklist
- [ ] Shadow runners are healthy (pods running)
- [ ] Smoke test passed (GPU visible, dind working)
- [ ] Tenant notified and approved
- [ ] Ready for soak period / cutover
EOF
)
            gh pr create \
                --title "Migrate ${tenants_str// /, } to $TARGET_CLUSTER ($mode_label)" \
                --body "$pr_body" \
                --base staging

            log_ok "PR created!"
        fi
    fi

    echo ""
    echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║                    Migration Complete!                       ║${NC}"
    echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if [[ "$MODE" == "shadow" ]]; then
        echo -e "  ${BOLD}Next steps:${NC}"
        echo -e "  1. Wait for ArgoCD to sync and runners to come up"
        echo -e "  2. Notify tenants to test with .test labels"
        echo -e "  3. Once approved, run the wizard again with ${CYAN}Promote${NC} mode"
        echo -e "  4. Then ${CYAN}Drain${NC} the source cluster"
        echo ""
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    banner
    check_prereqs
    build_tenant_db

    select_tenants
    select_source_cluster
    select_target_cluster
    select_mode
    select_namespaces
    configure_capacity
    configure_rbac
    configure_branch
    show_summary
    execute
}

main "$@"
