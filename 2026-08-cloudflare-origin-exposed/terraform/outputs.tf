# outputs.tf — Cloudflare Origin Lockdown lab
# The check commands come out pre-filled with the real origin IP — copy/paste them.

output "origin_ip" {
  description = "The origin's real public IP (the Elastic IP). This is exactly what leaks via DNS history / crt.sh / Shodan and gets hit directly."
  value       = aws_eip.origin.public_ip
}

output "origin_hostname" {
  description = "The proxied hostname in front of the origin."
  value       = var.origin_hostname
}

output "protection_state" {
  description = "The lock currently applied to the origin."
  value       = var.protection
}

output "check_direct" {
  description = "THE 30-second exposure check — hit the origin IP directly, bypassing Cloudflare."
  value       = "curl -k --resolve ${var.origin_hostname}:443:${aws_eip.origin.public_ip} https://${var.origin_hostname}/ -o /dev/null -w '%%{http_code}\\n'"
}

output "check_via_cloudflare" {
  description = "The legit path — through Cloudflare. Should stay 200 in every state."
  value       = "curl -sS https://${var.origin_hostname}/ -o /dev/null -w '%%{http_code}\\n'"
}

output "expected_direct_result" {
  description = "What the direct check should return in the current state."
  value = {
    none         = "200      -> EXPOSED: any host that knows the IP bypasses every Cloudflare rule"
    ip_allowlist = "000/timeout -> LAYER 1: the security group drops non-Cloudflare source IPs at the network layer"
    aop          = "403      -> LAYER 2: nginx rejects requests without Cloudflare's client cert (mTLS)"
  }[var.protection]
}

output "next_step" {
  description = "How to advance the lab."
  value = {
    none         = "Re-apply with -var protection=ip_allowlist, then re-run check_direct (expect a timeout)."
    ip_allowlist = "Re-apply with -var protection=aop, wait ~90s for the box to reboot into the mTLS config, then re-run check_direct (expect 403)."
    aop          = "Origin locked. Run `terraform destroy` when done — it reverts the A record, the AOP toggle, and the SSL setting."
  }[var.protection]
}
