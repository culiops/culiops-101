# Lock Down a Cloudflare Origin

Companion code for the video **"You enabled Cloudflare. Your origin is still exposed."**
You stand up a real origin behind Cloudflare, prove it's reachable directly (bypassing every
Cloudflare rule), then lock it **by hand in two layers** and watch a 30-second check flip from
exposed → locked. Not a toy demo.

> Terraform only stands up the exposed origin (the "stage"). Everything else — Cloudflare, and the
> two locks — you do by hand, because *watching each lock happen* is the point.

> ⚠️ This lab **intentionally exposes a web server to the whole internet**, then locks it. Run it on
> a **throwaway / sandbox Cloudflare zone**, never a production domain.

## Prerequisites

- Terraform ≥ 1.5, AWS account + **AWS CLI**, an **EC2 key pair** (for the Layer 2 SSH step)
- A Cloudflare account with a **throwaway zone**, its **Zone ID**, and an **API token** scoped to
  that zone with `DNS : Edit` + `Zone Settings : Edit` (Global AOP is a zone setting — it does not
  need `SSL and Certificates : Edit`)
- `curl` and `ssh`

## Setup — stand up the exposed origin

```bash
cp .env.example .env          # AWS creds + CLOUDFLARE_API_TOKEN + CLOUDFLARE_ZONE_ID + ORIGIN_HOSTNAME
source .env
cd terraform
cp terraform.tfvars.example terraform.tfvars   # set key_name + ssh_ingress_cidr (your IP/32)
terraform init && terraform apply              # ~1 min, then ~90s for cloud-init to install nginx

export SG_ID=$(terraform output -raw security_group_id)
export ORIGIN_IP=$(terraform output -raw origin_ip)
cd ..
```

## Steps

**1. Put Cloudflare in front (the orange cloud)** — create the proxied A record:
```bash
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json" \
  --data "{\"type\":\"A\",\"name\":\"$ORIGIN_HOSTNAME\",\"content\":\"$ORIGIN_IP\",\"proxied\":true,\"ttl\":1}"
```

**2. Prove it's exposed** — direct hit returns 200, bypassing Cloudflare:
```bash
./scripts/check-origin.sh "$ORIGIN_HOSTNAME" "$ORIGIN_IP"   # direct 200 EXPOSED, via-CF 200
```

**3. Layer 1 — accept only Cloudflare's IP ranges** (network lock):
```bash
for cidr in $(curl -s https://www.cloudflare.com/ips-v4); do
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 443 --cidr "$cidr" >/dev/null
done
aws ec2 revoke-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 443 --cidr 0.0.0.0/0
./scripts/check-origin.sh "$ORIGIN_HOSTNAME" "$ORIGIN_IP"   # direct times out, via-CF 200
```
Weakness: Cloudflare's IP list changes — automate the refresh, or move to Layer 2.

**4. Layer 2 — Authenticated Origin Pulls (mTLS)** (IP-independent lock). Reopen 443, enable mTLS on
nginx over SSH, then turn AOP on at Cloudflare:
```bash
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 443 --cidr 0.0.0.0/0

ssh -i ~/.ssh/<your-key>.pem ubuntu@"$ORIGIN_IP"
# on the box:
sudo curl -fsS -o /etc/nginx/certs/cloudflare-origin-pull-ca.pem \
  https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem
sudo tee /etc/nginx/mtls/aop.conf >/dev/null <<'CONF'
ssl_client_certificate /etc/nginx/certs/cloudflare-origin-pull-ca.pem;
ssl_verify_client      optional;
if ($ssl_client_verify != SUCCESS) { return 403; }
CONF
sudo nginx -t && sudo systemctl reload nginx && exit

# Cloudflare side — SSL mode Full (AOP precondition), then AOP on:
curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/settings/ssl" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json" --data '{"value":"full"}'
curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/settings/tls_client_auth" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json" --data '{"value":"on"}'

./scripts/check-origin.sh "$ORIGIN_HOSTNAME" "$ORIGIN_IP"   # direct 403 LOCKED, via-CF 200
```

**Cleanup — required** (tears down the AWS stage *and* reverses the Cloudflare changes):
```bash
source .env
./cleanup.sh            # AOP off, delete the A record, SSL back to Flexible, then terraform destroy
```

## Troubleshooting

- **Direct check returns `000` before any lock:** cloud-init isn't done — wait ~90s and confirm you're
  hitting the Elastic IP (`terraform output origin_ip`).
- **The via-Cloudflare check returns `403` right after enabling AOP:** Global AOP hasn't propagated
  yet — wait ~60s; the direct hit stays `403` while via-Cloudflare returns to `200`.
- **via-Cloudflare returns `525`/`526`:** SSL/TLS mode isn't **Full**, or the mTLS snippet has a typo
  (run `sudo nginx -t` on the box).

## Cost

About **~$0.10** — one `t3.micro` for an hour; the Elastic IP is free while attached, Cloudflare
features are on the Free plan. Run `./cleanup.sh` right after to release the EIP and drop to $0.

## Notes

- **Global** AOP uses a certificate shared across all Cloudflare accounts — it proves traffic came
  from *Cloudflare's network*, not specifically your account. For stronger isolation, use zone-level /
  per-hostname AOP with your own certificate.
- This locks the front door; it does not fix vulnerabilities inside your app — it forces every
  request back through Cloudflare, where your WAF and rate-limit actually apply.

—
🧑‍🍳 **CuliOps** — Learn DevOps through real labs. Full walkthrough on the CuliOps YouTube channel.
