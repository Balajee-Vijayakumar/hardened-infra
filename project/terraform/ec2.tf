##############################################
# ec2.tf — AMI lookup, instance, userdata,
#           patch association, DLM snapshots
##############################################

# ── AMI Discovery (no Lambda needed in TF!) ──
# Terraform has a native data source for this.
# Much simpler than the CFN Lambda approach.

data "aws_ami" "ubuntu" {
  count       = var.os_type == "Ubuntu" ? 1 : 0
  most_recent = true
  owners      = ["099720109477"] # Canonical official

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-*-${var.os_version}-amd64-server-*"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

data "aws_ami" "rocky" {
  count       = var.os_type == "RockyLinux" ? 1 : 0
  most_recent = true
  owners      = ["679593333241"] # Rocky Linux official

  filter {
    name   = "name"
    values = ["Rocky-${var.os_version}-EC2-*"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

locals {
  ami_id = var.os_type == "Ubuntu" ? data.aws_ami.ubuntu[0].id : data.aws_ami.rocky[0].id

  # CloudWatch agent config JSON — shipped to instance via userdata
  cw_agent_config = jsonencode({
    agent = {
      metrics_collection_interval = 60
      run_as_user                 = "root"
    }
    logs = {
      logs_collected = {
        files = {
          collect_list = [
            {
              file_path        = "/var/log/syslog"
              log_group_name   = "/ec2/hardened/${var.environment}"
              log_stream_name  = "{instance_id}/syslog"
            },
            {
              file_path        = "/var/log/auth.log"
              log_group_name   = "/ec2/hardened/${var.environment}"
              log_stream_name  = "{instance_id}/auth"
            },
            {
              file_path        = "/var/log/secure"
              log_group_name   = "/ec2/hardened/${var.environment}"
              log_stream_name  = "{instance_id}/secure"
            },
            {
              file_path        = "/var/log/userdata.log"
              log_group_name   = "/ec2/hardened/${var.environment}/userdata"
              log_stream_name  = "{instance_id}/userdata"
            }
          ]
        }
      }
    }
    metrics = {
      metrics_collected = {
        disk = {
          measurement                 = ["used_percent"]
          resources                   = ["/"]
          metrics_collection_interval = 60
        }
        mem = {
          measurement                 = ["mem_used_percent"]
          metrics_collection_interval = 60
        }
      }
    }
  })

  userdata = <<-USERDATA
    #!/bin/bash
    set -euo pipefail
    exec > >(tee /var/log/userdata.log | logger -t userdata) 2>&1

    echo "=== Starting CIS hardening ==="

    # ── SSH Hardening ──────────────────────────────────
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/'               /etc/ssh/sshd_config
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    systemctl restart sshd

    # ── OS detection ──────────────────────────────────
    if command -v apt &>/dev/null; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y auditd ufw unattended-upgrades awscli

      wget -q https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
      dpkg -i amazon-cloudwatch-agent.deb
      rm amazon-cloudwatch-agent.deb

      ufw --force enable
    else
      yum update -y
      yum install -y audit firewalld awscli
      rpm -Uvh https://s3.amazonaws.com/amazoncloudwatch-agent/redhat/amd64/latest/amazon-cloudwatch-agent.rpm
      systemctl enable --now firewalld
    fi

    systemctl enable --now auditd

    # ── Kernel hardening ──────────────────────────────
    cat >> /etc/sysctl.conf <<'EOF'
    net.ipv4.ip_forward=0
    net.ipv4.conf.all.accept_redirects=0
    net.ipv4.conf.default.accept_redirects=0
    net.ipv4.conf.all.send_redirects=0
    net.ipv4.conf.all.log_martians=1
    kernel.randomize_va_space=2
    EOF
    sysctl -p

    # ── CloudWatch Agent config ────────────────────────
    cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'CWEOF'
    ${local.cw_agent_config}
    CWEOF

    /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
      -a fetch-config -m ec2 -s \
      -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

    systemctl enable amazon-cloudwatch-agent
    systemctl start  amazon-cloudwatch-agent

    echo "=== Hardening complete ==="
  USERDATA
}

# ── EC2 Instance ─────────────────────────────
resource "aws_instance" "hardened" {
  ami                  = local.ami_id
  instance_type        = var.instance_type
  subnet_id            = aws_subnet.private.id
  iam_instance_profile = aws_iam_instance_profile.instance.name

  vpc_security_group_ids = [aws_security_group.instance.id]

  monitoring                           = var.enable_detailed_monitoring
  disable_api_termination              = var.enable_termination_protection
  user_data                            = local.userdata
  user_data_replace_on_change          = true

  metadata_options {
    http_tokens                 = "required"   # IMDSv2 enforced
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size           = var.volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = var.delete_volume_on_termination
  }

  depends_on = [
    aws_vpc_endpoint.ssm,
    aws_vpc_endpoint.ec2messages,
    aws_vpc_endpoint.ssmmessages,
    aws_nat_gateway.nat
  ]

  tags = {
    Name       = "HardenedEC2-${var.environment}"
    PatchGroup = "hardened-${var.environment}"
  }
}

# ── SSM Patch Association ─────────────────────
resource "aws_ssm_association" "patch" {
  name                = "AWS-RunPatchBaseline"
  schedule_expression = var.patch_schedule

  targets {
    key    = "tag:PatchGroup"
    values = ["hardened-${var.environment}"]
  }
}

# ── DLM Snapshot Lifecycle Policy ────────────
resource "aws_iam_role" "dlm" {
  name_prefix = "DLMRole-${var.environment}-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "dlm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "snapshots" {
  description        = "Daily EBS snapshots - ${var.environment} - ${var.stack_owner}"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["INSTANCE"]

    target_tags = {
      Environment = var.environment
    }

    schedule {
      name = "DailySnapshots"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = [var.snapshot_time]
      }

      retain_rule {
        count = var.snapshot_retention_count
      }

      copy_tags = true
    }
  }

  tags = { Name = "DLMPolicy-${var.environment}" }
}
