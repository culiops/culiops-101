# Auto-Deploy to ECS Fargate with GitHub Actions (OIDC, no stored keys)

Companion code for the video: automate deploys to AWS ECS Fargate with GitHub Actions —
authenticated by **OpenID Connect (OIDC)**, so there is **no long-lived AWS key** stored
anywhere. Not a toy demo: branch-scoped trust, least-privilege, immutable image tags, and
auto-rollback.

## Prerequisites

- **AWS CLI v2**, configured with rights to manage IAM / ECR / ECS / EC2 / CloudWatch Logs.
- **Docker** (only for the one-time baseline bootstrap).
- **jq**, and the **GitHub CLI** (`gh`) authenticated to a repo you can push to.
- Region defaults to `ap-southeast-1` (override with `REGION=...`). If your account has no
  default VPC, pass `SUBNET_ID=<a public subnet>`.

## How it works

The pipeline **updates an existing** Fargate service, so you first stand one up (once), then
every `git push` to `main` builds, pushes, and deploys automatically.

```bash
# --- One-time setup -------------------------------------------------------
./bootstrap/01-build-and-push.sh     # build linux/amd64 image, push v1.0.0 to ECR
./bootstrap/02-deploy-fargate.sh     # cluster + service (circuit breaker + rollback)
GH_ORG=<you> GH_REPO=<repo> ./iam/setup-oidc.sh   # OIDC provider + branch-scoped deploy role

# It prints the deploy role ARN. Set it as a repo secret:
gh secret set AWS_DEPLOY_ROLE_ARN --body '<role-arn>' --repo <you>/<repo>

# Put the workflow at YOUR repo root, then push:
mkdir -p .github/workflows && cp .github/workflows/deploy.yml <your-repo>/.github/workflows/
git commit -am "ship it" && git push origin main       # → the pipeline deploys

# --- Clean up (required — Fargate bills by the hour) ----------------------
./cleanup.sh
```

> Note: in this repo the workflow lives under a sub-folder, so it does **not** run here. Copy it
> to **your** repository's root `.github/workflows/` to activate it.

## What it teaches

- **OIDC beats stored keys** — GitHub presents a short-lived token; AWS returns short-lived
  credentials. Nothing to leak.
- **The `sub` condition is the control** — the deploy role trusts only
  `repo:<you>/<repo>:ref:refs/heads/main`; no other repo or branch can assume it.
- **Least privilege, incl. `iam:PassRole`** — the most-missed permission.
- **Pin actions to a commit SHA, not a tag** — a mutable tag is a supply-chain hole
  (tj-actions/changed-files, 2025); only a SHA is immutable. Let Dependabot bump them.
- **Immutable image tags + circuit breaker** — deploy by git SHA; a failed health check
  auto-rolls-back to the last good revision.

## Troubleshooting

- `Not authorized to perform sts:AssumeRoleWithWebIdentity` — the workflow is missing
  `permissions: id-token: write`, or the role trust `sub` doesn't match your `org/repo` + branch.
- `register-task-definition ... Unknown parameter` — `describe-task-definition` returns read-only
  fields; the workflow's `jq 'del(...)'` step strips them. Confirm it ran before render.
- No default VPC — pass `SUBNET_ID=<public subnet>` to `02-deploy-fargate.sh`, or
  `aws ec2 create-default-vpc`.

## Cost

Run the flow and clean up right after: about **~$0.02** (Fargate 0.25 vCPU / 0.5 GB + a few
ECR/CloudWatch pennies). All charges stop after `./cleanup.sh`.

—
🧑‍🍳 **CuliOps** — Learn DevOps through real labs. Full walkthrough on the CuliOps YouTube channel.
