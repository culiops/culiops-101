# Lock Down a Cloudflare Origin

Companion code for the video **"You enabled Cloudflare. Your origin is still exposed."**
(Series: *Cloudflare as a gate* — episode 1 of 2.)

You put Cloudflare in front of your server, turned on the orange cloud, and assumed brute-force was
handled. It isn't: your origin still answers anyone who hits its IP directly — straight past your
WAF, rate-limit, and DDoS rules. This lab stands up that exposed origin with Terraform, proves it's
wide open in 30 seconds, then locks it by hand in two layers so you watch each lock take.

> ⚠️ **This lab intentionally exposes a web server to the whole internet, then locks it.**
> Run it on a **throwaway / sandbox Cloudflare zone** — never a production domain.

## Prerequisites

- **Terraform ≥ 1.5**
- **AWS CLI** with credentials for a sandbox account. The credentials must be able to **create an
  IAM role** (the origin gets an SSM instance profile), so use an admin-ish profile.
- **The Session Manager plugin** for the AWS CLI — admin access to the box is over **AWS SSM Session
  Manager**, not SSH (no key pair, no open port 22). Check with `session-manager-plugin --version`.
- **A Cloudflare account with a throwaway zone**, its **Zone ID**, and an **API token** scoped to
  that zone with `Zone : DNS : Edit` and `Zone : Zone Settings : Edit`.
- `curl`.

## Setup

Set the environment the by-hand steps use:

```bash
export AWS_PROFILE=your-sandbox-profile
export AWS_REGION=ap-southeast-1
export CLOUDFLARE_API_TOKEN=your-token
export CLOUDFLARE_ZONE_ID=your-zone-id
export ORIGIN_HOSTNAME=cf-origin.example.com   # a subdomain of your throwaway zone
```

Stand up the exposed origin (no variables to set — admin access is SSM, so there is no key pair or
SSH CIDR):

```bash
cd terraform
terraform init
terraform apply        # ~1 min; then give cloud-init ~90s to install nginx + register the SSM agent

export SG_ID=$(terraform output -raw security_group_id)
export ORIGIN_IP=$(terraform output -raw origin_ip)
export INSTANCE_ID=$(terraform output -raw instance_id)
cd ..
```

## Steps

### 1. Put Cloudflare in front, and set SSL/TLS mode to Full

Create the proxied `A` record, then set the encryption mode to **Full**:

```bash
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json" \
  --data "{\"type\":\"A\",\"name\":\"$ORIGIN_HOSTNAME\",\"content\":\"$ORIGIN_IP\",\"proxied\":true,\"ttl\":1}"

curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/settings/ssl" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json" \
  --data '{"value":"full"}'
```

**Full matters:** it makes Cloudflare reach the origin over **HTTPS (443)** — the port the origin
serves on, the port Layer 1 allowlists, and the port Authenticated Origin Pulls runs on. Flexible
would make Cloudflare use HTTP (80), and Layer 1 (which locks 443) would then break the legit path
with a `522`. Use **Full**, not Full (strict) — the origin cert is self-signed.

### 2. Prove the origin is exposed

```bash
./scripts/check-origin.sh "$ORIGIN_HOSTNAME" "$ORIGIN_IP"
# Direct hit -> 200 (EXPOSED), via Cloudflare -> 200
```

### 3. Understand that the IP always leaks

Hiding the origin IP is not a fix — DNS history, Certificate Transparency logs, MX records, and
Shodan/Censys all leak it. The fix is to make the origin **refuse** anything that didn't come from
Cloudflare.

### 4. Layer 1 — only accept Cloudflare's IP ranges

```bash
for cidr in $(curl -s https://www.cloudflare.com/ips-v4); do
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --protocol tcp --port 443 --cidr "$cidr" >/dev/null && echo "allowed $cidr"
done
aws ec2 revoke-security-group-ingress --group-id "$SG_ID" \
  --protocol tcp --port 443 --cidr 0.0.0.0/0

./scripts/check-origin.sh "$ORIGIN_HOSTNAME" "$ORIGIN_IP"
# Direct hit -> timeout, via Cloudflare -> 200
```

An IP allowlist works but rots — Cloudflare adds ranges over time, so automate the refresh or move
to Layer 2, which doesn't depend on IPs at all.

### 5. Layer 2 — Authenticated Origin Pulls (mTLS)

Reopen 443 so a direct hit reaches nginx (and is refused at TLS instead of timing out), then enable
mTLS on the box over an SSM shell:

```bash
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
  --protocol tcp --port 443 --cidr 0.0.0.0/0

aws ssm start-session --target "$INSTANCE_ID"
# --- on the box (SSM lands you as ssm-user; sudo works) ---
sudo curl -fsS -o /etc/nginx/certs/cloudflare-origin-pull-ca.pem \
  https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem
sudo tee /etc/nginx/mtls/aop.conf >/dev/null <<'CONF'
ssl_client_certificate /etc/nginx/certs/cloudflare-origin-pull-ca.pem;
ssl_verify_client      optional;
if ($ssl_client_verify != SUCCESS) { return 403; }
CONF
sudo nginx -t && sudo systemctl reload nginx
exit
```

Then turn on Global Authenticated Origin Pulls at Cloudflare (SSL mode is already Full from Step 1):

```bash
curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/settings/tls_client_auth" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json" \
  --data '{"value":"on"}'

./scripts/check-origin.sh "$ORIGIN_HOSTNAME" "$ORIGIN_IP"
# Direct hit -> 403 (no client cert), via Cloudflare -> 200
```

## Cleanup

```bash
./cleanup.sh      # turns AOP off, deletes the A record, resets SSL mode, then terraform destroy
```

## Troubleshooting

- **Via-Cloudflare returns `522` after Layer 1** — the SSL/TLS mode is Flexible, so Cloudflare is
  trying the origin over port 80 while Layer 1 locked 443. Set the mode to **Full** (Step 1). This
  is a connection issue, not an SSL one.
- **Via-Cloudflare returns `526`** — the mode is Full (strict), which rejects the self-signed origin
  cert. Use **Full**, not Full (strict).
- **`aws ssm start-session` fails with `TargetNotConnected`** — the SSM agent needs ~1–2 minutes
  after boot to register. Wait and retry; confirm with
  `aws ssm describe-instance-information`.

## Cost

About **~$0.10** — one `t3.micro` for an hour; everything else is free-tier. Run the flow and clean
up right after with `./cleanup.sh`; all costs drop to $0 once the origin and its Elastic IP are gone.

—
🧑‍🍳 **CuliOps** — Learn DevOps through real labs. Full walkthrough on the CuliOps YouTube channel.
