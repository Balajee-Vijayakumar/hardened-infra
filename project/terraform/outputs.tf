##############################################
# outputs.tf — All deployed resource details
##############################################

output "instance_id" {
  description = "EC2 Instance ID"
  value       = aws_instance.hardened.id
}

output "private_ip" {
  description = "Instance private IP address"
  value       = aws_instance.hardened.private_ip
}

output "ami_id" {
  description = "AMI ID used for the instance"
  value       = local.ami_id
}

output "os_type" {
  description = "Operating system deployed"
  value       = var.os_type
}

output "os_version" {
  description = "OS version deployed"
  value       = var.os_version
}

output "instance_type" {
  description = "EC2 instance type"
  value       = var.instance_type
}

output "environment" {
  description = "Deployment environment"
  value       = var.environment
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "private_subnet_id" {
  description = "Private subnet ID"
  value       = aws_subnet.private.id
}

output "nat_gateway_ip" {
  description = "NAT Gateway Elastic IP (for outbound traffic whitelisting)"
  value       = aws_eip.nat.public_ip
}

output "ssm_session_command" {
  description = "Run this command to connect to the instance (no SSH needed)"
  value       = "aws ssm start-session --target ${aws_instance.hardened.id} --region ${var.aws_region}"
}

output "log_group_name" {
  description = "CloudWatch Log Group"
  value       = aws_cloudwatch_log_group.instance.name
}

output "alarm_topic_arn" {
  description = "SNS Topic ARN for CloudWatch alarms"
  value       = aws_sns_topic.alarms.arn
}

output "patch_group" {
  description = "SSM Patch Manager target tag value"
  value       = "hardened-${var.environment}"
}
