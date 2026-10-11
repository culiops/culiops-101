# Cloudflare SSL Modes: from a Redirect Loop to Full (strict)

Companion code for the video **"You turned on HTTPS through Cloudflare. Why is the site stuck in a
redirect loop?"**

You put a new site behind Cloudflare, picked "Flexible" because it gave you a green padlock in ten
seconds, and now the browser says `ERR_TOO_MANY_REDIRECTS`. Or worse: the site works, the padlock is
green, and the leg between Cloudflare and your server is plain HTTP. This lab builds that exact
mistake with Terraform, then has you fix it **by hand**, one SSL mode at a time —
Flexible → Full → Full (strict) → a `526` → a free Cloudflare Origin CA certificate — so you see
what each mode actually does.

> ⚠️ **SSL mode is a ZONE-WIDE Cloudflare setting.** While you run this lab, *every* hostname in the
> zone is affected by the mode you pick. Run it on a **throwaway / sandbox zone**, never a
> production domain. The defaults point at our own lab zone (`culilab.dev` / `app.culilab.dev`) —
> set `LAB_ZONE_NAME`, `CLOUDFLARE_ZONE_ID` and `ORIGIN_HOSTNAME` in `.env` to yours. The scripts and
> Terraform refuse to run against any other zone (see [Safety guard](#safety-guard)). Example
> output below shows `app.culilab.dev`; you will see your own hostname.

| | |
|---|---|
| **Time** | ~30 min |
| **Cost** | ~$0.01 on AWS (about $0.02/hour while it runs); Cloudflare Free plan = $0 |
| **Versions** | Terraform ≥ 1.5 · AWS provider `~> 6.0` · Cloudflare provider `~> 5.0` · Ubuntu 24.04 LTS + stock nginx |

---

## How this lab works

**Terraform builds the stage, and the stage is wrong on purpose:**

- an EC2 origin running nginx that **forces HTTPS** (port 80 → `301` to `https://$host$request_uri`) and serves port 443 with a **self-signed certificate**,
- a **proxied** (orange cloud) DNS record for it in your lab zone.

Everything that *teaches* you do **by hand**. Terraform could set the SSL mode through an API, but
then you would see the result change and never the action — and the action is the whole lesson.

| You do (by hand)                              | Where                       | `https://app.culilab.dev/` returns |
|-----------------------------------------------|-----------------------------|------------------------------------|
| Start state: Flexible + force-HTTPS origin    | (Terraform stage)           | **301 → same URL, forever** (the loop) |
| Switch SSL mode to **Full**                   | Cloudflare dashboard        | **200** — encrypted, cert unchecked |
| Switch SSL mode to **Full (strict)**          | Cloudflare dashboard        | **526** — Invalid SSL certificate  |
| Create an Origin CA cert, install it, reload  | Dashboard + SSM shell       | **200** — encrypted **and** verified |

**The design trick that keeps the fix honest:** cloud-init generates the *self-signed* certificate
at `/etc/nginx/certs/origin-ca.pem` and `/etc/nginx/certs/origin-ca.key` — the same two paths the
final nginx config uses. So the fix is literally "overwrite these two files with the Origin CA pair
and reload nginx". No config edit, no new paths. The nginx block that was already there:

```nginx
server {
    listen 443 ssl;
    server_name app.culilab.dev;
    ssl_certificate     /etc/nginx/certs/origin-ca.pem;
    ssl_certificate_key /etc/nginx/certs/origin-ca.key;
}
```

(The real file also has a `location /` that returns a one-line response, and a port-80 block that
does the `301`.) Teardown is `./cleanup.sh`: it restores the zone-wide SSL settings you changed by
hand, then runs `terraform destroy`.

---

## Prerequisites

- [ ] **Terraform ≥ 1.5**
  ```bash
  terraform version
  # Expected: Terraform v1.x.x
  ```
- [ ] **AWS CLI + credentials** for a sandbox account (this creates billable resources). The
      credentials must be allowed to **create an IAM role** — the origin needs an SSM instance
      profile — so use an admin-ish profile, not a read-only one.
  ```bash
  aws sts get-caller-identity --profile <your-sandbox-profile>   # or: export AWS_PROFILE=... first
  # Expected: your sandbox account id
  # (Setup sources .env, which sets AWS_PROFILE for the rest of the lab - before that, pass it yourself.)
  ```
- [ ] **The Session Manager plugin** for the AWS CLI (you open a shell on the origin over SSM — no SSH, no key pair, no open port 22).
  ```bash
  session-manager-plugin --version
  # If missing: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html
  ```
- [ ] **A Cloudflare account with a throwaway zone** (Free plan is fine) and its **Zone ID** (zone Overview → right sidebar).
- [ ] **A Cloudflare API token** scoped to that zone with:
  - `Zone : DNS : Edit` — Terraform creates the proxied record
  - `Zone : Zone : Read` — the safety guard looks the zone's name up
  - `Zone : Zone Settings : Edit` — `prepare-zone.sh` / `cleanup.sh` read and restore the SSL mode

  > It does **not** need `SSL and Certificates : Edit`. Changing the SSL mode and creating the
  > Origin CA certificate are done by hand in the dashboard — that is the lesson.
- [ ] **A Cloudflare dashboard login with API Access enabled** (account → Members). The dashboard needs it to create Origin CA certificates.
- [ ] `curl` and `openssl` (any recent version).

---

## Setup — build the wrong-on-purpose stage

```bash
cd culiops-101/2026-09-cloudflare-ssl-modes

# 1. Environment: AWS creds + the Cloudflare token / zone the scripts and Terraform use
cp .env.example .env
#    edit .env: AWS_PROFILE, CLOUDFLARE_API_TOKEN, CLOUDFLARE_ZONE_ID
#    (LAB_ZONE_NAME and ORIGIN_HOSTNAME default to culilab.dev / app.culilab.dev - change both for your own zone)
source .env
```

**Remember the zone's current SSL settings, then set the starting state.** SSL mode is zone-wide,
so this script first saves your zone's current `ssl` and `ssl_automatic_mode` to
`.zone-ssl-before.env` (that is what `cleanup.sh` restores), then sets **Custom SSL/TLS +
Flexible**. New zones default to *Automatic SSL/TLS*, where Cloudflare picks the mode for you — you
have to be on Custom to choose one yourself.

```bash
./scripts/prepare-zone.sh
```

**Expected:**
```
✔ zone guard passed: culilab.dev (<zone id>)
✔ saved original state to .zone-ssl-before.env:  ssl=<before>  ssl_automatic_mode=<before>
✔ ssl_automatic_mode -> custom        # (or "already custom")
✔ ssl -> flexible                     # (or "already flexible")
Zone is now:  ssl=flexible  ssl_automatic_mode=custom
```

Now build the origin and the DNS record:

```bash
cd terraform
terraform init
terraform apply        # ~1-2 min; then give cloud-init ~90s to install nginx
```

Grab the values the steps below use, and go back to the lab root:

```bash
export ORIGIN_IP=$(terraform output -raw origin_ip)
export INSTANCE_ID=$(terraform output -raw instance_id)
cd ..
echo "origin: $ORIGIN_HOSTNAME -> $ORIGIN_IP  (instance $INSTANCE_ID)"
```

**Verify the stage** (the hostname must resolve to Cloudflare, *not* to your origin IP):

```bash
dig +short "$ORIGIN_HOSTNAME"
# Expected: two Cloudflare IPs (104.x / 172.67.x / 2606:...), NOT $ORIGIN_IP
aws ssm describe-instance-information \
  --query "InstanceInformationList[?InstanceId=='$INSTANCE_ID'].PingStatus" --output text
# Expected: Online     (repeat for a minute or two if empty - the SSM agent is still registering)
curl -s -o /dev/null -w '%{http_code}\n' "http://$ORIGIN_IP/"
# Expected: 301   (a 200 here means cloud-init is still installing nginx - its stock page answers
#                  for ~15 s before our config lands; wait and re-run, or Step 1 shows 200, not the loop)
```

---

## Instructions

### Step 1 — Reproduce the redirect loop (Flexible + force-HTTPS)

**Purpose:** See the classic first-day failure from the terminal, before changing anything. In
Flexible mode Cloudflare always talks to your origin over **HTTP**. Your origin answers "go to
HTTPS" with a `301`, Cloudflare follows it back to itself over HTTP again, and so on forever.

**Command:**
```bash
curl -sSIL --max-redirs 2 --stderr - "https://$ORIGIN_HOSTNAME/" | grep -iE '^(http|location|curl)'
```

(The `--stderr -` is required: without it
curl's error line prints *before* the `301`s, because stdout through a pipe is buffered.)

**Expected output:**
```
HTTP/2 301
location: https://app.culilab.dev/
HTTP/2 301
location: https://app.culilab.dev/
HTTP/2 301
location: https://app.culilab.dev/
curl: (47) Maximum (2) redirects followed
```

Three `301`s, every `location:` pointing back at the **same URL**. A browser gives up after about
20 of these and shows `ERR_TOO_MANY_REDIRECTS` (use a private window — see Troubleshooting).

**Verify — who is saying "go to HTTPS"?** Ask your origin directly on port 80, skipping Cloudflare:

```bash
curl -sI -H "Host: $ORIGIN_HOSTNAME" "http://$ORIGIN_IP/" | grep -iE '^(http|location)'
# Expected:
# HTTP/1.1 301 Moved Permanently
# Location: https://app.culilab.dev/
```

The origin's own "force HTTPS" rule is the `301`. Nothing is wrong with it — it is what almost
every app does. The problem is that Flexible makes Cloudflare call it over HTTP, so the rule can
never be satisfied.

> The folk fix is to disable force-HTTPS in the app or trust `X-Forwarded-Proto`. It silences the
> loop and leaves the Cloudflare → origin leg in **plain HTTP**, with the padlock still green.
> That is hiding the symptom, not fixing it.

---

### Step 2 — Switch to Full: the loop is gone, the certificate is not checked

**Purpose:** Make Cloudflare call the origin over **HTTPS (443)**. That ends the HTTP/HTTPS
argument — and shows what "encrypted but not authenticated" means.

**Command (by hand, in the dashboard):** your zone → **SSL/TLS** → **Overview** → *Custom SSL/TLS*
→ choose **Full** → Save. It usually takes effect in 3–10 seconds; if the check below still shows the old result, wait a few seconds and re-run it.

**Verify:**
```bash
./scripts/check-ssl-mode.sh "$ORIGIN_HOSTNAME" "$ORIGIN_IP"
```

**Expected:**
```
1) Redirect-loop test (does the site bounce to ITSELF?):
HTTP/2 200
2) Status code Cloudflare returns for https://app.culilab.dev/ :
   -> 200 - the site works. (Full accepts ANY origin cert; only Full (strict) proves it is a trusted one.)
3) Certificate the ORIGIN itself presents on :443 (bypassing Cloudflare):
   issuer=CN = app.culilab.dev
   subject=CN = app.culilab.dev
   notAfter=...
```

`200`, loop gone. But look at line 3: the origin is serving a **self-signed** certificate (issuer =
subject) and Cloudflare accepted it without a word. "Full" encrypts the leg and does **not** check
who is on the other end. Anyone who can sit between Cloudflare and your server can present any
certificate they like. Encrypted, not authenticated.

---

### Step 3 — Switch to Full (strict): the 526

**Purpose:** Turn on the mode that also *authenticates* the origin, and watch it reject the
self-signed certificate. This is the outage you will meet the day you (or Automatic SSL/TLS) flip
to strict without a real certificate on the origin.

**Command (by hand, in the dashboard):** SSL/TLS → Overview → **Full (strict)** → Save. It usually takes effect
in 3–10 seconds (strict took ~10 s in testing).

**Verify:**
```bash
./scripts/check-ssl-mode.sh "$ORIGIN_HOSTNAME"
```

**Expected:**
```
2) Status code Cloudflare returns for https://app.culilab.dev/ :
   -> 526 - handshake worked but the origin CERTIFICATE is not valid/trusted (Full strict at work). Fix the certificate.
```

In a browser it is the Cloudflare error page: **Error 526 — Invalid SSL certificate**. Working as
designed: strict refused the self-signed certificate.

**Read the code, not the symptom:**

| Code | Meaning | You fix |
|------|---------|---------|
| **525** | The TLS **handshake** with the origin failed — 443 is open but not speaking TLS (e.g. `listen 443;` without `ssl`), or no common cipher. (nginx down = **521**, measured; a firewall timeout is **522** per Cloudflare's docs — neither is 525) | the handshake / the listener |
| **526** | The handshake worked, but the origin **certificate** is not valid or not trusted (expired, wrong hostname, self-signed, unknown CA) | the certificate |

You are at 526, so the next step is a certificate Cloudflare trusts.

---

### Step 4 — Create a Cloudflare Origin CA certificate (by hand)

**Purpose:** Get a certificate that Cloudflare trusts for your origin. A **Cloudflare Origin CA**
certificate is free on every plan, and strict mode accepts it. It is *not* trusted by browsers —
it only needs to satisfy Cloudflare, because Cloudflare is the only thing that should ever talk to
this origin.

**Command (by hand, in the dashboard):** your zone → **SSL/TLS** → **Origin Server** → **Create
Certificate**.

1. Choose **Generate private key and CSR with Cloudflare** (RSA is fine).
2. **Hostnames:** replace the defaults with just `app.culilab.dev` (your hostname).
3. **Validity:** the video uses the 15-year default. For a throwaway lab, pick the shortest period
   offered — a lab certificate should expire on its own. (Cloudflare does **not** send expiry
   reminders for Origin CA certificates; in real life, track the date yourself.)
4. **Create**, then keep the key format as **PEM**.
5. You now see the **Origin Certificate** and the **Private Key**. Leave the page open: the private
   key is shown **once**, and you paste both into the next step.

**Verify:** the certificate appears under *SSL/TLS → Origin Server → Origin Certificates* for
`app.culilab.dev`.

> Do not confuse this with the **Authenticated Origin Pull** CA (the one an origin uses to verify
> *Cloudflare's* client certificate). Different certificate, different job — that is the origin-lockdown episode ([`2026-08-cloudflare-origin-exposed`](../2026-08-cloudflare-origin-exposed)).

---

### Step 5 — Install it on the origin and reload nginx

**Purpose:** Replace the self-signed pair with the Origin CA pair. nginx already points at these two
paths, so there is no config to edit — overwrite the files and reload.

Open a shell on the origin **over SSM Session Manager** (no SSH, no key, no open port):

```bash
aws ssm start-session --target "$INSTANCE_ID"
```

On the box (you land as `ssm-user`; `sudo` works), replace each three-line placeholder below with
the full block Cloudflare shows you — its own `BEGIN`/`END` lines included. (A key header of
`BEGIN RSA PRIVATE KEY` or `BEGIN EC PRIVATE KEY` is fine too.)

```bash
sudo tee /etc/nginx/certs/origin-ca.pem >/dev/null <<'EOF'
-----BEGIN CERTIFICATE-----
(paste the Origin Certificate here)
-----END CERTIFICATE-----
EOF

sudo tee /etc/nginx/certs/origin-ca.key >/dev/null <<'EOF'
-----BEGIN PRIVATE KEY-----
(paste the Private Key here)
-----END PRIVATE KEY-----
EOF

sudo chmod 600 /etc/nginx/certs/origin-ca.key
sudo nginx -t && sudo systemctl reload nginx
```

**Expected:**
```
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
```

Confirm what nginx is serving now, then leave the shell:

```bash
sudo openssl x509 -in /etc/nginx/certs/origin-ca.pem -noout -issuer -subject -enddate
# Expected: issuer=... CloudFlare Origin SSL Certificate Authority ..., subject=... CN = CloudFlare Origin Certificate, notAfter=...
sudo openssl x509 -in /etc/nginx/certs/origin-ca.pem -noout -ext subjectAltName
# Expected: DNS:app.culilab.dev   (your hostname lives in the SAN, not the subject)
sudo grep -nE 'listen|server_name|ssl_certificate' /etc/nginx/sites-available/default   # same paths, same config
exit
```

**Verify:**
```bash
./scripts/check-ssl-mode.sh "$ORIGIN_HOSTNAME" "$ORIGIN_IP"
```

**Expected:**
```
2) Status code Cloudflare returns for https://app.culilab.dev/ :
   -> 200 - the site works. (Full accepts ANY origin cert; only Full (strict) proves it is a trusted one.)
3) Certificate the ORIGIN itself presents on :443 (bypassing Cloudflare):
   issuer=... CloudFlare Origin SSL Certificate Authority ...
```

You are in **Full (strict)** (nothing changed in the dashboard since Step 3) and it returns `200`:
the origin leg is encrypted **and** Cloudflare verified the certificate. Compared to Step 2, same
status code, completely different guarantee.

**The catch (say it out loud):** browsers do not trust this certificate — only Cloudflare does.
Call the origin directly and you see it:

```bash
curl -sS --resolve "$ORIGIN_HOSTNAME:443:$ORIGIN_IP" "https://$ORIGIN_HOSTNAME/"
# Expected: curl: (60) SSL certificate problem: unable to get local issuer certificate (wording varies by curl/OpenSSL version)
```

That is fine here — traffic is supposed to go through Cloudflare. But it also tells you the origin
still answers anyone who knows its IP. Closing that door (Authenticated Origin Pulls, IP
allowlists) is the episode *"You enabled Cloudflare. Your origin is still exposed."* (folder
[`2026-08-cloudflare-origin-exposed`](../2026-08-cloudflare-origin-exposed) in this repo); this lab deliberately keeps ports 80 and 443 open to the world.

---

## Verification Checklist

- [ ] After setup: the hostname resolves to Cloudflare IPs, not to `$ORIGIN_IP`; SSM shows `Online`.
- [ ] Step 1 (Flexible): three `301`s with `location:` equal to the request URL, then `curl: (47)`.
- [ ] Step 2 (Full): status `200`; the origin presents a **self-signed** certificate (issuer = subject).
- [ ] Step 3 (Full strict): status **`526`**.
- [ ] Step 5 (Full strict + Origin CA): status `200`; the origin presents a certificate issued by `CloudFlare Origin SSL Certificate Authority`.
- [ ] After `./cleanup.sh`: the SSL settings are back to what they were, no DNS record, no instance — and you revoked the Origin CA certificate by hand.

---

## Troubleshooting

### Error: `TargetNotConnected` from `aws ssm start-session`

**Cause:** The SSM agent has not registered yet. It needs the instance profile (Terraform attaches
it) **and** 1–2 minutes after boot to check in.

**Fix:** Wait a minute and retry. Confirm the box is registered:
```bash
aws ssm describe-instance-information \
  --query "InstanceInformationList[?InstanceId=='$INSTANCE_ID'].PingStatus" --output text
# Expected: Online
```

---

### Error: Step 1 prints `curl: (6) Could not resolve host`, or the status is `521` / `522` / `000`

**Cause:** Either the DNS record is not **proxied**, has not propagated yet, or the origin is still
running cloud-init (nginx installs ~90s after the instance starts). `521`/`522` mean Cloudflare
cannot reach the origin *at all* — that is not an SSL-mode problem.

**Fix:**
```bash
dig +short "$ORIGIN_HOSTNAME"      # Expected: Cloudflare IPs. If it prints $ORIGIN_IP, the record is grey-clouded (DNS only).
cd terraform && terraform apply    # re-applies proxied = true if someone toggled the cloud in the dashboard
# Read the bootstrap log over SSM: aws ssm start-session --target "$INSTANCE_ID", then on the box:
#   sudo tail -n 30 /var/log/lab-bootstrap.log
```

---

### Error: the browser still shows the loop (or an old result) after you changed the mode

**Cause:** Browsers cache a `301` aggressively, sometimes indefinitely. Your curl output is the
truth; the browser is showing history.

**Fix:** Test with `curl` (as the steps do) or a private/incognito window. Also give a mode change
~10 seconds to take effect before judging it (a check at +3 s can still show the old mode).

---

### Error: still `526` after installing the Origin CA certificate

**Cause:** Strict still does not like what nginx serves. Almost always: nginx was not reloaded (or
`nginx -t` failed and the `&&` stopped the reload), the certificate and key are not a matching pair,
the paste lost a line, or the certificate does not cover `app.culilab.dev`.

**Fix:** On the box:
```bash
sudo nginx -t                                                                  # must say "successful"
sudo openssl x509 -in /etc/nginx/certs/origin-ca.pem -noout -subject -issuer -ext subjectAltName
# Expected: issuer mentions CloudFlare Origin SSL Certificate Authority; SAN includes your hostname
sudo systemctl reload nginx
```
If the issuer still equals the subject, you are still serving the self-signed pair — redo the paste.

---

### Error: `525` instead of `526`

**Cause:** The handshake itself failed: port 443 accepts the connection but does not speak TLS —
typically a `listen 443;` line that lost its `ssl`, so nginx answers plain HTTP on 443 — or there is
no cipher in common. This is *not* a certificate trust problem. (Measured on this lab: stopping nginx
gives **521**, not 525. Per Cloudflare's docs, a connection that times out — e.g. a firewall
dropping 443 — is **522**.) Note that `systemctl status` and
`ss` look perfectly healthy in this case — the listener is up, it just isn't TLS.

**Fix:**
```bash
# on the box (aws ssm start-session ...)
sudo systemctl status nginx --no-pager | head -5
sudo ss -ltnp | grep -E ':(80|443) '    # Expected: nginx on both
sudo grep -nE '^\s*listen' /etc/nginx/sites-available/default
# Expected: "listen 443 ssl;" - if it says just "listen 443;", put the ssl back, then:
sudo nginx -t && sudo systemctl reload nginx
```

---

## Teardown

Teardown reverses **both** halves of the lab:

- the **zone-wide SSL settings** you changed by hand — Terraform never owned them, so
  `terraform destroy` cannot undo them; `cleanup.sh` restores the values saved in `.zone-ssl-before.env`;
- the **stage** Terraform built (EC2, Elastic IP, VPC, security group, IAM role, and the proxied DNS record) — `terraform destroy`.

```bash
cd culiops-101/2026-09-cloudflare-ssl-modes
source .env          # CLOUDFLARE_API_TOKEN / CLOUDFLARE_ZONE_ID / ... for the script
./cleanup.sh
```

The script asks for confirmation, restores the SSL settings, runs `terraform destroy`, and then
**verifies** (DNS record gone, no lab instance or Elastic IP left, SSL mode restored). It does not
print a green "done" if a step failed. It exits non-zero and lists what is still on you.

**One step is always manual:** the Cloudflare **Origin CA certificate**. The API token has no
`SSL and Certificates` permission, so the script cannot revoke it — it prints this as a checklist item:

- [ ] Dashboard → your zone → **SSL/TLS** → **Origin Server** → *Origin Certificates* → select the certificate → **Revoke** (cannot be undone).
- [ ] Delete any copy of the certificate/private key you saved on your machine.

> `ssl_automatic_mode` (Automatic vs Custom SSL/TLS) is restored on a best-effort basis. If the API
> refuses, the script says so and prints the exact dashboard step instead of claiming success.

**Verify cleanup:**
```bash
dig +short "$ORIGIN_HOSTNAME"                  # Expected: empty (resolver caches can keep answering for 2–3 minutes)
aws ec2 describe-instances --filters "Name=tag:Lab,Values=cloudflare-ssl-modes" \
  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text     # Expected: empty
```

If `cleanup.sh` fails, the manual fallback, in order: restore the SSL/TLS mode in the dashboard
(SSL/TLS → Overview) → `cd terraform && terraform destroy` → revoke the Origin CA certificate.

---

## Cost Breakdown

| Resource                | Type / Size             | Est. Cost/Hour | Est. Cost (30-min lab) |
|-------------------------|-------------------------|----------------|------------------------|
| EC2 origin              | `t3.micro`, Linux       | $0.0132        | ~$0.007                |
| Public IPv4 (Elastic IP)| attached to the instance| $0.005         | ~$0.003                |
| EBS root volume         | 8 GB gp3                | ~$0.001        | ~$0.001                |
| VPC / subnet / IGW / SG / IAM / SSM | —           | $0.00          | $0.00                  |
| Cloudflare              | Free plan (Origin CA, all SSL modes) | $0.00 | $0.00            |
| **Total**               |                         | **~$0.019**    | **~$0.01**             |

> Estimates for `ap-southeast-1`. The `t3.micro` rate is from the AWS public Price List (checked
> 2026-10-08); the public IPv4 charge is AWS's flat $0.005/hour. Forget to tear it down and it
> costs about $0.46/day — which is why `cleanup.sh` exists. All costs drop to $0 after teardown.

---

## What You Learned

- **The padlock proves one leg.** Green means browser → Cloudflare is encrypted. It says nothing about Cloudflare → your origin.
- **The SSL mode decides leg two**, and answers two separate questions: *is it encrypted?* and *is the origin authenticated?*
- **Leg two is not a private link.** Cloudflare reaches your origin over the public internet — the hosting network, transit providers, whatever routes sit in between. Under Flexible anyone on that path reads plain HTTP; under Full anyone on it can present their own certificate and still get the handshake.
- **Flexible** sends leg two over plain HTTP — which is also why a force-HTTPS origin loops forever. Patching the app hides the loop and keeps the plain-HTTP leg.
- **Full** encrypts leg two but never checks the certificate; a self-signed cert sails through.
- **Full (strict)** checks it. Without a trusted certificate on the origin you get a **526** — and **525 means fix the handshake, 526 means fix the certificate**.
- **A Cloudflare Origin CA certificate is the free way to satisfy strict** — trusted by Cloudflare only, which is exactly right when all traffic goes through Cloudflare.

---

## Safety guard

This lab changes a **zone-wide** setting, and an API token that can reach production zones is one
typo away from changing theirs. So every script that writes to Cloudflare (`prepare-zone.sh`, `set-ssl-mode.sh`,
`cleanup.sh`) first looks up the zone by id and **aborts unless its name equals `LAB_ZONE_NAME`**
(default `culilab.dev`). It always refuses `culiops.dev`, `culipulse.dev` and `1cost.dev`. Terraform
carries the same check as plan-time postconditions on the zone. If you run this on your own zone,
set `LAB_ZONE_NAME`, `CLOUDFLARE_ZONE_ID` and `ORIGIN_HOSTNAME` in `.env`.

---

## Appendix — change the SSL mode from the terminal (optional fallback)

Steps 2 and 3 are meant to be done in the dashboard so you *see* the setting move. If you cannot or
prefer not to use the dashboard, this script makes the same zone-wide change through the API
(guarded as above):

```bash
./scripts/set-ssl-mode.sh full       # Step 2
./scripts/set-ssl-mode.sh strict     # Step 3  (strict = Full (strict))
./scripts/set-ssl-mode.sh flexible   # back to the starting state
```

There is no API fallback for **Step 4** (creating the Origin CA certificate): that needs the
`SSL and Certificates : Edit` permission, which this lab's token intentionally does not have.

---

## Next Steps

- [ ] Add **HSTS only after** Full (strict) has run stably for a while — never while on Flexible.
- [ ] If you use Let's Encrypt on the origin: keep `/.well-known/acme-challenge/` out of your WAF / cache / redirect rules, or use DNS-01, or switch to an Origin CA certificate.
- [ ] **Close the back door:** your origin still answers anyone who knows its IP. See the *"You enabled Cloudflare. Your origin is still exposed."* episode and its lab in [`2026-08-cloudflare-origin-exposed`](../2026-08-cloudflare-origin-exposed).

—
🧑‍🍳 **CuliOps** — Learn DevOps through real labs. Full walkthrough on the CuliOps YouTube channel.
