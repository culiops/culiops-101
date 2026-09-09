# Adopt a Click-Ops EC2 Instance into Terraform

Companion code for the video: take an EC2 instance + Security Group that were created by
hand in the Console, let an AI agent (read-only) draft the Terraform for them, and use
`terraform plan` as the safety net that catches the agent's mistake **before** anything is
destroyed. Not a toy demo — it runs on real AWS.

The lesson: the agent does the tedious discovery and drafting; `terraform plan` decides.
A fast agent reaches for a `data.aws_ami { most_recent = true }` "latest" lookup, which
resolves to a newer AMI than the box actually runs. Because `ami` is a force-new attribute,
`plan` reports `# forces replacement` and `1 to destroy` — a running instance about to be
torn down. You fix it by pinning the real AMI id, then `plan` again until Terraform says
`No changes`.

## Layout

This lab is split into **two separate Terraform roots** so ownership never overlaps:

- **`stage/`** — the "pre-existing environment". `scripts/01-setup-stage.sh` applies it,
  then `terraform state rm`s the instance + SG so they become genuinely **unmanaged** — an
  honest stand-in for something clicked into existence in the Console. After setup, `stage/`
  only owns the VPC + IAM plumbing. Don't re-`plan`/`apply` it until cleanup.
- **`adopt/`** — "your IaC repo adopting the resource": the agent's draft config, the
  `import {}` blocks, and the `plan` → forced-replacement → fix → `plan` loop.

The trap fires whether you use a live agent (Step 1) or the pre-baked `adopt/*.tf.example`
fallback, because the safety margin lives in the **stage**: the legacy box runs a
deliberately older AMI, so any "latest" lookup resolves to a newer id and forces the replace.

## Prerequisites

- **Terraform >= 1.5** — native `import {}` blocks require it. (Tested with AWS provider
  `~> 6.0`; verify the latest at run time.)
- **AWS CLI v2**, configured with an admin-capable profile for the `apply` steps. Creating
  the VPC/EC2/IAM in `stage/` needs admin — the lab's own read-only agent profile cannot apply.
- An AWS account you control, in a region of your choice (the lab defaults to `ap-southeast-1`).
  Resources are tagged `Lab=adopt-clickops-ec2` and suffixed with a `random_id` to avoid collisions.
- (Optional) an AI coding agent for the real discovery workflow. No agent? Use the fallback.

## Steps

```bash
cp .env.example .env              # confirm your AWS profile + region

./scripts/01-setup-stage.sh       # create the "click-ops" precondition, then state-rm it
                                  # so the instance + SG are unmanaged. Prints the real ids.

# Step 1 (real workflow): give an agent read-only creds and have it discover + draft config.
./scripts/02-agent-discover.sh    # mints a short-lived read-only key for the agent user
#   Then, in a clean dir OUTSIDE this tree, prompt the agent to discover the instance
#   tagged Lab=adopt-clickops-ec2 and write Terraform for it. Watch the ami: it will
#   reach for a "latest" lookup. Don't fix it yet — let plan reveal it.

# ...or the reproducible fallback (no agent):
cd adopt
cp agent-draft.tf.example agent-draft.tf
cp import.tf.example       import.tf
cp terraform.tfvars.example terraform.tfvars
cd ../stage && terraform output   # fill terraform.tfvars with these ids
cd ../adopt

terraform init
terraform plan                    # THE MONEY STEP: # forces replacement on ami, 1 to destroy
#   Plan: 2 to import, 1 to add, 0 to change, 1 to destroy

# The fix: pin the REAL running ami (var.real_ami_id), delete the "latest" data source.
terraform plan                    # Plan: 2 to import, 0 to add, 0 to change, 0 to destroy
terraform apply                   # 2 imported, 0 added, 0 changed, 0 destroyed
terraform plan                    # No changes. Your infrastructure matches the configuration.

./cleanup.sh                      # REQUIRED — tears down adopt/ then stage/ (billable EC2)
```

## Troubleshooting

- **`plan` wants to CREATE the instance instead of importing it** — you're missing the
  `import {}` block (`cp import.tf.example import.tf`), or the ids in `terraform.tfvars`
  don't match the real ones from `stage`'s `terraform output`.
- **`plan` shows "No changes" immediately, no forced replacement** — you edited the draft to
  use `var.real_ami_id` before running the first `plan`. Put the "latest" `data.aws_ami`
  lookup back for that first plan so the trap can fire.
- **`AccessDenied` on `terraform apply`** — you're running with the read-only agent profile.
  Every `apply` (stage and adopt) needs an admin-capable profile; the agent only discovers
  and drafts.
- **`cleanup.sh` / `destroy` fails to delete the IAM user** — delete the access key you
  minted for the agent first (`aws iam delete-access-key ...`); the user has
  `force_destroy = false`.

## Cost

About **~$0.05** — one `t3.small` running for under an hour (VPC, subnet, IGW, Security
Groups, and IAM are free). Estimate based on `ap-southeast-1` on-demand pricing; it drops to
$0 once you run `./cleanup.sh`. Run the flow and clean up right after.

—
🧑‍🍳 **CuliOps** — Learn DevOps through real labs. Full walkthrough on the CuliOps YouTube channel.
