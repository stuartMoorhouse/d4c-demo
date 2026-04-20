#!/bin/bash
# Create and enable an ES|QL detection rule for container breakout via nsenter.
# Idempotent: if a rule with the same rule_id already exists, this is a no-op.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

: "${KIBANA_URL:=$(terraform -chdir="${PROJECT_DIR}/infra" output -raw kibana_url)}"
: "${ES_PASSWORD:=$(terraform -chdir="${PROJECT_DIR}/infra" output -raw elasticsearch_password)}"

RULE_ID="d4c2-container-breakout"

EXISTING=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "elastic:${ES_PASSWORD}" \
  -H "kbn-xsrf: true" \
  -H "elastic-api-version: 2023-10-31" \
  "${KIBANA_URL}/api/detection_engine/rules?rule_id=${RULE_ID}")

if [[ "$EXISTING" == "200" ]]; then
  echo "Container breakout rule (rule_id=${RULE_ID}) already exists — skipping."
  exit 0
fi

echo "Creating node-level breakout detection rule..."

RULE_RESPONSE=$(curl -s -X POST "${KIBANA_URL}/api/detection_engine/rules" \
  -H "kbn-xsrf: true" \
  -H "Content-Type: application/json" \
  -H "elastic-api-version: 2023-10-31" \
  -u "elastic:${ES_PASSWORD}" \
  -d '{
    "rule_id": "'"${RULE_ID}"'",
    "type": "esql",
    "language": "esql",
    "name": "Container Breakout via nsenter (Node-Level Escape)",
    "description": "Detects a container using nsenter to escape into the host node namespaces. This is a container breakout technique where a privileged pod with hostPID access uses nsenter to execute commands directly on the underlying Kubernetes node.",
    "risk_score": 99,
    "severity": "critical",
    "query": "FROM logs-cloud_defend.process-* | WHERE process.name == \"nsenter\" | EVAL args_str = MV_CONCAT(process.args, \" \") | WHERE args_str LIKE \"*--target*\"",
    "interval": "5s",
    "from": "now-1m",
    "enabled": true,
    "tags": ["D4C", "Container Breakout", "Node-Level", "Privilege Escalation", "Demo"],
    "alert_suppression": {
      "group_by": ["host.name"],
      "duration": {
        "value": 10,
        "unit": "m"
      },
      "missing_fields_strategy": "suppress"
    }
  }')

ID=$(echo "$RULE_RESPONSE" | jq -r '.id')

if [[ -z "$ID" || "$ID" == "null" ]]; then
  echo "ERROR: Failed to create detection rule"
  echo "$RULE_RESPONSE" | jq .
  exit 1
fi

echo "Breakout rule created: ${KIBANA_URL}/app/security/rules/id/${ID}"
