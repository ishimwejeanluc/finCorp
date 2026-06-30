# Kubernetes manifests for FinCorp on EKS

These manifests deploy the same app the ECS stack runs, onto an EKS cluster (managed node groups). No IRSA, no Helm — plain kubectl.

## What gets created

| File | Resource | Purpose |
|---|---|---|
| `00-namespace.yaml` | Namespace `fincorp` | Logical isolation. Also matches the Fargate profile selector if you ever switch to Fargate. |
| `01-backend-deployment.yaml` | ServiceAccount + Deployment (replicas: 2) | Python FastAPI; reads `POSTGRES_DSN` and `REDIS_URL` from the `fincorp-db` Secret. |
| `02-backend-service.yaml` | ClusterIP Service on :8000 | In-cluster DNS: `backend.fincorp.svc.cluster.local`. |
| `03-frontend-deployment.yaml` | ServiceAccount + Deployment (replicas: 2) | Node + Express; calls backend via the ClusterIP service. |
| `04-frontend-service.yaml` | LoadBalancer Service → NLB | Public entry point. Annotation tells EKS to provision an NLB. |

## Prerequisites

1. EKS cluster already running (`infra/live-eks/` applied via Terraform).
2. Images already pushed to ECR:
   - `<account>.dkr.ecr.eu-west-1.amazonaws.com/fincorp/backend:v1`
   - `<account>.dkr.ecr.eu-west-1.amazonaws.com/fincorp/frontend:v1`
3. RDS Postgres + ElastiCache Redis reachable from the cluster (security group rule `cluster_security_group_id` → RDS:5432 and → Redis:6379 is in the `live-eks` workspace).
4. `kubectl` and `aws` CLI installed locally.

## Step 1 — Configure kubectl

```bash
aws eks update-kubeconfig --name fincorp --region eu-west-1
kubectl config current-context     # should mention "fincorp"
kubectl get nodes                  # 2 nodes Ready
```

## Step 2 — Replace the image placeholder

Both Deployments have `ACCOUNT_ID` as a placeholder. Substitute your real AWS account number:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
cd k8s
sed -i.bak "s/ACCOUNT_ID/${ACCOUNT_ID}/g" 01-backend-deployment.yaml 03-frontend-deployment.yaml
rm -f *.bak
```

(Or use `kustomize` with an `images:` override — leave the YAML untouched.)

## Step 3 — Create the namespace and the DB Secret

The Deployments mount `POSTGRES_DSN` and `REDIS_URL` from a Secret named `fincorp-db`. Don't commit it to git — build the strings in the exact format the backend expects and create the Secret imperatively.

### Required string formats

```
POSTGRES_DSN  →  postgresql://<user>:<URL-ENCODED password>@<host>:<port>/<dbname>
REDIS_URL     →  rediss://default:<auth_token>@<host>:<port>/0
```

Examples (not real credentials):

```
postgresql://postgres:I%3CH7E%23o%3FHZ%3Ey9MQ%21ubRvka8439%7CQ@fincorp-pg-instance-1.clckkisc2cyg.eu-west-1.rds.amazonaws.com:5432/fincorp
rediss://default:Lukatoni1234567890@master.fincorp-redis.8oszx4.euw1.cache.amazonaws.com:6379/0
```

The Postgres password **must** be URL-encoded — the auto-generated RDS password almost always contains characters that break a raw DSN (`<>#?!|@:/&`). The Redis AUTH token should be encoded too (defensive — usually unnecessary).

### Build the strings from Secrets Manager and create the Secret

```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-configmap.yaml

# --- Postgres DSN (URL-encoded password, dbname fixed to "fincorp") ---
PG_DSN=$(aws secretsmanager get-secret-value \
  --secret-id fincorp-eks/rds/credentials --region eu-west-1 \
  --query SecretString --output text \
  | python3 -c '
import sys, json
from urllib.parse import quote
d = json.load(sys.stdin)
user = d["username"]
pw   = quote(d["password"], safe="")     # URL-encode special chars
host = d["host"]
port = d.get("port", 5432)
db   = d.get("dbname", "fincorp")
print(f"postgresql://{user}:{pw}@{host}:{port}/{db}")
')

# --- Redis URL (TLS, default user, db 0) ---
REDIS_URL=$(aws secretsmanager get-secret-value \
  --secret-id fincorp-eks/redis/credentials --region eu-west-1 \
  --query SecretString --output text \
  | python3 -c '
import sys, json
from urllib.parse import quote
d = json.load(sys.stdin)
token = quote(d["auth_token"], safe="")
host  = d["host"]
port  = d.get("port", 6379)
print(f"rediss://default:{token}@{host}:{port}/0")
')

# --- Sanity-check before creating the Secret ---
# Both should start with the expected scheme and NOT contain raw special chars in the password slot.
echo "PG_DSN     starts: $(echo "$PG_DSN" | cut -c1-30)..."
echo "REDIS_URL  starts: $(echo "$REDIS_URL" | cut -c1-30)..."

# --- Create / replace the Secret ---
kubectl -n fincorp create secret generic fincorp-db \
  --from-literal=POSTGRES_DSN="$PG_DSN" \
  --from-literal=REDIS_URL="$REDIS_URL" \
  --dry-run=client -o yaml | kubectl apply -f -
```

The `--dry-run=client -o yaml | kubectl apply -f -` idiom lets you re-run this command to **update** the Secret without first deleting it (plain `kubectl create secret` would error if it already exists).

### If your Secrets Manager JSON shape is different

Adjust the Python field names. Common shapes:

| Created by | Postgres secret keys | Redis secret keys |
|---|---|---|
| Aurora "Managed in Secrets Manager" | `username`, `password`, `host`, `port`, `dbClusterIdentifier` | n/a |
| Standard RDS "Managed in Secrets Manager" | `username`, `password`, `host`, `port`, `dbInstanceIdentifier` | n/a |
| Terraform `shared/rds` module | `username`, `password`, `host`, `port`, `dbname`, `dsn` (pre-built) | n/a |
| Terraform `shared/elasticache` module | n/a | `auth_token`, `host`, `port`, `url` (pre-built) |
| Manually created (Part 2 of docs/manual-setup) | varies — match your input | varies |

If your secret already has a pre-built `dsn` / `url` field (Terraform-managed ones do), you can simplify to:
```bash
PG_DSN=$(aws secretsmanager get-secret-value --secret-id fincorp-eks/rds/credentials \
  --region eu-west-1 --query SecretString --output text \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["dsn"])')
```
…but verify the pre-built `dsn` itself has the password URL-encoded — Terraform's `format()` doesn't encode by default.

### Hand-built (no Secrets Manager)

If you don't use Secrets Manager at all, paste the URLs directly:

```bash
kubectl -n fincorp create secret generic fincorp-db \
  --from-literal=POSTGRES_DSN='postgresql://postgres:I%3CH7E%23o%3FHZ%3Ey9MQ%21ubRvka8439%7CQ@fincorp-pg-instance-1.clckkisc2cyg.eu-west-1.rds.amazonaws.com:5432/fincorp' \
  --from-literal=REDIS_URL='rediss://default:Lukatoni1234567890@master.fincorp-redis.8oszx4.euw1.cache.amazonaws.com:6379/0'
```

Note the **single quotes** around the values — bash won't try to interpret `$` or `!` inside them.

## Step 4 — Apply the rest of the manifests

```bash
kubectl apply -f 01-backend-deployment.yaml
kubectl apply -f 02-backend-service.yaml
kubectl apply -f 03-frontend-deployment.yaml
kubectl apply -f 04-frontend-service.yaml
```

Or in one shot:
```bash
kubectl apply -f .
```

## Step 5 — Wait for the pods

```bash
kubectl -n fincorp get pods -w
# backend-xxxxxxxxxx-yyyyy   1/1   Running
# backend-xxxxxxxxxx-zzzzz   1/1   Running
# frontend-xxxxxxxxxx-aaaaa  1/1   Running
# frontend-xxxxxxxxxx-bbbbb  1/1   Running
```

If pods stay `Pending`, check `kubectl -n fincorp describe pod <name>` — usually node capacity or image pull.

If they stay `CrashLoopBackOff`, check logs:
```bash
kubectl -n fincorp logs deploy/backend
kubectl -n fincorp logs deploy/frontend
```

## Step 6 — Get the public URL

```bash
kubectl -n fincorp get svc frontend -w
# Wait until EXTERNAL-IP becomes a hostname like:
#   abcdef123456.elb.eu-west-1.amazonaws.com
```

Then:
```bash
ALB_DNS=$(kubectl -n fincorp get svc frontend -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -fsS "http://$ALB_DNS/"
curl -fsS "http://$ALB_DNS/healthz"
curl -fsS "http://$ALB_DNS/api/products"     # first call -> source:"db"
curl -fsS "http://$ALB_DNS/api/products"     # second call -> source:"cache" (Redis)
```

The NLB typically takes 2-3 minutes to become reachable after the Service is created.

## Resiliency demo

Kill a backend pod and watch the Deployment replace it:

```bash
# Capture before
kubectl -n fincorp get pods -l app=backend

# Stop one pod
POD=$(kubectl -n fincorp get pods -l app=backend -o jsonpath='{.items[0].metadata.name}')
kubectl -n fincorp delete pod "$POD"

# Watch the replacement come up (Deployment notices and spawns a new pod within seconds)
kubectl -n fincorp get pods -l app=backend -w
```

You should see the deleted pod disappear and a new one transition `Pending → ContainerCreating → Running` within ~15-30 seconds. The Service keeps routing to the remaining healthy pod throughout — no user-visible outage.

Same with the frontend:
```bash
kubectl -n fincorp delete pod -l app=frontend --field-selector status.phase=Running
```

The NLB target group health-checks at the node level (not pod level with `externalTrafficPolicy: Local`), so a brief blip is possible if all pods on one node die. In practice with replicas: 2 spread across both nodes, there's no outage.

## Updating to a new image

```bash
NEW_TAG=v2
kubectl -n fincorp set image deployment/backend  backend=$ACCOUNT_ID.dkr.ecr.eu-west-1.amazonaws.com/fincorp/backend:$NEW_TAG
kubectl -n fincorp set image deployment/frontend frontend=$ACCOUNT_ID.dkr.ecr.eu-west-1.amazonaws.com/fincorp/frontend:$NEW_TAG

# Watch the rolling deploy
kubectl -n fincorp rollout status deploy/backend
kubectl -n fincorp rollout status deploy/frontend
```

Rollback if it goes wrong:
```bash
kubectl -n fincorp rollout undo deploy/backend
```

## Teardown

```bash
kubectl delete namespace fincorp
# This removes everything in the namespace and (after ~1-2 min) the NLB created by the LoadBalancer Service.
```

The cluster itself, RDS, Redis, and the VPC are destroyed by `terraform destroy` in `infra/live-eks/`.

## Common pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| Pod stuck `ImagePullBackOff` | ACCOUNT_ID placeholder not replaced, or node IAM role missing ECR read | Re-run the `sed` from Step 2; check `AmazonEC2ContainerRegistryReadOnly` on the node role |
| Backend logs `relation "products" does not exist` | Schema not initialized in RDS | Same Postgres as ECS — run the init SQL via RDS Console / CloudShell once |
| Backend logs `connection refused` to Postgres | SG rule from cluster SG to RDS missing | Re-check `aws_security_group_rule.rds_from_cluster` in `live-eks/main.tf` |
| Backend logs scheme error from asyncpg | `POSTGRES_DSN` is empty or malformed | Verify the Secret: `kubectl -n fincorp get secret fincorp-db -o jsonpath='{.data.POSTGRES_DSN}' \| base64 -d` |
| Frontend can't resolve `backend.fincorp.svc.cluster.local` | CoreDNS not running | `kubectl -n kube-system get pods` — coredns should be Running |
| `EXTERNAL-IP` stays `<pending>` for >5 min | Node SG missing AWS LB tags, or cluster lacks LB controller config | Default in-tree controller usually just works; check `kubectl describe svc frontend` events |

## What's NOT here (intentionally)

- **HorizontalPodAutoscaler** — needs metrics-server installed in the cluster. Add later.
- **Ingress** — would need AWS Load Balancer Controller + IRSA. Using `Service type: LoadBalancer` instead.
- **NetworkPolicy** — needs a CNI that enforces it (vpc-cni doesn't by default). Skip for lab.
- **PodDisruptionBudget** — useful with cluster autoscaling; lab cluster has fixed nodes.

Add these later if/when you need them.
