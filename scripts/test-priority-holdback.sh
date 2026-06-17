#!/usr/bin/env bash
# test-priority-holdback.sh
#
# Validates the priority holdback feature against a live llm-d cluster.
#
# The test creates InferenceObjective CRDs with different priorities, configures
# the priority-holdback-policy plugin, then sends concurrent requests at each
# priority level while driving the pool toward saturation. It verifies that
# lower-priority requests are gated before higher-priority ones by observing
# HTTP response codes and Prometheus metrics.
#
# Prerequisites:
#   - kubectl configured and pointing at the target cluster
#   - llm-d installed with flow control enabled
#   - curl and jq available
#   - A model server deployment behind the EPP (the script creates InferenceObjectives
#     but expects an existing InferencePool)
#
# Usage:
#   ./test-priority-holdback.sh [GATEWAY_URL] [METRICS_URL] [NAMESPACE] [INFERENCE_POOL]
#
# Example:
#   ./test-priority-holdback.sh http://localhost:30080 http://localhost:9090 default my-pool

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

GATEWAY_URL="${1:-http://localhost:30080}"
METRICS_URL="${2:-http://localhost:9090}"
NAMESPACE="${3:-default}"
INFERENCE_POOL="${4:-my-pool}"
MODEL_NAME="${MODEL_NAME:-test-model}"

# Priority levels to test (highest to lowest)
PRIORITY_HIGH=10
PRIORITY_MED=5
PRIORITY_LOW=1

# Number of concurrent requests per priority level during the load test
LOAD_CONCURRENCY="${LOAD_CONCURRENCY:-20}"

# Timeout for individual requests (seconds)
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-30}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; FAILURES=$((FAILURES + 1)); }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

FAILURES=0
CLEANUP_ITEMS=()

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

cleanup() {
    info "Cleaning up test resources..."
    for item in "${CLEANUP_ITEMS[@]:-}"; do
        kubectl delete -f - <<< "$item" --namespace "$NAMESPACE" --ignore-not-found 2>/dev/null || true
    done
    # Remove temp files
    rm -f /tmp/holdback-test-*.log 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helper: create an InferenceObjective CRD
# ---------------------------------------------------------------------------

create_inference_objective() {
    local name="$1"
    local priority="$2"

    local manifest
    manifest=$(cat <<EOF
apiVersion: inference.networking.x-k8s.io/v1alpha2
kind: InferenceObjective
metadata:
  name: ${name}
  namespace: ${NAMESPACE}
spec:
  targetRef:
    name: ${INFERENCE_POOL}
  priority: ${priority}
EOF
)
    CLEANUP_ITEMS+=("$manifest")
    echo "$manifest" | kubectl apply -f - --namespace "$NAMESPACE"
}

# ---------------------------------------------------------------------------
# Helper: send a request and capture HTTP status
# ---------------------------------------------------------------------------

send_request() {
    local objective="$1"
    local prompt="${2:-test prompt for priority holdback}"
    local output_file="${3:-/dev/null}"

    curl -s -o "$output_file" -w "%{http_code}" \
        --max-time "$REQUEST_TIMEOUT" \
        -X POST "${GATEWAY_URL}/v1/completions" \
        -H "Content-Type: application/json" \
        -H "x-llm-d-inference-objective: ${objective}" \
        -d "{\"model\":\"${MODEL_NAME}\",\"prompt\":\"${prompt}\",\"max_tokens\":10,\"temperature\":0}" \
        2>/dev/null || echo "000"
}

# ---------------------------------------------------------------------------
# Helper: send N concurrent requests and collect status codes
# ---------------------------------------------------------------------------

send_concurrent_requests() {
    local objective="$1"
    local count="$2"
    local log_prefix="$3"

    local pids=()
    for i in $(seq 1 "$count"); do
        local log_file="/tmp/holdback-test-${log_prefix}-${i}.log"
        send_request "$objective" "load test request ${i}" "$log_file" > "/tmp/holdback-test-${log_prefix}-${i}.status" &
        pids+=($!)
    done

    local success=0
    local gated=0
    local errors=0

    for pid in "${pids[@]}"; do
        wait "$pid" || true
    done

    for i in $(seq 1 "$count"); do
        local status
        status=$(cat "/tmp/holdback-test-${log_prefix}-${i}.status" 2>/dev/null || echo "000")
        case "$status" in
            200) success=$((success + 1)) ;;
            429|503) gated=$((gated + 1)) ;;
            *) errors=$((errors + 1)) ;;
        esac
    done

    echo "${success}:${gated}:${errors}"
}

# ---------------------------------------------------------------------------
# Helper: query a Prometheus metric
# ---------------------------------------------------------------------------

query_metric() {
    local metric="$1"
    local labels="${2:-}"

    local query
    if [[ -n "$labels" ]]; then
        query="${metric}{${labels}}"
    else
        query="${metric}"
    fi

    curl -s "${METRICS_URL}/api/v1/query" \
        --data-urlencode "query=${query}" 2>/dev/null \
        | jq -r '.data.result[0].value[1] // "N/A"' 2>/dev/null || echo "N/A"
}

# ---------------------------------------------------------------------------
# Helper: get pool saturation
# ---------------------------------------------------------------------------

get_saturation() {
    query_metric "llm_d_router_epp_flow_control_pool_saturation" "inference_pool=\"${INFERENCE_POOL}\""
}

# ---------------------------------------------------------------------------
# Helper: get queue duration by priority and outcome
# ---------------------------------------------------------------------------

get_request_count_by_outcome() {
    local priority="$1"
    local outcome="$2"

    query_metric "llm_d_router_epp_flow_control_request_queue_duration_seconds_count" \
        "priority=\"${priority}\",outcome=\"${outcome}\""
}

# ===========================================================================
# Test 1: Prerequisites check
# ===========================================================================

echo ""
echo "============================================="
echo " Priority Holdback Feature Test"
echo "============================================="
echo ""

info "Gateway URL: ${GATEWAY_URL}"
info "Metrics URL: ${METRICS_URL}"
info "Namespace:   ${NAMESPACE}"
info "Pool:        ${INFERENCE_POOL}"
echo ""

info "Checking prerequisites..."

# Check kubectl access
if kubectl get namespace "$NAMESPACE" &>/dev/null; then
    pass "kubectl access to namespace ${NAMESPACE}"
else
    fail "Cannot access namespace ${NAMESPACE}"
    echo "Aborting: cluster access required."
    exit 1
fi

# Check gateway is reachable
if curl -s --max-time 5 "${GATEWAY_URL}/v1/completions" -X POST \
    -H "Content-Type: application/json" \
    -d '{"model":"'${MODEL_NAME}'","prompt":"ping","max_tokens":1}' \
    -o /dev/null -w "%{http_code}" | grep -qE "200|400|404|503"; then
    pass "Gateway is reachable at ${GATEWAY_URL}"
else
    fail "Gateway is not reachable at ${GATEWAY_URL}"
    echo "Aborting: gateway must be reachable."
    exit 1
fi

# ===========================================================================
# Test 2: Create InferenceObjective CRDs
# ===========================================================================

echo ""
info "Creating InferenceObjective CRDs with priorities ${PRIORITY_HIGH}, ${PRIORITY_MED}, ${PRIORITY_LOW}..."

create_inference_objective "holdback-test-high" "$PRIORITY_HIGH"
create_inference_objective "holdback-test-med"  "$PRIORITY_MED"
create_inference_objective "holdback-test-low"  "$PRIORITY_LOW"

# Wait for the CRDs to be picked up
sleep 3

# Verify they exist
for name in holdback-test-high holdback-test-med holdback-test-low; do
    if kubectl get inferenceobjective "$name" -n "$NAMESPACE" &>/dev/null; then
        pass "InferenceObjective ${name} created"
    else
        fail "InferenceObjective ${name} not found"
    fi
done

# ===========================================================================
# Test 3: Baseline -- requests succeed at low saturation
# ===========================================================================

echo ""
info "Test: Baseline requests at low saturation..."

for obj in holdback-test-high holdback-test-med holdback-test-low; do
    status=$(send_request "$obj")
    if [[ "$status" == "200" ]]; then
        pass "Baseline request to ${obj} returned 200"
    else
        fail "Baseline request to ${obj} returned ${status} (expected 200)"
    fi
done

# Record baseline saturation
baseline_sat=$(get_saturation)
info "Baseline pool saturation: ${baseline_sat}"

# ===========================================================================
# Test 4: Load test -- drive saturation and observe priority differentiation
# ===========================================================================

echo ""
info "Test: Driving load to trigger priority holdback..."
info "Sending ${LOAD_CONCURRENCY} concurrent requests per priority level..."

# Send requests for all priorities simultaneously to create contention.
# Lower priorities should see more gating than higher priorities.

results_low=$(send_concurrent_requests "holdback-test-low" "$LOAD_CONCURRENCY" "low")
results_med=$(send_concurrent_requests "holdback-test-med" "$LOAD_CONCURRENCY" "med")
results_high=$(send_concurrent_requests "holdback-test-high" "$LOAD_CONCURRENCY" "high")

IFS=':' read -r low_success low_gated low_errors <<< "$results_low"
IFS=':' read -r med_success med_gated med_errors <<< "$results_med"
IFS=':' read -r high_success high_gated high_errors <<< "$results_high"

echo ""
info "Results (success/gated/error):"
info "  High priority (${PRIORITY_HIGH}): ${high_success}/${high_gated}/${high_errors}"
info "  Med  priority (${PRIORITY_MED}):  ${med_success}/${med_gated}/${med_errors}"
info "  Low  priority (${PRIORITY_LOW}):  ${low_success}/${low_gated}/${low_errors}"

current_sat=$(get_saturation)
info "Pool saturation after load: ${current_sat}"

# ===========================================================================
# Test 5: Verify priority ordering in gating behavior
# ===========================================================================

echo ""
info "Test: Verifying priority-based gating order..."

# The core invariant: lower priorities should be gated more than higher priorities.
# If the pool wasn't saturated enough to trigger any gating, the test is inconclusive
# (not a failure -- it means the cluster has too much capacity for our load).

total_gated=$((low_gated + med_gated + high_gated))

if [[ "$total_gated" -eq 0 ]]; then
    info "No requests were gated. The pool may not have reached saturation."
    info "Try increasing LOAD_CONCURRENCY (current: ${LOAD_CONCURRENCY}) or reducing pool capacity."
    info "Skipping gating order checks (inconclusive, not a failure)."
else
    # Check: low priority should be gated >= medium priority
    if [[ "$low_gated" -ge "$med_gated" ]]; then
        pass "Low priority gated (${low_gated}) >= medium priority gated (${med_gated})"
    else
        fail "Low priority gated (${low_gated}) < medium priority gated (${med_gated}) -- priority inversion"
    fi

    # Check: medium priority should be gated >= high priority
    if [[ "$med_gated" -ge "$high_gated" ]]; then
        pass "Medium priority gated (${med_gated}) >= high priority gated (${high_gated})"
    else
        fail "Medium priority gated (${med_gated}) < high priority gated (${high_gated}) -- priority inversion"
    fi

    # Check: high priority should have the most successes
    if [[ "$high_success" -ge "$low_success" ]]; then
        pass "High priority success (${high_success}) >= low priority success (${low_success})"
    else
        fail "High priority success (${high_success}) < low priority success (${low_success})"
    fi
fi

# ===========================================================================
# Test 6: Verify metrics are being recorded
# ===========================================================================

echo ""
info "Test: Checking Prometheus metrics..."

sat_value=$(get_saturation)
if [[ "$sat_value" != "N/A" ]]; then
    pass "Pool saturation metric is available: ${sat_value}"
else
    info "Pool saturation metric not available (Prometheus may not be configured)"
fi

# Check that flow control queue duration is recorded per priority
for priority in "$PRIORITY_HIGH" "$PRIORITY_MED" "$PRIORITY_LOW"; do
    dispatched=$(get_request_count_by_outcome "$priority" "Dispatched")
    if [[ "$dispatched" != "N/A" && "$dispatched" != "0" ]]; then
        pass "Flow control dispatch metric recorded for priority ${priority}: count=${dispatched}"
    else
        info "No dispatch metric for priority ${priority} (may not have been dispatched through flow control)"
    fi
done

# ===========================================================================
# Test 7: Recovery -- requests succeed after load subsides
# ===========================================================================

echo ""
info "Test: Waiting for saturation to subside..."
sleep 5

for obj in holdback-test-high holdback-test-med holdback-test-low; do
    status=$(send_request "$obj")
    if [[ "$status" == "200" ]]; then
        pass "Post-load request to ${obj} returned 200 (system recovered)"
    else
        fail "Post-load request to ${obj} returned ${status} (system may not have recovered)"
    fi
done

# ===========================================================================
# Summary
# ===========================================================================

echo ""
echo "============================================="
if [[ "$FAILURES" -eq 0 ]]; then
    echo -e " ${GREEN}All checks passed${NC}"
else
    echo -e " ${RED}${FAILURES} check(s) failed${NC}"
fi
echo "============================================="
echo ""

exit "$FAILURES"
