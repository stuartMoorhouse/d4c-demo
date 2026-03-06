#!/bin/bash -xe
exec > >(tee /var/log/user-data.log) 2>&1

export DEBIAN_FRONTEND=noninteractive

echo "=== D4C2 Control Plane Bootstrap ==="

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

# Init control plane
PRIVATE_IP=$(hostname -I | awk '{print $1}')
PUBLIC_IP=$(curl -s --max-time 5 http://169.254.169.254/latest/meta-data/public-ipv4)
kubeadm init \
  --pod-network-cidr=${pod_cidr} \
  --apiserver-advertise-address="$PRIVATE_IP" \
  --apiserver-cert-extra-sans="$PUBLIC_IP"

# Setup kubeconfig for root
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config

# Setup kubeconfig for ubuntu user
mkdir -p /home/ubuntu/.kube
cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
chown -R ubuntu:ubuntu /home/ubuntu/.kube

# Install Flannel CNI
kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f \
  https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# Publish join command to SSM
JOIN_CMD=$(kubeadm token create --print-join-command)
aws ssm put-parameter \
  --name "${ssm_param}" \
  --value "$JOIN_CMD" \
  --type String \
  --overwrite \
  --region ${region}

# Publish kubeconfig to SSM (rewrite server to public IP for external access)
KUBECONFIG_CONTENT=$(cat /etc/kubernetes/admin.conf | sed "s|$PRIVATE_IP|$PUBLIC_IP|g")
aws ssm put-parameter \
  --name "${ssm_kubeconfig}" \
  --value "$KUBECONFIG_CONTENT" \
  --type SecureString \
  --tier Advanced \
  --overwrite \
  --region ${region}

echo "=== Control plane bootstrap complete ==="
