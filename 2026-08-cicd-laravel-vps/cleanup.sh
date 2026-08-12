#!/usr/bin/env bash
# cleanup.sh — CuliOps Lab Cleanup (Docker deploy lab)
# ⚠️  Tears down BOTH the local harness and any Terraform-provisioned VPS.
set -euo pipefail

echo "🧹 CuliOps Deploy-Laravel-Docker Lab Cleanup"
echo "==========================================="
echo ""
echo "This will remove:"
echo "  - local Docker Compose stack + named volumes (storage, mysql-data, public)"
echo "  - the Terraform VPS + VPC/subnet/SG/IGW (if applied)"
echo ""
read -r -p "Continue? (y/N) " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

echo ""
echo "→ local harness..."
docker compose down -v --remove-orphans 2>/dev/null || echo "  (no local stack running)"

echo "→ Terraform VPS..."
if [ -f terraform/terraform.tfstate ] && [ -s terraform/terraform.tfstate ]; then
  terraform -chdir=terraform destroy -auto-approve || {
    echo "  ⚠️  destroy failed — resources may still be BILLING. Re-run: terraform -chdir=terraform destroy"
    exit 1
  }
else
  echo "  (no Terraform state — nothing provisioned)"
fi

echo ""
echo "✅ Cleanup complete."
echo "💰 Estimated savings: ~\$0.36/day by removing the t3.micro + public IP."
echo ""
echo "If you ran Path B on a shared repo, also delete the secrets:"
echo "  gh secret delete VPS_HOST -R <owner>/<repo>   # and DEPLOY_USER, DEPLOY_SSH_KEY"
echo "And double-check the AWS console: EC2 > Instances, VPC."
