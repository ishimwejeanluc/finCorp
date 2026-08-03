# Kubernetes manifests for FinCorp on EKS

Plain `kubectl` manifests for the app on an EKS managed node group. Public entry
is an **ALB via an Ingress** (provisioned by the AWS Load Balancer Controller).
For a field-by-field walkthrough of every manifest see [MANIFESTS.md](MANIFESTS.md);
for the end-to-end deploy (cluster → images → deploy → DB seed) see
[../docs/00-deploy.md](../docs/00-deploy.md).

## What gets created

| File | Resource | Purpose |
|---|---|---|
| `00-namespace.yaml` | Namespace `fincorp` | Logical isolation |
| `01-configmap.yaml` | ConfigMap `fincorp-app` | Non-secret config (e.g. `BACKEND_URL`) |
| `02-backend-deployment.yaml` | ServiceAccount + Deployment | FastAPI backend; reads `POSTGRES_DSN` from the `fincorp-db` Secret |
| `03-backend-service.yaml` | ClusterIP Service :8000 | In-cluster DNS `backend.fincorp.svc.cluster.local` |
| `04-frontend-deployment.yaml` | ServiceAccount + Deployment | Express frontend; proxies `/api/*` to the backend |
| `05-frontend-service.yaml` | ClusterIP Service | Backend for the Ingress |
| `06-ingress.yaml` | Ingress (`ingressClassName: alb`) | Public entry — becomes an internet-facing ALB |
| `07-db-migrate.yaml` | Job (manual, one-shot) | Applies the schema + seed to RDS (see below) |

> The `fincorp-db` **Secret** is **not** a manifest (it holds credentials). It's
> created at deploy time by [../scripts/deploy-eks-k8s.sh](../scripts/deploy-eks-k8s.sh),
> which reads `fincorp/rds/credentials` from Secrets Manager and assembles
> `POSTGRES_DSN`. There is no Redis/`REDIS_URL` — the app uses Postgres only.

## Deploying — use the script, not raw kubectl

`scripts/deploy-eks-k8s.sh` is the single source of truth (used identically by the
GitHub Actions pipeline and locally). It updates kubeconfig, creates the namespace
+ ConfigMap + `fincorp-db` Secret, renders the image tag into the Deployments, and
applies everything including the Ingress:

```bash
# one-time per cluster: install the AWS Load Balancer Controller (Helm, IRSA)
./scripts/deploy-eks-k8s.sh --ensure-lb-controller

# subsequent deploys (the pipeline runs exactly this):
./scripts/deploy-eks-k8s.sh --image-tag "<git-sha>" --include-ingress
```
The IRSA role + subnet discovery tags the controller needs are created by
Terraform (`infra/modules/stack`). Prerequisites: the cluster from
`infra/live-primary` (eu-west-1) is up, and images are in ECR.

## Seed the database (one-time, manual)

RDS doesn't auto-run the schema. Apply it once via the migration Job (idempotent):
```bash
kubectl delete job db-migrate -n fincorp --ignore-not-found
kubectl apply -f 07-db-migrate.yaml
kubectl -n fincorp wait --for=condition=complete job/db-migrate --timeout=120s
```
(Not needed after a DR restore — the restored DB already contains the data.)

## Get the public URL

```bash
kubectl -n fincorp get ingress fincorp        # ADDRESS = the ALB hostname
ALB=$(kubectl -n fincorp get ingress fincorp -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -fsS "http://$ALB/"
curl -fsS "http://$ALB/api/products"
```
The ALB takes 2-3 minutes to become reachable after the Ingress is first created.

## Teardown

```bash
kubectl delete namespace fincorp     # removes workloads; the LB controller then deletes the ALB
```
The cluster, RDS, and VPC are destroyed by `terraform destroy` in
`infra/live-primary` (or use `scripts/teardown-all.sh` for the full, ordered teardown).

## Common pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| Pod `ImagePullBackOff` | image tag not in the region's ECR | check the tag exists; on DR, confirm ECR replication copied it |
| Backend `relation "products" does not exist` | schema not seeded | run the `07-db-migrate.yaml` Job above |
| Backend `connection refused` to Postgres | SG rule from cluster SG → RDS:5432 missing | it's `aws_security_group_rule.rds_from_cluster` in `infra/modules/stack` |
| Ingress has no `ADDRESS` | LB controller not installed | run `deploy-eks-k8s.sh --ensure-lb-controller` once |
| Ingress rejected: webhook TLS / `x509` | LB controller webhook cert churn from repeated installs | `kubectl -n kube-system rollout restart deploy/aws-load-balancer-controller`, then re-apply |
