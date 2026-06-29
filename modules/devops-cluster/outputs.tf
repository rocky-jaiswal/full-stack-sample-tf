output "server_instance_id" {
  description = "SSM target ID for the K3s server node"
  value       = aws_instance.server.id
}

output "agent_instance_id" {
  description = "SSM target ID for the K3s agent node"
  value       = aws_instance.agent.id
}

output "cluster_sg_id" {
  description = "Security group ID shared by all cluster nodes (used by RDS/ElastiCache to allow inbound)"
  value       = aws_security_group.devops_cluster.id
}

output "server_private_ip" {
  description = "Private IP of the K3s server node"
  value       = aws_instance.server.private_ip
}
