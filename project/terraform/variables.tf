##############################################
# variables.tf — All inputs, no defaults
# Every variable is prompted at terraform apply
##############################################

variable "environment" {
  description = "Deployment environment (dev / stage / prod)"
  type        = string
  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "Must be dev, stage, or prod."
  }
}

variable "stack_owner" {
  description = "Owner name or team — applied as a tag to every resource. Example: platform-team"
  type        = string
}

variable "os_type" {
  description = "Operating system: Ubuntu or RockyLinux"
  type        = string
  validation {
    condition     = contains(["Ubuntu", "RockyLinux"], var.os_type)
    error_message = "Must be Ubuntu or RockyLinux."
  }
}

variable "os_version" {
  description = "OS version. Ubuntu examples: 22.04 / 24.04  |  RockyLinux examples: 8 / 9"
  type        = string
  validation {
    condition     = can(regex("^[0-9]+\\.?[0-9]*$", var.os_version))
    error_message = "Must be a version number like 22.04 or 9."
  }
}

variable "instance_type" {
  description = "EC2 instance type. t3=burstable, m5=consistent CPU (use m5 for prod)"
  type        = string
  validation {
    condition = contains([
      "t3.micro", "t3.small", "t3.medium", "t3.large",
      "m5.large", "m5.xlarge", "m5.2xlarge"
    ], var.instance_type)
    error_message = "Must be one of: t3.micro, t3.small, t3.medium, t3.large, m5.large, m5.xlarge, m5.2xlarge."
  }
}

variable "volume_size" {
  description = "Root EBS volume size in GB. Min 20 (Ubuntu) or 30 (RockyLinux), max 500."
  type        = number
  validation {
    condition     = var.volume_size >= 20 && var.volume_size <= 500
    error_message = "Volume size must be between 20 and 500 GB."
  }
}

variable "delete_volume_on_termination" {
  description = "Delete EBS volume when instance is terminated? false = retain data (recommended for prod)"
  type        = bool
}

variable "enable_detailed_monitoring" {
  description = "Enable 1-minute CloudWatch metrics? true = extra granularity (small cost)"
  type        = bool
}

variable "enable_termination_protection" {
  description = "Prevent accidental instance termination via CLI/console?"
  type        = bool
}

variable "vpc_cidr" {
  description = "VPC CIDR block. Example: 10.10.0.0/16"
  type        = string
  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "Must be a valid CIDR block e.g. 10.10.0.0/16."
  }
}

variable "private_subnet_cidr" {
  description = "Private subnet CIDR (must be subset of vpc_cidr). Example: 10.10.1.0/24"
  type        = string
  validation {
    condition     = can(cidrhost(var.private_subnet_cidr, 0))
    error_message = "Must be a valid CIDR block e.g. 10.10.1.0/24."
  }
}

variable "public_subnet_cidr" {
  description = "Public subnet CIDR for NAT gateway (must be subset of vpc_cidr). Example: 10.10.0.0/24"
  type        = string
  validation {
    condition     = can(cidrhost(var.public_subnet_cidr, 0))
    error_message = "Must be a valid CIDR block e.g. 10.10.0.0/24."
  }
}

variable "patch_schedule" {
  description = "SSM patch cron schedule UTC. Example: cron(0 2 ? * SUN *)"
  type        = string
  validation {
    condition     = can(regex("^cron\\(.*\\)$", var.patch_schedule))
    error_message = "Must be a valid SSM cron expression e.g. cron(0 2 ? * SUN *)."
  }
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days. Allowed: 1,3,7,14,30,60,90,180,365"
  type        = number
  validation {
    condition     = contains([1, 3, 7, 14, 30, 60, 90, 180, 365], var.log_retention_days)
    error_message = "Must be one of: 1, 3, 7, 14, 30, 60, 90, 180, 365."
  }
}

variable "snapshot_retention_count" {
  description = "Number of daily EBS snapshots to keep. 7 = one week, 30 = one month."
  type        = number
  validation {
    condition     = var.snapshot_retention_count >= 1 && var.snapshot_retention_count <= 365
    error_message = "Must be between 1 and 365."
  }
}

variable "snapshot_time" {
  description = "Daily snapshot time UTC in HH:MM format. Example: 03:00"
  type        = string
  validation {
    condition     = can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", var.snapshot_time))
    error_message = "Must be HH:MM format e.g. 03:00."
  }
}

variable "alarm_email" {
  description = "Email address for CloudWatch alarm notifications."
  type        = string
  validation {
    condition     = can(regex("^[a-zA-Z0-9._%+\\-]+@[a-zA-Z0-9.\\-]+\\.[a-zA-Z]{2,}$", var.alarm_email))
    error_message = "Must be a valid email address."
  }
}

variable "cpu_alarm_threshold" {
  description = "CPU % threshold to trigger alarm. Recommended: 80"
  type        = number
  validation {
    condition     = var.cpu_alarm_threshold >= 1 && var.cpu_alarm_threshold <= 100
    error_message = "Must be between 1 and 100."
  }
}

variable "disk_alarm_threshold" {
  description = "Disk used % threshold to trigger alarm. Recommended: 85"
  type        = number
  validation {
    condition     = var.disk_alarm_threshold >= 1 && var.disk_alarm_threshold <= 100
    error_message = "Must be between 1 and 100."
  }
}

variable "aws_region" {
  description = "AWS region to deploy into. Example: us-east-1"
  type        = string
}
