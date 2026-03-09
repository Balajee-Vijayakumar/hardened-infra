##############################################
# iam.tf — Instance role + DLM role
##############################################

# ── EC2 Instance Role ─────────────────────────
resource "aws_iam_role" "instance" {
  name_prefix = "HardenedInstanceRole-${var.environment}-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "HardenedInstanceRole-${var.environment}" }
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "instance" {
  name_prefix = "HardenedProfile-${var.environment}-"
  role        = aws_iam_role.instance.name
  tags        = { Name = "HardenedProfile-${var.environment}" }
}
