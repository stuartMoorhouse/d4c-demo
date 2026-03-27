#!/usr/bin/env bash
# Fetch kubeconfig from SSM and configure local kubectl access
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../shared/env.json"
INFRA_DIR="${SCRIPT_DIR}/../infra"

# Read config from Terraform state
PREFIX=$(cd "$INFRA_DIR" && terraform output -raw prefix 2>/dev/null) || PREFIX="d4c2"
REGION=$(cd "$INFRA_DIR" && terraform output -raw region 2>/dev/null) || REGION="eu-north-1"
AWS_PROFILE="company"

KUBECONFIG_PATH="${HOME}/.kube/d4c2-config"
CONTEXT_NAME="${PREFIX}"

echo "Fetching kubeconfig from SSM (/${PREFIX}/kubeconfig)..."
KUBECONFIG_CONTENT=$(aws ssm get-parameter \
  --name "/${PREFIX}/kubeconfig" \
  --with-decryption \
  --region "$REGION" \
  --profile "$AWS_PROFILE" \
  --query 'Parameter.Value' \
  --output text)

if [[ -z "$KUBECONFIG_CONTENT" || "$KUBECONFIG_CONTENT" == "pending" ]]; then
  echo "ERROR: Kubeconfig not yet available (cluster may still be bootstrapping)."
  exit 1
fi

# Write to dedicated kubeconfig file
mkdir -p "$(dirname "$KUBECONFIG_PATH")"
echo "$KUBECONFIG_CONTENT" > "$KUBECONFIG_PATH"
chmod 600 "$KUBECONFIG_PATH"

# Rename context for clarity
export KUBECONFIG="$KUBECONFIG_PATH"
CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || true)
if [[ -n "$CURRENT_CONTEXT" && "$CURRENT_CONTEXT" != "$CONTEXT_NAME" ]]; then
  kubectl config rename-context "$CURRENT_CONTEXT" "$CONTEXT_NAME" 2>/dev/null || true
fi

# Merge into default kubeconfig
if [[ -f "${HOME}/.kube/config" ]]; then
  cp "${HOME}/.kube/config" "${HOME}/.kube/config.bak"
  KUBECONFIG="${HOME}/.kube/config:${KUBECONFIG_PATH}" kubectl config view --flatten > "${HOME}/.kube/config.merged"
  mv "${HOME}/.kube/config.merged" "${HOME}/.kube/config"
  chmod 600 "${HOME}/.kube/config"
  echo "Merged into ~/.kube/config (backup at ~/.kube/config.bak)"
else
  cp "$KUBECONFIG_PATH" "${HOME}/.kube/config"
  chmod 600 "${HOME}/.kube/config"
  echo "Written to ~/.kube/config"
fi

# Switch to the new context
kubectl config use-context "$CONTEXT_NAME" 2>/dev/null || \
  kubectl config use-context "$(kubectl config get-contexts -o name | head -1)"

echo ""
echo "Testing connection..."
if kubectl get nodes --request-timeout=10s; then
  echo ""
  echo "Cluster is accessible. Run 'k9s' or 'kubectl' to interact."
else
  echo ""
  echo "WARNING: Could not reach the cluster API. Check that:"
  echo "  - The cluster is running"
  echo "  - Your IP is allowed through the security group (port 6443)"
fi
