# Kubernetes Manifests Reference

Per-file definition of every manifest in this directory: what object(s) it creates, every notable field, and why it's shaped the way it is. For the operational walkthrough (apply order, troubleshooting), see [README.md](README.md).

## File map

| File | Kind(s) | Purpose |
|---|---|---|
| [00-namespace.yaml](00-namespace.yaml) | Namespace | Logical container for everything below |
| [01-configmap.yaml](01-configmap.yaml) | ConfigMap | Non-secret env vars (backend URL, log level) |
| [02-backend-deployment.yaml](02-backend-deployment.yaml) | ServiceAccount + Deployment | Runs the FastAPI backend (2 replicas) |
| [03-backend-service.yaml](03-backend-service.yaml) | Service (ClusterIP) | In-cluster DNS for the backend |
| [04-frontend-deployment.yaml](04-frontend-deployment.yaml) | ServiceAccount + Deployment | Runs the Node/Express frontend (2 replicas) |
| [05-frontend-service.yaml](05-frontend-service.yaml) | Service (ClusterIP) | In-cluster DNS for the frontend |
| [06-ingress.yaml](06-ingress.yaml) | Ingress | Public entry point — becomes an ALB |

One resource is **NOT** in this directory because it has secret content that must not be committed:

- `Secret: fincorp-db` — `POSTGRES_DSN` and `REDIS_URL`. Created at deploy time by [../scripts/deploy-eks-k8s.sh](../scripts/deploy-eks-k8s.sh), which reads AWS Secrets Manager and assembles the strings.

---

## 00-namespace.yaml — Namespace `fincorp`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: fincorp
  labels:
    name: fincorp
    app.kubernetes.io/part-of: fincorp
```

**What it is.** A namespace is a logical partition inside the cluster. Every other resource in this stack lives in `fincorp`.

**Why each field.**
- `metadata.name: fincorp` — referenced by every other manifest's `metadata.namespace`. If you rename the namespace you must update every other file.
- `labels.app.kubernetes.io/part-of: fincorp` — a Kubernetes-recommended label that lets tools group resources by application (`kubectl get all -l app.kubernetes.io/part-of=fincorp --all-namespaces`).

**What it does for you.**
- Lets `kubectl -n fincorp ...` scope every command to just this app.
- One `kubectl delete namespace fincorp` cleans up the whole app at once.
- Future-friendly: RBAC, NetworkPolicies, and ResourceQuotas can all be scoped to this namespace.

**What it does NOT do.** It's not a security boundary by itself. Pods in different namespaces can still reach each other unless you add NetworkPolicies.

---

## 01-configmap.yaml — ConfigMap `fincorp-app`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: fincorp-app
  namespace: fincorp
data:
  BACKEND_URL: "http://backend.fincorp.svc.cluster.local:8000"
  LOG_LEVEL:   "info"
```

**What it is.** A ConfigMap is a key-value store for non-secret configuration. Mount it into a pod as environment variables or as files.

**Why each key.**
- `BACKEND_URL` — fully-qualified in-cluster DNS for the backend Service. Form: `<service>.<namespace>.svc.cluster.local`. The frontend Deployment reads this and uses it to call the backend.
- `LOG_LEVEL` — tweakable without rebuilding the image. Change with `kubectl edit cm fincorp-app` + rollout restart.

**How pods consume it.** [04-frontend-deployment.yaml](04-frontend-deployment.yaml) uses `envFrom.configMapRef.name: fincorp-app`, which spreads every key into the container's env. So the frontend sees `BACKEND_URL` and `LOG_LEVEL` as environment variables.

**Trap.** Changing a ConfigMap does **not** restart pods automatically. Running pods keep the old value. To pick up changes:
```bash
kubectl -n fincorp rollout restart deployment/frontend
```

**Why not put `BACKEND_URL` directly in the Deployment manifest?** Because then changing it requires editing the manifest and re-deploying. With a ConfigMap, ops can `kubectl edit cm` + `rollout restart`. Cleaner separation of code and config.

---

## 02-backend-deployment.yaml — ServiceAccount + Deployment `backend`

This file is two objects separated by `---`:

### Part 1: ServiceAccount `backend`

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: backend
  namespace: fincorp
```

**What it is.** An identity inside the cluster. Every pod runs as some ServiceAccount (defaults to `default` if not specified). This pod runs as `backend`.

**Why have one at all?** Two reasons:
1. **Audit clarity** — pod-level identity shows up in API audit logs.
2. **Future IRSA** — if the backend ever needs AWS API access (S3 reads, etc.), annotate this ServiceAccount with an IAM role ARN. The IRSA plumbing then "just works" without changing the pod template.

Right now this SA has no annotations and no special permissions. It exists as a stub.

### Part 2: Deployment `backend`

The bulk of the file. Owns a ReplicaSet that owns 2 backend pods.

**Replica strategy:**
```yaml
replicas: 2
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 0
    maxSurge: 1
```
During a rolling update, never drop below 2 healthy pods. K8s creates a 3rd pod (the new one), waits for it Ready, then deletes one old pod. Zero-downtime even on a 2-replica setup.

**Selector / template labels:**
```yaml
selector:
  matchLabels:
    app: backend
template:
  metadata:
    labels:
      app: backend
```
The Service ([03-backend-service.yaml](03-backend-service.yaml)) finds pods via the **same** `app: backend` label. Selectors and template labels must match or the Deployment errors at creation.

**Container image:**
```yaml
image: 497924967546.dkr.ecr.eu-west-1.amazonaws.com/fincorp/backend:backend-20260517T162305Z-90273d65
imagePullPolicy: IfNotPresent
```
- Tag is **immutable** (timestamp + git-sha suffix), produced by `scripts/push-ecr.sh`. ECR rejects re-pushing the same tag.
- `IfNotPresent` = don't re-pull if the node already has this exact tag cached. Faster pod starts. Safe because the tag is immutable.

**Port declaration:**
```yaml
ports:
  - name: http
    containerPort: 8000
```
Doesn't open a port by itself (`containerPort` is informational). But the **name** `http` is what the Service's `targetPort: http` references — that's the link.

**Environment variables from Secret:**
```yaml
env:
  - name: POSTGRES_DSN
    valueFrom:
      secretKeyRef:
        name: fincorp-db
        key: POSTGRES_DSN
  - name: REDIS_URL
    valueFrom:
      secretKeyRef:
        name: fincorp-db
        key: REDIS_URL
```
The `fincorp-db` Secret is created at deploy time, not from a manifest. If it's missing the pod fails with `CreateContainerConfigError`.

**Resource requests + limits:**
```yaml
resources:
  requests: { cpu: 100m, memory: 256Mi }
  limits:   { cpu: 500m, memory: 512Mi }
```
- `requests` = guaranteed allocation. The scheduler uses these to decide which node can host the pod.
- `limits` = hard cap. CPU over the limit → throttled. Memory over the limit → OOM-killed.

**Probes:**
```yaml
livenessProbe:
  httpGet: { path: /healthz, port: http }
  initialDelaySeconds: 30
  periodSeconds: 30
readinessProbe:
  httpGet: { path: /readyz, port: http }
  initialDelaySeconds: 10
  periodSeconds: 10
```
- **liveness** fails → kubelet kills + restarts the container. For "process is wedged."
- **readiness** fails → pod is removed from Service endpoints (no traffic) but **not** killed. For "process is up but not yet able to serve" (warming caches, waiting on a downstream).

`initialDelaySeconds: 30` on liveness gives FastAPI + the Postgres connection pool time to start before the kill-counter starts.

**Security context:**
```yaml
securityContext:
  allowPrivilegeEscalation: false
  runAsNonRoot: true
  runAsUser: 1001
  capabilities: { drop: ["ALL"] }
```
Drops all Linux capabilities, runs as UID 1001 (non-root). Matches the Dockerfile's `USER 1001`. If you set `runAsNonRoot: true` and the image actually runs as root, the pod fails to start — defense in depth.

---

## 03-backend-service.yaml — Service `backend` (ClusterIP)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: fincorp
spec:
  type: ClusterIP
  selector:
    app: backend
  ports:
    - name: http
      port: 8000
      targetPort: 8000
      protocol: TCP
```

**What it is.** A stable virtual IP + DNS name that load-balances across all pods matching the selector.

**Why `ClusterIP` (not `LoadBalancer` or `NodePort`).** The backend is internal-only. The frontend is the only thing that calls it. No need to expose it outside the cluster.

**Key fields.**
- `selector.app: backend` — picks up every pod with this label. Must match the Deployment's `template.metadata.labels`.
- `port: 8000` — what other in-cluster clients connect to.
- `targetPort: 8000` — where the traffic lands in the pod. (Could also be `http` to reference the named port — same effect.)

**How clients reach it.** The Service gets:
- A **ClusterIP** allocated from the service CIDR (e.g., `10.100.45.12`).
- A **DNS record** in CoreDNS: `backend.fincorp.svc.cluster.local → ClusterIP`.

The frontend's `BACKEND_URL` ConfigMap value uses that FQDN. Request path:
```
frontend pod → DNS lookup → ClusterIP:8000 → iptables (DNAT) → one of the backend pod IPs:8000
```

No proxy server in the middle. kube-proxy programs iptables rules on every node so the DNAT happens in kernel.

**How pod IPs stay in sync.** The Endpoint controller watches pods matching the selector and writes their IPs into an `EndpointSlice`. kube-proxy watches EndpointSlices and updates iptables. Pod dies → removed from slice → iptables updated within seconds.

---

## 04-frontend-deployment.yaml — ServiceAccount + Deployment `frontend`

Same structural shape as the backend Deployment. Three differences worth calling out:

| Aspect | Backend | Frontend |
|---|---|---|
| `containerPort` | 8000 (FastAPI) | 3000 (Node) |
| Image | `fincorp/backend:...` | `fincorp/frontend:...` |
| Env source | `secretKeyRef` to `fincorp-db` | `envFrom.configMapRef` to `fincorp-app` |
| Extra `env` | (just the secrets) | `PORT: "3000"` — Node convention |

**Why the frontend uses ConfigMap, not Secret.** It only needs `BACKEND_URL` and `LOG_LEVEL`. Neither is a secret. Putting non-secrets in a Secret would just obscure where things come from.

**Why a separate `PORT` env var when `containerPort: 3000` is already declared.** `containerPort` is **informational** to Kubernetes — it does NOT make the Node process listen on 3000. The Node code reads `process.env.PORT` to know what to bind. Declaring `PORT: "3000"` is what actually makes the process listen there.

The ServiceAccount + securityContext + probe blocks mirror the backend exactly.

---

## 05-frontend-service.yaml — Service `frontend` (ClusterIP)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: frontend
  namespace: fincorp
spec:
  type: ClusterIP
  selector:
    app: frontend
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
```

**Important detail.** This is `ClusterIP`, NOT `LoadBalancer`. Public exposure is handled by the **Ingress** in [06-ingress.yaml](06-ingress.yaml), which creates an ALB *in front of* this Service.

**Why not `LoadBalancer` directly?**
- `type: LoadBalancer` creates a separate AWS NLB per Service. Expensive if you have many Services.
- Ingress consolidates multiple Services behind one ALB, supports path-based routing, TLS termination, custom health checks, WAF integration — features `type: LoadBalancer` doesn't offer.
- The AWS Load Balancer Controller reads Ingress objects and creates ALBs accordingly.

**`targetPort: http`** — references the named port `http` declared in the Deployment's container spec (which is `containerPort: 3000`). Using the name instead of the number keeps the Service decoupled from the container's port number; you could change the container to listen on 8080 by editing the Deployment alone.

The Service exposes port **80** internally because that's what the Ingress's `backend.service.port.number` will reference.

---

## 06-ingress.yaml — Ingress `fincorp` (becomes the public ALB)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: fincorp
  namespace: fincorp
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
    alb.ingress.kubernetes.io/healthcheck-path: /healthz
    alb.ingress.kubernetes.io/healthcheck-interval-seconds: "15"
    alb.ingress.kubernetes.io/healthy-threshold-count: "2"
    alb.ingress.kubernetes.io/unhealthy-threshold-count: "3"
    alb.ingress.kubernetes.io/success-codes: "200"
    alb.ingress.kubernetes.io/group.name: fincorp
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend
                port:
                  number: 80
```

**What it is.** An Ingress is a Kubernetes manifest that **declares** routing rules. It does not by itself create any AWS resource. The **AWS Load Balancer Controller** (a separate component running in `kube-system`, installed via Helm by [../scripts/deploy-eks-k8s.sh](../scripts/deploy-eks-k8s.sh)) watches Ingress objects and creates a real ALB to match.

**`ingressClassName: alb`** — tells K8s "this Ingress is for the ALB controller." Without it, the Ingress is ignored.

### Annotation walkthrough

| Annotation | What it does |
|---|---|
| `scheme: internet-facing` | Public ALB. Use `internal` for a private one. |
| `target-type: ip` | Register pod IPs directly in the target group (not node IPs + NodePort). Lower latency, one less hop. |
| `listen-ports: '[{"HTTP": 80}]'` | Open ALB listener on port 80, HTTP only. Add `{"HTTPS": 443}` once you have an ACM cert. |
| `healthcheck-path: /healthz` | ALB-side health check. Independent of the K8s `readinessProbe`. |
| `healthcheck-interval-seconds: 15` | How often the ALB probes each target. |
| `healthy-threshold-count: 2` | 2 consecutive successes = healthy. |
| `unhealthy-threshold-count: 3` | 3 consecutive failures = remove from rotation. |
| `success-codes: 200` | Only 200 = healthy. Default is `200-399`; tightening avoids treating 3xx redirects as healthy. |
| `group.name: fincorp` | Consolidate all Ingresses with this group name onto one shared ALB. Adding a second Ingress with the same group adds a listener rule instead of a new ALB. |

### Routing rule

```yaml
rules:
  - http:
      paths:
        - path: /
          pathType: Prefix
          backend:
            service:
              name: frontend
              port:
                number: 80
```

Everything (`/` prefix) routes to the `frontend` Service on port 80. The frontend's Express app proxies `/api/*` calls in-cluster to the backend Service, so the ALB never needs a direct route to the backend.

**Alternative shape (if you wanted ALB → backend directly):**
```yaml
- path: /api
  pathType: Prefix
  backend:
    service:
      name: backend
      port:
        number: 8000
- path: /
  pathType: Prefix
  backend:
    service:
      name: frontend
      port:
        number: 80
```
We don't do this here because the frontend already proxies `/api/*` server-side. Keeps the public surface small (one Service exposed).

### What the LB Controller does when this manifest is applied

1. Calls AWS ELBv2 to create an ALB in the public subnets (discovered via the `kubernetes.io/role/elb` subnet tag).
2. Creates an ALB security group, allows `0.0.0.0/0:80` inbound.
3. Adds an ingress rule on the **cluster security group** allowing the ALB SG inbound on the pod's container port (3000).
4. Creates a target group (target-type IP, health check `/healthz`).
5. Registers the current frontend pod IPs into the target group, sourced from the Service's EndpointSlice.
6. Creates a listener on port 80, forwarding to the target group.
7. Writes the ALB DNS name back into the Ingress's `status.loadBalancer.ingress[0].hostname` — that's what `kubectl get ingress` shows as `ADDRESS`.

Total time: ~60-90 seconds from `kubectl apply` to "ALB is ready."

---

## Cross-references between manifests

The manifests are not independent — they reference each other by name. If you rename one thing you must update everywhere it's referenced.

```
Namespace fincorp
   └── ConfigMap fincorp-app
   │     └── data.BACKEND_URL points to "backend.fincorp.svc.cluster.local"
   │
   ├── ServiceAccount backend ←─── used by Deployment backend
   ├── Deployment backend (label app=backend, container port name "http")
   │     └── env from Secret fincorp-db (POSTGRES_DSN, REDIS_URL)
   ├── Service backend (selector app=backend, targetPort 8000)
   │
   ├── ServiceAccount frontend ←─── used by Deployment frontend
   ├── Deployment frontend (label app=frontend, container port name "http")
   │     └── envFrom ConfigMap fincorp-app
   ├── Service frontend (selector app=frontend, targetPort http)
   │
   └── Ingress fincorp (rule: / → frontend:80)
         └── handled by ingressClass "alb" → AWS Load Balancer Controller → ALB
```

## Apply order

Strictly required dependency order:

1. `00-namespace.yaml` — must exist before anything in it can be created.
2. `01-configmap.yaml` — must exist before the frontend Deployment, which `envFrom`s it.
3. **The `fincorp-db` Secret** — created out-of-band by the deploy script. Must exist before the backend Deployment, which `secretKeyRef`s it.
4. `02-backend-deployment.yaml` and `03-backend-service.yaml` — order within these two doesn't strictly matter (the Service just has no endpoints until the Deployment's pods become Ready).
5. `04-frontend-deployment.yaml` and `05-frontend-service.yaml` — same.
6. `06-ingress.yaml` — needs the frontend Service to exist (it references `frontend` by name).

In practice you can just `kubectl apply -f k8s/` and Kubernetes will retry until everything settles. The "right" order above is what avoids transient errors in the logs.
