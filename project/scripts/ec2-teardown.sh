#!/usr/bin/env bash
# =============================================================================
# ec2-teardown.sh — Destroy all hardened EC2 infrastructure
#
# Deletes in reverse order:
#   1. Hardened EC2 infra stack  (EC2, VPC, NAT, SGs, IAM, CW, SNS, DLM)
#   2. CodePipeline stack
#   3. S3 artifact bucket        (emptied first)
#   4. CodeStar GitHub connection
#   5. CloudWatch log group      (not auto-deleted by CFN)
#   6. EBS snapshots             (created by DLM)
#   7. Key pair                  (optional)
# =============================================================================
set -euo pipefail

RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
DIM='\033[2m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[ ✔ ]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERR]${RESET}   $*" >&2; exit 1; }
skip()    { echo -e "${DIM}[ - ]  $* — skipping${RESET}"; }
header()  { echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n  $*\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"; }
ask()     { echo -ne "${YELLOW}▶ $* ${RESET}"; }
divider() { echo -e "${DIM}───────────────────────────────────────────${RESET}"; }

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

# =============================================================================
# BANNER
# =============================================================================
clear
echo -e "${BOLD}${RED}"
cat <<'BANNER'
 ████████╗███████╗ █████╗ ██████╗ ██████╗  ██████╗ ██╗    ██╗███╗   ██╗
 ╚══██╔══╝██╔════╝██╔══██╗██╔══██╗██╔══██╗██╔═══██╗██║    ██║████╗  ██║
    ██║   █████╗  ███████║██████╔╝██║  ██║██║   ██║██║ █╗ ██║██╔██╗ ██║
    ██║   ██╔══╝  ██╔══██║██╔══██╗██║  ██║██║   ██║██║███╗██║██║╚██╗██║
    ██║   ███████╗██║  ██║██║  ██║██████╔╝╚██████╔╝╚███╔███╔╝██║ ╚████║
    ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝  ╚═════╝  ╚══╝╚══╝ ╚═╝  ╚═══╝
              Hardened EC2 — Full Infrastructure Teardown
BANNER
echo -e "${RESET}"

echo -e "${RED}${BOLD}  ⚠  WARNING: This will PERMANENTLY DELETE all resources.${RESET}"
echo -e "${RED}     This cannot be undone.\n${RESET}"

# =============================================================================
# STEP 1 — Choose environment
# =============================================================================
header "Step 1: Choose Environment to Destroy"
echo -e "  1) dev"
echo -e "  2) stage"
echo -e "  3) prod"
ask "Which environment to destroy [1/2/3]:"
read -r ENV_CHOICE
case "$ENV_CHOICE" in
  1) ENVIRONMENT="dev"   ;;
  2) ENVIRONMENT="stage" ;;
  3) ENVIRONMENT="prod"  ;;
  *) error "Invalid choice." ;;
esac

# =============================================================================
# STEP 2 — Region + AWS account
# =============================================================================
header "Step 2: AWS Configuration"

DETECTED_REGION=$(curl -s --connect-timeout 2 \
  http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || \
  aws configure get region 2>/dev/null || echo "")

if [[ -n "$DETECTED_REGION" ]]; then
  info "Auto-detected region: $DETECTED_REGION"
  ask "AWS Region [$DETECTED_REGION]:"
  read -r AWS_REGION; AWS_REGION="${AWS_REGION:-$DETECTED_REGION}"
else
  ask "AWS Region (e.g. us-east-1):"
  read -r AWS_REGION
fi
[[ -z "$AWS_REGION" ]] && error "Region cannot be empty."
export AWS_DEFAULT_REGION="$AWS_REGION"

CALLER=$(aws sts get-caller-identity --output json 2>/dev/null) \
  || error "AWS credentials not configured."
AWS_ACCOUNT=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
AWS_ARN=$(echo "$CALLER"     | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'])")
success "AWS authenticated → $AWS_ARN"

# =============================================================================
# STEP 3 — Confirm destruction
# =============================================================================
header "Step 3: Confirm Destruction"

INFRA_STACK="hardened-ec2-${ENVIRONMENT}"
PIPELINE_STACK="hardened-ec2-pipeline-${ENVIRONMENT}"
BUCKET_NAME="pipeline-artifacts-${AWS_ACCOUNT}-${ENVIRONMENT}"
LOG_GROUP="/ec2/hardened/${ENVIRONMENT}"
PIPELINE_NAME="HardenedEC2-Pipeline-${ENVIRONMENT}"
CONN_NAME="github-connection-${ENVIRONMENT}"

echo -e "  The following resources will be destroyed:\n"
echo -e "  ${RED}✘${RESET}  CFN Stack      : $INFRA_STACK"
echo -e "  ${RED}✘${RESET}  CFN Stack      : $PIPELINE_STACK"
echo -e "  ${RED}✘${RESET}  S3 Bucket      : s3://$BUCKET_NAME"
echo -e "  ${RED}✘${RESET}  CodeStar Conn  : $CONN_NAME"
echo -e "  ${RED}✘${RESET}  CW Log Group   : $LOG_GROUP"
echo -e "  ${RED}✘${RESET}  EBS Snapshots  : all tagged Environment=$ENVIRONMENT"
echo -e "  ${YELLOW}?${RESET}  Key Pair       : will ask below\n"

ask "Type 'yes' to confirm destruction of $ENVIRONMENT environment:"
read -r CONFIRM
[[ "$CONFIRM" != "yes" ]] && { echo "Aborted."; exit 0; }

# Key pair deletion
divider
ask "Also delete the key pair 'hardened-ec2-${ENVIRONMENT}'? (yes/no) [no]:"
read -r DEL_KEY; DEL_KEY="${DEL_KEY:-no}"

echo ""

# =============================================================================
# STEP 4 — Delete infra stack (EC2, VPC, NAT, everything)
# =============================================================================
header "Step 4: Deleting Hardened EC2 Infra Stack"

INFRA_STATUS=$(aws cloudformation describe-stacks \
  --stack-name "$INFRA_STACK" --region "$AWS_REGION" \
  --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

if [[ "$INFRA_STATUS" == "DOES_NOT_EXIST" ]]; then
  skip "Infra stack $INFRA_STACK not found"
else
  info "Stack status: $INFRA_STATUS"

  # Disable termination protection first (if enabled)
  aws cloudformation update-termination-protection \
    --no-enable-termination-protection \
    --stack-name "$INFRA_STACK" \
    --region "$AWS_REGION" &>/dev/null || true

  info "Deleting stack: $INFRA_STACK (this takes 5-10 minutes)..."
  aws cloudformation delete-stack \
    --stack-name "$INFRA_STACK" \
    --region "$AWS_REGION"

  (aws cloudformation wait stack-delete-complete \
    --stack-name "$INFRA_STACK" --region "$AWS_REGION") &
  spinner $! "Deleting EC2, VPC, NAT Gateway, IAM roles, alarms..."
  success "Infra stack deleted."
fi

# =============================================================================
# STEP 5 — Delete CodePipeline stack
# =============================================================================
header "Step 5: Deleting CodePipeline Stack"

PIPE_STATUS=$(aws cloudformation describe-stacks \
  --stack-name "$PIPELINE_STACK" --region "$AWS_REGION" \
  --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

if [[ "$PIPE_STATUS" == "DOES_NOT_EXIST" ]]; then
  skip "Pipeline stack $PIPELINE_STACK not found"
else
  info "Deleting stack: $PIPELINE_STACK..."
  aws cloudformation delete-stack \
    --stack-name "$PIPELINE_STACK" \
    --region "$AWS_REGION"

  (aws cloudformation wait stack-delete-complete \
    --stack-name "$PIPELINE_STACK" --region "$AWS_REGION") &
  spinner $! "Deleting CodePipeline, IAM roles..."
  success "Pipeline stack deleted."
fi

# =============================================================================
# STEP 6 — Empty and delete S3 artifact bucket
# =============================================================================
header "Step 6: Deleting S3 Artifact Bucket"

if aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" 2>/dev/null; then
  info "Emptying bucket: s3://$BUCKET_NAME"

  # Delete all versioned objects
  aws s3api delete-objects \
    --bucket "$BUCKET_NAME" \
    --delete "$(aws s3api list-object-versions \
      --bucket "$BUCKET_NAME" \
      --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
      --output json 2>/dev/null)" \
    --region "$AWS_REGION" &>/dev/null || true

  # Delete all delete markers
  aws s3api delete-objects \
    --bucket "$BUCKET_NAME" \
    --delete "$(aws s3api list-object-versions \
      --bucket "$BUCKET_NAME" \
      --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
      --output json 2>/dev/null)" \
    --region "$AWS_REGION" &>/dev/null || true

  # Final sweep for any remaining objects
  aws s3 rm "s3://$BUCKET_NAME" --recursive --region "$AWS_REGION" &>/dev/null || true

  aws s3api delete-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION"
  success "S3 bucket deleted: s3://$BUCKET_NAME"
else
  skip "Bucket s3://$BUCKET_NAME not found"
fi

# =============================================================================
# STEP 7 — Delete CodeStar connection
# =============================================================================
header "Step 7: Deleting CodeStar GitHub Connection"

CONN_ARN=$(aws codestar-connections list-connections \
  --region "$AWS_REGION" \
  --query "Connections[?ConnectionName=='$CONN_NAME'].ConnectionArn" \
  --output text 2>/dev/null || echo "")

if [[ -n "$CONN_ARN" && "$CONN_ARN" != "None" ]]; then
  aws codestar-connections delete-connection \
    --connection-arn "$CONN_ARN" \
    --region "$AWS_REGION"
  success "CodeStar connection deleted: $CONN_NAME"
else
  skip "CodeStar connection $CONN_NAME not found"
fi

# =============================================================================
# STEP 8 — Delete CloudWatch log group
# =============================================================================
header "Step 8: Deleting CloudWatch Log Group"

if aws logs describe-log-groups \
  --log-group-name-prefix "$LOG_GROUP" \
  --region "$AWS_REGION" \
  --query 'logGroups[0].logGroupName' \
  --output text 2>/dev/null | grep -q "$LOG_GROUP"; then
  aws logs delete-log-group \
    --log-group-name "$LOG_GROUP" \
    --region "$AWS_REGION"
  success "Log group deleted: $LOG_GROUP"
else
  skip "Log group $LOG_GROUP not found"
fi

# =============================================================================
# STEP 9 — Delete EBS snapshots created by DLM
# =============================================================================
header "Step 9: Deleting EBS Snapshots"

SNAPSHOT_IDS=$(aws ec2 describe-snapshots \
  --owner-ids "$AWS_ACCOUNT" \
  --region "$AWS_REGION" \
  --filters "Name=tag:Environment,Values=$ENVIRONMENT" \
  --query 'Snapshots[*].SnapshotId' \
  --output text 2>/dev/null || echo "")

if [[ -n "$SNAPSHOT_IDS" && "$SNAPSHOT_IDS" != "None" ]]; then
  COUNT=0
  for SNAP_ID in $SNAPSHOT_IDS; do
    aws ec2 delete-snapshot --snapshot-id "$SNAP_ID" --region "$AWS_REGION" &>/dev/null
    COUNT=$((COUNT+1))
  done
  success "Deleted $COUNT snapshot(s) tagged Environment=$ENVIRONMENT"
else
  skip "No snapshots found tagged Environment=$ENVIRONMENT"
fi

# =============================================================================
# STEP 10 — Delete key pair (optional)
# =============================================================================
header "Step 10: Key Pair"

if [[ "$DEL_KEY" =~ ^(yes|y)$ ]]; then
  KEY_NAME="hardened-ec2-${ENVIRONMENT}"
  KEY_EXISTS=$(aws ec2 describe-key-pairs \
    --key-names "$KEY_NAME" \
    --region "$AWS_REGION" \
    --query 'KeyPairs[0].KeyName' \
    --output text 2>/dev/null || echo "")

  if [[ -n "$KEY_EXISTS" && "$KEY_EXISTS" != "None" ]]; then
    aws ec2 delete-key-pair --key-name "$KEY_NAME" --region "$AWS_REGION"
    success "Key pair deleted: $KEY_NAME"
    warn "Remember to also delete ${KEY_NAME}.pem from your local machine."
  else
    skip "Key pair $KEY_NAME not found in AWS"
  fi
else
  skip "Key pair deletion skipped (keeping it)"
fi

# =============================================================================
# SUMMARY
# =============================================================================
header "Teardown Complete"

echo -e "  ${GREEN}${BOLD}All $ENVIRONMENT infrastructure has been destroyed.${RESET}\n"
echo -e "  Resources deleted:"
echo -e "  ${GREEN}✔${RESET}  EC2 instance, VPC, subnets, NAT Gateway"
echo -e "  ${GREEN}✔${RESET}  Security groups, IAM roles"
echo -e "  ${GREEN}✔${RESET}  CloudWatch alarms, log group, SNS topic"
echo -e "  ${GREEN}✔${RESET}  DLM snapshot policy + snapshots"
echo -e "  ${GREEN}✔${RESET}  CodePipeline + CodeBuild roles"
echo -e "  ${GREEN}✔${RESET}  S3 artifact bucket (all versions purged)"
echo -e "  ${GREEN}✔${RESET}  CodeStar GitHub connection\n"
echo -e "  ${DIM}GitHub repo, IAM user, and this EC2 instance are untouched.${RESET}"
echo -e "  ${DIM}To redeploy from scratch: ./scripts/deploy.sh${RESET}\n"
