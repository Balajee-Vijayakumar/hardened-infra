##############################################
# security_groups.tf — Instance SG
# Note: endpoint SG is in vpc.tf because it
# references instance SG (dependency order)
##############################################

resource "aws_security_group" "instance" {
  name        = "InstanceSG-${var.environment}"
  description = "Hardened instance - ${var.environment} - SSM only, no inbound SSH"
  vpc_id      = aws_vpc.main.id

  # No ingress rules — zero inbound traffic
  # Access via SSM Session Manager through VPC endpoints only

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS for SSM, CloudWatch, package repos"
  }

  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP for package repos"
  }

  tags = { Name = "InstanceSG-${var.environment}" }
}
