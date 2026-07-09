# 0 — Deploy Guide (end to end)

Order of operations to stand up the whole FinCorp lab.

## Prerequisites
- Terraform ≥ 1.6, AWS CLI v2, kubectl, Docker (for local builds), `jq`.
- The Terraform remote-state backend bootstrapped:
  ```bash
  cd infra/bootstrap && terraform init && terraform apply
  # creates fincorp-tfstate-<account-id> (S3) + fincorp-tfstate-lock (DynamoDB)
  ```
  The new roots' backend blocks already point at `fincorp-tfstate-<account-id>`
  (distinct state keys per root). Adjust the bucket name if yours differs.

## 1. Provision infrastructure
The stack is split into three roots (see [06-dr-rebuild-design.md](06-dr-rebuild-design.md)).
Apply the persistent layer first (its CI role is consumed by the regional stacks):
```bash
# a) persistent: backups, ECR + cross-region replication, OIDC, CodeArtifact
terraform -chdir=infra/live-persistent init
terraform -chdir=infra/live-persistent apply

# b) primary regional stack: VPC, EKS, RDS, Redis (eu-west-1)
terraform -chdir=infra/live-primary init
terraform -chdir=infra/live-primary apply    # DR stack (live-dr) is applied only at failover
```
Capture outputs:
```bash
terraform -chdir=infra/live-persistent output -raw gha_ci_role_arn   # → GitHub var AWS_GHA_ROLE_ARN
terraform -chdir=infra/live-persistent output -raw backup_role_arn   # → GitHub var BACKUP_ROLE_ARN
terraform -chdir=infra/live-persistent output ecr_repository_urls
terraform -chdir=infra/live-primary    output -raw kubeconfig_command | bash   # point kubectl at the cluster
```

> Already have the old single `infra/live-fincorp` root deployed? Follow
> [07-migration.md](07-migration.md) instead of applying fresh.

## 2. Configure GitHub repo Variables
Settings → Secrets and variables → Actions → **Variables** (see
[02-pipeline.md](02-pipeline.md) for the full list): `AWS_GHA_ROLE_ARN`,
`AWS_REGION=eu-west-1`, `AWS_ACCOUNT_ID`, `CODEARTIFACT_DOMAIN=fincorp`,
`EKS_CLUSTER=fincorp`, `K8S_NAMESPACE=fincorp`, `BACKUP_ROLE_ARN`.

## 3. Install the AWS Load Balancer Controller (one-time)
The ALB ingress needs the controller running in the cluster. Install it once with
the deploy script (Helm, IRSA wired automatically):
```bash
./scripts/deploy-eks-k8s.sh --ensure-lb-controller
```
This also does a full deploy using the latest image already in ECR. (Or install
via Helm yourself, annotating the ServiceAccount with
`terraform output lb_controller_role_arn`.)

## 4. App deploy — the pipeline does it
There is **no separate bootstrap**. Push to `main` (or run **build-and-push**).
The pipeline builds through CodeArtifact, fails on HIGH/CRITICAL via Trivy, pushes
immutable `:<git-sha>` images, then **calls `scripts/deploy-eks-k8s.sh`** — the
single source of truth for deploys. The script:

1. updates kubeconfig,
2. creates the `fincorp` namespace + `fincorp-db` Secret (from Secrets Manager) if absent,
3. renders the manifests' `:placeholder` tag to the commit SHA,
4. `kubectl apply`s deployments, services, and ingress declaratively.

Because `kubectl apply` is declarative, every later run changes only what actually
changed: unchanged manifests report `unchanged` (no rollout); only the image field —
which moves with each commit SHA — triggers a rolling update. Re-running on the same
commit is a no-op (the build is skipped and apply finds nothing to change).

> The same script runs locally for manual deploys — see `--help`. The CI run does
> NOT pass `--ensure-lb-controller` (no Helm on the runner; the controller is a
> one-time setup from step 3).

## 5. Create the DB schema (one-time, manual)
RDS doesn't auto-run `db/init/init.sql` like local compose does. Apply the schema
once, from inside the cluster, with the manual migration Job (NOT run by the
pipeline). It's idempotent, so re-running is safe:
```bash
kubectl delete job db-migrate -n fincorp --ignore-not-found
kubectl apply -f k8s/07-db-migrate.yaml
kubectl -n fincorp wait --for=condition=complete job/db-migrate --timeout=120s
kubectl -n fincorp logs job/db-migrate
```
After this the `products` table exists and `/products` works. (Not needed after a
DR restore — the restored instance already contains the schema and data.)

## 6. DR drill
Follow the [DR runbook](05-dr-runbook.md).

## Teardown
```bash
# delete any restored DR instance first (see runbook), then tear down in order:
terraform -chdir=infra/live-dr        destroy   # if the DR stack was ever applied
terraform -chdir=infra/live-primary   destroy
terraform -chdir=infra/live-persistent destroy  # empty the ECR repos first (see 07-migration.md)
```
