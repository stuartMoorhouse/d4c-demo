# D4C2: Defend for Containers Threat Detection Demo

Automated demo environment that deploys Elastic's **Defend for Containers** (D4C) integration on a self-managed Kubernetes cluster to detect threats both inside containers and on the underlying host nodes.

## What This Demonstrates

Elastic Defend for Containers provides runtime security observability for Kubernetes workloads. It uses eBPF-based sensors deployed as a DaemonSet to monitor process, file, and network activity across all pods on a node.

This demo shows two detection scenarios:

### 1. In-Container Threat Detection

A Kubernetes Job simulates a crypto miner inside a container -- downloading a binary named `xmrig` to `/tmp`, connecting to a mining pool, and executing the binary. D4C observes these process executions and network connections from within the container and surfaces them as security events in Kibana.

### 2. Container Breakout to Host (Node-Level Detection)

A privileged pod with `hostPID: true` uses `nsenter` to escape into the host node's namespaces. Once on the host, it performs reconnaissance (`whoami`, `uname -a`), reads `/etc/shadow`, and drops a persistence mechanism. D4C detects this breakout because it monitors at the node level -- it sees the `nsenter` call cross namespace boundaries and the subsequent host-level commands, even though they originate from a container.

Both scenarios use custom ES|QL detection rules that query `logs-cloud_defend.process-*` to generate alerts in Kibana Security.

## Architecture

```
Operator Machine
  |
  |-- terraform apply (infra/)
  |     |
  |     |-- Elastic Cloud deployment (Elasticsearch + Kibana + Fleet Server)
  |     |
  |     '-- AWS EC2 (3x Ubuntu, kubeadm cluster)
  |           |-- 1 control plane node
  |           '-- 2 worker nodes
  |                 '-- Elastic Agent DaemonSet (D4C integration)
  |
  |-- scripts/setup-fleet.sh    -> configures Fleet, deploys agent
  |-- scripts/create-rule.sh    -> ES|QL rule for crypto miner detection
  |-- scripts/create-rule-node.sh -> ES|QL rule for container breakout
  |-- scripts/attack.sh         -> simulates crypto miner in a pod
  '-- scripts/attack-node.sh    -> simulates container breakout to host
```

## Prerequisites

- Terraform
- AWS CLI configured with the `company` profile
- `EC_API_KEY` environment variable set for Elastic Cloud
- `jq`, `kubectl` (used by scripts)

## Usage

### Deploy

```bash
cd infra
terraform init
terraform apply
```

Once infrastructure is up, configure Fleet and deploy the Elastic Agent:

```bash
./scripts/setup-fleet.sh
```

### Create Detection Rules

```bash
./scripts/create-rule.sh       # crypto miner detection
./scripts/create-rule-node.sh  # container breakout detection
```

### Run Attack Simulations

```bash
./scripts/attack.sh            # crypto miner in a container
./scripts/attack-node.sh       # container breakout via nsenter
```

Check alerts at **Kibana > Security > Alerts** within 1-2 minutes.

### Teardown

```bash
./scripts/destroy.sh
```

## Key Data Source

All detections query from `logs-cloud_defend.process-*`, the index pattern written by the D4C integration. This contains process execution events enriched with container and Kubernetes metadata (pod name, namespace, node, image), which is what allows correlation between container-level and host-level activity.
