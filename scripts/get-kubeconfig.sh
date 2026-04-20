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

# Rename cluster/user/context to unique names so the merge doesn't collide with
# a pre-existing "kubernetes" cluster entry (e.g. docker-desktop, prior kubeadm run).
# kubeadm always emits cluster=kubernetes, user=kubernetes-admin, context=kubernetes-admin@kubernetes.
# Patterns use `-E` extended regex and anchor on end-of-line to avoid matching
# substrings inside certificate data.
sed -i.tmp -E \
  -e "s/(name: )kubernetes-admin@kubernetes$/\1${CONTEXT_NAME}/" \
  -e "s/(name: )kubernetes-admin$/\1${CONTEXT_NAME}/" \
  -e "s/(name: )kubernetes$/\1${CONTEXT_NAME}/" \
  -e "s/(cluster: )kubernetes$/\1${CONTEXT_NAME}/" \
  -e "s/(user: )kubernetes-admin$/\1${CONTEXT_NAME}/" \
  -e "s/(current-context: )kubernetes-admin@kubernetes$/\1${CONTEXT_NAME}/" \
  "$KUBECONFIG_PATH"
rm -f "${KUBECONFIG_PATH}.tmp"

# Verify rename worked — if any "kubernetes"/"kubernetes-admin" names remain, bail.
if grep -qE "(name|cluster|user|current-context): (kubernetes|kubernetes-admin|kubernetes-admin@kubernetes)$" "$KUBECONFIG_PATH"; then
  echo "ERROR: Failed to rename all entries in $KUBECONFIG_PATH"
  grep -nE "(name|cluster|user|current-context): (kubernetes|kubernetes-admin|kubernetes-admin@kubernetes)$" "$KUBECONFIG_PATH"
  exit 1
fi

# Merge into default kubeconfig
if [[ -f "${HOME}/.kube/config" ]]; then
  cp "${HOME}/.kube/config" "${HOME}/.kube/config.bak"
  # Strip any stale entry with our target name from the existing config first
  KUBECONFIG="${HOME}/.kube/config" kubectl config delete-cluster "$CONTEXT_NAME" >/dev/null 2>&1 || true
  KUBECONFIG="${HOME}/.kube/config" kubectl config delete-user    "$CONTEXT_NAME" >/dev/null 2>&1 || true
  KUBECONFIG="${HOME}/.kube/config" kubectl config delete-context "$CONTEXT_NAME" >/dev/null 2>&1 || true
  KUBECONFIG="${HOME}/.kube/config:${KUBECONFIG_PATH}" kubectl config view --flatten > "${HOME}/.kube/config.merged"
  mv "${HOME}/.kube/config.merged" "${HOME}/.kube/config"
  chmod 600 "${HOME}/.kube/config"
  echo "Merged into ~/.kube/config (backup at ~/.kube/config.bak)"
else
  cp "$KUBECONFIG_PATH" "${HOME}/.kube/config"
  chmod 600 "${HOME}/.kube/config"
  echo "Written to ~/.kube/config"
fi

# Switch to the new context in ~/.kube/config (unset KUBECONFIG so we edit the default file)
unset KUBECONFIG
kubectl config use-context "$CONTEXT_NAME"

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
