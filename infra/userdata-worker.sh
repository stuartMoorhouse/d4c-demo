#!/bin/bash -xe
exec > >(tee /var/log/user-data.log) 2>&1

export DEBIAN_FRONTEND=noninteractive

echo "=== D4C2 Worker Node Bootstrap ==="

# Disable swap
swapoff -a
sed -i '/swap/d' /etc/fstab

# Kernel modules
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# Install containerd
apt-get update
apt-get install -y ca-certificates curl gnupg awscli
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y containerd.io
containerd config default | sed 's/SystemdCgroup = false/SystemdCgroup = true/' > /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# Install kubeadm, kubelet, kubectl
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# Wait for join command from control plane via SSM (timeout after 10 minutes)
echo "Waiting for control plane join command..."
MAX_WAIT=600
WAITED=0
while true; do
  JOIN_CMD=$(aws ssm get-parameter \
    --name "${ssm_param}" \
    --region ${region} \
    --query 'Parameter.Value' \
    --output text 2>/dev/null || echo "pending")
  if [[ "$JOIN_CMD" != "pending" && -n "$JOIN_CMD" ]]; then
    echo "Got join command"
    break
  fi
  if [[ $WAITED -ge $MAX_WAIT ]]; then
    echo "FATAL: Timed out waiting for join command after $${MAX_WAIT}s"
    exit 1
  fi
  echo "  Still waiting... ($${WAITED}s / $${MAX_WAIT}s)"
  sleep 15
  WAITED=$((WAITED + 15))
done

# Verify API server is healthy before joining
echo "Verifying API server health..."
CONTROL_IP="${control_plane_ip}"
until curl -sk --max-time 5 "https://$CONTROL_IP:6443/healthz" | grep -q ok; do
  echo "  API server not ready yet..."
  sleep 10
done
echo "API server is healthy"

# Join the cluster
$JOIN_CMD

echo "=== Worker node bootstrap complete ==="
