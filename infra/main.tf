terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    ec = {
      source  = "elastic/ec"
      version = "~> 0.12"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = "company"

  default_tags {
    tags = var.aws_tags
  }
}

provider "ec" {}

# ---------- Data Sources ----------

data "http" "my_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  my_ip = "${chomp(data.http.my_ip.response_body)}/32"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "ec_stack" "latest" {
  version_regex = "8\\.\\d+\\.\\d+"
  region        = "aws-eu-north-1"
}

# ---------- SSH Key ----------

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "this" {
  key_name   = "${var.prefix}-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "local_file" "ssh_key" {
  content         = tls_private_key.ssh.private_key_pem
  filename        = "${path.module}/../d4c2-key.pem"
  file_permission = "0400"
}

# ---------- VPC ----------

resource "aws_vpc" "this" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.prefix}-vpc" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "${var.region}a"

  tags = { Name = "${var.prefix}-public" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.prefix}-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.prefix}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ---------- Security Group ----------

resource "aws_security_group" "k8s" {
  name_prefix = "${var.prefix}-k8s-"
  vpc_id      = aws_vpc.this.id

  # SSH from operator
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.my_ip]
  }

  # K8s API from operator
  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [local.my_ip]
  }

  # All traffic within VPC (inter-node)
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [aws_vpc.this.cidr_block]
  }

  # All outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-k8s-sg" }
}

# ---------- IAM for SSM ----------

resource "aws_iam_role" "k8s_node" {
  name_prefix = "${var.prefix}-node-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "ssm_access" {
  name_prefix = "${var.prefix}-ssm-"
  role        = aws_iam_role.k8s_node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:GetParameter",
        "ssm:PutParameter"
      ]
      Resource = aws_ssm_parameter.join_cmd.arn
    }]
  })
}

resource "aws_iam_instance_profile" "k8s_node" {
  name_prefix = "${var.prefix}-node-"
  role        = aws_iam_role.k8s_node.name
}

# ---------- SSM Parameter (join command) ----------

resource "aws_ssm_parameter" "join_cmd" {
  name  = "/${var.prefix}/join-command"
  type  = "String"
  value = "pending"

  lifecycle {
    ignore_changes = [value]
  }
}

# ---------- EC2 Spot Instances ----------

resource "aws_spot_instance_request" "control" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  spot_type              = "one-time"
  wait_for_fulfillment   = true
  key_name               = aws_key_pair.this.key_name
  vpc_security_group_ids = [aws_security_group.k8s.id]
  subnet_id              = aws_subnet.public.id
  iam_instance_profile   = aws_iam_instance_profile.k8s_node.name

  user_data = templatefile("${path.module}/userdata-control.sh", {
    ssm_param = aws_ssm_parameter.join_cmd.name
    region    = var.region
    pod_cidr  = "10.244.0.0/16"
  })

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  tags = { Name = "${var.prefix}-control" }
}

resource "aws_spot_instance_request" "worker" {
  count = 2

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  spot_type              = "one-time"
  wait_for_fulfillment   = true
  key_name               = aws_key_pair.this.key_name
  vpc_security_group_ids = [aws_security_group.k8s.id]
  subnet_id              = aws_subnet.public.id
  iam_instance_profile   = aws_iam_instance_profile.k8s_node.name

  user_data = templatefile("${path.module}/userdata-worker.sh", {
    ssm_param        = aws_ssm_parameter.join_cmd.name
    region           = var.region
    control_plane_ip = aws_spot_instance_request.control.private_ip
  })

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  tags = { Name = "${var.prefix}-worker-${count.index}" }
}

# ---------- Elastic Cloud ----------

resource "ec_deployment" "this" {
  name                   = "${var.prefix}-elastic"
  region                 = "aws-eu-north-1"
  version                = data.ec_stack.latest.version
  deployment_template_id = "aws-general-purpose-faster-warm"

  elasticsearch = {
    hot = {
      autoscaling = {}
      size        = "2g"
      zone_count  = 1
    }
  }

  kibana = {
    size       = "1g"
    zone_count = 1
  }

  integrations_server = {
    size       = "1g"
    zone_count = 1
  }

}
