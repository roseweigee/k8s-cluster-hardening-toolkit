#!/bin/bash
# ============================================================
# Safe batch apply for suggested probe patches.
# Reads suggested_patches.sh (one command per line), skips known
# exceptions and platform namespaces, then for every remaining item:
#   confirm -> apply -> watch rollout -> on failure roll back and stop.
#
# Usage: ./apply_probes_batch.sh
#        EXCLUDE_INFRA_NS=false ./apply_probes_batch.sh   # include platform namespaces
# ============================================================
set -uo pipefail

PATCHFILE="suggested_patches.sh"
TIMEOUT=120

# --- Exclude platform/monitoring namespaces (default: on) ---
# Lesson learned: adding a probe to Loki restarted it and exposed a
# data-directory lock on local storage. Platform components are handled
# separately, never in the same batch as business services.
EXCLUDE_INFRA_NS="${EXCLUDE_INFRA_NS:-true}"

# Adjust to your cluster's namespace naming.
INFRA_NAMESPACES=(
  "monitoring"
  "loki"
  "prometheus"
  "grafana"
  "logging"
  "observability"
)

command -v kubectl >/dev/null || { echo "ERROR: kubectl not found"; exit 1; }
if [ ! -f "$PATCHFILE" ]; then
  echo "ERROR: $PATCHFILE not found (run ./check_and_suggest.sh first)"
  exit 1
fi

# --- Known exceptions (namespace|name), always skipped ---
# Edit for your cluster. Typical reasons:
#   - multi-container workloads: patch all containers in ONE command manually
#     (separate patches trigger back-to-back rollouts that collide)
#   - node-level agents with no Service port to probe (kube-proxy, CNI)
#   - batch/worker containers that do not listen on any port
SKIP_LIST=(
  "airflow|airflow"
  "cattle-fleet-system|fleet-controller"
  "cattle-fleet-local-system|fleet-agent"
  "kube-flannel|kube-flannel-ds"
  "kube-system|kube-proxy"
  "cert-manager|cert-manager"
  "cert-manager|cert-manager-cainjector"
  "example-app|example-app-mail-worker"
  "example-app|example-app-screenshot-job"
)

is_skipped() {
  local ns=$1 name=$2
  for entry in "${SKIP_LIST[@]}"; do
    IFS='|' read -r sns sname <<< "$entry"
    if [ "$ns" = "$sns" ] && [ "$name" = "$sname" ]; then
      return 0
    fi
  done
  return 1
}

is_infra_namespace() {
  local ns=$1
  [ "$EXCLUDE_INFRA_NS" = "true" ] || return 1
  for infra_ns in "${INFRA_NAMESPACES[@]}"; do
    if [ "$ns" = "$infra_ns" ]; then
      return 0
    fi
  done
  return 1
}

# --- Parse suggested_patches.sh and show an overview first ---
declare -a TODO_LINES=()
declare -a SKIPPED_ITEMS=()
declare -a SKIPPED_INFRA_ITEMS=()

while IFS= read -r line; do
  [[ "$line" == kubectl\ patch* ]] || continue
  kind=$(echo "$line" | awk '{print $3}')
  name=$(echo "$line" | awk '{print $4}')
  ns=$(echo "$line" | sed -E 's/.*-n ([^ ]+).*/\1/')

  if is_infra_namespace "$ns"; then
    SKIPPED_INFRA_ITEMS+=("[$kind] $ns/$name")
  elif is_skipped "$ns" "$name"; then
    SKIPPED_ITEMS+=("[$kind] $ns/$name")
  else
    TODO_LINES+=("$line")
  fi
done < "$PATCHFILE"

echo "=== Overview ==="
echo "To confirm one by one: ${#TODO_LINES[@]} item(s)"
echo "Auto-skipped (platform/monitoring namespaces, EXCLUDE_INFRA_NS=$EXCLUDE_INFRA_NS): ${#SKIPPED_INFRA_ITEMS[@]} item(s)"
for item in "${SKIPPED_INFRA_ITEMS[@]}"; do
  echo "  - skip(infra): $item"
done
echo "Auto-skipped (known exceptions): ${#SKIPPED_ITEMS[@]} item(s)"
for item in "${SKIPPED_ITEMS[@]}"; do
  echo "  - skip: $item"
done
echo ""

# --- Confirm and apply one at a time ---
INDEX=0
APPLIED=0
SKIPPED_MANUAL=0
for line in "${TODO_LINES[@]}"; do
  INDEX=$((INDEX+1))
  kind=$(echo "$line" | awk '{print $3}')
  name=$(echo "$line" | awk '{print $4}')
  ns=$(echo "$line" | sed -E 's/.*-n ([^ ]+).*/\1/')

  echo ""
  echo "=========================================================="
  echo ">>> [$INDEX/${#TODO_LINES[@]}] [$kind] $ns/$name"
  echo "=========================================================="
  echo "$line"
  echo ""
  read -rp "Apply? (yes = apply / skip = skip this one / anything else = abort batch): " CONFIRM

  if [ "$CONFIRM" = "skip" ]; then
    echo "Skipped $ns/$name."
    SKIPPED_MANUAL=$((SKIPPED_MANUAL+1))
    continue
  fi
  if [ "$CONFIRM" != "yes" ]; then
    echo "Batch aborted ($APPLIED item(s) applied)."
    exit 1
  fi

  echo ""
  echo "Pods before the change:"
  kubectl get pods -n "$ns" | grep "$name" || echo "(no matching pods)"

  echo ""
  echo "Applying..."
  if ! eval "$line"; then
    echo "ERROR: the patch command itself failed; aborting batch."
    exit 1
  fi

  echo ""
  echo "Waiting for rollout (up to ${TIMEOUT}s)..."
  if kubectl rollout status "$kind/$name" -n "$ns" --timeout="${TIMEOUT}s"; then
    echo "OK: $ns/$name rolled out."
    kubectl get pods -n "$ns" -o wide | grep "$name" || true
    APPLIED=$((APPLIED+1))
  else
    echo ""
    echo "FAILED: $ns/$name did not roll out in time; rolling back..."
    # Known limitation: an un-pinned undo switches to the PREVIOUS revision.
    # For multi-container workloads or repeated undos, roll back manually
    # with --to-revision (see docs/runbook.md).
    kubectl rollout undo "$kind/$name" -n "$ns"
    kubectl rollout status "$kind/$name" -n "$ns" --timeout=60s
    echo ""
    echo "Rolled back. Batch stopped here ($APPLIED applied, $SKIPPED_MANUAL skipped manually). Investigate before continuing."
    exit 1
  fi
done

echo ""
echo "=== Done: $APPLIED applied, $SKIPPED_MANUAL skipped manually, ${#SKIPPED_ITEMS[@]} known exceptions, ${#SKIPPED_INFRA_ITEMS[@]} platform namespace items ==="
