#!/bin/bash -xe
# Create and enable an ES|QL detection rule for crypto miner (xmrig)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

KIBANA_URL=$(terraform -chdir="${PROJECT_DIR}/infra" output -raw kibana_url)
ES_PASSWORD=$(terraform -chdir="${PROJECT_DIR}/infra" output -raw elasticsearch_password)

echo "Creating crypto miner detection rule..."

RULE_RESPONSE=$(curl -s -X POST "${KIBANA_URL}/api/detection_engine/rules" \
  -H "kbn-xsrf: true" \
  -H "Content-Type: application/json" \
  -H "elastic-api-version: 2023-10-31" \
  -u "elastic:${ES_PASSWORD}" \
  -d '{
    "type": "esql",
    "language": "esql",
    "name": "Crypto Miner Detected (xmrig in /tmp)",
    "description": "Detects execution of xmrig crypto miner binary from /tmp directory inside a container, observed by Defend for Containers.",
    "risk_score": 73,
    "severity": "high",
    "query": "FROM logs-cloud_defend.process-* | WHERE process.name LIKE \"xmrig*\" AND process.executable LIKE \"/tmp/xmrig*\"",
    "interval": "5s",
    "from": "now-1m",
    "enabled": true,
    "tags": ["D4C", "Crypto Miner", "Demo"],
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
echo "Interval:   5 seconds"
echo "Suppression: host.name for 10 minutes"
echo ""
echo "View rule: ${KIBANA_URL}/app/security/rules/id/${RULE_ID}"
echo "Alerts:    ${KIBANA_URL}/app/security/alerts"
