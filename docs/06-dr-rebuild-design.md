# 6 — DR Redesign: Full-Region Rebuild (design doc)

**Status:** proposed — for review before implementation
**Author:** DR working session, 2026-07-09
**Supersedes the DB-only model in** [04-dr-setup.md](04-dr-setup.md) / [05-dr-runbook.md](05-dr-runbook.md)

---

## 1. What changes and why

### Today (DB-only failover)
The app runs permanently in **eu-west-1**. DR is a "pilot light": AWS Backup copies
the RDS snapshot to **eu-west-2** daily, and on a drill we delete *only the DB*,
restore it into a bare eu-west-2 landing VPC, and **re-point the still-running
eu-west-1 app** at that restored DB **across regions**.

- Simulation ≠ region failure — the app/EKS never go down.
- The recovered app talks to its DB **cross-region** (higher latency, and only
  works because eu-west-1 is actually still alive).

### Target (full-region rebuild)
Treat a drill as a **true loss of eu-west-1** (app **and** DB gone together).
Recovery = **Terraform re-creates the identical stack in eu-west-2** from one
parameterized template, and the DB is **restored into that same eu-west-2 VPC**, so
the rebuilt app and the restored DB **sit together and connect locally** — no
cross-region reach, no VPC peering.

This is a **cold-standby / rebuild** posture (was: warm DB-only). It is a
deliberate trade: cleaner "everything lives in one region" story, at the cost of a
longer RTO (§7).

---

## 2. Feasibility & the three caveats (agreed)

Feasible. The modules are already region-clean — `network` derives region/AZs from
data sources, and `rds`/`eks`/`elasticache` take injected VPC/subnet IDs — so the
stack ports to eu-west-2 unchanged. Three things were decided up front:

| # | Issue | Decision |
|---|---|---|
| 1 | **ECR is regional** — a rebuilt eu-west-2 ECR is empty, nothing to pull. | **ECR cross-region replication** eu-west-1 → eu-west-2 (images always present in DR, zero failover steps). |
| 2 | **TF state backend is in eu-west-1** — unreachable in a *real* region loss. | Accept for the drill (we delete infra, not the region — the state bucket + DR vault survive). DR stack gets its **own state key**. Documented as a known limitation; production would replicate state to a third region. |
| 3 | **RTO** — rebuilding EKS from zero is slow. | Accepted as inherent to cold-standby (§7). |

---

## 3. Target Terraform layout (best-practice separation)

Split the single root into **three concerns** so the destroyable regional stacks
are cleanly isolated from the DR-critical persistent infra. One shared
`modules/stack` is instantiated **once per region**.

```
infra/
  modules/
    stack/            # NEW — wraps the whole regional app+data stack
      main.tf         #   network + eks/* + elasticache + rds + lb-controller
      variables.tf    #   region, vpc_cidr, project, rds_mode, cluster_version, ...
      outputs.tf      #   vpc_id, cluster_name, rds_sg_id, cluster_sg_id, ...
    network/  eks/*  rds/  elasticache/  ecr/  backup/  github-oidc/  codeartifact/   # unchanged
  live-persistent/    # NEW — survives the drill (never destroyed)
      backup module (vaults/KMS/plan/role, cross-region copy)
      ecr repos + aws_ecr_replication_configuration  (eu-west-1 -> eu-west-2)
      github-oidc + codeartifact  (account-level / build-time)
      state key: fincorp/persistent.tfstate
  live-primary/       # RENAMED from live-fincorp — region = eu-west-1
      module.stack { region = eu-west-1, vpc_cidr = 10.20.0.0/16, rds_mode = "create" }
      state key: fincorp/primary.tfstate
  live-dr/            # NEW — region = eu-west-2, applied only at failover
      module.stack { region = eu-west-2, vpc_cidr = 10.40.0.0/16, rds_mode = "restore" }
      state key: fincorp/dr.tfstate
```

**Why this split**
- `live-primary` and `live-dr` are the *same* module with different
  `region`/`vpc_cidr`/`rds_mode` — literally the "parameterized template" re-created
  in the second region.
- `live-persistent` holds everything that **must outlive** the simulated failure:
  the backup vaults + recovery points (the whole point of DR), the ECR
  images+replication, and account-level IAM/CodeArtifact. Destroying the primary
  stack can never touch them.
- Separate state keys → primary and DR never collide; each region is
  independently `apply`/`destroy`-able.

> Alternative considered: one root + `primary`/`dr` **workspaces**. Rejected —
> `count`-gating the backup module and the restore-mode DB per workspace is
> fiddlier and easier to get wrong than three explicit roots. (Your call if you'd
> rather have it; it's a smaller file count.)

### 3.1 `rds_mode` toggle (create vs restore)

The `rds` module gains `rds_mode`:
- `"create"` (primary): current behaviour — a fresh CMK-encrypted instance.
- `"restore"` (DR): the module **does not create `aws_db_instance`**. It still
  creates the DB subnet group + RDS security group (so the SG-from-cluster rule and
  the restore landing exist), but the instance itself is landed by
  `dr-restore.sh` via `start-restore-job` (AWS Backup restores aren't a native TF
  resource here). Terraform owns the *plumbing*; the restore job owns the *data*.

This keeps the DB and the app in the **same VPC**; the SG rule `rds_from_cluster`
(already in the root) attaches the DR cluster SG → restored DB on port 5432 =
**local** connectivity.

### 3.2 ECR replication (caveat #1)

In `live-persistent`, add to the ECR concern:

```hcl
resource "aws_ecr_replication_configuration" "this" {
  replication_configuration {
    rule {
      destination { region = var.dr_region }   # eu-west-2
    }
  }
}
```

Replication auto-creates the repos in eu-west-2 and keeps images in sync, so the
rebuilt DR nodes can pull `fincorp/backend` + `fincorp/frontend` immediately.

---

## 4. Rewrite: `dr-simulate-failure.sh` (whole-infra failure)

**Now:** deletes only the RDS instance.
**Target:** destroy the **entire primary regional stack** (app + EKS + DB +
network), leaving the persistent layer intact.

Flow:
1. **Safety gate (unchanged):** refuse unless a `COMPLETED` RDS recovery point
   exists in `fincorp-backup-dr` (eu-west-2). Nothing to rebuild-to otherwise.
2. **Explicit confirmation** (type the project name).
3. Start the RTO clock.
4. `cd infra/live-primary && terraform destroy -auto-approve`
   — tears down network, EKS, ElastiCache, RDS in eu-west-1. Because backup/ECR/OIDC
   live in `live-persistent`, the recovery point, images, and state bucket survive.
5. Print the recover command.

> The recovery point lives in the DR **vault** and is independent of the backup
> plan/selection lifecycle, so it survives even a full `destroy` of the primary
> stack.

---

## 5. Rewrite: `dr-restore.sh` + `dr-restore.yml` (Terraform + DB restore + wire-up)

**Now:** DB-only restore, then re-point the eu-west-1 app cross-region.
**Target:** orchestrate the full rebuild in eu-west-2, in order:

1. **Rebuild infra:** `cd infra/live-dr && terraform init && terraform apply -auto-approve`
   → VPC 10.40.0.0/16, EKS cluster + nodes + addons + LB controller, ElastiCache,
   RDS subnet group + SG (rds_mode=restore, no instance yet).
2. **Restore the DB into the DR VPC:** the existing `start-restore-job` logic
   (find latest recovery point → clean metadata → restore), targeting the
   **`live-dr` stack's** DB subnet group. Poll to `COMPLETED`.
3. **Wire DB ↔ app locally:** attach the restored instance to the RDS SG from the
   stack (already trusts the DR cluster SG on 5432) — same-VPC, no peering.
4. **Deploy the app:** `aws eks update-kubeconfig` for the **DR** cluster, write the
   `fincorp-db` Secret with the **local** restored endpoint + preserved master
   creds + the DR Redis URL, `kubectl apply` the manifests, roll out.
5. Report endpoint + elapsed vs RTO.

Workflow (`dr-restore.yml`) input changes:
- `aws-region` → `eu-west-2` for the whole job (already is).
- New step order: **terraform apply (DR)** → restore DB → deploy app.
- Drop `repoint_app` (the old "keep app in primary" path no longer exists);
  replace with `rebuild_infra` (default true) so the restore can be re-run
  idempotently against an already-built DR stack.
- Runner needs Terraform + the CI OIDC role must be allowed to apply the DR stack
  (it already has broad rights; confirm state-bucket + eu-west-2 permissions).

---

## 6. State migration (existing → new layout)

Current state has flat addresses (`module.network`, `module.rds`, …) in
`live-fincorp`. The refactor changes addresses to `module.stack.module.network`,
etc. To avoid destroy/recreate of live infra:

- Add `moved {}` blocks in `live-primary` mapping each `module.X` →
  `module.stack.module.X`, **or** `terraform state mv` in a one-off migration.
- Move the `backup`, `ecr`, `github-oidc`, `codeartifact` resources into
  `live-persistent` state via `terraform state mv -state-out` (or
  `terraform import`), then remove them from the primary root.
- The inline eu-west-2 DR VPC (`aws_vpc.dr`, subnets, subnet group) currently in
  `live-fincorp` is **deleted** — the DR VPC is now produced by `live-dr`'s
  `module.stack`. It's empty today, so a destroy/recreate is safe.

A dry `terraform plan` after each move must show **no destroys** of primary EKS/RDS.
This migration is the riskiest step — do it in a maintenance window with a state
backup (`terraform state pull > backup.tfstate`).

---

## 7. RTO / RPO impact

| Metric | DB-only (today) | Full rebuild (target) |
|---|---|---|
| **RPO** | ≤ 24 h (daily copy) | ≤ 24 h (unchanged) |
| **RTO** | 10–20 min (restore only) | **~25–40 min** — EKS control plane (~10-15m) + nodes/addons + LB controller + app rollout + DB restore (partly parallel) |

The 30-minute RTO in [05-dr-runbook.md](05-dr-runbook.md) will likely **not** hold
for a from-zero EKS rebuild. Options: (a) accept a larger RTO and update the
runbook, or (b) keep a minimal always-on EKS node group in DR (warm standby) to
cut cluster-provision time — at standing cost. **Recommend (a)** for the lab.

---

## 8. Open questions / your call

1. **RTO target:** accept ~40 min (update runbook), or move toward warm standby?
2. **Redis data:** ElastiCache is rebuilt **empty** in DR (it's a cache, no backup).
   Confirm the app tolerates a cold cache on failover (it should — cache miss →
   repopulate). Flagging so it's a conscious choice.
3. **DR cluster/LB DNS:** the DR app comes up behind a *new* ALB with a new
   hostname. Out of scope here is the DNS/Route 53 failover to that hostname — do
   you want a follow-up for automated DNS cutover, or is showing the new ALB URL
   enough for the drill?
4. **State backend hardening:** leave the known eu-west-1 limitation documented, or
   add S3 cross-region replication of the state bucket now?

---

## 9. Work breakdown (once approved)

1. Extract `modules/stack` (move network/eks*/elasticache/rds/lb-controller/SG
   rules/subnet-tags into it; add `region`, `vpc_cidr`, `rds_mode` vars + outputs).
2. Add `rds_mode` to the `rds` module (skip instance in `restore`).
3. Create `live-persistent` (backup + ECR + replication + oidc + codeartifact);
   migrate state.
4. Rename `live-fincorp` → `live-primary`; call `module.stack` (create); `moved` blocks.
5. Create `live-dr`; call `module.stack` (restore), own state key.
6. Rewrite `dr-simulate-failure.sh` → `terraform destroy` of `live-primary`.
7. Rewrite `dr-restore.sh` → apply `live-dr` + restore DB + deploy app.
8. Update `dr-restore.yml` step order + inputs.
9. Update `04`/`05` docs + `README` to the new model.
