# Runbook: filling resource and probe gaps safely

This runbook covers adding missing CPU/memory requests and limits and liveness/readiness probes to Deployments, StatefulSets and DaemonSets in a running cluster.

**Rule of thumb:** checks and suggestions run automatically; every change to the cluster is confirmed by a person, one item at a time. Never run a batch of patches blindly.

## Standard flow

1. **Scan.** `./scripts/check_and_suggest.sh` (or `--probes-only`) writes `suggested_patches.sh` and a readable `check_report_*.txt`. Probe ports come from the matching Service's `targetPort`; the report warns when the declared `containerPort` disagrees.
2. **Review.** Read the report. Move multi-container workloads, node agents and port-less workers to the skip list in `apply_probes_batch.sh`.
3. **Apply.** `./scripts/apply_probes_batch.sh` asks for `yes` before each patch, watches the rollout, and on failure rolls back and stops the whole batch. Start with replicated business services; leave platform components (monitoring, Rancher, CoreDNS) for last, handled separately.
4. **Accept.** `./scripts/final_acceptance_check.sh` checks every item against the live cluster and writes `final_acceptance_*.txt`.

## Multi-container workloads (manual)

Patching each container separately triggers one rolling update per patch, and the rollouts collide. Instead:

1. **Size from real usage, not defaults.** `kubectl top pod <pod> -n <ns> --containers`, then set the limit at about 1.3–1.5× observed usage. Applying the default 512Mi memory limit to a scheduler that really uses ~4.7Gi would OOMKill it.
2. **Check node capacity with requests, not usage.** The scheduler places pods by the sum of requests, so use `kubectl describe node <node> | grep -A 5 "Allocated resources"`, not `kubectl top nodes`.
3. **Send one patch for all containers:**
   ```bash
   kubectl patch deployment <name> -n <ns> -p '{"spec":{"template":{"spec":{"containers":[
     {"name":"<c1>","resources":{...}},
     {"name":"<c2>","resources":{...}}
   ]}}}}'
   ```
4. **Watch for 5–10 minutes.** `kubectl get pods -n <ns> -w`. A successful rollout only proves the probes pass; OOMKills can appear later. RESTARTS must stay at 0.

## Troubleshooting: the pod will not come up

First decide whether it **cannot be scheduled** or **starts and gets killed**:

```bash
kubectl get pods -n <ns>
kubectl get events -n <ns> --sort-by='.lastTimestamp' | tail -30
```

| Symptom | Likely cause | How to confirm |
| --- | --- | --- |
| Pod stuck in Pending | Requests do not fit on any node | `kubectl describe pod`, look for FailedScheduling |
| Probe fails with connection refused | Wrong port: nothing listens there | `kubectl describe svc <name>`, trust TargetPort |
| Probe fails with timeout (not refused) | Service starts slowly | Increase `initialDelaySeconds` before suspecting the port |
| Restarts / OOMKilled | Memory limit too tight | `kubectl top pod --containers`, raise the limit |

Declared ports are often stale. Real examples from this engagement: a backend declared 3000 but served on 3004; a frontend declared 80 but served on 5176.

## Rolling back correctly

Never call an un-pinned `kubectl rollout undo` twice. It switches to the *previous* revision, not to a known-good one, so a second call flips back to the broken version.

```bash
# 1. Find the ReplicaSet that is healthy (READY matches the expected count)
kubectl get rs -n <ns>
# 2. Read its revision number
kubectl get rs <rs-name> -n <ns> \
  -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}'
# 3. Roll back to that exact revision
kubectl rollout undo deployment/<name> -n <ns> --to-revision=<n>
# 4. Confirm it converged
kubectl rollout status deployment/<name> -n <ns> --timeout=60s
```

The automatic rollback in `apply_probes_batch.sh` uses an un-pinned undo. If it times out or does not converge cleanly, stop retrying the script and use the steps above.

## Case log

| Workload | Problem | Root cause and fix |
| --- | --- | --- |
| Web backend | Probe timeout, rollout failed | Declared port 3000, Service forwards to 3004; used the Service port |
| Airflow (4 containers) | Rollout stuck twice | Separate patches on a single replica collided; merged into one patch |
| Airflow scheduler | Would OOMKill with default 512Mi | Real usage 4715Mi; sized the limit from `kubectl top` |
| Loki | CrashLoopBackOff after probe was added | Not a probe failure; suspected data-directory lock on local storage; rolled back, paused for investigation |

## Handover checklist

- [ ] `jq` installed (offline install in air-gapped environments)
- [ ] `kubectl get nodes` works from the operator machine
- [ ] Scripts are executable and in one working folder
- [ ] Multi-container workloads are on the skip list and handled manually
- [ ] When a pod fails, decide "cannot schedule" vs "starts and gets killed" first
- [ ] Roll back only with `--to-revision`
