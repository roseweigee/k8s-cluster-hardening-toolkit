#!/bin/bash
# ============================================================
# K8s cluster final acceptance check.
# Verifies each remediation item against the LIVE cluster state
# instead of a manually updated progress sheet, and prints a
# PASS / WARN / FAIL report.
#
# Usage: ./final_acceptance_check.sh
# Optional settings (environment variables):
#   CP_NODE            control-plane node to check for taint/encryption (default: cp-01)
#   INFRA_NODE         dedicated infra node                           (default: infra-01)
#   INCIDENT_NS        namespace of a known-broken deployment to verify (optional)
#   INCIDENT_DEPLOY    name of that deployment                          (optional)
#   MONITORING_NS      monitoring namespace                             (default: monitoring)
# Requires: kubectl; jq for the probe-gap section
# ============================================================
set -uo pipefail

command -v kubectl >/dev/null || { echo "ERROR: kubectl not found"; exit 1; }

CP_NODE="${CP_NODE:-cp-01}"
INFRA_NODE="${INFRA_NODE:-infra-01}"
INCIDENT_NS="${INCIDENT_NS:-}"
INCIDENT_DEPLOY="${INCIDENT_DEPLOY:-}"
MONITORING_NS="${MONITORING_NS:-monitoring}"

PASS=0
WARN=0
FAIL=0

pass() { echo "  ✔ PASS: $1"; PASS=$((PASS+1)); }
warn() { echo "  ⚠ WARN: $1"; WARN=$((WARN+1)); }
fail() { echo "  ✘ FAIL: $1"; FAIL=$((FAIL+1)); }

section() {
  echo ""
  echo "=========================================================="
  echo "$1"
  echo "=========================================================="
}

REPORT="final_acceptance_$(date +%Y%m%d_%H%M%S).txt"

{
echo "K8s cluster final acceptance check"
echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"

# ------------------------------------------------------------
section "1. Service outage fix (known-broken deployment) + CrashLoopBackOff sweep"
# ------------------------------------------------------------
if [ -n "$INCIDENT_NS" ] && [ -n "$INCIDENT_DEPLOY" ]; then
  if kubectl get deployment -n "$INCIDENT_NS" "$INCIDENT_DEPLOY" >/dev/null 2>&1; then
    RESTARTS=$(kubectl get pods -n "$INCIDENT_NS" -l app="$INCIDENT_DEPLOY" \
      -o jsonpath='{.items[*].status.containerStatuses[*].restartCount}' 2>/dev/null)
    echo "  Deployment still exists, restart counts: $RESTARTS"
    warn "$INCIDENT_DEPLOY still exists; check whether restarts keep increasing"
  else
    pass "$INCIDENT_DEPLOY removed (misconfigured deployment cleaned up)"
  fi
else
  echo "  INCIDENT_NS / INCIDENT_DEPLOY not set; skipping the specific incident check"
fi
echo "  Pods currently in CrashLoopBackOff:"
kubectl get pods -A 2>/dev/null | grep CrashLoopBackOff || echo "  (none)"

# ------------------------------------------------------------
section "2. Cluster resilience (CoreDNS spread across nodes)"
# ------------------------------------------------------------
COREDNS_NODES=$(kubectl get pods -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n' | sort -u | wc -l)
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide
if [ "$COREDNS_NODES" -ge 2 ]; then
  pass "CoreDNS replicas run on $COREDNS_NODES different nodes"
else
  fail "CoreDNS replicas share one node; single point of failure remains"
fi

# ------------------------------------------------------------
section "3. Ingress controller"
# ------------------------------------------------------------
if kubectl get pods -n ingress-nginx >/dev/null 2>&1 && [ -n "$(kubectl get pods -n ingress-nginx --no-headers 2>/dev/null)" ]; then
  kubectl get pods -n ingress-nginx
  kubectl get ingressclass 2>/dev/null
  pass "ingress-nginx installed with running pods"
else
  warn "ingress-nginx not detected; acceptable only if it is a known pending item (e.g. waiting for domain/network allocation)"
fi

# ------------------------------------------------------------
section "4. Alerting (Alertmanager)"
# ------------------------------------------------------------
AM_PODS=$(kubectl get pods -n "$MONITORING_NS" -l app=alertmanager --no-headers 2>/dev/null | wc -l)
kubectl get pods -n "$MONITORING_NS" -l app=alertmanager 2>/dev/null
if [ "$AM_PODS" -ge 1 ] && ! kubectl get pods -n "$MONITORING_NS" -l app=alertmanager --no-headers 2>/dev/null | grep -qv Running; then
  pass "Alertmanager deployed and Running"
else
  fail "Alertmanager missing or not Running"
fi

# ------------------------------------------------------------
section "5. Control-plane node protection (taint on $CP_NODE)"
# ------------------------------------------------------------
TAINT=$(kubectl get node "$CP_NODE" -o jsonpath='{.spec.taints[?(@.key=="node-role.kubernetes.io/control-plane")]}' 2>/dev/null)
if [ -n "$TAINT" ]; then
  pass "$CP_NODE has the control-plane taint"
else
  fail "$CP_NODE is missing the control-plane taint"
fi
echo "  Taints on all control-plane nodes:"
kubectl get nodes -l node-role.kubernetes.io/control-plane -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints 2>/dev/null

# ------------------------------------------------------------
section "6. Resource governance (ResourceQuota per namespace)"
# ------------------------------------------------------------
MISSING_RQ=0
TOTAL_NS=0
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  TOTAL_NS=$((TOTAL_NS+1))
  rq_count=$(kubectl get resourcequota -n "$ns" --no-headers 2>/dev/null | wc -l)
  if [ "$rq_count" -eq 0 ]; then
    MISSING_RQ=$((MISSING_RQ+1))
  fi
done
echo "  $TOTAL_NS namespaces, $MISSING_RQ without a ResourceQuota"
if [ "$MISSING_RQ" -eq 0 ]; then
  pass "Every namespace has a ResourceQuota"
else
  warn "$MISSING_RQ namespace(s) have no ResourceQuota (platform/system namespaces may be excluded by policy)"
fi

# ------------------------------------------------------------
section "7. Log collection (Promtail coverage)"
# ------------------------------------------------------------
PT_DESIRED=$(kubectl get daemonset promtail -n "$MONITORING_NS" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
PT_READY=$(kubectl get daemonset promtail -n "$MONITORING_NS" -o jsonpath='{.status.numberReady}' 2>/dev/null)
echo "  promtail: desired=$PT_DESIRED, ready=$PT_READY"
if [ -n "$PT_DESIRED" ] && [ "$PT_DESIRED" = "$PT_READY" ]; then
  pass "promtail covers all $PT_DESIRED nodes"
else
  fail "promtail coverage incomplete (desired=$PT_DESIRED, ready=$PT_READY)"
fi

# ------------------------------------------------------------
section "8. Web console (Rancher)"
# ------------------------------------------------------------
RANCHER_READY=$(kubectl get deployment rancher -n cattle-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
kubectl get pods -n cattle-system -l app=rancher 2>/dev/null
kubectl get svc rancher -n cattle-system 2>/dev/null
if [ "${RANCHER_READY:-0}" -ge 1 ]; then
  pass "Rancher deployed with at least 1 ready replica"
else
  fail "Rancher missing or has no ready replica"
fi

# ------------------------------------------------------------
section "9. Application health checks (liveness/readiness probe gaps)"
# ------------------------------------------------------------
# Multi-container workloads handled manually, outside the batch script.
KNOWN_MULTI_CONTAINER_NS_NAME=(
  "airflow|airflow"
  "cattle-fleet-system|fleet-controller"
  "cattle-fleet-local-system|fleet-agent"
)

# Accepted exceptions: probes do not apply architecturally (node-level
# components with no Service port). Closed, not counted as gaps.
ACCEPTED_EXCEPTIONS_NS_NAME=(
  "kube-flannel|kube-flannel-ds"
  "kube-system|kube-proxy"
)

# Paused items: attempted, a problem was found, rolled back. These are NOT
# done; the reason is recorded so the next person can continue without
# re-investigating. Format: namespace|name|reason
PAUSED_PENDING_INVESTIGATION=(
  "monitoring|loki|Restart after adding probes led to CrashLoopBackOff of the container itself (not a probe failure); suspected WAL/index lock on local-storage data dir; rolled back to no probes; next step: kubectl logs --previous"
)

if command -v jq >/dev/null 2>&1; then
  PROBE_GAP_TOTAL=0
  PROBE_GAP_KNOWN=0
  PROBE_GAP_UNKNOWN=0
  PROBE_GAP_EXCEPTED=0
  PROBE_GAP_PAUSED=0
  UNKNOWN_LIST=""

  for kind in deployment statefulset daemonset; do
    while IFS=$'\t' read -r ns name; do
      [ -z "$ns" ] && continue
      is_known=false
      is_excepted=false
      is_paused=false
      for entry in "${KNOWN_MULTI_CONTAINER_NS_NAME[@]}"; do
        IFS='|' read -r kns kname <<< "$entry"
        if [ "$ns" = "$kns" ] && [ "$name" = "$kname" ]; then
          is_known=true
          break
        fi
      done
      for entry in "${ACCEPTED_EXCEPTIONS_NS_NAME[@]}"; do
        IFS='|' read -r ens ename <<< "$entry"
        if [ "$ns" = "$ens" ] && [ "$name" = "$ename" ]; then
          is_excepted=true
          break
        fi
      done
      for entry in "${PAUSED_PENDING_INVESTIGATION[@]}"; do
        IFS='|' read -r pns pname preason <<< "$entry"
        if [ "$ns" = "$pns" ] && [ "$name" = "$pname" ]; then
          is_paused=true
          PAUSE_REASON="$preason"
          break
        fi
      done
      if [ "$is_excepted" = true ]; then
        PROBE_GAP_EXCEPTED=$((PROBE_GAP_EXCEPTED+1))
      elif [ "$is_paused" = true ]; then
        PROBE_GAP_PAUSED=$((PROBE_GAP_PAUSED+1))
        echo "  ⏸ Paused: [$kind] $ns/$name"
        echo "     Reason: $PAUSE_REASON"
      elif [ "$is_known" = true ]; then
        PROBE_GAP_KNOWN=$((PROBE_GAP_KNOWN+1))
      else
        PROBE_GAP_UNKNOWN=$((PROBE_GAP_UNKNOWN+1))
        UNKNOWN_LIST="${UNKNOWN_LIST}  - [$kind] $ns/$name\n"
      fi
      PROBE_GAP_TOTAL=$((PROBE_GAP_TOTAL+1))
    done < <(kubectl get "$kind" -A -o json 2>/dev/null | jq -r '
      .items[]? |
      select([.spec.template.spec.containers[]? | select((.livenessProbe==null) or (.readinessProbe==null))] | length > 0) |
      [.metadata.namespace, .metadata.name] | @tsv
    ')
  done

  echo "  Workloads still missing probes: $PROBE_GAP_TOTAL"
  echo "    accepted exceptions (not counted as gaps): $PROBE_GAP_EXCEPTED"
  echo "    paused pending investigation (attempted, NOT done): $PROBE_GAP_PAUSED"
  echo "    known multi-container items (manual plan exists): $PROBE_GAP_KNOWN"
  echo "    unexpected gaps: $PROBE_GAP_UNKNOWN"
  if [ "$PROBE_GAP_UNKNOWN" -gt 0 ]; then
    echo -e "  Unexpected gaps:\n$UNKNOWN_LIST"
  fi

  if [ "$PROBE_GAP_TOTAL" -eq 0 ]; then
    pass "All workloads have liveness/readiness probes"
  elif [ "$PROBE_GAP_UNKNOWN" -eq 0 ] && [ "$PROBE_GAP_PAUSED" -eq 0 ]; then
    warn "Remaining gaps are all known items with a manual plan"
  elif [ "$PROBE_GAP_UNKNOWN" -eq 0 ]; then
    warn "Remaining gaps are known items, plus $PROBE_GAP_PAUSED paused item(s) (see reasons above); do not count them as done"
  elif [ "$PROBE_GAP_UNKNOWN" -le 3 ]; then
    warn "$PROBE_GAP_UNKNOWN unexpected gap(s) (plus $PROBE_GAP_KNOWN known items); wrap-up stage"
  else
    fail "$PROBE_GAP_UNKNOWN unexpected gap(s) (plus $PROBE_GAP_KNOWN known items); needs review"
  fi
else
  warn "jq not installed; probe gap statistics skipped (run check_and_suggest.sh --probes-only instead)"
fi

# ------------------------------------------------------------
section "10. Prometheus"
# ------------------------------------------------------------
PROM_READY=$(kubectl get deployment prometheus -n "$MONITORING_NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if [ "${PROM_READY:-0}" -ge 1 ]; then
  pass "Prometheus running (check target up/down counts in the UI or API)"
else
  fail "Prometheus not running"
fi

# ------------------------------------------------------------
section "11. Monitoring and business data backup"
# ------------------------------------------------------------
CJ_COUNT=$(kubectl get cronjob -n "$MONITORING_NS" --no-headers 2>/dev/null | wc -l)
kubectl get cronjob -n "$MONITORING_NS" 2>/dev/null
if [ "$CJ_COUNT" -ge 1 ]; then
  echo "  Last schedule:"
  kubectl get cronjob -n "$MONITORING_NS" -o custom-columns=NAME:.metadata.name,LAST_SCHEDULE:.status.lastScheduleTime 2>/dev/null
  pass "$CJ_COUNT backup CronJob(s) configured"
else
  fail "No backup CronJob found in $MONITORING_NS"
fi

# ------------------------------------------------------------
section "12. Dedicated infra node ($INFRA_NODE)"
# ------------------------------------------------------------
INFRA_LABEL=$(kubectl get node "$INFRA_NODE" -o jsonpath='{.metadata.labels.node-role}' 2>/dev/null)
INFRA_TAINT=$(kubectl get node "$INFRA_NODE" -o jsonpath='{.spec.taints[?(@.key=="dedicated")]}' 2>/dev/null)
echo "  node-role label: $INFRA_LABEL"
echo "  dedicated taint: $INFRA_TAINT"
if [ "$INFRA_LABEL" = "infra" ] && [ -n "$INFRA_TAINT" ]; then
  pass "$INFRA_NODE has the infra label and dedicated taint"
else
  fail "$INFRA_NODE label or taint incomplete"
fi
echo "  Pods scheduled on $INFRA_NODE:"
kubectl get pods -A -o wide 2>/dev/null | awk -v n="$INFRA_NODE" '$8==n{print}'

# ------------------------------------------------------------
section "13. Secret encryption at rest (etcd)"
# ------------------------------------------------------------
ENC_FLAG=$(kubectl get pod "kube-apiserver-$CP_NODE" -n kube-system -o jsonpath='{.spec.containers[0].command}' 2>/dev/null | grep -o "encryption-provider-config" || true)
if [ -n "$ENC_FLAG" ]; then
  pass "kube-apiserver has encryption-provider-config"
else
  fail "kube-apiserver has no encryption-provider-config; Secrets may be stored as plain base64"
fi

# ------------------------------------------------------------
section "Summary"
# ------------------------------------------------------------
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo ""
if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
  echo "Result: all items passed; ready for acceptance."
elif [ "$FAIL" -eq 0 ]; then
  echo "Result: no FAIL, $WARN WARN item(s); explain them before acceptance (usually known risks or wrap-up items)."
else
  echo "Result: $FAIL FAIL item(s); fix them before acceptance."
fi

} | tee "$REPORT"

echo ""
echo "Report saved to: $REPORT"
