#!/bin/bash -xe
# Create and enable an ES|QL detection rule for container breakout via nsenter

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

KIBANA_URL=$(terraform -chdir="${PROJECT_DIR}/infra" output -raw kibana_url)
ES_PASSWORD=$(terraform -chdir="${PROJECT_DIR}/infra" output -raw elasticsearch_password)

echo "Creating node-level breakout detection rule..."

RULE_RESPONSE=$(curl -s -X POST "${KIBANA_URL}/api/detection_engine/rules" \
  -H "kbn-xsrf: true" \
  -H "Content-Type: application/json" \
  -H "elastic-api-version: 2023-10-31" \
  -u "elastic:${ES_PASSWORD}" \
  -d '{
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

RULE_ID=$(echo "$RULE_RESPONSE" | jq -r '.id')

if [[ -z "$RULE_ID" || "$RULE_ID" == "null" ]]; then
  echo "ERROR: Failed to create detection rule"
  echo "$RULE_RESPONSE" | jq .
  exit 1
fi

echo ""
echo "====================================="
echo " Detection rule created and enabled"
echo "====================================="
echo ""
echo "Rule ID:    $RULE_ID"
echo "Severity:   critical (risk score 99)"
echo "Interval:   5 seconds"
echo "Suppression: host.name for 10 minutes"
echo ""
echo "View rule: ${KIBANA_URL}/app/security/rules/id/${RULE_ID}"
echo "Alerts:    ${KIBANA_URL}/app/security/alerts"
