# K8s Cluster Hardening Toolkit

Scripts and a runbook I wrote to take over an on-prem Kubernetes cluster (3 control-plane, 6 worker nodes, air-gapped) that had not reached production, audit it, fix the gaps, and hand it over with an acceptance report the operations team can rerun.

The cluster went from a 24-item audit to delivery in 7 working days. These scripts handled the two items with the most moving parts (resource limits and health probes across every workload), plus the final acceptance check for all 13 remediation items.

Names of real services, nodes and namespaces have been replaced with generic examples.

## What is in here

| Script | Stage | What it does |
| --- | --- | --- |
| [`check_and_suggest.sh`](scripts/check_and_suggest.sh) | Scan | Finds containers missing requests/limits or liveness/readiness probes and writes suggested `kubectl patch` commands. Takes probe ports from the matching Service's `targetPort` and warns when the declared `containerPort` is stale. |
| [`apply_probes_batch.sh`](scripts/apply_probes_batch.sh) | Apply | Applies suggestions one at a time: asks for confirmation, watches the rollout, rolls back and stops the batch on failure. Skips known exceptions and platform namespaces. |
| [`final_acceptance_check.sh`](scripts/final_acceptance_check.sh) | Accept | Checks 13 remediation items against the live cluster (CoreDNS spread, control-plane taint, Alertmanager, Promtail coverage, ResourceQuota, probe gaps, backups, infra node, etcd encryption, …) and prints a PASS / WARN / FAIL report. |
| [`docs/runbook.md`](docs/runbook.md) | Operate | How to run the flow safely, patch multi-container workloads, size memory from real usage, and roll back to a pinned revision. Includes a case log. |

```text
check_and_suggest.sh  ──►  review report  ──►  apply_probes_batch.sh  ──►  final_acceptance_check.sh
   (suggest only)         (edit skip list)     (confirm → rollout →        (live state → PASS/WARN/FAIL)
                                                 rollback on failure)
```

## Design choices

- **Suggest automatically, change manually.** Nothing touches the cluster without a typed `yes`. One failure stops the batch.
- **Trust the Service, not the YAML.** Declared container ports were wrong in several workloads (3000 vs 3004, 80 vs 5176). Matching Service selectors to pod labels finds the port traffic actually goes to.
- **Business services first, platform last.** Monitoring namespaces are excluded by default after adding a probe to Loki exposed a storage lock and crash-looped it.
- **Acceptance reads the cluster, not a spreadsheet.** Remaining gaps are classified as accepted exceptions, known manual items, or paused items, so nothing unfinished is reported as done.

## Usage

```bash
# requires kubectl (configured for the target cluster) and jq
./scripts/check_and_suggest.sh --probes-only
less check_report_*.txt
./scripts/apply_probes_batch.sh
CP_NODE=<control-plane-node> INFRA_NODE=<infra-node> ./scripts/final_acceptance_check.sh
```

Edit `SKIP_LIST` and `INFRA_NAMESPACES` in `apply_probes_batch.sh`, and the exception lists in `final_acceptance_check.sh`, for your own cluster.

## Known limitations and next steps

- Probes are generic `tcpSocket` checks (the port is open). Next step: switch to `httpGet` on a real health endpoint once each service owner confirms one.
- The automatic rollback uses an un-pinned `rollout undo`, which can flip-flop on multi-container workloads. The runbook documents the manual `--to-revision` procedure; the script should pin the revision too.
- Suggested resource values are conservative defaults (100m/128Mi requests, 500m/512Mi limits) and must be tuned from real usage.

## License

MIT
