#!/usr/bin/env bash
# Recreates the real cost-safety setup built for this project's personal AWS
# account after the billing incident documented in docs/COST_SAFETY.md: a
# monthly budget with alert thresholds, Cost Anomaly Detection, and
# CloudWatch billing alarms wired to an SNS topic. Same resource names,
# amounts, and thresholds as the real setup -- only the account id and
# notification email are parameterized instead of hardcoded, so this is
# safe to publish and safe to point at any account.
#
#   PERSONAL_ACCOUNT_ID=<account id> \
#   NOTIFICATION_EMAIL=<email> \
#   AWS_PROFILE=<admin profile for that account> \
#   bash setup_cost_safety.sh
set -euo pipefail

: "${PERSONAL_ACCOUNT_ID:?set PERSONAL_ACCOUNT_ID to the account this budget/alarms apply to}"
: "${NOTIFICATION_EMAIL:?set NOTIFICATION_EMAIL to where alerts should go}"
: "${AWS_PROFILE:?set AWS_PROFILE to an admin profile for that account (Budgets/CloudWatch/SNS/Cost Explorer access)}"

BUDGET_NAME="${BUDGET_NAME:-monthly-limit-50usd}"
BUDGET_LIMIT_USD="${BUDGET_LIMIT_USD:-50}"
ANOMALY_MONITOR_NAME="${ANOMALY_MONITOR_NAME:-Default-Services-Monitor}"
ANOMALY_IMPACT_THRESHOLD_USD="${ANOMALY_IMPACT_THRESHOLD_USD:-5}"
SNS_TOPIC_NAME="${SNS_TOPIC_NAME:-aws-billing-alerts}"
REGION="${AWS_REGION:-us-east-1}"

echo "=== Account check ==="
ACTUAL_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
if [ "$ACTUAL_ACCOUNT" != "$PERSONAL_ACCOUNT_ID" ]; then
  echo "ERROR: AWS_PROFILE=$AWS_PROFILE resolves to account $ACTUAL_ACCOUNT, not PERSONAL_ACCOUNT_ID=$PERSONAL_ACCOUNT_ID. Refusing to continue."
  exit 1
fi

echo "=== SNS topic for billing alerts ==="
TOPIC_ARN=$(aws sns create-topic --name "$SNS_TOPIC_NAME" --region "$REGION" --query TopicArn --output text)
echo "Topic: $TOPIC_ARN"
aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol email --notification-endpoint "$NOTIFICATION_EMAIL" --region "$REGION" >/dev/null
echo "Subscribed $NOTIFICATION_EMAIL -- confirm the subscription email AWS just sent before alerts will actually arrive."

echo ""
echo "=== CloudWatch billing alarms (AWS/Billing EstimatedCharges, USD) ==="
# Billing metrics only publish in us-east-1, regardless of where your
# resources actually run.
THRESHOLD_80=$(python3 -c "print($BUDGET_LIMIT_USD * 0.8)")
aws cloudwatch put-metric-alarm --region us-east-1 \
  --alarm-name "billing-alert-80pct" \
  --alarm-description "80% of the ${BUDGET_LIMIT_USD} USD monthly budget" \
  --namespace "AWS/Billing" --metric-name EstimatedCharges \
  --dimensions Name=Currency,Value=USD \
  --statistic Maximum --period 21600 --evaluation-periods 1 \
  --threshold "$THRESHOLD_80" --comparison-operator GreaterThanOrEqualToThreshold \
  --alarm-actions "$TOPIC_ARN"
aws cloudwatch put-metric-alarm --region us-east-1 \
  --alarm-name "billing-alert-100pct" \
  --alarm-description "100% of the ${BUDGET_LIMIT_USD} USD monthly budget" \
  --namespace "AWS/Billing" --metric-name EstimatedCharges \
  --dimensions Name=Currency,Value=USD \
  --statistic Maximum --period 21600 --evaluation-periods 1 \
  --threshold "$BUDGET_LIMIT_USD" --comparison-operator GreaterThanOrEqualToThreshold \
  --alarm-actions "$TOPIC_ARN"
echo "Alarms: billing-alert-80pct (\$${THRESHOLD_80}), billing-alert-100pct (\$${BUDGET_LIMIT_USD})"

echo ""
echo "=== AWS Budget (alerts at 50/80/100% actual + 100% forecasted) ==="
cat > /tmp/budget.json <<EOF
{
  "BudgetName": "$BUDGET_NAME",
  "BudgetLimit": {"Amount": "$BUDGET_LIMIT_USD", "Unit": "USD"},
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST"
}
EOF
cat > /tmp/budget-notifications.json <<EOF
[
  {
    "Notification": {"NotificationType": "ACTUAL", "ComparisonOperator": "GREATER_THAN", "Threshold": 50, "ThresholdType": "PERCENTAGE"},
    "Subscribers": [{"SubscriptionType": "EMAIL", "Address": "$NOTIFICATION_EMAIL"}]
  },
  {
    "Notification": {"NotificationType": "ACTUAL", "ComparisonOperator": "GREATER_THAN", "Threshold": 80, "ThresholdType": "PERCENTAGE"},
    "Subscribers": [{"SubscriptionType": "EMAIL", "Address": "$NOTIFICATION_EMAIL"}]
  },
  {
    "Notification": {"NotificationType": "ACTUAL", "ComparisonOperator": "GREATER_THAN", "Threshold": 100, "ThresholdType": "PERCENTAGE"},
    "Subscribers": [{"SubscriptionType": "EMAIL", "Address": "$NOTIFICATION_EMAIL"}]
  },
  {
    "Notification": {"NotificationType": "FORECASTED", "ComparisonOperator": "GREATER_THAN", "Threshold": 100, "ThresholdType": "PERCENTAGE"},
    "Subscribers": [{"SubscriptionType": "EMAIL", "Address": "$NOTIFICATION_EMAIL"}]
  }
]
EOF
aws budgets create-budget --account-id "$PERSONAL_ACCOUNT_ID" \
  --budget file:///tmp/budget.json --notifications-with-subscribers file:///tmp/budget-notifications.json
rm -f /tmp/budget.json /tmp/budget-notifications.json
echo "Budget: $BUDGET_NAME, \$${BUDGET_LIMIT_USD}/month, alerts at 50/80/100% actual + 100% forecasted"

echo ""
echo "=== Cost Anomaly Detection ==="
MONITOR_ARN=$(aws ce create-anomaly-monitor --anomaly-monitor '{
  "MonitorName": "'"$ANOMALY_MONITOR_NAME"'",
  "MonitorType": "DIMENSIONAL",
  "MonitorDimension": "SERVICE"
}' --query MonitorArn --output text)
echo "Monitor: $MONITOR_ARN"
aws ce create-anomaly-subscription --anomaly-subscription '{
  "SubscriptionName": "'"$ANOMALY_MONITOR_NAME"'-daily-alerts",
  "MonitorArnList": ["'"$MONITOR_ARN"'"],
  "Subscribers": [{"Type": "EMAIL", "Address": "'"$NOTIFICATION_EMAIL"'"}],
  "Threshold": '"$ANOMALY_IMPACT_THRESHOLD_USD"',
  "Frequency": "DAILY"
}' >/dev/null
echo "Subscription: daily alerts to $NOTIFICATION_EMAIL for anomalies with >\$${ANOMALY_IMPACT_THRESHOLD_USD} impact"

echo ""
echo "Done. Check $NOTIFICATION_EMAIL for the SNS subscription confirmation email --"
echo "alarms and the anomaly subscription won't actually notify you until it's confirmed."
