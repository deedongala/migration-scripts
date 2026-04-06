#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MIGRATE="$SCRIPT_DIR/migrate-runners.sh"

# ─── Test configuration ──────────────────────────────────────────────────────
# Migrate arc-rocm-gpu-1 (1 runner, shared packages/ value path, 1 ESO secret)
# Future: swap to aws-stg / aws-dev once ghaRunners are set up on those clusters
SOURCE="tw-mia1-mi355-public"
DEST="do-atl1-vm-public"
NS="arc-rocm-gpu-1"

CLUSTERS="$REPO_ROOT/clusters"
SRC_VALUES="$CLUSTERS/$SOURCE/cluster-package-values.yaml"
DST_VALUES="$CLUSTERS/$DEST/cluster-package-values.yaml"
SRC_ESO="$CLUSTERS/$SOURCE/external-secrets/values.yaml"
DST_ESO="$CLUSTERS/$DEST/external-secrets/values.yaml"

THROWAWAY_BRANCH="test/migration-dry-run-$$"
ORIGINAL_BRANCH=""

EXPECTED_RUNNERS=("rocm-mi355-1gpu-runner")
EXPECTED_RELEASE_NAMES=("linux-mi355-1gpu-ossci-rocm")
# Value file is a shared packages/ path — no copy to dest cluster dir expected
EXPECTED_SHARED_VALUE_PATH="packages/arc-runners/rocm/rocm-mi355-1gpu-runner-tw.yaml"
EXPECTED_ESO_SECRET_COUNT="1"

# ─── Colors & logging ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

pass()  { echo -e "  ${GREEN}PASS${NC} $*"; }
fail()  { echo -e "  ${RED}FAIL${NC} $*"; FAILURES=$((FAILURES + 1)); }
info()  { echo -e "${BLUE}[TEST]${NC} $*"; }
header(){ echo -e "\n${BOLD}═══════════════════════════════════════════════════════${NC}"; echo -e "${BOLD} $*${NC}"; echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}\n"; }
gate()  { echo ""; echo -e "${YELLOW}──── Manual gate ────${NC}"; read -r -p "$(echo -e "${YELLOW}Press Enter to continue to next phase (or Ctrl-C to abort)...${NC} ")"; echo ""; }

FAILURES=0

# ─── Prerequisites ────────────────────────────────────────────────────────────
check_prereqs() {
    command -v yq &>/dev/null || { echo "yq v4+ required"; exit 1; }
    command -v git &>/dev/null || { echo "git required"; exit 1; }
    [[ -f "$MIGRATE" ]] || { echo "migrate-runners.sh not found at $MIGRATE"; exit 1; }
    [[ -f "$SRC_VALUES" ]] || { echo "Source cluster-package-values.yaml not found"; exit 1; }
    [[ -f "$DST_VALUES" ]] || { echo "Dest cluster-package-values.yaml not found"; exit 1; }
}

# ─── Setup: create throwaway branch ──────────────────────────────────────────
setup() {
    header "SETUP"
    ORIGINAL_BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)
    info "Current branch: $ORIGINAL_BRANCH"
    info "Creating throwaway branch: $THROWAWAY_BRANCH"

    git -C "$REPO_ROOT" stash --include-untracked -q 2>/dev/null || true
    git -C "$REPO_ROOT" checkout -b "$THROWAWAY_BRANCH"

    info "Recording initial state (git SHA: $(git -C "$REPO_ROOT" rev-parse --short HEAD))"
    echo ""
}

# ─── Cleanup: offer to discard throwaway branch ──────────────────────────────
cleanup() {
    header "CLEANUP"
    echo -e "${YELLOW}Throwaway branch: $THROWAWAY_BRANCH${NC}"
    read -r -p "$(echo -e "${YELLOW}Delete throwaway branch and return to $ORIGINAL_BRANCH? [y/N] ${NC}")" choice
    if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
        git -C "$REPO_ROOT" checkout "$ORIGINAL_BRANCH"
        git -C "$REPO_ROOT" branch -D "$THROWAWAY_BRANCH"
        git -C "$REPO_ROOT" checkout -- . 2>/dev/null || true
        git -C "$REPO_ROOT" clean -fd 2>/dev/null || true
        git -C "$REPO_ROOT" stash pop -q 2>/dev/null || true
        info "Cleaned up. Back on $ORIGINAL_BRANCH"
    else
        info "Keeping branch $THROWAWAY_BRANCH for inspection"
    fi
}

trap 'echo -e "\n${RED}Test aborted.${NC} You are on branch $THROWAWAY_BRANCH — run: git checkout $ORIGINAL_BRANCH && git branch -D $THROWAWAY_BRANCH"' ERR

# ─── Assertion helpers ────────────────────────────────────────────────────────
assert_file_exists() {
    local path="$1"; local label="${2:-$path}"
    [[ -f "$REPO_ROOT/$path" ]] && pass "$label exists" || fail "$label missing"
}

assert_file_not_exists() {
    local path="$1"; local label="${2:-$path}"
    [[ ! -f "$REPO_ROOT/$path" ]] && pass "$label removed" || fail "$label still exists"
}

assert_dir_exists() {
    local path="$1"; local label="${2:-$path}"
    [[ -d "$REPO_ROOT/$path" ]] && pass "$label exists" || fail "$label missing"
}

assert_dir_not_exists() {
    local path="$1"; local label="${2:-$path}"
    [[ ! -d "$REPO_ROOT/$path" ]] && pass "$label removed" || fail "$label still exists"
}

assert_yq_equals() {
    local file="$1"; local expr="$2"; local expected="$3"; local label="$4"
    local actual
    actual=$(yq eval "$expr" "$file" 2>/dev/null)
    [[ "$actual" == "$expected" ]] && pass "$label (got: $actual)" || fail "$label (expected: $expected, got: $actual)"
}

assert_yq_not_null() {
    local file="$1"; local expr="$2"; local label="$3"
    local actual
    actual=$(yq eval "$expr" "$file" 2>/dev/null)
    [[ "$actual" != "null" && -n "$actual" ]] && pass "$label" || fail "$label (got null/empty)"
}

assert_yq_is_null() {
    local file="$1"; local expr="$2"; local label="$3"
    local actual
    actual=$(yq eval "$expr" "$file" 2>/dev/null)
    [[ "$actual" == "null" || -z "$actual" ]] && pass "$label" || fail "$label (expected null, got: $actual)"
}

assert_yq_contains() {
    local file="$1"; local expr="$2"; local needle="$3"; local label="$4"
    local actual
    actual=$(yq eval "$expr" "$file" 2>/dev/null)
    [[ "$actual" == *"$needle"* ]] && pass "$label" || fail "$label (\"$needle\" not found in output)"
}

assert_yq_not_contains() {
    local file="$1"; local expr="$2"; local needle="$3"; local label="$4"
    local actual
    actual=$(yq eval "$expr" "$file" 2>/dev/null)
    [[ "$actual" != *"$needle"* ]] && pass "$label" || fail "$label (\"$needle\" still found)"
}

assert_source_unchanged() {
    if git -C "$REPO_ROOT" diff --quiet -- "clusters/$SOURCE/"; then
        pass "Source cluster files unchanged"
    else
        fail "Source cluster files were modified"
        git -C "$REPO_ROOT" diff --stat -- "clusters/$SOURCE/"
    fi
}

assert_dest_unchanged() {
    if git -C "$REPO_ROOT" diff --quiet -- "clusters/$DEST/"; then
        pass "Destination cluster files unchanged"
    else
        fail "Destination cluster files were modified"
        git -C "$REPO_ROOT" diff --stat -- "clusters/$DEST/"
    fi
}

show_diff() {
    echo ""
    info "Git diff summary:"
    git -C "$REPO_ROOT" diff --stat
    echo ""
    info "Detailed changes:"
    git -C "$REPO_ROOT" diff
}

commit_phase() {
    local phase="$1"
    git -C "$REPO_ROOT" add -A
    git -C "$REPO_ROOT" commit -m "test: $phase phase for $NS ($SOURCE -> $DEST)" --allow-empty -q
    info "Committed $phase changes (for clean diff in next phase)"
}

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE TESTS
# ═══════════════════════════════════════════════════════════════════════════════

test_shadow_dry_run() {
    header "Phase 1a: SHADOW (dry-run)"
    "$MIGRATE" --phase shadow --source "$SOURCE" --dest "$DEST" --namespaces "$NS" --dry-run
    echo ""
    info "Assertions (nothing should change in dry-run):"
    assert_source_unchanged
    assert_dest_unchanged
}

test_shadow() {
    header "Phase 1b: SHADOW (real)"
    "$MIGRATE" --phase shadow --source "$SOURCE" --dest "$DEST" --namespaces "$NS"
    echo ""
    info "Assertions:"

    # Namespace directory created on destination
    assert_dir_exists "clusters/$DEST/namespaces/$NS" "Dest namespace dir"
    assert_file_exists "clusters/$DEST/namespaces/$NS/namespace.yaml" "Dest namespace.yaml"

    # Shared packages/ value file should NOT be copied (stays in packages/)
    assert_file_exists "$EXPECTED_SHARED_VALUE_PATH" "Shared value file still in packages/"

    # canaryApps.ghaRunners entries with .test release names
    for i in "${!EXPECTED_RUNNERS[@]}"; do
        local key="${EXPECTED_RUNNERS[$i]}"
        local rn="${EXPECTED_RELEASE_NAMES[$i]}"
        assert_yq_equals "$DST_VALUES" \
            ".argocdApplications.canaryApps.ghaRunners.\"${key}\".helm.releaseName" \
            "${rn}.test" \
            "canaryApps runner $key has releaseName ${rn}.test"
        assert_yq_equals "$DST_VALUES" \
            ".argocdApplications.canaryApps.ghaRunners.\"${key}\".namespace" \
            "$NS" \
            "canaryApps runner $key has namespace $NS"
        assert_yq_equals "$DST_VALUES" \
            ".argocdApplications.canaryApps.ghaRunners.\"${key}\".helm.valueFiles" \
            "$EXPECTED_SHARED_VALUE_PATH" \
            "canaryApps runner $key points to shared value path"
    done

    # canaryApps.namespaces includes NS
    assert_yq_contains "$DST_VALUES" \
        '.argocdApplications.canaryApps.namespaces[]' \
        "$NS" \
        "canaryApps.namespaces includes $NS"

    # canaryApps.externalSecrets includes NS
    assert_yq_contains "$DST_VALUES" \
        '.argocdApplications.canaryApps.externalSecrets[]' \
        "$NS" \
        "canaryApps.externalSecrets includes $NS"

    # ESO secrets copied to destination
    assert_yq_not_null "$DST_ESO" ".clusterSecrets.\"$NS\"" "Dest ESO has clusterSecrets.$NS"
    local secret_count
    secret_count=$(yq eval ".clusterSecrets.\"$NS\" | length" "$DST_ESO")
    [[ "$secret_count" == "$EXPECTED_ESO_SECRET_COUNT" ]] \
        && pass "Dest ESO has $EXPECTED_ESO_SECRET_COUNT secret(s) for $NS" \
        || fail "Expected $EXPECTED_ESO_SECRET_COUNT secrets, got $secret_count"

    # Source cluster should be UNCHANGED
    assert_source_unchanged

    show_diff
    commit_phase "shadow"
}

test_drain_dry_run() {
    header "Phase 2a: DRAIN (dry-run)"
    "$MIGRATE" --phase drain --source "$SOURCE" --dest "$DEST" --namespaces "$NS" --dry-run
    echo ""
    info "Assertions (nothing should change in dry-run):"
    if git -C "$REPO_ROOT" diff --quiet; then
        pass "No files changed in dry-run"
    else
        fail "Files changed during dry-run"
    fi
}

test_drain() {
    header "Phase 2b: DRAIN (real)"
    "$MIGRATE" --phase drain --source "$SOURCE" --dest "$DEST" --namespaces "$NS"
    echo ""
    info "Assertions:"

    # Runner value file has minRunners=0 and maxRunners=0
    assert_yq_equals "$REPO_ROOT/$EXPECTED_SHARED_VALUE_PATH" '.minRunners' '0' \
        "$EXPECTED_SHARED_VALUE_PATH minRunners=0"
    assert_yq_equals "$REPO_ROOT/$EXPECTED_SHARED_VALUE_PATH" '.maxRunners' '0' \
        "$EXPECTED_SHARED_VALUE_PATH maxRunners=0"

    # Destination should be unchanged
    assert_dest_unchanged

    show_diff
    commit_phase "drain"
}

test_delete_source_dry_run() {
    header "Phase 3a: DELETE-SOURCE (dry-run)"
    "$MIGRATE" --phase delete-source --source "$SOURCE" --dest "$DEST" --namespaces "$NS" --dry-run
    echo ""
    info "Assertions (nothing should change in dry-run):"
    if git -C "$REPO_ROOT" diff --quiet; then
        pass "No files changed in dry-run"
    else
        fail "Files changed during dry-run"
    fi
}

test_delete_source() {
    header "Phase 3b: DELETE-SOURCE (real)"
    "$MIGRATE" --phase delete-source --source "$SOURCE" --dest "$DEST" --namespaces "$NS"
    echo ""
    info "Assertions:"

    # ghaRunners on source has no arc-sglang runners
    for key in "${EXPECTED_RUNNERS[@]}"; do
        assert_yq_is_null "$SRC_VALUES" \
            ".argocdApplications.ghaRunners.\"${key}\"" \
            "Source ghaRunners.$key removed"
    done

    # namespaceManager.namespaces no longer includes arc-sglang
    assert_yq_not_contains "$SRC_VALUES" \
        '.argocdApplications.namespaceManager.namespaces[]' \
        "$NS" \
        "Source namespaceManager no longer includes $NS"

    # externalSecrets.namespaces no longer includes arc-sglang
    assert_yq_not_contains "$SRC_VALUES" \
        '.argocdApplications.externalSecrets.namespaces[]' \
        "$NS" \
        "Source externalSecrets no longer includes $NS"

    # clusterSecrets.arc-sglang removed from source ESO
    assert_yq_is_null "$SRC_ESO" \
        ".clusterSecrets.\"$NS\"" \
        "Source ESO clusterSecrets.$NS removed"

    # Destination should be unchanged
    assert_dest_unchanged

    show_diff
    commit_phase "delete-source"
}

test_promote_dry_run() {
    header "Phase 4a: PROMOTE (dry-run)"
    "$MIGRATE" --phase promote --source "$SOURCE" --dest "$DEST" --namespaces "$NS" --dry-run
    echo ""
    info "Assertions (nothing should change in dry-run):"
    if git -C "$REPO_ROOT" diff --quiet; then
        pass "No files changed in dry-run"
    else
        fail "Files changed during dry-run"
    fi
}

test_promote() {
    header "Phase 4b: PROMOTE (real)"
    "$MIGRATE" --phase promote --source "$SOURCE" --dest "$DEST" --namespaces "$NS"
    echo ""
    info "Assertions:"

    # canaryApps.ghaRunners on dest has no NS entries
    for key in "${EXPECTED_RUNNERS[@]}"; do
        assert_yq_is_null "$DST_VALUES" \
            ".argocdApplications.canaryApps.ghaRunners.\"${key}\"" \
            "Dest canaryApps.$key removed"
    done

    # ghaRunners on dest has entries without .test suffix
    for i in "${!EXPECTED_RUNNERS[@]}"; do
        local key="${EXPECTED_RUNNERS[$i]}"
        local rn="${EXPECTED_RELEASE_NAMES[$i]}"
        assert_yq_equals "$DST_VALUES" \
            ".argocdApplications.ghaRunners.\"${key}\".helm.releaseName" \
            "$rn" \
            "Dest ghaRunners.$key has releaseName $rn (no .test)"
        assert_yq_equals "$DST_VALUES" \
            ".argocdApplications.ghaRunners.\"${key}\".namespace" \
            "$NS" \
            "Dest ghaRunners.$key has namespace $NS"
        assert_yq_equals "$DST_VALUES" \
            ".argocdApplications.ghaRunners.\"${key}\".helm.valueFiles" \
            "$EXPECTED_SHARED_VALUE_PATH" \
            "Dest ghaRunners.$key still points to shared value path"
    done

    # namespaceManager.namespaces on dest includes NS
    assert_yq_contains "$DST_VALUES" \
        '.argocdApplications.namespaceManager.namespaces[]' \
        "$NS" \
        "Dest namespaceManager includes $NS"

    # externalSecrets.namespaces on dest includes NS
    assert_yq_contains "$DST_VALUES" \
        '.argocdApplications.externalSecrets.namespaces[]' \
        "$NS" \
        "Dest externalSecrets includes $NS"

    # canaryApps.namespaces should no longer contain NS
    assert_yq_not_contains "$DST_VALUES" \
        '.argocdApplications.canaryApps.namespaces[]' \
        "$NS" \
        "Dest canaryApps.namespaces no longer includes $NS"

    show_diff
    commit_phase "promote"
}

test_verify() {
    header "Phase 5: VERIFY"
    "$MIGRATE" --phase verify --source "$SOURCE" --dest "$DEST" --namespaces "$NS"
    local rc=$?
    echo ""
    [[ $rc -eq 0 ]] && pass "Verify phase exited with code 0" || fail "Verify phase exited with code $rc"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    check_prereqs
    setup

    # Phase 1: Shadow
    test_shadow_dry_run
    test_shadow
    gate

    # Phase 2: Drain
    test_drain_dry_run
    test_drain
    gate

    # Phase 3: Delete source
    test_delete_source_dry_run
    test_delete_source
    gate

    # Phase 4: Promote
    test_promote_dry_run
    test_promote
    gate

    # Phase 5: Verify
    test_verify

    # Summary
    header "TEST SUMMARY"
    if [[ $FAILURES -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}All assertions passed!${NC}"
    else
        echo -e "${RED}${BOLD}$FAILURES assertion(s) failed.${NC}"
    fi
    echo ""

    cleanup

    exit "$FAILURES"
}

main "$@"
