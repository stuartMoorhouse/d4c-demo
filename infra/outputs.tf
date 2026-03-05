output "control_plane_public_ip" {
  value = aws_spot_instance_request.control.public_ip
}

output "worker_public_ips" {
  value = aws_spot_instance_request.worker[*].public_ip
}

output "ssh_key_path" {
  value = local_file.ssh_key.filename
}

output "elasticsearch_url" {
  value = ec_deployment.this.elasticsearch.https_endpoint
}

output "kibana_url" {
  value = ec_deployment.this.kibana.https_endpoint
}

output "fleet_url" {
  value = ec_deployment.this.integrations_server.https_endpoint
}

output "elasticsearch_password" {
  value     = ec_deployment.this.elasticsearch_password
  sensitive = true
}


output "elastic_version" {
  value = data.ec_stack.latest.version
}

output "region" {
  value = var.region
}

output "prefix" {
  value = var.prefix
}
