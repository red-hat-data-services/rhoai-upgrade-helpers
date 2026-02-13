# TrustyAI 2.5 → 3.x Upgrade Scripts

If you want, you can backup and restore TrustyAI scheduled metrics during operator upgrades (see [Backup and restore metrics](#backup-and-restore-metrics) at the end).

---

## Fixes

Prereqs: `oc` (and `oc login`). `jq` is optional (it just makes JSON output easier to read).

### Fix 1: GuardrailsOrchestrator (RHOAI 2.25 -> 3.x)

This fix is relevant if you have GuardrailsOrchestrator instances and:

- your GuardrailsOrchestrator `/health` or `/info` endpoints return errors, or
- you enabled OpenTelemetry on RHOAI 2.25 and now the `spec.otelExporter` fields are not compatible with RHOAI 3.x.

#### Step 0: Check if you have GuardrailsOrchestrator instances

```bash
oc get guardrailsorchestrator -n <namespace>
```

If you don't know the namespace, list them across all namespaces:

```bash
oc get guardrailsorchestrator -A
```

If this returns `No resources found`, you can skip Fix 1.

#### Step 1: Fix `/health` and `/info` endpoint errors (deployment readiness probe)

This patches the GuardrailsOrchestrator Deployment(s) to add the expected readiness probe on port `8034` at `/health`.

```bash
./patch-guardrails-deployment.sh <namespace>
```

Verify:

```bash
ORCH_ROUTE_HEALTH=$(oc get routes -n <namespace> guardrails-orchestrator-health -o jsonpath='{.spec.host}')
curl -s https://$ORCH_ROUTE_HEALTH/info | jq
```

If the route name differs, list routes in the namespace and pick the GuardrailsOrchestrator health route:

```bash
oc get routes -n <namespace>
```

#### Step 2: Fix OpenTelemetry `spec.otelExporter` incompatibility (CR migration)

If you enabled OpenTelemetry on RHOAI 2.25, the `spec.otelExporter` keys changed in RHOAI 3.x. This script migrates the old fields to the new ones.

1. Check what would be migrated:

```bash
./migrate-gorch-otel-exporter.sh --namespace <namespace>
./migrate-gorch-otel-exporter.sh --namespace <namespace> --dry-run
```

2. Apply the migration:

```bash
./migrate-gorch-otel-exporter.sh --namespace <namespace> --fix
```

3. Verify the migrated fields (you should see keys like `otlpProtocol`, `otlpTracesEndpoint`, `otlpMetricsEndpoint`, `enableTraces`, `enableMetrics`):

```bash
oc get guardrailsorchestrator -n <namespace> <name> -o jsonpath='{.spec.otelExporter}{"\n"}'
```

### Fix 2: GPU deadlock

This issue can occur when there is a llm deployment and then trustyai service is created in the same namespace. The LLM deployment would be then stuck in `pending`

#### How to identify

1. Look for an InferenceService predictor that has **both** a Running pod and a Pending pod:

```bash
oc get pods -n <namespace> -l component=predictor
```

Typical symptoms:

- Two pods for the same predictor
- One pod **Running**, one pod **Pending**
- Different container counts (e.g. `2/2` vs `0/3`)

2. Use the helper script to check for deadlocks (recommended):

```bash
./break-gpu-deadlock.sh --namespace <namespace> --check
```

#### Solution

To avoid this deadlock, you can run script `break-gpu-deadlock.sh` which will delete the pending pod and then re-create it. This will allow the LLM deployment to proceed without being stuck in pending state. 

1. Fix deadlocks:

```bash
./break-gpu-deadlock.sh --namespace <namespace> --fix
```

2. Verify pods are no longer stuck:

```bash
oc get pods -n <namespace> -l component=predictor
```

---

## Backup and restore metrics

This is optional. Only do this if you have TrustyAIService instances (scheduled metrics live there).

#### Step 0: Check if you have TrustyAIService instances

```bash
oc get trustyaiservice -A
```

If this returns `No resources found`, you can skip metrics backup/restore.

#### Backup (pre-upgrade)

Run this once per namespace that has a TrustyAIService:

```bash
./backup-metrics.sh -n <namespace>
```

This writes a timestamped JSON under `./backups/` and updates `./backups/trustyai-metrics-latest.json`.

#### Restore (post-upgrade)

```bash
./restore-metrics.sh -n <namespace> -f backups/trustyai-metrics-latest.json
```

Useful options:

- `--dry-run` to preview
- `--skip-existing` to avoid re-creating metrics that already exist

**Note:** restored metrics receive new UUIDs (original IDs are not preserved).
