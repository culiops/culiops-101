# Docker → ECR → ECS Fargate

Companion code for the video: take a container from `docker run` on your laptop → push it
to **Amazon ECR** → run it for real on **AWS ECS Fargate**, reachable over the internet.
Not a toy demo — it does the steps production actually needs.

## Prerequisites

- **Docker** running (to build the image).
- **AWS CLI v2** configured (`aws configure`; verify with `aws sts get-caller-identity`).
- An AWS account with **ECR / ECS / IAM / EC2 / CloudWatch Logs** permissions.
- No local Node.js needed — the image is built inside Docker (Node 24 LTS).

## Steps

```bash
# 1. Build for the right platform (linux/amd64) and push to ECR
./01-build-and-push.sh

# 2. Create IAM roles, cluster, task definition, service → prints a public URL
./02-deploy-fargate.sh

# Open the URL it prints:  http://<public-ip>:3000/
# Tail the logs:
aws logs tail /ecs/hello-fargate --follow --region ap-southeast-1

# 3. CLEAN UP (required — Fargate bills for as long as the task runs)
./cleanup.sh
```

Override config via environment variables, e.g.
`REGION=ap-southeast-1 IMAGE_TAG=v1.0.1 ./01-build-and-push.sh`.

## Troubleshooting

- **`No default VPC in ap-southeast-1`** — your account has no default VPC (common on
  hardened / org-managed accounts). Create one with
  `aws ec2 create-default-vpc --region ap-southeast-1`, or point the deploy at any existing
  public subnet:
  ```bash
  SUBNET_ID=subnet-xxxxxxxx ./02-deploy-fargate.sh
  ```
- **Deploy fails and prints `stoppedReason`** — the script tells you exactly why the task
  died (CPU architecture mismatch, `CannotPullContainerError`, ...). Fix the cause and
  re-run — the script is idempotent and safe to re-run after `./cleanup.sh`.
- **`./cleanup.sh` says a security group is left over** — an ENI is still draining; wait
  ~30s and run `./cleanup.sh` again.

## Cost

Run the whole flow and `cleanup.sh` right after: about **~$0.01**. Fargate bills for
running time, so **don't forget to clean up**.

—
🧑‍🍳 **CuliOps** — Learn DevOps through real labs. Full walkthrough on the CuliOps YouTube channel.
