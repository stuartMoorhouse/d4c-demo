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

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) (>= 1.5)
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) configured with valid credentials
- An [Elastic Cloud](https://cloud.elastic.co/) account with an API key exported as `EC_API_KEY`
- `kubectl`, `jq` installed locally
- SSH access (port 22) not blocked by your network

## Setup

1. Clone the repo and copy the example config:

   ```bash
   cd infra
   cp ../terraform.tfvars.example terraform.tfvars
   ```

2. Edit `terraform.tfvars` to set your preferences:

   ```hcl
   region        = "eu-north-1"      # AWS region (Elastic Cloud region is derived from this)
   prefix        = "d4c2"            # Resource name prefix
   instance_type = "t3.medium"       # EC2 instance type for K8s nodes
   aws_profile   = "default"         # AWS CLI profile name
   ```

3. Export your Elastic Cloud API key:

   ```bash
   export EC_API_KEY="your-elastic-cloud-api-key"
   ```

## Deploy

```bash
cd infra
terraform init
terraform apply
```

This single command provisions everything:
- 3 EC2 instances (1 control plane + 2 workers) running a kubeadm Kubernetes cluster
- An Elastic Cloud deployment (Elasticsearch + Kibana + Fleet Server)
- Elastic Agent DaemonSet with the D4C integration on all K8s nodes

## Run the Demo

Once `terraform apply` completes, create the detection rules and run the attacks:

```bash
# Create the ES|QL detection rules
./scripts/create-rule.sh           # crypto miner detection (high severity)
./scripts/create-rule-node.sh      # container breakout detection (critical severity)

# Run both attack simulations
./scripts/attack.sh                # crypto miner in a container
./scripts/attack-node.sh           # container breakout via nsenter
```

Alerts appear in **Kibana > Security > Alerts** within 1-2 minutes.

To reset the demo (clean up alerts and re-run the attacks from a clean state):

```bash
./scripts/reset-demo.sh
```

## Teardown

```bash
./scripts/destroy.sh
```

This destroys all AWS and Elastic Cloud resources and cleans up local files.

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
  |-- scripts/create-rule*.sh   -> ES|QL detection rules
  |-- scripts/attack*.sh        -> attack simulations
  '-- scripts/reset-demo.sh     -> clean and re-run demo
```

## Key Data Source

All detections query from `logs-cloud_defend.process-*`, the index pattern written by the D4C integration. This contains process execution events enriched with container and Kubernetes metadata (pod name, namespace, node, image), which is what allows correlation between container-level and host-level activity.
