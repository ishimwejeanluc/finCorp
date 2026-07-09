# 7 — Migrating to the split layout (persistent / primary / dr)

The old single root `infra/live-fincorp` is replaced by three roots that share one
reusable `infra/modules/stack`:

| Root | State key | What it holds | Region |
|---|---|---|---|
| `infra/live-persistent` | `fincorp/persistent.tfstate` | backup vaults + plan, ECR + replication, GitHub OIDC, CodeArtifact | eu-west-1 (+ eu-west-2 vault) |
| `infra/live-primary` | `fincorp/primary.tfstate` | `module.stack` — VPC/EKS/RDS/Redis (the live app) | eu-west-1 |
| `infra/live-dr` | `fincorp/dr.tfstate` | same `module.stack`, `rds_mode=restore`, applied at failover | eu-west-2 |

Old state key `fincorp/terraform.tfstate` (used by `live-fincorp`) is retired.

> **These commands touch live infrastructure and remote state. Run them yourself,
> in a maintenance window, after backing up state. They are NOT run automatically.**

---

## Why you can't just `apply` the new roots alongside the old one

Three resources are globally unique per AWS account and are already owned by the
old `live-fincorp` state, so a fresh apply would collide (`EntityAlreadyExists`):

- the GitHub OIDC provider (`token.actions.githubusercontent.com`)
- the ECR repos (`fincorp/backend`, `fincorp/frontend`)
- the CodeArtifact domain

So you must either **tear the old root down first** (clean slate, recommended for
the lab) or **move resources between states** (advanced, preserves everything).

---

## Option A — Clean slate (recommended for the lab)

Simplest and least error-prone. Recreates the DB + cluster fresh (you re-seed the
DB and push images again). No `terraform state` surgery.

```bash
cd infra

# 0. Back up the current state, just in case.
terraform -chdir=live-fincorp state pull > ~/fincorp-oldstate-$(date +%s).tfstate

# 1. Tear down the OLD all-in-one stack.
#    ECR has no force_delete, so empty the repos first if they hold images:
for r in fincorp/backend fincorp/frontend; do
  aws ecr list-images --repository-name "$r" --region eu-west-1 \
    --query 'imageIds[*]' --output json > /tmp/ids.json
  [ "$(jq 'length' /tmp/ids.json)" -gt 0 ] && \
    aws ecr batch-delete-image --repository-name "$r" --region eu-west-1 \
      --image-ids file:///tmp/ids.json || true
done
terraform -chdir=live-fincorp destroy      # removes app, DB, OIDC, ECR, vaults

# 2. Stand up the PERSISTENT layer (new vaults, ECR + replication, OIDC, CodeArtifact).
terraform -chdir=live-persistent init
terraform -chdir=live-persistent apply

# 3. Point GitHub at the new CI role + backup role.
terraform -chdir=live-persistent output -raw gha_ci_role_arn   # -> repo var AWS_GHA_ROLE_ARN
terraform -chdir=live-persistent output -raw backup_role_arn   # -> repo var BACKUP_ROLE_ARN

# 4. Stand up the PRIMARY stack.
terraform -chdir=live-primary init
terraform -chdir=live-primary apply

# 5. Seed images + a recovery point.
#    - Run the build-and-push pipeline (pushes to eu-west-1 ECR; replication copies to eu-west-2).
#    - Deploy the app:      AWS_REGION=eu-west-1 scripts/deploy-eks-k8s.sh --ensure-lb-controller
#    - Seed the DB, then:   BACKUP_ROLE_ARN=... scripts/dr-backup-now.sh
```

After step 5 you have a recovery point in the DR vault and images replicated to
eu-west-2 — you're ready for the drill (docs/05-dr-runbook.md).

Finally, delete the retired root:
```bash
rm -rf infra/live-fincorp
```

---

## Option B — Move resources between states (advanced, preserves live infra)

Keeps the running cluster + DB. Uses local state files as scratch, then pushes.
Do this only if you're comfortable with `terraform state mv` and have the state
backup from step 0 above.

```bash
cd infra

# Init every root (creates the new empty remote states).
for d in live-persistent live-primary live-dr; do terraform -chdir="$d" init; done

# Pull all states to local files.
terraform -chdir=live-fincorp    state pull > old.tfstate
terraform -chdir=live-persistent state pull > persistent.tfstate
terraform -chdir=live-primary    state pull > primary.tfstate

# --- Move the PERSISTENT resources: old -> persistent.tfstate ---
for addr in \
  module.ecr module.github_oidc module.codeartifact module.backup \
  aws_ecr_replication_configuration.this ; do
  terraform state mv -state=old.tfstate -state-out=persistent.tfstate "$addr" "$addr"
done

# --- Move the STACK resources: old -> primary.tfstate, renaming under module.stack ---
for m in network rds elasticache eks_cluster eks_nodes eks_addons eks_oidc ; do
  terraform state mv -state=old.tfstate -state-out=primary.tfstate "module.$m" "module.stack.module.$m"
done
# Root-level stack resources that moved into the module:
terraform state mv -state=old.tfstate -state-out=primary.tfstate aws_eks_access_entry.ci                 module.stack.aws_eks_access_entry.ci
terraform state mv -state=old.tfstate -state-out=primary.tfstate aws_eks_access_policy_association.ci_admin module.stack.aws_eks_access_policy_association.ci_admin
terraform state mv -state=old.tfstate -state-out=primary.tfstate aws_iam_policy.lb_controller            module.stack.aws_iam_policy.lb_controller
terraform state mv -state=old.tfstate -state-out=primary.tfstate aws_iam_role.lb_controller              module.stack.aws_iam_role.lb_controller
terraform state mv -state=old.tfstate -state-out=primary.tfstate aws_iam_role_policy_attachment.lb_controller_irsa module.stack.aws_iam_role_policy_attachment.lb_controller_irsa
terraform state mv -state=old.tfstate -state-out=primary.tfstate 'aws_security_group_rule.rds_from_cluster'   module.stack.aws_security_group_rule.rds_from_cluster
terraform state mv -state=old.tfstate -state-out=primary.tfstate 'aws_security_group_rule.redis_from_cluster' module.stack.aws_security_group_rule.redis_from_cluster
terraform state mv -state=old.tfstate -state-out=primary.tfstate 'aws_ec2_tag.public_subnet_elb_role'          'module.stack.aws_ec2_tag.public_subnet_elb_role'
terraform state mv -state=old.tfstate -state-out=primary.tfstate 'aws_ec2_tag.private_subnet_internal_elb_role' 'module.stack.aws_ec2_tag.private_subnet_internal_elb_role'
terraform state mv -state=old.tfstate -state-out=primary.tfstate 'aws_ec2_tag.subnet_cluster_owner'            'module.stack.aws_ec2_tag.subnet_cluster_owner'

# The old inline DR VPC (aws_vpc.dr / aws_subnet.dr / aws_db_subnet_group.dr) is
# retired — leave it in old.tfstate and let the final destroy remove it (it's empty).

# Push the updated states back.
terraform -chdir=live-persistent state push persistent.tfstate
terraform -chdir=live-primary    state push primary.tfstate

# Verify NO destroys of live EKS/RDS:
terraform -chdir=live-persistent plan
terraform -chdir=live-primary    plan     # expect only in-place / no-op

# Remove leftovers (old DR VPC) + retire the old root.
terraform -chdir=live-fincorp state push old.tfstate
terraform -chdir=live-fincorp destroy -target=aws_db_subnet_group.dr -target=aws_subnet.dr -target=aws_vpc.dr
rm -rf infra/live-fincorp
```

> `terraform state mv` between `-state`/`-state-out` files does not resolve module
> resource addresses perfectly in every version — after pushing, ALWAYS run `plan`
> on each root and confirm there are no unexpected destroys before applying.

---

## Repo Variables to update (GitHub → Settings → Variables)

| Variable | New source |
|---|---|
| `AWS_GHA_ROLE_ARN` | `terraform -chdir=infra/live-persistent output -raw gha_ci_role_arn` |
| `BACKUP_ROLE_ARN` | `terraform -chdir=infra/live-persistent output -raw backup_role_arn` |
| `AWS_DR_PROVISIONER_ROLE_ARN` | *(optional)* a role allowed to `terraform apply` the DR stack, if you run the rebuild from CI rather than locally |
