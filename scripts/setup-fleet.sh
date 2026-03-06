#!/bin/bash -xe
# Setup Fleet, create D4C agent policy, and deploy Elastic Agent DaemonSet

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

KIBANA_URL=$(terraform -chdir="${PROJECT_DIR}/infra" output -raw kibana_url)
ES_PASSWORD=$(terraform -chdir="${PROJECT_DIR}/infra" output -raw elasticsearch_password)
ES_VERSION=$(terraform -chdir="${PROJECT_DIR}/infra" output -raw elastic_version)
REGION=$(terraform -chdir="${PROJECT_DIR}/infra" output -raw region 2>/dev/null || echo "eu-north-1")
PREFIX=$(terraform -chdir="${PROJECT_DIR}/infra" output -raw prefix 2>/dev/null || echo "d4c2")

# Fetch kubeconfig from SSM
echo "Fetching kubeconfig from SSM..."
KUBECONFIG_FILE=$(mktemp)
aws ssm get-parameter \
  --name "/${PREFIX}/kubeconfig" \
  --with-decryption \
  --region "$REGION" \
  --profile company \
  --query 'Parameter.Value' \
  --output text > "$KUBECONFIG_FILE"
export KUBECONFIG="$KUBECONFIG_FILE"
trap 'rm -f "$KUBECONFIG_FILE"' EXIT

echo "Kibana:  $KIBANA_URL"
echo "Version: $ES_VERSION"

# Wait for Kibana to be ready
echo ""
echo "Waiting for Kibana..."
for i in $(seq 1 30); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" -u "elastic:${ES_PASSWORD}" "${KIBANA_URL}/api/status" 2>/dev/null || echo "000")
  if [[ "$STATUS" == "200" ]]; then
    echo "Kibana is ready"
    break
  fi
  if [[ "$i" == "30" ]]; then
    echo "ERROR: Kibana not ready after 5 minutes"
    exit 1
  fi
  echo "  Attempt $i/30 - status: $STATUS"
  sleep 10
done

# Get Fleet Server URL from Fleet settings
echo ""
echo "Getting Fleet Server URL..."
FLEET_URL=$(curl -s -u "elastic:${ES_PASSWORD}" "${KIBANA_URL}/api/fleet/fleet_server_hosts" \
  -H "kbn-xsrf: true" | jq -r '.items[] | select(.is_default == true) | .host_urls[0]')
echo "Fleet:   $FLEET_URL"

if [[ -z "$FLEET_URL" || "$FLEET_URL" == "null" ]]; then
  echo "ERROR: Could not get Fleet Server URL from Fleet settings"
  exit 1
fi

# Create Agent Policy (idempotent — reuse existing if present)
echo ""
echo "Creating agent policy..."
POLICY_RESPONSE=$(curl -s -X POST "${KIBANA_URL}/api/fleet/agent_policies" \
  -H "kbn-xsrf: true" \
  -H "Content-Type: application/json" \
  -u "elastic:${ES_PASSWORD}" \
  -d '{
    "name": "d4c2-policy",
    "namespace": "default",
    "monitoring_enabled": ["logs", "metrics"]
  }')
POLICY_ID=$(echo "$POLICY_RESPONSE" | jq -r '.item.id')

if [[ -z "$POLICY_ID" || "$POLICY_ID" == "null" ]]; then
  # Check if policy already exists (409 Conflict)
  STATUS_CODE=$(echo "$POLICY_RESPONSE" | jq -r '.statusCode // empty')
  if [[ "$STATUS_CODE" == "409" ]]; then
    echo "Agent policy already exists, looking it up..."
    POLICY_ID=$(curl -s -u "elastic:${ES_PASSWORD}" \
      "${KIBANA_URL}/api/fleet/agent_policies" \
      -H "kbn-xsrf: true" | jq -r '.items[] | select(.name == "d4c2-policy") | .id')
    if [[ -z "$POLICY_ID" || "$POLICY_ID" == "null" ]]; then
      echo "ERROR: Could not find existing d4c2-policy"
      exit 1
    fi
    echo "Using existing agent policy: $POLICY_ID"
  else
    echo "ERROR: Failed to create agent policy"
    echo "$POLICY_RESPONSE" | jq .
    exit 1
  fi
else
  echo "Created agent policy: $POLICY_ID"
fi

# Get D4C package version
echo ""
echo "Looking up cloud_defend package version..."
D4C_VERSION=$(curl -s -u "elastic:${ES_PASSWORD}" \
  "${KIBANA_URL}/api/fleet/epm/packages/cloud_defend" \
  -H "kbn-xsrf: true" | jq -r '.item.version')
echo "D4C package version: $D4C_VERSION"

# Add D4C integration to policy (idempotent — skip if already attached)
echo ""
echo "Adding Defend for Containers integration..."
EXISTING_D4C=$(curl -s -u "elastic:${ES_PASSWORD}" \
  "${KIBANA_URL}/api/fleet/package_policies" \
  -H "kbn-xsrf: true" | jq -r ".items[] | select(.policy_id == \"${POLICY_ID}\" and .package.name == \"cloud_defend\") | .id")

if [[ -n "$EXISTING_D4C" && "$EXISTING_D4C" != "null" ]]; then
  echo "D4C integration already attached: $EXISTING_D4C"
  D4C_POLICY_ID="$EXISTING_D4C"
else
  # Explicit D4C configuration with process + file monitoring
  D4C_CONFIG=$(cat <<'YAMLEOF'
process:
  selectors:
    - name: allProcesses
      operation: [fork, exec]
  responses:
    - match: [allProcesses]
      actions: [log]
file:
  selectors:
    - name: executableChanges
      operation: [createExecutable, modifyExecutable]
  responses:
    - match: [executableChanges]
      actions: [alert]
YAMLEOF
)

  D4C_RESPONSE=$(curl -s -X POST "${KIBANA_URL}/api/fleet/package_policies" \
    -H "kbn-xsrf: true" \
    -H "Content-Type: application/json" \
    -u "elastic:${ES_PASSWORD}" \
    -d "$(jq -n \
      --arg name "d4c2-defend-for-containers" \
      --arg ns "default" \
      --arg pid "${POLICY_ID}" \
      --arg pkg_name "cloud_defend" \
      --arg pkg_ver "${D4C_VERSION}" \
      --arg config "$D4C_CONFIG" \
      '{
        name: $name,
        namespace: $ns,
        policy_id: $pid,
        package: { name: $pkg_name, version: $pkg_ver },
        inputs: {
          "cloud_defend-control": {
            vars: {
              configuration: $config
            }
          }
        }
      }')")

  D4C_POLICY_ID=$(echo "$D4C_RESPONSE" | jq -r '.item.id')
  if [[ -z "$D4C_POLICY_ID" || "$D4C_POLICY_ID" == "null" ]]; then
    echo "ERROR: Failed to add D4C integration"
    echo "$D4C_RESPONSE" | jq .
    exit 1
  fi
  echo "Added D4C integration: $D4C_POLICY_ID"
fi

# Get enrollment token
echo ""
echo "Retrieving enrollment token..."
ENROLLMENT_TOKEN=$(curl -s -u "elastic:${ES_PASSWORD}" \
  "${KIBANA_URL}/api/fleet/enrollment_api_keys" \
  -H "kbn-xsrf: true" | jq -r ".items[] | select(.policy_id == \"${POLICY_ID}\") | .api_key")

if [[ -z "$ENROLLMENT_TOKEN" ]]; then
  echo "ERROR: Could not find enrollment token for policy $POLICY_ID"
  exit 1
fi
echo "Got enrollment token"

# Template and deploy the Elastic Agent manifest
echo ""
echo "Deploying Elastic Agent DaemonSet..."
sed -e "s|FLEET_URL_PLACEHOLDER|${FLEET_URL}|g" \
    -e "s|FLEET_ENROLLMENT_TOKEN_PLACEHOLDER|${ENROLLMENT_TOKEN}|g" \
    -e "s|ELASTIC_VERSION_PLACEHOLDER|${ES_VERSION}|g" \
    "${PROJECT_DIR}/manifests/elastic-agent.yaml" > /tmp/elastic-agent-rendered.yaml

kubectl apply -f /tmp/elastic-agent-rendered.yaml

# Wait for rollout
echo ""
echo "Waiting for Elastic Agent rollout..."
kubectl -n kube-system rollout status daemonset/elastic-agent --timeout=120s

# Update shared state
cat > "${PROJECT_DIR}/shared/env.json" <<ENVEOF
{
  "elasticsearch_url": "$(terraform -chdir="${PROJECT_DIR}/infra" output -raw elasticsearch_url)",
  "kibana_url": "${KIBANA_URL}",
  "fleet_url": "${FLEET_URL}",
  "api_key": "",
  "infra_ready": true,
  "config_ready": true,
  "demo_executed": false
}
ENVEOF

echo ""
echo "====================================="
echo " Fleet setup complete!"
echo "====================================="
echo ""
echo "Fleet UI:  ${KIBANA_URL}/app/fleet/agents"
echo "Security:  ${KIBANA_URL}/app/security/alerts"
