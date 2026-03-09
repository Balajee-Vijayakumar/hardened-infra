# 🛡️ Hardened EC2 — Enterprise Infrastructure

Fully parameterized, CIS-hardened EC2 deployment.
Supports **CloudFormation** (GitHub → CodePipeline auto-deploy) and **Terraform** (local apply).

---

## 📁 Repository Structure

```
hardened-infra/
├── cloudformation/
│   ├── hardened-ec2.yaml          ← Main CFN template
│   ├── pipeline.yaml              ← CodePipeline (GitHub → CFN auto-deploy)
│   └── parameters/
│       ├── dev.json               ← Dev environment values
│       └── prod.json              ← Prod environment values
├── terraform/
│   ├── main.tf                    ← Provider + backend
│   ├── variables.tf               ← All inputs with validation
│   ├── vpc.tf                     ← VPC, subnets, NAT, endpoints
│   ├── iam.tf                     ← IAM roles
│   ├── security_groups.tf         ← Instance SG
│   ├── ec2.tf                     ← Instance, AMI lookup, userdata, patching
│   ├── monitoring.tf              ← Log groups, SNS, alarms
│   ├── outputs.tf                 ← All resource details printed after deploy
│   └── terraform.tfvars.example   ← Copy → terraform.tfvars (gitignored)
├── scripts/
│   └── deploy.sh                  ← Interactive deploy script
├── .gitignore
└── README.md
```

---

## ✅ Pre-Requirements

### Tools to install on your local machine

| Tool | Version | Install |
|------|---------|---------|
| AWS CLI | v2+ | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| Terraform | ≥ 1.6.0 | https://developer.hashicorp.com/terraform/install |
| Git | any | https://git-scm.com |
| Python 3 | 3.8+ | Pre-installed on most systems |

Check all are installed:
```bash
aws --version
terraform --version
git --version
python3 --version
```

### AWS account requirements

- An AWS account with permissions to create: EC2, VPC, IAM, Lambda, SSM, CloudWatch, DLM, CodePipeline
- AWS CLI configured with your credentials:
  ```bash
  aws configure
  # Enter: Access Key ID, Secret Access Key, Region, output format (json)
  ```
- Verify it works:
  ```bash
  aws sts get-caller-identity
  ```

---

## 🚀 Setup Steps

### Step 1 — Clone / initialise the repository

```bash
# Clone this repo (or create new and copy files in)
git clone https://github.com/YOUR-USERNAME/hardened-infra.git
cd hardened-infra

# Make deploy script executable
chmod +x scripts/deploy.sh
```

---

### Step 2 — Create a GitHub repository

1. Go to https://github.com/new
2. Create a **private** repository named `hardened-infra`
3. Push this project to it:

```bash
git remote add origin https://github.com/YOUR-USERNAME/hardened-infra.git
git branch -M main
git push -u origin main
```

---

### Step 3 — (CloudFormation only) Create a GitHub CodeStar Connection

> Skip this step if using Terraform only.

This is a one-time setup that lets AWS CodePipeline read your GitHub repo.

1. Open AWS Console → **Developer Tools** → **Settings** → **Connections**
2. Click **Create connection** → choose **GitHub**
3. Name it `github-connection`
4. Click **Connect to GitHub** → authorise AWS in the GitHub OAuth popup
5. Click **Connect**
6. Copy the **Connection ARN** — you'll need it in Step 4
   - Looks like: `arn:aws:codestar-connections:us-east-1:123456789012:connection/xxxxxxxx`

---

### Step 4 — (CloudFormation only) Create the S3 artifact bucket + deploy pipeline

CodePipeline needs an S3 bucket to store pipeline artifacts. Create it once:

```bash
# Replace with your own unique bucket name and region
BUCKET_NAME="my-pipeline-artifacts-$(aws sts get-caller-identity --query Account --output text)"
REGION="us-east-1"

aws s3 mb s3://$BUCKET_NAME --region $REGION
aws s3api put-bucket-versioning \
  --bucket $BUCKET_NAME \
  --versioning-configuration Status=Enabled
```

Now deploy the pipeline stack (this is a one-time setup per environment):

```bash
aws cloudformation deploy \
  --template-file cloudformation/pipeline.yaml \
  --stack-name hardened-ec2-pipeline-dev \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
      GitHubOwner=YOUR-GITHUB-USERNAME \
      GitHubRepo=hardened-infra \
      GitHubBranch=main \
      GitHubConnectionArn=arn:aws:codestar-connections:us-east-1:ACCOUNT:connection/XXXX \
      ArtifactBucketName=$BUCKET_NAME \
      Environment=dev \
      StackOwner=your-name \
      OSType=Ubuntu \
      OSVersion=22.04 \
      InstanceType=t3.medium \
      VolumeSize=30 \
      DeleteVolumeOnTermination=false \
      EnableDetailedMonitoring=false \
      EnableTerminationProtection=false \
      VpcCIDR=10.10.0.0/16 \
      SubnetCIDR=10.10.1.0/24 \
      NATSubnetCIDR=10.10.0.0/24 \
      PatchSchedule="cron(0 2 ? * SUN *)" \
      LogRetentionDays=14 \
      SnapshotRetentionCount=7 \
      SnapshotTime=03:00 \
      AlarmEmail=you@example.com \
      CPUAlarmThreshold=80 \
      DiskAlarmThreshold=85
```

**After this, every `git push` to main automatically triggers a deployment.**

---

### Step 5 — Run the deploy script

```bash
./scripts/deploy.sh
```

The script will:

1. Ask you: **CloudFormation** or **Terraform**?
2. Ask you: **dev**, **stage**, or **prod**?
3. Ask for all configuration values interactively
4. Commit and push your code to GitHub
5. Deploy the infrastructure
6. Print all deployed resource details to the screen

---

### Step 6 — Confirm your alarm email

After deploying, AWS sends an email to the address you provided.
**You must click "Confirm subscription"** in that email for CloudWatch alarms to notify you.

---

### Step 7 — Connect to your instance

No SSH needed. Use SSM Session Manager:

```bash
# The exact command is printed at the end of deploy.sh
aws ssm start-session --target i-0abc123def456 --region us-east-1
```

Or via AWS Console: EC2 → Instances → Select instance → Connect → Session Manager

---

## 🔁 Day-to-day workflow (after first setup)

```bash
# Make changes to any template or Terraform file
vim cloudformation/hardened-ec2.yaml

# Run deploy script — it commits, pushes, and deploys
./scripts/deploy.sh

# CloudFormation: CodePipeline picks up the push and deploys automatically
# Terraform: script runs terraform plan → confirm → apply
```

---

## 🗑️ Tear down

### CloudFormation
```bash
# Delete the EC2 stack
aws cloudformation delete-stack --stack-name hardened-ec2-dev

# Delete the pipeline stack (optional)
aws cloudformation delete-stack --stack-name hardened-ec2-pipeline-dev
```

### Terraform
```bash
cd terraform
terraform destroy
```

> ⚠️  If you set `DeleteVolumeOnTermination=false` (recommended for prod),
> the EBS volume will remain after stack deletion. Delete it manually in EC2 → Volumes.

---

## 💰 Cost reminder (us-east-1 per day)

| Component | Daily cost |
|-----------|-----------|
| NAT Gateway | ~$1.08 |
| VPC Endpoints × 3 | ~$0.72 |
| EC2 t3.medium | ~$1.00 |
| EBS 30 GB | ~$0.10 |
| Everything else | ~$0.10 |
| **Total (dev)** | **~$3.00/day** |

Stop costs when not in use: `aws ec2 stop-instances --instance-ids i-xxxx`
NAT gateway still runs — delete the stack to stop all charges.

---

## 🛡️ Security controls summary

- IMDSv2 enforced (blocks SSRF attacks)
- Zero inbound security group rules (SSM-only access)
- EBS encrypted at rest
- Root login and password auth disabled
- auditd syscall auditing
- Host-based firewall (ufw / firewalld)
- Full ASLR enabled
- IP forwarding disabled
- Weekly automated patching via SSM
- CloudWatch alarms for CPU, disk, status checks
- Daily EBS snapshots
