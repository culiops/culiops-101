# Lock Down a Cloudflare Origin

Companion code for the video: you enabled Cloudflare, but your origin server still answers
anyone who calls its IP directly — straight past your WAF, rate-limit, and DDoS rules. This lab
builds that exposed origin on purpose, proves it's open in 30 seconds, then locks it in two
layers. All with Terraform. Not a toy demo.

> ⚠️ This lab **intentionally exposes a web server to the internet**, then locks it. Run it on a
> **throwaway / sandbox Cloudflare zone**, never a production domain.

## How it works

One Terraform variable, `protection`, moves the origin through three states. You re-apply with a
new value and re-run the same check each time:

| `protection`    | What Terraform sets                                       | Direct hit on the origin IP |
|-----------------|----------------------------------------------------------|-----------------------------|
| `none`          | Security group open `0.0.0.0/0`, plain nginx             | **200** — exposed           |
| `ip_allowlist`  | Security group 443 restricted to Cloudflare's IP ranges  | **timeout** — dropped       |
| `aop`           | nginx + Cloudflare require an mTLS client cert           | **403** — no client cert    |

## Prerequisites

- **Terraform ≥ 1.5**
- **AWS credentials** for a sandbox account (this creates billable resources).
- **A Cloudflare account with a throwaway zone**, its **Zone ID**, and an **API token** scoped to
  that zone with `Zone : DNS : Edit` and `Zone : Zone Settings : Edit`. (Global Authenticated
  Origin Pulls is a zone setting — it does **not** need `SSL and Certificates : Edit`.)
- `curl`.

## Steps

```bash
# 1. Credentials — AWS + the Cloudflare token (the provider reads it from the env)
export AWS_PROFILE=your-sandbox-profile          # or export AWS creds another way
export AWS_REGION=ap-southeast-1
export CLOUDFLARE_API_TOKEN=your-scoped-token

# 2. Variables
cd terraform
cp terraform.tfvars.example terraform.tfvars     # set cloudflare_zone_id + origin_hostname
terraform init

# 3. Stand up the exposed origin (the mistake), wait ~90s for cloud-init, then check
terraform apply -var protection=none
../scripts/check-origin.sh "$(terraform output -raw origin_hostname)" "$(terraform output -raw origin_ip)"
#   -> direct hit returns 200: the origin answers requests that skipped Cloudflare

# 4. Layer 1 — restrict the security group to Cloudflare's IP ranges (a pure SG change)
terraform apply -var protection=ip_allowlist
../scripts/check-origin.sh "$(terraform output -raw origin_hostname)" "$(terraform output -raw origin_ip)"
#   -> direct hit times out; traffic through Cloudflare still works

# 5. Layer 2 — Authenticated Origin Pulls (mTLS), wait ~90s for the box to rebuild
terraform apply -var protection=aop
../scripts/check-origin.sh "$(terraform output -raw origin_hostname)" "$(terraform output -raw origin_ip)"
#   -> direct hit returns 403 (no Cloudflare client cert); traffic through Cloudflare still works
```

## Teardown (required — these resources cost money)

`terraform destroy` removes everything it created. One catch: Cloudflare zone settings (SSL mode,
the Global AOP toggle) can only be *changed* by Terraform, not deleted on destroy — so if you're
in the `aop` state, flip it back off first:

```bash
cd terraform
terraform apply -var protection=none    # only if currently in the aop state
terraform destroy
```

## Troubleshooting

- **The direct check returns `000` in state `none`.** The box is still running cloud-init (give it
  ~90s), or you're not hitting the real IP. The check uses `curl -k` on purpose — the origin serves
  a self-signed cert in SSL mode Full, and an attacker probing reachability doesn't validate it.
- **The via-Cloudflare check returns `403` right after enabling `aop`.** Global AOP hasn't
  propagated yet, or the box is still rebuilding. Wait ~60s; the direct hit stays `403` while the
  legit path returns to `200`. Confirm Global AOP is on: the `tls_client_auth` zone setting = `on`.
- **`525` / `526` via Cloudflare.** SSL/TLS mode must be `Full`; the origin box may still be booting.

## Cost

Run the flow and clean up right after: about **~$0.10** (one `t3.micro` for the duration; the VPC,
Elastic IP while attached, and Cloudflare Free plan are $0). An **unattached** Elastic IP bills, so
always `terraform destroy` when you're done.

—
🧑‍🍳 **CuliOps** — Learn DevOps through real labs. Full walkthrough on the CuliOps YouTube channel.
