# Node OS Patching Strategy

## TL;DR

| Node pool | OS | Patching mechanism | Cadence |
|---|---|---|---|
| Bootstrap MNG (`<cluster>-managed`) | Bottlerocket | Brupop (in-place) | Weekly, business-hours-quiet window |
| Karpenter `default-*` | Bottlerocket | Karpenter drift (replace) | On AMI alias change OR `expireAfter: 720h` |
| Karpenter `system` | Bottlerocket | Karpenter drift (replace) | On AMI alias change OR `expireAfter: 720h` |
| Karpenter `batch` | Bottlerocket | Karpenter drift (replace) | On AMI alias change OR `expireAfter: 168h` (weekly) |

Two complementary mechanisms because the two node populations have different
constraints:

- The **bootstrap MNG** must exist for Karpenter to schedule itself. Drift-
  based replacement would create a chicken-and-egg problem (the controller
  rolling its own host). Brupop handles it: in-place patches via the
  Bottlerocket update API, one node at a time, on a cron.

- The **Karpenter-managed pools** can safely be rolled because Karpenter
  provisions replacement capacity *before* draining old nodes. Drift
  reconciliation kicks in any time the EC2NodeClass spec differs from the
  EC2 instance reality — including when the AMI alias resolves to a new ID.

## Why Bottlerocket

- Immutable OS image — drift detection is meaningful (`bottlerocket-version`
  label vs alias-resolved version is a clean diff).
- Two partitions (A/B) for atomic upgrades. Failed update → instant rollback.
- Container-optimised. No SSH by default; no shell unless `host-containers.admin`
  is enabled (we leave it off).
- Signed by AWS, verified at boot.
- API-driven settings (TOML in user-data) — no Ansible needed at runtime.
- Compliance: meets SOC 2 CC6.7 (system component hardening) and FedRAMP
  AC-3 / SI-7 controls out of the box; signed image satisfies HIPAA
  §164.312(c)(1) integrity controls.

## How drift-based replacement works (Karpenter pools)

1. EC2NodeClass references `amiSelectorTerms: [{alias: bottlerocket@latest}]`.
2. Karpenter resolves the alias to a concrete AMI ID on every reconcile loop.
3. When the resolved AMI differs from what an existing node is running,
   Karpenter marks the node `karpenter.sh/disrupted: drift`.
4. Disruption budget is checked (see `nodepools.yaml`). If allowed,
   Karpenter:
   - cordons the node
   - launches a replacement
   - waits for replacement to become Ready
   - drains the old node (respecting PDBs)
   - terminates the old node

A node always has a successor before draining starts — there is no
maintenance window for the application.

## How Brupop works (bootstrap MNG)

1. Each Bottlerocket node runs the Brupop agent as a privileged DaemonSet.
2. The Brupop controller queries `apiserver` for `BottlerocketShadow` CRs
   that show an update is available.
3. On the cron schedule, it picks one node, drains it, calls the Bottlerocket
   update API, waits for the node to reboot into the new partition, and
   uncordons.
4. `maxConcurrentUpdates: 1` ensures only one bootstrap node at a time —
   the MNG normally has 2-3 nodes, so the surviving nodes carry the load.

Schedule: weekdays 02:00 UTC (helmfile values). Adjust per region.

## Operating procedures

### Force an AMI refresh (security patch came out yesterday)

```sh
# Karpenter pools — change the alias to a specific ID, commit, push.
# ArgoCD syncs, Karpenter drifts, nodes get replaced.
yq -i '.spec.amiSelectorTerms[0].alias = "bottlerocket@1.20.3"' \
  mgmt-cluster-aws/apps/karpenter/ec2nodeclass.yaml
git commit -am "karpenter: pin Bottlerocket 1.20.3 (CVE-2026-XXXXX)"

# Bootstrap MNG — trigger Brupop manually
kubectl -n brupop-bottlerocket-aws annotate cronjob brupop \
  "brupop.bottlerocket.aws/manual-trigger=$(date +%s)"
```

### Pin an AMI in regulated environments (FedRAMP / SOC 2)

```yaml
# Replace the alias with a specific ID — reproducible builds, audit-friendly
amiSelectorTerms:
  - id: ami-0123456789abcdef0
    owner: amazon
```

Karpenter will only ever launch this AMI. Updates require a PR (changes
land in git, evidence in the commit log). Brupop is disabled for these
environments — we cut a new MNG launch template instead.

### Roll back a bad update

Bottlerocket keeps the previous partition. To revert:

```sh
# Find the affected node
kubectl get bottlerocketshadow -A

# SSH-less rollback via Brupop or the host-controlled API container
kubectl -n brupop-bottlerocket-aws exec deploy/brupop-controller -- \
  brupopctl rollback --node <node-name>
```

For Karpenter nodes: re-pin the EC2NodeClass to the previous AMI ID and
let drift do its thing.

### What if Karpenter is down?

The bootstrap MNG keeps the cluster alive. Karpenter HA (3 replicas across
AZs) makes a full controller outage rare; even in that case, scale-from-zero
just stops working — running workloads continue. Restore by re-applying the
helmfile.

## SLOs

| Indicator | Target |
|---|---|
| Time from upstream Bottlerocket release → all nodes patched | ≤ 14 days |
| In-flight pod evictions per node replacement | ≤ 0 PDB violations |
| Failed updates rolled back automatically | 100% (Bottlerocket A/B) |
| Mean time to apply critical CVE patch (KEV catalog) | ≤ 24 hours |

## Related

- ADR-0009 — Karpenter + Bottlerocket + Brupop (decision record)
- `mgmt-cluster-aws/apps/karpenter/` — NodePool + EC2NodeClass definitions
- `mgmt-cluster-aws/helmfile.yaml.gotmpl` — Brupop chart pinning
- `platform-fleet/modules/aws-karpenter/` — IAM + interruption queue
