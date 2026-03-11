#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Fully automated interactive deployment script
#
# Automates:
#   - AWS CodeStar GitHub connection creation  (Step 3)
#   - S3 artifact bucket creation              (Step 4)
#   - CodePipeline stack deployment            (Step 4)
#   - Git push to GitHub
#   - CloudFormation OR Terraform deployment
#   - Post-deploy infra summary printed to screen
# =============================================================================
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m';  RESET='\033[0m'
DIM='\033[2m'

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[ ✔ ]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERR]${RESET}   $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n  $*\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"; }
ask()     { echo -ne "${YELLOW}▶ $* ${RESET}"; }
divider() { echo -e "${DIM}───────────────────────────────────────────${RESET}"; }

# ── Spinner ───────────────────────────────────────────────────────────────────
spinner() {
  local pid=$1 msg=$2
  local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  ${CYAN}${spin:$((i % ${#spin})):1}${RESET}  $msg"
    i=$((i+1)); sleep 0.1
  done
  printf "\r"
}

# ── Pre-flight checks ─────────────────────────────────────────────────────────
check_deps() {
  header "Pre-flight Checks"
  local missing=0
  for cmd in aws git python3; do
    if command -v "$cmd" &>/dev/null; then
      success "$cmd found"
    else
      echo -e "  ${RED}✘${RESET}  $cmd not found — install it first"
      missing=$((missing+1))
    fi
  done

  if [[ "$TOOL" == "terraform" ]]; then
    if command -v terraform &>/dev/null; then
      success "terraform found"
    else
      echo -e "  ${RED}✘${RESET}  terraform not found — install from https://developer.hashicorp.com/terraform/install"
      missing=$((missing+1))
    fi
  fi

  [[ $missing -gt 0 ]] && error "$missing required tool(s) missing. Install and re-run."

  info "Checking AWS credentials..."
  CALLER=$(aws sts get-caller-identity --output json 2>/dev/null) \
    || error "AWS credentials not configured. Run: aws configure"
  AWS_ACCOUNT=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
  AWS_ARN=$(echo     "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'])")
  success "AWS authenticated  →  $AWS_ARN"
}

# =============================================================================
# BANNER
# =============================================================================
clear
echo -e "${BOLD}${BLUE}"
cat <<'BANNER'
 ██╗  ██╗ █████╗ ██████╗ ██████╗ ███████╗███╗   ██╗███████╗██████╗
 ██║  ██║██╔══██╗██╔══██╗██╔══██╗██╔════╝████╗  ██║██╔════╝██╔══██╗
 ███████║███████║██████╔╝██║  ██║█████╗  ██╔██╗ ██║█████╗  ██║  ██║
 ██╔══██║██╔══██║██╔══██╗██║  ██║██╔══╝  ██║╚██╗██║██╔══╝  ██║  ██║
 ██║  ██║██║  ██║██║  ██║██████╔╝███████╗██║ ╚████║███████╗██████╔╝
 ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝ ╚══════╝╚═╝  ╚═══╝╚══════╝╚═════╝
          Enterprise Hardened EC2 — Fully Automated Deployment
BANNER
echo -e "${RESET}"

# =============================================================================
# STEP 1 — Choose tool
# =============================================================================
header "Step 1: Choose Deployment Tool"
echo -e "  ${BOLD}1)${RESET} CloudFormation  — Push to GitHub → CodePipeline auto-deploys on every commit"
echo -e "  ${BOLD}2)${RESET} Terraform       — Push to GitHub → terraform apply runs locally"
echo ""
ask "Enter choice [1 or 2]:"
read -r TOOL_CHOICE
case "$TOOL_CHOICE" in
  1) TOOL="cloudformation"; success "Selected: CloudFormation + CodePipeline" ;;
  2) TOOL="terraform";      success "Selected: Terraform" ;;
  *) error "Invalid choice. Enter 1 or 2." ;;
esac

# =============================================================================
# STEP 2 — Environment
# =============================================================================
header "Step 2: Choose Environment"
echo -e "  ${BOLD}1)${RESET} dev    — t3.medium, 7-day logs, no termination protection"
echo -e "  ${BOLD}2)${RESET} stage  — t3.large,  30-day logs"
echo -e "  ${BOLD}3)${RESET} prod   — m5.large,  365-day logs, termination protection ON"
echo ""
ask "Enter choice [1/2/3]:"
read -r ENV_CHOICE
case "$ENV_CHOICE" in
  1) ENVIRONMENT="dev"   ;;
  2) ENVIRONMENT="stage" ;;
  3) ENVIRONMENT="prod"  ;;
  *) error "Invalid choice." ;;
esac
success "Environment: $ENVIRONMENT"

check_deps

# =============================================================================
# STEP 3 — Collect configuration
# =============================================================================
header "Step 3: Configuration"

# Auto-detect region from EC2 instance metadata (works when running on EC2)
DETECTED_REGION=$(curl -s --connect-timeout 2 \
  http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "")

# Also check AWS CLI config as fallback
if [[ -z "$DETECTED_REGION" ]]; then
  DETECTED_REGION=$(aws configure get region 2>/dev/null || echo "")
fi

if [[ -n "$DETECTED_REGION" ]]; then
  info "Auto-detected region: ${BOLD}$DETECTED_REGION${RESET}"
  ask "AWS Region [${DETECTED_REGION}]:"
  read -r AWS_REGION
  AWS_REGION="${AWS_REGION:-$DETECTED_REGION}"
else
  ask "AWS Region (e.g. us-east-1):"
  read -r AWS_REGION
fi

# Validate region is not empty
[[ -z "$AWS_REGION" ]] && error "Region cannot be empty. Re-run and enter your AWS region (e.g. ap-south-1)"

# Export so all AWS CLI calls in this session use it
export AWS_DEFAULT_REGION="$AWS_REGION"
success "Region set to: $AWS_REGION"

ask "Your name or team (Owner tag, e.g. platform-team):"
read -r STACK_OWNER

divider
echo -e "  ${BOLD}Operating System:${RESET}"
echo -e "  1) Ubuntu     (Canonical LTS)"
echo -e "  2) RockyLinux (RHEL-compatible, enterprise)"
ask "Choice [1/2]:"
read -r OS_CHOICE
case "$OS_CHOICE" in
  1) OS_TYPE="Ubuntu";
     ask "Ubuntu version (20.04 / 22.04 / 24.04) [22.04]:";
     read -r OS_VERSION; OS_VERSION="${OS_VERSION:-22.04}" ;;
  2) OS_TYPE="RockyLinux";
     ask "RockyLinux version (8 / 9) [9]:";
     read -r OS_VERSION; OS_VERSION="${OS_VERSION:-9}" ;;
  *) error "Invalid OS choice." ;;
esac

divider
echo -e "  ${BOLD}Instance Type:${RESET}"
echo -e "  1) t3.micro   — Testing only  (~\$2.25/day total)"
echo -e "  2) t3.small   — Light dev     (~\$2.50/day total)"
echo -e "  3) t3.medium  — Dev ✅        (~\$3.00/day total)"
echo -e "  4) t3.large   — Heavy dev     (~\$4.00/day total)"
echo -e "  5) m5.large   — Production    (~\$4.30/day total)"
echo -e "  6) m5.xlarge  — Prod medium   (~\$6.60/day total)"
echo -e "  7) m5.2xlarge — Prod heavy    (~\$11.20/day total)"
ask "Choice [1-7]:"
read -r IT_CHOICE
case "$IT_CHOICE" in
  1) INSTANCE_TYPE="t3.micro"   ;;
  2) INSTANCE_TYPE="t3.small"   ;;
  3) INSTANCE_TYPE="t3.medium"  ;;
  4) INSTANCE_TYPE="t3.large"   ;;
  5) INSTANCE_TYPE="m5.large"   ;;
  6) INSTANCE_TYPE="m5.xlarge"  ;;
  7) INSTANCE_TYPE="m5.2xlarge" ;;
  *) error "Invalid instance type choice." ;;
esac

ask "Volume size GB (min 20 Ubuntu / 30 Rocky) [30]:"
read -r VOLUME_SIZE; VOLUME_SIZE="${VOLUME_SIZE:-30}"

ask "Delete volume on termination? (yes/no) [no]:"
read -r IN; IN="${IN:-no}"; [[ "$IN" =~ ^(yes|y)$ ]] && DELETE_VOL="true" || DELETE_VOL="false"

ask "Enable detailed monitoring 1-min metrics? (yes/no) [no]:"
read -r IN; IN="${IN:-no}"; [[ "$IN" =~ ^(yes|y)$ ]] && DETAILED_MON="true" || DETAILED_MON="false"

ask "Enable termination protection? (yes/no) [no]:"
read -r IN; IN="${IN:-no}"; [[ "$IN" =~ ^(yes|y)$ ]] && TERM_PROT="true" || TERM_PROT="false"

divider
echo -e "  ${BOLD}Key Pair (optional — only needed if you want SSH access):${RESET}"
echo -e "  ${DIM}Note: Instance is accessible via SSM without any key pair.${RESET}"

# List existing key pairs
EXISTING_KEYS=$(aws ec2 describe-key-pairs --region "$AWS_REGION" \
  --query 'KeyPairs[*].KeyName' --output text 2>/dev/null | tr '\t' '\n')

if [[ -n "$EXISTING_KEYS" ]]; then
  echo -e "\n  ${BOLD}Existing key pairs in $AWS_REGION:${RESET}"
  i=1
  while IFS= read -r key; do
    echo -e "  $i) $key"
    i=$((i+1))
  done <<< "$EXISTING_KEYS"
  echo -e "  $i) Create a new key pair"
  echo -e "  $((i+1))) Skip — use SSM only (no key pair)"
  ask "Choice [${i+1}]:"
  read -r KEY_CHOICE
  KEY_CHOICE="${KEY_CHOICE:-$((i+1))}"

  TOTAL_OPTIONS=$((i+1))
  if [[ "$KEY_CHOICE" == "$TOTAL_OPTIONS" ]]; then
    KEY_PAIR_NAME=""
    info "No key pair — SSM access only."
  elif [[ "$KEY_CHOICE" == "$((TOTAL_OPTIONS-1))" ]]; then
    ask "New key pair name [hardened-ec2-${ENVIRONMENT}]:"
    read -r KEY_PAIR_NAME; KEY_PAIR_NAME="${KEY_PAIR_NAME:-hardened-ec2-${ENVIRONMENT}}"
    info "Creating key pair: $KEY_PAIR_NAME"
    aws ec2 create-key-pair \
      --key-name "$KEY_PAIR_NAME" \
      --region "$AWS_REGION" \
      --query 'KeyMaterial' \
      --output text > "${KEY_PAIR_NAME}.pem"
    chmod 400 "${KEY_PAIR_NAME}.pem"
    success "Key pair created → ${KEY_PAIR_NAME}.pem  (save this file — shown only once!)"
  else
    KEY_PAIR_NAME=$(echo "$EXISTING_KEYS" | sed -n "${KEY_CHOICE}p")
    success "Using existing key pair: $KEY_PAIR_NAME"
  fi
else
  echo -e "  ${DIM}No existing key pairs found.${RESET}"
  echo -e "  1) Create a new key pair"
  echo -e "  2) Skip — use SSM only (no key pair)"
  ask "Choice [2]:"
  read -r KEY_CHOICE; KEY_CHOICE="${KEY_CHOICE:-2}"
  if [[ "$KEY_CHOICE" == "1" ]]; then
    ask "New key pair name [hardened-ec2-${ENVIRONMENT}]:"
    read -r KEY_PAIR_NAME; KEY_PAIR_NAME="${KEY_PAIR_NAME:-hardened-ec2-${ENVIRONMENT}}"
    info "Creating key pair: $KEY_PAIR_NAME"
    aws ec2 create-key-pair \
      --key-name "$KEY_PAIR_NAME" \
      --region "$AWS_REGION" \
      --query 'KeyMaterial' \
      --output text > "${KEY_PAIR_NAME}.pem"
    chmod 400 "${KEY_PAIR_NAME}.pem"
    success "Key pair created → ${KEY_PAIR_NAME}.pem  (save this file — shown only once!)"
  else
    KEY_PAIR_NAME=""
    info "No key pair — SSM access only."
  fi
fi

divider
info "Networking (press Enter to accept defaults)"
ask "VPC CIDR [10.10.0.0/16]:"
read -r VPC_CIDR; VPC_CIDR="${VPC_CIDR:-10.10.0.0/16}"
ask "Private subnet CIDR [10.10.1.0/24]:"
read -r PRIVATE_CIDR; PRIVATE_CIDR="${PRIVATE_CIDR:-10.10.1.0/24}"
ask "Public subnet CIDR for NAT [10.10.0.0/24]:"
read -r PUBLIC_CIDR; PUBLIC_CIDR="${PUBLIC_CIDR:-10.10.0.0/24}"

divider
info "Patch / Logging / Snapshots"
ask "Patch cron schedule [cron(0 2 ? * SUN *)]:"
read -r PATCH_SCHED; PATCH_SCHED="${PATCH_SCHED:-cron(0 2 ? * SUN *)}"
ask "Log retention days (7/14/30/90/365) [14]:"
read -r LOG_DAYS; LOG_DAYS="${LOG_DAYS:-14}"
ask "Snapshot retention count [7]:"
read -r SNAP_COUNT; SNAP_COUNT="${SNAP_COUNT:-7}"
ask "Snapshot time UTC HH:MM [03:00]:"
read -r SNAP_TIME; SNAP_TIME="${SNAP_TIME:-03:00}"

divider
info "Alarms"
ask "Notification email address:"
read -r ALARM_EMAIL
ask "CPU alarm threshold % [80]:"
read -r CPU_THRESH; CPU_THRESH="${CPU_THRESH:-80}"
ask "Disk alarm threshold % [85]:"
read -r DISK_THRESH; DISK_THRESH="${DISK_THRESH:-85}"

divider
success "All configuration collected."

# =============================================================================
# STEP 4 — Git push
# =============================================================================
header "Step 4: Push Code to GitHub"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

git rev-parse --git-dir &>/dev/null \
  || error "Not a git repository. Run: git init && git remote add origin <url>"
REMOTE_URL=$(git remote get-url origin 2>/dev/null) \
  || error "No git remote 'origin'. Run: git remote add origin <url>"

# Parse GitHub owner/repo from either HTTPS or SSH remote URL
if [[ "$REMOTE_URL" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
  GITHUB_OWNER="${BASH_REMATCH[1]}"
  GITHUB_REPO="${BASH_REMATCH[2]}"
else
  error "Could not parse GitHub owner/repo from: $REMOTE_URL"
fi

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
info "Repo   : github.com/$GITHUB_OWNER/$GITHUB_REPO"
info "Branch : $CURRENT_BRANCH"

ask "Commit message [infra: deploy $ENVIRONMENT - $(date '+%Y-%m-%d %H:%M')]:"
read -r COMMIT_MSG
COMMIT_MSG="${COMMIT_MSG:-infra: deploy $ENVIRONMENT - $(date '+%Y-%m-%d %H:%M')}"

git add .
git diff --cached --quiet \
  && warn "Nothing new to commit — pushing existing HEAD" \
  || git commit -m "$COMMIT_MSG"
git push origin "$CURRENT_BRANCH"

COMMIT_SHA=$(git rev-parse --short HEAD)
success "Pushed commit $COMMIT_SHA → github.com/$GITHUB_OWNER/$GITHUB_REPO"

# =============================================================================
# CloudFormation path
# =============================================================================
deploy_cloudformation() {

  # ── AUTOMATED Step 3: CodeStar GitHub Connection ───────────────────────────
  header "Step 3 (Automated): GitHub CodeStar Connection"

  CONN_NAME="github-connection-${ENVIRONMENT}"
  info "Connection name: $CONN_NAME"

  # Check if it already exists
  EXISTING_CONN=$(aws codestar-connections list-connections \
    --provider-type GitHub \
    --region "$AWS_REGION" \
    --query "Connections[?ConnectionName=='$CONN_NAME'].ConnectionArn" \
    --output text 2>/dev/null || echo "")

  if [[ -n "$EXISTING_CONN" && "$EXISTING_CONN" != "None" ]]; then
    success "Connection already exists."
    CONNECTION_ARN="$EXISTING_CONN"
  else
    info "Creating connection via AWS CLI..."
    CONNECTION_ARN=$(aws codestar-connections create-connection \
      --provider-type GitHub \
      --connection-name "$CONN_NAME" \
      --region "$AWS_REGION" \
      --query 'ConnectionArn' \
      --output text)
    success "Connection created: $CONNECTION_ARN"
  fi

  # Check if GitHub OAuth authorisation is needed (status = PENDING)
  CONN_STATUS=$(aws codestar-connections get-connection \
    --connection-arn "$CONNECTION_ARN" \
    --region "$AWS_REGION" \
    --query 'Connection.ConnectionStatus' \
    --output text)

  if [[ "$CONN_STATUS" != "AVAILABLE" ]]; then
    echo ""
    echo -e "  ${YELLOW}${BOLD}┌──────────────────────────────────────────────────────────┐${RESET}"
    echo -e "  ${YELLOW}${BOLD}│  ACTION NEEDED — GitHub Authorisation (one-time, ~30s)   │${RESET}"
    echo -e "  ${YELLOW}${BOLD}├──────────────────────────────────────────────────────────┤${RESET}"
    echo -e "  ${YELLOW}│  1. Your browser will open the AWS Connections page       │${RESET}"
    echo -e "  ${YELLOW}│  2. Find '${BOLD}${CONN_NAME}${RESET}${YELLOW}' → click 'Update pending connection' │${RESET}"
    echo -e "  ${YELLOW}│  3. Authorise AWS in the GitHub OAuth popup               │${RESET}"
    echo -e "  ${YELLOW}│  4. Return here and press Enter                           │${RESET}"
    echo -e "  ${YELLOW}${BOLD}└──────────────────────────────────────────────────────────┘${RESET}"
    echo ""

    # Auto-open browser
    CONSOLE_URL="https://${AWS_REGION}.console.aws.amazon.com/codesuite/settings/connections"
    if   command -v xdg-open &>/dev/null; then xdg-open "$CONSOLE_URL" &>/dev/null &
    elif command -v open     &>/dev/null; then open     "$CONSOLE_URL" &>/dev/null &
    else info "Open manually: $CONSOLE_URL"; fi

    ask "Press Enter AFTER authorising GitHub in the browser..."
    read -r

    # Poll until AVAILABLE
    info "Polling connection status..."
    MAX=120; WAITED=0
    while true; do
      CONN_STATUS=$(aws codestar-connections get-connection \
        --connection-arn "$CONNECTION_ARN" \
        --region "$AWS_REGION" \
        --query 'Connection.ConnectionStatus' \
        --output text)
      echo -ne "\r  Status: ${BOLD}${CONN_STATUS}${RESET}  (${WAITED}s)   "
      [[ "$CONN_STATUS" == "AVAILABLE" ]] && { echo ""; break; }
      [[ $WAITED -ge $MAX ]] && { echo ""; error "Timed out. Re-run after authorising."; }
      sleep 5; WAITED=$((WAITED+5))
    done
  fi

  success "GitHub connection AVAILABLE ✔  ARN: $CONNECTION_ARN"

  # ── AUTOMATED Step 4a: S3 artifact bucket ──────────────────────────────────
  header "Step 4a (Automated): S3 Artifact Bucket"

  BUCKET_NAME="pipeline-artifacts-${AWS_ACCOUNT}-${ENVIRONMENT}"
  info "Bucket: s3://$BUCKET_NAME"

  if aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" 2>/dev/null; then
    success "Bucket already exists — skipping creation."
  else
    info "Creating bucket..."

    # us-east-1 does NOT accept LocationConstraint — other regions require it
    if [[ "$AWS_REGION" == "us-east-1" ]]; then
      aws s3 mb "s3://$BUCKET_NAME" --region "$AWS_REGION" &>/dev/null
    else
      aws s3 mb "s3://$BUCKET_NAME" \
        --region "$AWS_REGION" \
        --create-bucket-configuration LocationConstraint="$AWS_REGION" &>/dev/null
    fi

    # Versioning
    aws s3api put-bucket-versioning \
      --bucket "$BUCKET_NAME" \
      --versioning-configuration Status=Enabled &>/dev/null
    success "Versioning enabled."

    # Block all public access
    aws s3api put-public-access-block \
      --bucket "$BUCKET_NAME" \
      --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" &>/dev/null
    success "Public access blocked."

    # Encryption
    aws s3api put-bucket-encryption \
      --bucket "$BUCKET_NAME" \
      --server-side-encryption-configuration '{
        "Rules": [{
          "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"},
          "BucketKeyEnabled": true
        }]
      }' &>/dev/null
    success "AES-256 server-side encryption enabled."

    success "S3 bucket ready: s3://$BUCKET_NAME"
  fi

  # ── AUTOMATED Step 4b: Deploy CodePipeline stack ───────────────────────────
  header "Step 4b (Automated): Deploy CodePipeline Stack"

  PIPELINE_STACK="hardened-ec2-pipeline-${ENVIRONMENT}"
  info "Pipeline stack: $PIPELINE_STACK"

  PIPELINE_PARAMS=(
    "ParameterKey=GitHubOwner,ParameterValue=$GITHUB_OWNER"
    "ParameterKey=GitHubRepo,ParameterValue=$GITHUB_REPO"
    "ParameterKey=GitHubBranch,ParameterValue=$CURRENT_BRANCH"
    "ParameterKey=GitHubConnectionArn,ParameterValue=$CONNECTION_ARN"
    "ParameterKey=ArtifactBucketName,ParameterValue=$BUCKET_NAME"
    "ParameterKey=Environment,ParameterValue=$ENVIRONMENT"
    "ParameterKey=StackOwner,ParameterValue=$STACK_OWNER"
    "ParameterKey=OSType,ParameterValue=$OS_TYPE"
    "ParameterKey=OSVersion,ParameterValue=$OS_VERSION"
    "ParameterKey=InstanceType,ParameterValue=$INSTANCE_TYPE"
    "ParameterKey=VolumeSize,ParameterValue=$VOLUME_SIZE"
    "ParameterKey=DeleteVolumeOnTermination,ParameterValue=$DELETE_VOL"
    "ParameterKey=EnableDetailedMonitoring,ParameterValue=$DETAILED_MON"
    "ParameterKey=EnableTerminationProtection,ParameterValue=$TERM_PROT"
    "ParameterKey=VpcCIDR,ParameterValue=$VPC_CIDR"
    "ParameterKey=SubnetCIDR,ParameterValue=$PRIVATE_CIDR"
    "ParameterKey=NATSubnetCIDR,ParameterValue=$PUBLIC_CIDR"
    "ParameterKey=PatchSchedule,ParameterValue=$PATCH_SCHED"
    "ParameterKey=LogRetentionDays,ParameterValue=$LOG_DAYS"
    "ParameterKey=SnapshotRetentionCount,ParameterValue=$SNAP_COUNT"
    "ParameterKey=SnapshotTime,ParameterValue=$SNAP_TIME"
    "ParameterKey=AlarmEmail,ParameterValue=$ALARM_EMAIL"
    "ParameterKey=CPUAlarmThreshold,ParameterValue=$CPU_THRESH"
    "ParameterKey=DiskAlarmThreshold,ParameterValue=$DISK_THRESH"
    "ParameterKey=KeyPairName,ParameterValue=$KEY_PAIR_NAME"
  )

  STACK_STATUS=$(aws cloudformation describe-stacks \
    --stack-name "$PIPELINE_STACK" --region "$AWS_REGION" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

  if [[ "$STACK_STATUS" == "DOES_NOT_EXIST" ]]; then
    info "Creating pipeline stack (first time)..."
    aws cloudformation create-stack \
      --stack-name "$PIPELINE_STACK" \
      --template-body "file://$REPO_ROOT/cloudformation/pipeline.yaml" \
      --parameters "${PIPELINE_PARAMS[@]}" \
      --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
      --region "$AWS_REGION" &>/dev/null

    (aws cloudformation wait stack-create-complete \
      --stack-name "$PIPELINE_STACK" --region "$AWS_REGION") &
    spinner $! "Creating pipeline stack..."
    success "Pipeline stack created."
  else
    info "Updating existing pipeline stack..."
    UPDATE=$(aws cloudformation update-stack \
      --stack-name "$PIPELINE_STACK" \
      --template-body "file://$REPO_ROOT/cloudformation/pipeline.yaml" \
      --parameters "${PIPELINE_PARAMS[@]}" \
      --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
      --region "$AWS_REGION" 2>&1 || true)

    if echo "$UPDATE" | grep -q "No updates are to be performed"; then
      info "Pipeline stack already up to date."
    else
      (aws cloudformation wait stack-update-complete \
        --stack-name "$PIPELINE_STACK" --region "$AWS_REGION") &
      spinner $! "Updating pipeline stack..."
      success "Pipeline stack updated."
    fi
  fi

  # ── Monitor pipeline execution ─────────────────────────────────────────────
  header "Step 5: Monitoring Deployment Pipeline"

  PIPELINE_NAME="HardenedEC2-Pipeline-${ENVIRONMENT}"
  INFRA_STACK="hardened-ec2-${ENVIRONMENT}"

  info "Pipeline : $PIPELINE_NAME"
  info "Waiting 30s for pipeline to detect the GitHub push..."
  sleep 30

  TIMEOUT=1200; ELAPSED=0; INTERVAL=15

  while true; do
    SRC_STATUS=$(aws codepipeline get-pipeline-state \
      --name "$PIPELINE_NAME" --region "$AWS_REGION" \
      --query 'stageStates[?stageName==`Source`].latestExecution.status' \
      --output text 2>/dev/null || echo "...")
    DEP_STATUS=$(aws codepipeline get-pipeline-state \
      --name "$PIPELINE_NAME" --region "$AWS_REGION" \
      --query 'stageStates[?stageName==`Deploy`].latestExecution.status' \
      --output text 2>/dev/null || echo "...")

    echo -ne "\r  ${BOLD}Source:${RESET} ${SRC_STATUS}  |  ${BOLD}Deploy:${RESET} ${DEP_STATUS}  (${ELAPSED}s)   "

    [[ "$DEP_STATUS" == "Succeeded" ]] && { echo ""; success "Pipeline SUCCEEDED!"; break; }
    [[ "$DEP_STATUS" == "Failed"    ]] && { echo ""; error "Pipeline FAILED — check: https://${AWS_REGION}.console.aws.amazon.com/codesuite/codepipeline/pipelines/${PIPELINE_NAME}/view"; }
    [[ $ELAPSED -ge $TIMEOUT        ]] && { echo ""; error "Timeout after ${TIMEOUT}s — check pipeline manually."; }

    sleep $INTERVAL; ELAPSED=$((ELAPSED+INTERVAL))
  done

  # ── Print deployed infra summary ───────────────────────────────────────────
  header "Deployed Infrastructure — Full Summary"

  OUTPUTS=$(aws cloudformation describe-stacks \
    --stack-name "$INFRA_STACK" --region "$AWS_REGION" \
    --query 'Stacks[0].Outputs' --output json)

  echo -e "  ${BOLD}Stack Name      :${RESET}  $INFRA_STACK"
  echo -e "  ${BOLD}Stack Status    :${RESET}  ${GREEN}CREATE_COMPLETE / UPDATE_COMPLETE${RESET}"
  echo -e "  ${BOLD}Region          :${RESET}  $AWS_REGION"
  echo -e "  ${BOLD}Environment     :${RESET}  $ENVIRONMENT"
  echo -e "  ${BOLD}OS              :${RESET}  $OS_TYPE $OS_VERSION"
  echo -e "  ${BOLD}Instance Type   :${RESET}  $INSTANCE_TYPE"
  echo -e "  ${BOLD}Volume          :${RESET}  ${VOLUME_SIZE}GB encrypted"
  echo -e "  ${BOLD}Git Commit      :${RESET}  $COMMIT_SHA"
  echo -e "  ${BOLD}Pipeline        :${RESET}  $PIPELINE_NAME"
  echo -e "  ${BOLD}Artifact Bucket :${RESET}  s3://$BUCKET_NAME"
  echo -e "  ${BOLD}CFN Connection  :${RESET}  $CONNECTION_ARN"
  divider

  echo -e "\n  ${BOLD}${BLUE}CloudFormation Stack Outputs:${RESET}\n"
  echo "$OUTPUTS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for o in sorted(data, key=lambda x: x['OutputKey']):
    key  = o.get('OutputKey','')
    val  = o.get('OutputValue','')
    desc = o.get('Description','')
    print(f'  \033[1m{key:<35}\033[0m \033[36m{val}\033[0m')
    if desc:
        print(f'  {\" \"*35} \033[2m{desc}\033[0m')
    print()
"

  SSM_CMD=$(echo "$OUTPUTS" | python3 -c "
import sys, json
for o in json.load(sys.stdin):
  if o['OutputKey'] == 'SSMSessionCommand':
    print(o['OutputValue'])
" 2>/dev/null || echo "See SSMSessionCommand output above")

  echo -e "${GREEN}${BOLD}━━━  Connect to your instance (no SSH needed)  ━━━${RESET}"
  echo -e "  ${CYAN}$SSM_CMD${RESET}"
}

# =============================================================================
# Terraform path
# =============================================================================
deploy_terraform() {

  header "Step 5: Terraform Deployment"

  TF_DIR="$REPO_ROOT/terraform"
  cd "$TF_DIR"

  info "Writing terraform.tfvars..."
  cat > terraform.tfvars <<TFVARS
aws_region    = "$AWS_REGION"
environment   = "$ENVIRONMENT"
stack_owner   = "$STACK_OWNER"
os_type       = "$OS_TYPE"
os_version    = "$OS_VERSION"
instance_type = "$INSTANCE_TYPE"
volume_size   = $VOLUME_SIZE
delete_volume_on_termination  = $DELETE_VOL
enable_detailed_monitoring    = $DETAILED_MON
enable_termination_protection = $TERM_PROT
vpc_cidr            = "$VPC_CIDR"
private_subnet_cidr = "$PRIVATE_CIDR"
public_subnet_cidr  = "$PUBLIC_CIDR"
patch_schedule           = "$PATCH_SCHED"
log_retention_days       = $LOG_DAYS
snapshot_retention_count = $SNAP_COUNT
snapshot_time            = "$SNAP_TIME"
alarm_email          = "$ALARM_EMAIL"
cpu_alarm_threshold  = $CPU_THRESH
disk_alarm_threshold = $DISK_THRESH
TFVARS
  success "terraform.tfvars written (gitignored — safe)"

  info "terraform init..."
  terraform init -upgrade 2>&1 | tail -3

  info "terraform validate..."
  terraform validate && success "Configuration valid."

  info "terraform plan..."
  terraform plan -out=tfplan

  echo ""; ask "Apply the plan? (yes/no):"; read -r CONFIRM
  [[ ! "$CONFIRM" =~ ^(yes|y)$ ]] && { warn "Aborted. Plan saved to tfplan."; exit 0; }

  terraform apply tfplan

  header "Deployed Infrastructure — Full Summary"

  echo -e "  ${BOLD}Tool          :${RESET}  Terraform"
  echo -e "  ${BOLD}Region        :${RESET}  $AWS_REGION"
  echo -e "  ${BOLD}Environment   :${RESET}  $ENVIRONMENT"
  echo -e "  ${BOLD}OS            :${RESET}  $OS_TYPE $OS_VERSION"
  echo -e "  ${BOLD}Instance Type :${RESET}  $INSTANCE_TYPE"
  echo -e "  ${BOLD}Volume        :${RESET}  ${VOLUME_SIZE}GB encrypted"
  echo -e "  ${BOLD}Git Commit    :${RESET}  $COMMIT_SHA"
  divider
  echo -e "\n  ${BOLD}${BLUE}Terraform Outputs:${RESET}\n"

  terraform output -json | python3 -c "
import sys, json
for key, obj in sorted(json.load(sys.stdin).items()):
    val = obj.get('value','')
    print(f'  \033[1m{key:<35}\033[0m \033[36m{val}\033[0m')
    print()
"

  SSM_CMD=$(terraform output -raw ssm_session_command 2>/dev/null || echo "See outputs above")
  echo -e "${GREEN}${BOLD}━━━  Connect to your instance (no SSH needed)  ━━━${RESET}"
  echo -e "  ${CYAN}$SSM_CMD${RESET}"
}

# =============================================================================
# Branch
# =============================================================================
[[ "$TOOL" == "cloudformation" ]] && deploy_cloudformation || deploy_terraform

# =============================================================================
# DONE
# =============================================================================
header "All Done ✔"
echo -e "  ${GREEN}${BOLD}Hardened EC2 deployed successfully${RESET}"
echo ""
echo -e "  ${BOLD}Tool        :${RESET}  $TOOL"
echo -e "  ${BOLD}Environment :${RESET}  $ENVIRONMENT"
echo -e "  ${BOLD}Region      :${RESET}  $AWS_REGION"
echo -e "  ${BOLD}Commit      :${RESET}  $COMMIT_SHA"
echo ""
echo -e "  ${YELLOW}⚠  Check your email and click 'Confirm subscription' for SNS alarms!${RESET}"
echo ""
echo -e "  ${DIM}Next push to GitHub auto-redeploys (CloudFormation) or re-run this script (Terraform)${RESET}"
echo ""
