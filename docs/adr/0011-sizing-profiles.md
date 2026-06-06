# ADR-0011: Sizing profiles — sandbox, standard, production

## Status

Accepted — 2026-06-04.

## Context

Phase 0 already had a per-environment tfvars file (`envs/dev/`,
`envs/prod/`) but every numeric value — node count, IOPS, throughput,
replica counts, log retention — was either hard-coded in the module or
exposed as a top-level variable that the operator had to remember to
override. That breaks down as soon as the test/sandbox account appears:

- The sandbox account has a small EC2/EBS/S3 quota; running the prod
  default of m6i.xlarge × 6 nodes and 3000-IOPS gp3 is bigger than the
  account's VPC allotment and gets the request throttled.
- Operators copy-pasted the dev tfvars and trimmed numbers by hand;
  every new sandbox had drift vs. the canonical config in git.
- Helmfile values for controller replicas were literal `3` / `2`. There
  was no way to express "in the test account, one replica is enough."

We need a small set of named profiles that flip the whole stack at
once — the test account, the dev/staging default, and prod — and we
need the profile name to be the *only* thing an operator has to set
in the tfvars file.

## Decision

### One variable: `sizing_profile`

```
variable "sizing_profile" {
  default = "standard"
  validation { in ["sandbox", "standard", "production"] }
}
```

The validation rule is the gate. Anything else is rejected at
`terraform plan` time.

### One locals block: the sizing table

`locals.tf` now carries an inline three-key map. Each key is a profile;
each value is a struct with the small set of numbers that vary:

```hcl
local.sizing = {
  sandbox = {
    node_instance_types       = ["t3.small", "t3.medium"]
    node_min_size             = 1
    node_max_size             = 3
    node_desired_size         = 2
    node_disk_size            = 30
    gp3_default_iops          = 1000
    gp3_default_throughput    = 50
    gp3_throughput_iops       = 1500
    gp3_throughput_throughput = 100
    io2_iops                  = 1000
    efs_throughput_mode       = "bursting"
    s3_object_lock_enabled    = false
    s3_lifecycle_to_ia        = false
    s3_lifecycle_days         = 0
    log_retention_days        = 7
    default_spot_cpu_limit    = 40
    default_spot_memory_limit = "80Gi"
    # ... etc
  }
  standard  = { ...m6i.xlarge, 3-6 nodes, gp3 3000 IOPS, EFS elastic... }
  production = { ...m6i.xlarge, 6-20 nodes, gp3 3000 IOPS, io2 16000 IOPS, EFS elastic, 365d logs... }
}
```

The map literal uses a trailing `[var.sizing_profile]` to index into
the chosen profile, so callers see `local.sizing.node_min_size` and
never have to remember which key they picked.

### Profile content

| Knob | sandbox | standard | production |
|---|---|---|---|
| Bootstrap MNG instance type | t3.small / t3.medium | m6i/m6a/m7i xlarge | m6i/m6a/m7i xlarge |
| Bootstrap MNG node count | 1–3 (desired 2) | 3–6 (desired 3) | 6–20 (desired 6) |
| Bootstrap MNG disk | 30 GB | 100 GB | 200 GB |
| `gp3-encrypted` IOPS | 1000 | 3000 | 3000 |
| `gp3-encrypted` throughput | 50 MB/s | 125 MB/s | 125 MB/s |
| `io2-stateful` IOPS | 1000 | 16000 | 16000 |
| EFS throughput mode | bursting | elastic | elastic |
| S3 Object-Lock | off | off | on (gated by HIPAA/FedRAMP) |
| S3 INTELLIGENT_TIERING | off | on (30d) | on (30d) |
| CloudWatch log retention | 7 days | 30 days | 365 days (HIPAA: 7y) |
| Karpenter workload pools | none (system only) | spot + ondemand | spot + ondemand + batch |
| Karpenter limits (CPU) | 40 spot, 8 system | 1000 spot, 500 od, 32 system | 2000 batch, 1000 spot, 500 od, 32 system |
| Vault mode | dev (in-memory) | dev (in-memory) | HA Raft + KMS auto-unseal |
| All platform controller replicas | 1 | HA (3 controller / 2 others) | HA (3 controller / 2 others) |
| AZ count | 2 (EFS still gets 2 MTs) | 3 | 3 |
| **Cost ceiling / cluster / month** | **~$300** | **~$1,500** | **~$4,500** |

(The standard profile's Vault is dev mode today because dev/staging are
not the security boundary; the prod profile is the only one that gets
the HA Raft + KMS auto-unseal path. When staging starts carrying real
data we promote it to a fourth profile `staging` with Raft + KMS.)

### Helmfile replica wiring

Every `replicas:` value in `mgmt-cluster-aws/values/*.gotmpl` and in
the inline values of `helmfile.yaml.gotmpl` is now:

```
replicas: {{ if eq .Environment.Values.environment "sandbox" }}1{{ else }}3{{ end }}
```

Kyverno's four sub-controllers (admission / reports / background /
cleanup) all flip to 1. ArgoCD's redis HA flag flips off, and the
server / repo / controller / applicationSet replicas all flip to 1.
cert-manager, external-secrets, gatekeeper controllers, otel-collector,
argo-workflows controller + ui, and the karpenter controller itself
all flip to 1 in sandbox.

There is no `webhook.replicaCount` for cert-manager / external-secrets
in sandbox because their webhooks collapse to 1 too.

### Karpenter NodePools — workload pools are profile-conditional

`apps/karpenter/nodepools.yaml.gotmpl` uses `{{- if ne ... "sandbox" }}`
to skip the `default-spot` and `default-ondemand` pools in sandbox, and
`{{- if eq ... "prod" }}` to skip the `batch` pool except in prod.

The result: in sandbox, the only NodePool is `system` (1-2 nodes, t3
family, on-demand, taint `CriticalAddonsOnly`). The test account
literally cannot launch workload nodes because there is no NodePool
that would accept them.

### EFS, S3, and the StorageClass numbers

The EFS throughput mode is a single line in `aws-storage/main.tf`:

```hcl
throughput_mode = var.sizing.efs_throughput_mode
```

The S3 Object-Lock is a `count` that depends on both the profile
(`s3_object_lock_enabled`) and the compliance frameworks
(`hipaa` / `fedramp`). The S3 lifecycle `transition` is a `dynamic`
block that emits zero rules in sandbox and one in standard/production.

EBS IOPS / throughput numbers used to be hard-coded in the
StorageClass YAML (3000 / 125 / 1000). They are now envsubst
variables — `SIZING_GP3_DEFAULT_IOPS`, `SIZING_GP3_DEFAULT_THROUGHPUT`,
`SIZING_GP3_THROUGHPUT_IOPS`, `SIZING_GP3_THROUGHPUT_THROUGHPUT`,
`SIZING_IO2_IOPS` — exported by the bootstrap script from the
`aws_storage.sizing` Terraform output before running `helmfile sync`.

### Envsubst wiring

The bootstrap script now exports a block before invoking helmfile:

```bash
export SIZING_GP3_DEFAULT_IOPS=$(terraform output -raw sizing_gp3_default_iops)
export SIZING_GP3_DEFAULT_THROUGHPUT=$(terraform output -raw sizing_gp3_default_throughput)
# ...etc
```

envsubst substitutes these in `apps/storage/storageclass-ebs.yaml` at
helmfile render time. The values land in Kubernetes as the StorageClass
parameters. PVCs that land in the cluster then get the right IOPS
profile automatically.

### What the operator changes for a new sandbox account

1. Copy `envs/sandbox/terraform.tfvars.example` to `envs/sandbox/terraform.tfvars`.
2. Change `github_org` to the right value.
3. Run `terraform init && terraform apply`.
4. The bootstrap script exports the sizing outputs to env vars and runs
   `helmfile sync` with `--environment sandbox`.

That's it. There is no place to forget to override a number.

## Consequences

### Good

- **One knob, one place.** The operator changes one tfvar, the whole
  stack follows. If something is wrong, the fix is in `locals.tf`, not
  in three tfvars files and a values yaml.
- **The test account stays in budget.** ~$300/mo ceiling per cluster is
  well under the test account's typical $500-1000 monthly envelope.
- **Sandbox can't run away with capacity.** No `default-spot` or
  `default-ondemand` NodePool in sandbox means workload pods simply
  stay Pending if they're not tolerating `CriticalAddonsOnly`. That's
  intentional — the test account is for platform bring-up, not workload
  burn-in.
- **No new abstraction surface for the app team.** The StorageClass
  names and the cluster APIs are identical across profiles. The
  difference is the underlying numbers. App teams don't change a line
  of YAML.
- **Operator review is one diff per profile.** Changing the sandbox
  node size is a 1-line change in `locals.tf`, reviewed in the same
  PR as the policy change. No more "I forgot to update the sandbox
  tfvars again" PRs.

### Bad

- **Three profiles is not the same as N profiles.** If a future
  environment needs a custom mix (e.g. "staging with HIPAA and a 4-AZ
  VPC"), we have to add a fourth key. We accept this — most
  customizations are profile-fitting, not profile-creating.
- **`locals.tf` is now load-bearing.** If it breaks, every environment
  breaks. Mitigation: a unit test (`terraform test` in 1.6+) that
  evaluates the locals block with each profile and asserts the
  expected numbers — to be added in the next iteration.
- **Envsubst chain is one more thing to wire correctly.** The bootstrap
  script is the only place the `SIZING_*` env vars are set. A bug
  there means the StorageClasses render with empty values. Mitigation:
  the StorageClass yamls will fail helmfile render (yaml validation)
  on an empty `${SIZING_GP3_DEFAULT_IOPS}` substitution if envsubst
  is misconfigured.
- **The Helmfile env block got bigger.** `helmfile.yaml.gotmpl` now
  carries per-environment Karpenter limits as well as the existing
  `domain` keys. Acceptable — this is the same place teams already
  look for per-env overrides.

### Carry-forward

- The Karpenter `weight` field on each pool is not currently profile-
  driven. Weights make sense in standard/prod; in sandbox there's only
  the system pool, so weights are cosmetic. If we add a fourth profile
  that mixes two pools, weights come back into the sizing struct.
- The `standard` profile's Vault is still dev mode. Promoting it to
  Raft + KMS auto-unseal is a one-line change (move the
  `sizing.vault_mode` key into the struct, default `dev` for standard,
  `ha-raft-kms` for production) and a follow-up runbook update.
- The ADR-0001 cluster-topology diagram still shows three AZs as the
  default. The sandbox's `az_count = 2` is the first profile to
  diverge; this should be reflected in a future diagram revision.

## Alternatives considered

- **Per-env tfvars without a profile switch**: the status quo. Rejected
  — drift was the whole point of this ADR.
- **Helm values overrides per env**: rejected. Helm values don't reach
  Terraform-managed resources (EBS, EFS, S3, KMS), and the duplication
  is a maintenance trap.
- **A separate "sandbox" module that hard-codes small numbers**:
  rejected. Two modules, two code paths, double the bug surface.
- **One profile, environment-driven**: rejected. The shape of the
  stack changes too much between sandbox and prod (NodePool count,
  Vault mode, replica counts) for one map of numbers to cover both.

## References

- `platform-fleet/locals.tf` — sizing map (one source of truth)
- `platform-fleet/variables.tf` — `sizing_profile` variable + validation
- `platform-fleet/main.tf` — composition uses `local.sizing.*`
- `platform-fleet/envs/sandbox/terraform.tfvars.example` — the new env
- `platform-fleet/modules/aws-eks/main.tf` — `node_disk_size` +
  `log_retention_days` driven by the profile
- `platform-fleet/modules/aws-storage/main.tf` — EFS throughput mode,
  S3 Object-Lock + lifecycle
- `mgmt-cluster-aws/apps/storage/storageclass-ebs.yaml.gotmpl` —
  envsubst variables for IOPS / throughput
- `mgmt-cluster-aws/apps/karpenter/nodepools.yaml.gotmpl` — workload
  pools gated on `environment != sandbox`
- `mgmt-cluster-aws/values/*.yaml.gotmpl` — every controller replica
  count is profile-conditional
- ADR-0001 (cluster topology — sandbox keeps 2 AZs for EFS)
- ADR-0009 (Karpenter — sandbox only ships the system pool, drift-based
  patching is still active on the bootstrap MNG)
- ADR-0010 (storage strategy — StorageClass names are the same, only
  the IOPS/throughput numbers change)
