#!/usr/bin/env bash
# Run this BEFORE any AWS operation that costs money (EC2, Fargate, SageMaker,
# Bedrock, etc). Ported from this project's real preflight check, written
# after a real billing incident: a workshop sandbox job accidentally ran
# against a personal account instead, ~$639 of Rekognition/Comprehend/Bedrock
# usage before it was caught. See docs/COST_SAFETY.md for the full story.
#
#   PERSONAL_ACCOUNT_ID=<your account id> AWS_PROFILE=<profile> bash preflight_check.sh
set -euo pipefail

if [ -z "${AWS_PROFILE:-}" ]; then
  echo "MISSING: AWS_PROFILE isn't set. Don't proceed without picking an explicit profile."
  echo "Profiles available:"
  grep '^\[profile ' ~/.aws/config 2>/dev/null | sed 's/\[profile /  - /;s/\]//'
  grep '^\[' ~/.aws/credentials 2>/dev/null | grep -v '^\[default\]' | sed 's/\[/  - /;s/\]//'
  exit 1
fi

echo "=== Active profile: $AWS_PROFILE ==="
IDENTITY=$(aws sts get-caller-identity --output json 2>&1) || {
  echo "ERROR: invalid or expired credentials for $AWS_PROFILE."
  echo "$IDENTITY"
  exit 1
}
ACCOUNT=$(echo "$IDENTITY" | python3 -c "import json,sys; print(json.load(sys.stdin)['Account'])")
ARN=$(echo "$IDENTITY" | python3 -c "import json,sys; print(json.load(sys.stdin)['Arn'])")
echo "Account: $ACCOUNT"
echo "ARN: $ARN"

if [ -n "${PERSONAL_ACCOUNT_ID:-}" ] && [ "$ACCOUNT" = "$PERSONAL_ACCOUNT_ID" ]; then
  echo ""
  echo "!!! WARNING: this is your PERSONAL account. !!!"
  echo "Rekognition / Comprehend / Bedrock / bulk EC2-Fargate shouldn't run here."
  echo "If this is intentional (workshop's over, a small one-off task), go ahead."
  echo "If you expected to be in a sandbox, STOP and check your AWS_PROFILE."
  echo ""
fi

if [ -n "${PERSONAL_ACCOUNT_ID:-}" ]; then
  echo "=== Monthly budget (personal account) ==="
  aws budgets describe-budgets --account-id "$PERSONAL_ACCOUNT_ID" --region us-east-1 \
    --query 'Budgets[*].[BudgetName,BudgetLimit.Amount,CalculatedSpend.ActualSpend.Amount]' \
    --output text 2>/dev/null || echo "(couldn't read the budget - check credentials for the personal account)"
fi

echo ""
echo "=== Free Tier / credits ==="
aws freetier get-free-tier-usage --region us-east-1 \
  --query "freeTierUsages[?contains(usageType, 'DataTransfer') || contains(service, 'Community')]" \
  --output table 2>/dev/null || echo "(not available with this profile)"

echo ""
echo "Preflight OK. Confirm the account above is the one you expected before continuing."
