#!/bin/bash -xe
# Simulate a crypto miner attack to trigger D4C detection

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

CONTROL_IP=$(terraform -chdir="${PROJECT_DIR}/infra" output -raw control_plane_public_ip)
KIBANA_URL=$(terraform -chdir="${PROJECT_DIR}/infra" output -raw kibana_url)
SSH_KEY="${PROJECT_DIR}/d4c2-key.pem"

# Create the crypto miner simulation job
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

# Delete previous run if exists
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@${CONTROL_IP} \
  "kubectl delete job crypto-miner-sim --ignore-not-found=true"

# Deploy the job
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
  /tmp/crypto-miner-job.yaml ubuntu@${CONTROL_IP}:/tmp/

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@${CONTROL_IP} \
  "kubectl apply -f /tmp/crypto-miner-job.yaml"

# Update shared state
jq '.demo_executed = true' "${PROJECT_DIR}/shared/env.json" > /tmp/env-updated.json \
  && mv /tmp/env-updated.json "${PROJECT_DIR}/shared/env.json"

echo ""
echo "====================================="
echo " Crypto miner simulation deployed!"
echo "====================================="
echo ""
echo "Check for alerts in Kibana:"
echo "  Security Alerts: ${KIBANA_URL}/app/security/alerts"
echo "  Security Events: ${KIBANA_URL}/app/security/events"
echo ""
echo "It may take 1-2 minutes for events to appear."
