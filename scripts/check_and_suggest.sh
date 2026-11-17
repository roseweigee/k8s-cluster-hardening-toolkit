#!/bin/bash
# ============================================================
# K8s audit: resource requests/limits + liveness/readiness probe gaps.
# Scans Deployments, StatefulSets and DaemonSets cluster-wide and
# generates suggested `kubectl patch` commands for every gap found.
#
# Usage: ./check_and_suggest.sh               # check resources + probes
#        ./check_and_suggest.sh --probes-only # check probes only
# Requires: kubectl, jq
#
# IMPORTANT: this script only SUGGESTS changes. It never applies anything.
#   - Suggested resource values are conservative starting points, not
#     sized values. Tune them later against real usage (Prometheus,
#     `kubectl top`). In --probes-only mode no resource suggestions are made.
#   - The suggested probe port comes from the matching Service's
#     targetPort first (what traffic is actually forwarded to). Only when
#     no Service matches does it fall back to the declared containerPort,
#     which may be stale. Double-check with `kubectl describe svc`.
#   - Probes are generic tcpSocket checks (port is open), not real
#     application-level health checks. Replace with httpGet (e.g. /healthz)
#     once the service owner confirms a health endpoint.
#   - All commands are collected in suggested_patches.sh. Review them one
#     by one; never run the whole file blindly.
# ============================================================
set -euo pipefail

PROBES_ONLY=false
if [ "${1:-}" = "--probes-only" ]; then
  PROBES_ONLY=true
fi

command -v kubectl >/dev/null || { echo "ERROR: kubectl not found"; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq is required (e.g. sudo apt install -y jq)"; exit 1; }

DEFAULT_CPU_REQUEST="100m"
DEFAULT_MEM_REQUEST="128Mi"
DEFAULT_CPU_LIMIT="500m"
DEFAULT_MEM_LIMIT="512Mi"

if [ "$PROBES_ONLY" = true ]; then
  echo "Mode: --probes-only (probes only; resource requests/limits are not checked)"
fi

echo "Loading Services as the primary source for probe ports (more reliable than declared containerPort)..."
SVC_TMPFILE=$(mktemp)
trap 'rm -f "$SVC_TMPFILE"' EXIT
kubectl get svc -A -o json > "$SVC_TMPFILE"

OUTFILE="suggested_patches.sh"
{
  echo "#!/bin/bash"
  echo "# Auto-generated suggested patches - review each line before running; never run blindly"
  echo "# Resources are conservative starting values; probes are generic tcpSocket checks"
  echo "set -e"
  echo ""
} > "$OUTFILE"
chmod +x "$OUTFILE"

process_kind() {
  local kind=$1
  kubectl get "$kind" -A -o json 2>/dev/null | jq -r \
    --slurpfile svcs_arr "$SVC_TMPFILE" \
    --arg cpuReq "$DEFAULT_CPU_REQUEST" --arg memReq "$DEFAULT_MEM_REQUEST" \
    --arg cpuLim "$DEFAULT_CPU_LIMIT" --arg memLim "$DEFAULT_MEM_LIMIT" \
    --arg kind "$kind" --argjson probesOnly "$PROBES_ONLY" '
    ($svcs_arr[0]) as $svcs |
    # A Service matches a workload when every key in its selector equals the pod template label
    def matchesSelector(sel; labels):
      (sel | length) > 0 and
      ((sel | to_entries) | map(labels[.key] == .value) | all);

    .items[]? as $item |
    $item.metadata.namespace as $ns |
    $item.metadata.name as $name |
    ($item.spec.template.metadata.labels // {}) as $podLabels |
    ([$svcs.items[]? | select(.metadata.namespace == $ns) |
      select((.spec.selector // {}) as $sel | matchesSelector($sel; $podLabels))
     ]) as $matchedSvcs |
    (($matchedSvcs[0].spec.ports[0].targetPort) // null) as $svcPort |
    ($item.spec.template.spec.containers // [])[] as $c |
    ($c.resources.requests.cpu // null) as $hasReqCpu |
    ($c.resources.requests.memory // null) as $hasReqMem |
    ($c.resources.limits.cpu // null) as $hasLimCpu |
    ($c.resources.limits.memory // null) as $hasLimMem |
    ($c.livenessProbe // null) as $hasLive |
    ($c.readinessProbe // null) as $hasReady |
    (($c.ports // [])[0].containerPort // null) as $declaredPort |
    ($svcPort // $declaredPort) as $port |
    ($svcPort != null) as $portFromSvc |
    (
      if $probesOnly then ($hasLive != null and $hasReady != null)
      else ($hasReqCpu != null and $hasReqMem != null and $hasLimCpu != null and $hasLimMem != null and $hasLive != null and $hasReady != null)
      end
    ) as $complete |
    (if $complete
     then empty
     else
      {
        ns: $ns, kind: $kind, name: $name, container: $c.name,
        port: $port, portFromSvc: $portFromSvc, declaredPort: $declaredPort,
        missing: ([
          (if $probesOnly then empty elif $hasReqCpu == null then "cpu-request" else empty end),
          (if $probesOnly then empty elif $hasReqMem == null then "mem-request" else empty end),
          (if $probesOnly then empty elif $hasLimCpu == null then "cpu-limit" else empty end),
          (if $probesOnly then empty elif $hasLimMem == null then "mem-limit" else empty end),
          (if $hasLive == null then "liveness" else empty end),
          (if $hasReady == null then "readiness" else empty end)
        ]),
        patchContainer: ({name: $c.name} +
          (if $probesOnly or ($hasReqCpu != null and $hasReqMem != null and $hasLimCpu != null and $hasLimMem != null) then {} else
            {resources: {
              requests: {cpu: ($hasReqCpu // $cpuReq), memory: ($hasReqMem // $memReq)},
              limits: {cpu: ($hasLimCpu // $cpuLim), memory: ($hasLimMem // $memLim)}
            }}
          end) +
          (if ($hasLive != null) or ($port == null) then {} else
            {livenessProbe: {tcpSocket: {port: $port}, initialDelaySeconds: 10, periodSeconds: 10}}
          end) +
          (if ($hasReady != null) or ($port == null) then {} else
            {readinessProbe: {tcpSocket: {port: $port}, initialDelaySeconds: 5, periodSeconds: 10}}
          end)
        )
      } | @json
     end)
  '
}

REPORT="check_report_$(date +%Y%m%d_%H%M%S).txt"

{
  if [ "$PROBES_ONLY" = true ]; then
    echo "=== Liveness/readiness probe gap check (probes only) ==="
  else
    echo "=== Resource requests/limits + probe gap check ==="
  fi
  echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
  echo ""

  {
    process_kind deployment
    process_kind statefulset
    process_kind daemonset
  } | while IFS= read -r line; do
    ns=$(echo "$line" | jq -r '.ns')
    kind=$(echo "$line" | jq -r '.kind')
    name=$(echo "$line" | jq -r '.name')
    container=$(echo "$line" | jq -r '.container')
    port=$(echo "$line" | jq -r '.port')
    port_from_svc=$(echo "$line" | jq -r '.portFromSvc')
    declared_port=$(echo "$line" | jq -r '.declaredPort')
    missing=$(echo "$line" | jq -r '.missing | join(", ")')
    patch_container=$(echo "$line" | jq -c '.patchContainer')

    echo "--------------------------------------------------------"
    echo "[$kind] $ns/$name (container: $container)"
    echo "  Missing: $missing"

    if [ "$port" = "null" ] && echo "$missing" | grep -qE "liveness|readiness"; then
      echo "  NOTE: probes are missing and no Service or containerPort is available; decide the health check manually"
    elif echo "$missing" | grep -qE "liveness|readiness"; then
      if [ "$port_from_svc" = "true" ]; then
        echo "  Port source: Service targetPort = $port (reliable: taken from actual forwarding)"
        if [ "$declared_port" != "null" ] && [ "$declared_port" != "$port" ]; then
          echo "  WARNING: declared containerPort ($declared_port) differs from Service targetPort ($port). The YAML is stale; using the Service value."
        fi
      else
        echo "  Port source: declared containerPort = $port (no matching Service to cross-check; verify before applying)"
      fi
    fi

    patch_json=$(jq -cn --argjson c "$patch_container" '{spec:{template:{spec:{containers:[$c]}}}}')
    cmd="kubectl patch $kind $name -n $ns -p '$patch_json'"
    echo "  Suggested command:"
    echo "  $cmd"
    echo "$cmd" >> "$OUTFILE"
  done

  echo ""
  echo "=== Done ==="
  echo "All suggested patch commands were written to $OUTFILE (executable)."
  echo "Review each line before running. Probes are generic tcpSocket checks; confirm a real health endpoint with the service owner."
  echo "Apply them safely with: ./apply_probes_batch.sh"
} | tee "$REPORT"

echo ""
echo "Report saved to: $REPORT"
