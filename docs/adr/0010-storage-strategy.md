# ADR-0010: Storage strategy — EBS, EFS, S3 Mountpoint, and the policy that keeps it sane

## Status

Accepted — 2026-06-04.

## Context

A regulated multi-tenant Kubernetes platform with a regulated data model
(SOC 2 + ISO 27001 + HIPAA + PCI + FedRAMP + GDPR) needs three distinct
storage substrates, and a policy layer that prevents teams from picking
the wrong one (or worse, escaping the abstraction with `hostPath`).

The drivers were chosen on three axes:

1. **Data class** — ephemeral scratch vs. durable stateful vs. read-mostly
   bulk vs. long-term archive
2. **Access pattern** — RWO block, RWX file, object stream
3. **Compliance** — encryption at rest + in transit, audit trail, retention,
   residency, backup

Teams will pull *some* defaults out of the box; the hard part is the
infrastructure that makes compliance the path of least resistance
without slowing down 20+ engineers.

## Decision

### One driver per data class

| Data class | Driver | StorageClasses | Why this driver |
|---|---|---|---|
| Ephemeral scratch | (none — `emptyDir`) | — | Don't pay for a PV |
| Stateful block (DBs, single-writer workloads) | `aws-ebs-csi-driver` | `gp3-encrypted`, `gp3-throughput`, `io2-stateful` | RWO block, dynamic, snapshot-ready, KMS-encrypted |
| RWX shared (CI runners, content repos, multi-pod reads) | `aws-efs-csi-driver` | `efs-shared`, `efs-archive` | RWX NFS-4, dynamic access points, scales to PB, regional |
| Read-mostly bulk (ML datasets, model artifacts, log archive) | `aws-mountpoint-s3-csi-driver` | `s3-mountpoint` (static PVs) | S3 is the cheapest durable store; Mountpoint gives FUSE access |

### EBS — three StorageClasses, one of them is default

- **`gp3-encrypted`** — default. 3000 IOPS baseline, 125 MB/s. Encrypted
  with the cluster CMK. `Delete` reclaim. 95% of stateful workloads.
- **`io2-stateful`** — for production databases. 16000 IOPS, `xfs`,
  `Retain` reclaim, encrypted with the cluster CMK. `Retain` is the
  defence-in-depth: a PVC deletion must not silently destroy a
  production DB volume.
- **`gp3-throughput`** — for analytics, log indices, anything that wants
  high MB/s more than high IOPS. 4000 IOPS, 1000 MB/s. Encrypted.

We do **not** expose `io1`, `io2 Block Express`, `st1`, or `sc1`. Teams
that want HDD throughput should use EFS-IA. Keeping the surface small
is the point.

### EFS — two StorageClasses, dynamic access points, TLS in transit

- **`efs-shared`** — `ReadWriteMany`, dynamic access point per PVC,
  `Delete` reclaim, lifecycle to IA at 30 days. The "default RWX" class.
- **`efs-archive`** — `ReadWriteMany`, dynamic access point, `Retain`
  reclaim, lifecycle to IA at 30 days and archive at 90 days. For
  snapshots, backups, anything that has to outlive its PVC.

`tls` mountOption is **required** on both. Without it, NFS traffic is
cleartext even if the file system is encrypted at rest (KMS), and that
fails HIPAA §164.312(e).

`uid: 1000`, `gid: 1000`, `gidRangeStart: 50000`, `gidRangeEnd: 7000000`
on both. The 50k–7M range is for `ensureUniqueDirectory` access points —
it lets multiple pods mount the same EFS without UID collisions, even
though they're all speaking as 1000:1000 to the cluster.

### S3 Mountpoint — read-mostly, static PVs only

- **`s3-mountpoint`** — `ReadWriteMany`, `Retain`, no dynamic provisioning.
  Mountpoint S3 does **not** support random writes, rename, hardlinks,
  or symlinks. Teams that need any of those should not be on S3.

PVs are statically provisioned by the platform team. The bucket lifecycle
is owned by Terraform (`aws-storage` module). The CSI driver does not
own the bucket.

We use this for read-mostly ML datasets, model artifacts, and log
archive. The S3 bucket is KMS-encrypted, has object-lock enabled for
HIPAA/FedRAMP workloads (7-year retention), and the bucket policy
denies non-TLS requests and denies any put with a CMK other than the
cluster's.

### Snapshot strategy

- `ebs-snapshot-default` (default class) — Retain, used by Velero
  (phase 2) and per-team CronJobs. Snapshots inherit the source
  volume's CMK.
- `ebs-snapshot-compliance` — Retain, tagged `aws-backup:enabled=true`
  and `snapshot-policy=compliance-35d`. The 35-day retention is
  enforced by AWS Backup on the snapshot tag, not by the SC. This is
  for HIPAA / FedRAMP namespaces.

The `snapshot-controller` (not the sidecar) is installed in `kube-system`
on a 2-replica Deployment, with the `volumesnapshots` / `contents` CRDs
installed by the EBS CSI driver's chart. The controller reconciles
snapshot lifecycle and exposes a `ServiceMonitor` so the cluster's
Prometheus can alert on snapshot failures.

### Policy layer (Kyverno)

`policies/kyverno/baseline/40-storage.yaml` enforces:

1. **PVCs must declare an explicit `storageClassName`** — the empty
   default (gp2 / standard) is unencrypted and out of policy.
2. **StorageClass must be in the approved set** — gp3-encrypted,
   io2-stateful, gp3-throughput, efs-shared, efs-archive, s3-mountpoint.
   Anything else is a deny.
3. **AccessModes must match the driver** — EBS is RWO-only (EBS CSI
   silently downgrades RWX to RWO); EFS and S3 are RWX-only (RWO has
   no meaning for a network FS).
4. **`hostPath` is forbidden in tenant namespaces** — the classic
   escape-the-namespace-and-the-policy vector. Critical severity,
   enforce in every environment.
5. **PVs are platform-team-only** — cluster-scoped, bypass namespace
   quotas. Dynamic provisioning via PVC + SC is the default.
6. **PVCs are tenant-namespace-only** — they cannot be created in
   `kube-system`, `argocd`, etc.
7. **Default SC is mutated to `gp3-encrypted`** — teams that forget
   the field don't fall back to the upstream default.

All are `Enforce` everywhere except `require-storageclass` which is
`Enforce` in prod and `Audit` in dev (so an onboarding engineer can
get a "your PVC didn't specify a storage class" warning while they're
still in the loop).

## Consequences

### Good

- **Compliance is the path of least resistance.** Engineers do nothing
  → gp3-encrypted → encrypted, backed up, CMK-isolated. The 95% case
  is also the compliant case.
- **`hostPath` is a critical-severity Enforce everywhere.** A single
  Kyverno policy closes the most common namespace-escape path.
- **Data residency is enforceable.** The cluster CMK is in the cluster
  region, the S3 bucket is in the cluster region, EFS is regional.
  Cross-region replication is opt-in per class, not by accident.
- **One source of truth for retention.** EFS lifecycle policies and
  AWS Backup plans are both driven by the SC tag set, not by ad-hoc
  cron jobs.
- **Snapshot class for regulated workloads is a single label.** A team
  in a HIPAA namespace adds `snapshot-policy=compliance-35d` to the
  namespace, and AWS Backup picks it up.

### Bad

- **No HDD EBS classes.** Teams that need cheap spinning rust for
  cold logs get redirected to EFS-IA or S3. Adds a conversation
  before a PVC.
- **S3 Mountpoint is not POSIX.** It is read-mostly, append-only-ish,
  no rename. Engineers who don't read the warning will hit weird
  errors. We pre-empt with the comment block in `storageclass-s3.yaml`.
- **PVs require the platform team.** A common onboarding friction:
  "I just want a static volume." The right answer is "use a dynamic
  PVC, here's the SC name," but it takes a few PRs to get used to.
- **Kyverno policies can reject legitimate workloads** if the
  StorageClass name is mistyped in the SC yaml. We mitigate by
  pinning SC names in the policy to match the SC yaml by PR review
  (the same PR that adds a SC must add a policy entry).

### Carry-forward

- **Velero** (phase 2) will use `ebs-snapshot-default` for cluster
  backup and `ebs-snapshot-compliance` for regulated namespaces. No
  policy change required.
- **Cross-region DR replication** of EFS (read-replica in second
  region) is in scope for phase 2. The SC yaml does not change;
  the EFS file system gets a replica.
- **Kubecost** (phase 2) will charge back by SC. The named classes
  are deliberately short — they fit in a chart legend.
- **Multi-cloud** is the same shape: Azure has `azure-disk-csi-driver`
  and `azure-file-csi-driver` filling the EBS / EFS slots. The
  Kyverno policy is storage-class-name based, not driver-based, so
  the same `40-storage.yaml` works in Azure after renaming the SC
  entries.

## Alternatives considered

- **One StorageClass per driver (no tiering):** ruled out — forces
  every team to figure out IOPS and throughput, and gives no way to
  express "this is prod stateful, Retain it."
- **EBS-only with EFS for shared:** ruled out — EFS-IA and S3 are
  both cheaper than gp3 for read-mostly bulk. The data classes are
  different enough to deserve different substrates.
- **OpenEBS / Longhorn / Rook:** ruled out for phase 1. Adds
  operators on top of nodes, more failure modes. Cloud-native drivers
  first, self-hosted block storage only if a real use case appears
  (stateful workloads with tight latency SLAs in non-AWS regions).
- **CephFS:** ruled out — same operator complexity, no advantage
  over EFS in AWS.
- **`emptyDir` everywhere except prod DBs:** ruled out — defeats
  the purpose of "production-grade platform." Even the 95% case
  deserves a real PVC.

## References

- `platform-fleet/modules/aws-storage/main.tf` — EFS, S3, IAM
- `mgmt-cluster-aws/values/csi-*.yaml.gotmpl` — driver Helm values
- `mgmt-cluster-aws/apps/storage/storageclass-*.yaml.gotmpl` — SC yamls
- `mgmt-cluster-aws/apps/storage/volumesnapshotclass.yaml.gotmpl` — SCs
- `mgmt-cluster-aws/apps/storage/snapshot-controller.yaml` — controller
- `policies/kyverno/baseline/40-storage.yaml` — enforcement
- ADR-0001 (cluster topology — EFS is regional)
- ADR-0004 (policy engines — Kyverno owns validation, Gatekeeper owns Rego)
- ADR-0009 (Karpenter — the same `node.kubernetes.io/role: platform`
  labelling applies to storage-bearing nodes; IO2 nodes are scheduled
  onto the system pool)
