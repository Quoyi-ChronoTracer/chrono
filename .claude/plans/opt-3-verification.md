# OPT-3 Verification: ECS Task Resource Increase

## Terraform Verification

### Diff review

```bash
git diff chrono-devops/services/ecs.tf
```

Verify the diff shows **only** the cpu/memory change:
- `cpu = 2048` -> `cpu = 4096`
- `memory = 4096` -> `memory = 8192`
- No other lines modified

### Template propagation

After running `scripts/create_templates.py`, verify all output ecs.tf files are updated:

```bash
grep -r "cpu\s*=" chrono-devops/accounts/*/services/ecs.tf
grep -r "memory\s*=" chrono-devops/accounts/*/services/ecs.tf
```

All accounts should show `cpu = 4096` and `memory = 8192`.

### Terraform plan

```bash
terraform plan -target=aws_ecs_task_definition.pipeline_task_definition
```

Verify the plan shows:
- Only the task definition resource is changing
- `cpu: "2048" => "4096"`
- `memory: "4096" => "8192"`
- No unexpected resource creations or destructions
- No changes to other resources (security groups, IAM, etc.)

### Valid Fargate combination

Confirm `cpu=4096` / `memory=8192` is a valid Fargate combination per AWS documentation:
- 4096 CPU supports memory between 8192 and 30720 in 1024 increments
- 8192 is the minimum for the 4096 CPU tier

---

## Deployment Verification

### New task definition revision

```bash
aws ecs describe-task-definition \
  --task-definition pipeline-task-definition \
  --query 'taskDefinition.{cpu:cpu,memory:memory,revision:revision}'
```

Verify:
- `cpu` is `"4096"`
- `memory` is `"8192"`
- `revision` is incremented from the previous value

### Step Functions references

Verify the Step Functions state machine references the new task definition revision:

```bash
aws stepfunctions describe-state-machine \
  --state-machine-arn <arn> \
  --query 'definition' | jq '.States | .. | .Resource? // empty' | grep pipeline
```

Confirm it references the latest revision.

### Task launch verification

Launch a test task and verify:
- Task transitions to RUNNING state (no STOPPED with resource failures)
- No "Insufficient resources" or "Out of memory" errors in events
- Container starts successfully

```bash
aws ecs describe-tasks \
  --cluster pipeline-cluster \
  --tasks <task-arn> \
  --query 'tasks[0].{status:lastStatus,stoppedReason:stoppedReason,cpu:cpu,memory:memory}'
```

### No STOPPED tasks with resource failures

Monitor for 24 hours after deployment:

```bash
aws ecs list-tasks --cluster pipeline-cluster --desired-status STOPPED
```

Check any stopped tasks for resource-related stop reasons.

---

## Performance Verification

### Before/after per-file OCR times

Compare pipeline log output for the same document set:
- Parse "Step text_extraction took Xs" log lines
- Group by file type and size
- Calculate mean, median, p95, p99 per-file OCR time
- Expected: measurable improvement from reduced memory pressure

### CloudWatch Container Insights

Monitor CPU and memory utilization after deployment:

| Metric | Expected Before | Expected After |
|---|---|---|
| CPU utilization | ~90% peak | 40-60% peak |
| Memory utilization | ~85% peak | 40-50% peak |

### Degradation pattern

The current configuration shows a degradation pattern where OCR times increase as memory pressure builds over long-running tasks. After the resource increase:
- Per-file OCR time should remain stable throughout the task
- No increasing trend in per-file duration over time
- Total task duration should decrease

---

## Cost Verification

### Cost Explorer comparison

After running comparable workloads on both configurations:

```bash
aws ce get-cost-and-usage \
  --time-period Start=<before>,End=<after> \
  --granularity DAILY \
  --filter '{"Dimensions":{"Key":"SERVICE","Values":["Amazon Elastic Container Service"]}}' \
  --metrics "BlendedCost"
```

Normalize per file processed:
- Per-task-hour cost doubles ($0.0988 -> $0.1975)
- But duration should decrease
- Net cost per file is the key metric

### Break-even analysis

Track actual task durations to validate cost projections:
- If duration drops by >50%, net cost decreases
- If duration drops by exactly 50%, cost is neutral
- If duration drops by <50%, cost increases (but performance improves)

---

## Rollback Plan

### Standard rollback

1. Revert `ecs.tf` changes:
   ```bash
   git checkout chrono-devops/services/ecs.tf
   ```
2. Re-run templates:
   ```bash
   python scripts/create_templates.py
   ```
3. Apply:
   ```bash
   terraform apply -target=aws_ecs_task_definition.pipeline_task_definition
   ```

### Emergency rollback

If immediate rollback is needed without going through the full terraform pipeline:

1. Register old task definition revision via CLI:
   ```bash
   aws ecs register-task-definition \
     --cli-input-json file://old-task-def.json
   ```
2. Update the Step Functions state machine to reference the old revision:
   ```bash
   aws stepfunctions update-state-machine \
     --state-machine-arn <arn> \
     --definition file://state-machine-with-old-revision.json
   ```
3. Follow up with terraform state reconciliation to align IaC with actual state:
   ```bash
   terraform import aws_ecs_task_definition.pipeline_task_definition <old-revision-arn>
   terraform plan  # verify no unexpected changes
   ```
