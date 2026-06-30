# 0 — Deploy Guide (end to end)

Order of operations to stand up the whole FinCorp lab.

## Prerequisites
- Terraform ≥ 1.6, AWS CLI v2, kubectl, Docker (for local builds), `jq`.
- AWS account with the shared state bucket already bootstrapped
  (`infra/bootstrap` — reused from the shopnow lab).

## 1. Provision infrastructure
```bash
cd infra/live-fincorp
terraform init
terraform apply        # creates VPC, EKS, ECR, RDS, CodeArtifact, OIDC, AWS Backup, DR network
```
Capture outputs:
```bash
terraform output gha_ci_role_arn      # → GitHub var AWS_GHA_ROLE_ARN
terraform output backup_role_arn      # → GitHub var BACKUP_ROLE_ARN
terraform output ecr_repository_urls
terraform output -raw kubeconfig_command | bash   # point kubectl at the cluster
```

## 2. Configure GitHub repo Variables
Settings → Secrets and variables → Actions → **Variables** (see
[02-pipeline.md](02-pipeline.md) for the full list): `AWS_GHA_ROLE_ARN`,
`AWS_REGION=eu-west-1`, `AWS_ACCOUNT_ID`, `CODEARTIFACT_DOMAIN=fincorp`,
`EKS_CLUSTER=fincorp`, `K8S_NAMESPACE=fincorp`, `BACKUP_ROLE_ARN`.

## 3. Install the AWS Load Balancer Controller (one-time)
Annotate its ServiceAccount with `terraform output lb_controller_role_arn` and
install via Helm (kube-system). Required for the ALB ingress.

## 4. First app deploy
Create the namespace + app Secret/ConfigMap, then apply manifests:
```bash
kubectl apply -f k8s/00-namespace.yaml
# Create the fincorp-db Secret from the RDS secret:
aws secretsmanager get-secret-value --secret-id fincorp/rds/credentials \
  --query SecretString --output text   # build the K8s Secret from this DSN
kubectl apply -f k8s/        # configmap, deployments, services, ingress
```

## 5. Run the pipeline
Push to `main` (or run **build-and-push** manually). It builds through
CodeArtifact, fails on HIGH/CRITICAL via Trivy, pushes immutable `:<git-sha>`
images, and rolls them out to EKS.

## 6. DR drill
Follow the [DR runbook](05-dr-runbook.md).

## Teardown
```bash
# delete any restored DR instance first (see runbook), then:
cd infra/live-fincorp && terraform destroy
```
