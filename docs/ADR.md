# Architecture Decision Record — FinCorp Lab

## ADR-1: Standard RDS Postgres instance (not Aurora) for the DR-protected DB
**Decision:** use a single `aws_db_instance` (Postgres).
**Why:** the scenario says "an RDS database" and requires a delete-then-restore in
another region within 30 min. A single instance has the cleanest, fastest
AWS Backup restore path; Aurora restores reconstruct a cluster (more steps, longer).
**Trade-off:** no built-in multi-writer/cluster HA — acceptable, since DR here is
cross-region via AWS Backup, not in-region clustering.

## ADR-2: Trivy as the build-blocking gate; ECR scan-on-push for audit
**Decision:** fail the build with Trivy (`exit-code 1`, HIGH/CRITICAL) **before**
push; keep ECR scan-on-push enabled too.
**Why:** ECR scanning is asynchronous, so it can't synchronously block a build.
Trivy runs inline and deterministically fails the job. ECR scanning then provides
continuous re-evaluation of pushed images as new CVEs land.
**Trade-off:** two scanners. Worth it: one gates, one audits.

## ADR-3: GitHub OIDC, no long-lived AWS keys
**Decision:** the pipeline assumes `fincorp-gha-ci` via GitHub OIDC.
**Why:** the scenario demands an *auditable* supply chain. OIDC issues short-lived
creds per run, scoped to this repo; every assume-role is in CloudTrail. No secret
to leak or rotate.
**Trade-off:** initial OIDC provider + trust-policy setup. One-time.

## ADR-4: Immutable artifacts = commit-SHA tags + ECR tag immutability
**Decision:** tag every image with the full Git SHA; ECR repos are `IMMUTABLE`.
**Why:** guarantees one unique, permanent, tamper-proof artifact per change; the
deploy always pins an exact digest, never a moving `latest`.
**Trade-off:** the lifecycle policy still expires very old SHA tags (retention
`max_image_count`); immutability is preserved, only ancient tags are GC'd.

## ADR-5: CodeArtifact as the npm/pip proxy
**Decision:** route all dependency installs through CodeArtifact `npm-proxy` /
`pypi-proxy`; inject the token into Docker builds via a BuildKit secret.
**Why:** central caching, attribution, and an upstream kill-switch — the
auditable-supply-chain requirement — without baking secrets into image layers.
**Trade-off:** builds depend on CodeArtifact availability; mitigated by the cache.

## ADR-6: Reuse the state bucket with a new key; new `fincorp` namespace
**Decision:** keep the existing `shopnow-tfstate` bucket + lock table, use key
`fincorp/terraform.tfstate`; rename everything to `fincorp` with VPC `10.20.0.0/16`.
**Why:** zero state collision with the shopnow-eks lab and no extra bootstrap,
while resource names/CIDRs never clash in the shared account.
**Trade-off:** the two labs share one state bucket (account-global infra) — fine,
state keys are isolated.

## ADR-7: Minimal DR network in eu-west-2
**Decision:** create a small VPC + 2 subnets + DB subnet group in the DR region.
**Why:** a restored RDS instance needs a DB subnet group in-region; this makes the
restore target deterministic instead of depending on a default VPC.
**Trade-off:** a little extra infra (subnets are free; no NAT/IGW provisioned).
