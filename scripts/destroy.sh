#!/bin/bash
# Destroy all D4C2 demo resources

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [[ "$1" != "-y" ]]; then
  read -p "This will destroy ALL d4c2 resources (AWS + Elastic Cloud). Continue? [y/N] " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

echo "Destroying infrastructure..."
terraform -chdir="${PROJECT_DIR}/infra" destroy -auto-approve

echo "Cleaning up local files..."
rm -f "${PROJECT_DIR}/d4c2-key.pem"
rm -f /tmp/elastic-agent-rendered.yaml
rm -f /tmp/crypto-miner-job.yaml

# Reset shared state
cat > "${PROJECT_DIR}/shared/env.json" <<'EOF'
{
  "elasticsearch_url": "",
  "kibana_url": "",
  "fleet_url": "",
  "api_key": "",
  "infra_ready": false,
  "config_ready": false,
  "demo_executed": false
}
EOF

echo ""
echo "Teardown complete."
