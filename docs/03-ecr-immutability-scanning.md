# 3 — ECR: Immutable Tags + Image Scanning

Module: `infra/modules/ecr` · Repos: `fincorp/backend`, `fincorp/frontend`

## Configuration

```hcl
resource "aws_ecr_repository" "this" {
  name                 = "fincorp/<service>"
  image_tag_mutability = "IMMUTABLE"        # tags can never be overwritten
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration     { encryption_type = "AES256" }
}
```

## Immutable artifacts — the two guarantees

1. **Every image change gets a unique tag.** The pipeline tags each build with the
   full Git commit SHA. New commit ⇒ new SHA ⇒ new tag. No two images share a tag.
2. **A tag can never change.** With `IMMUTABLE`, ECR rejects any re-push of an
   existing tag with `ImageTagAlreadyExistsException`. A tag is permanently bound
   to one image digest — what you scanned is byte-for-byte what you deploy.

> A code change forces a new tag. Re-running the pipeline on the same commit is a
> clean skip: the workflow first checks ECR for the tag (`describe-images`) and, if
> it already exists, bypasses build/scan/push. (Even without that guard, ECR would
> reject the re-push because the repo is `IMMUTABLE` — the check just turns that
> hard failure into a graceful skip.) This is the FinCorp "immutable artifact"
> requirement.

## Two layers of scanning

| Layer | Where | Blocks the build? |
|---|---|---|
| **Trivy** | in the GitHub Actions job, before push | **Yes** — `exit-code 1` on HIGH/CRITICAL |
| **ECR scan-on-push** | asynchronously, after push | No — continuous/audit visibility |

Trivy is the **gate** (the constraint: build fails on High/Critical). ECR
scan-on-push is defense-in-depth: it keeps re-evaluating already-pushed images as
new CVEs are published.

### Inspect ECR findings later

```bash
aws ecr describe-image-scan-findings \
  --repository-name fincorp/backend \
  --image-id imageTag=<git-sha> \
  --region eu-west-1
```

## Why the build fails on High/Critical

`exit-code: "1"` in the Trivy step makes the job (and therefore the whole
pipeline) fail when any HIGH or CRITICAL, fixable vulnerability is found. Because
the scan runs **before** `docker push`, a vulnerable image never enters ECR and is
never deployable.
