# Cost safety

## Why this exists

This project had a real billing incident: on 2026-08-06/07, ~$639 of gross
Rekognition/Comprehend/Bedrock usage ran against a personal AWS account
instead of a workshop sandbox, because a job was launched without
double-checking which `AWS_PROFILE` was active. The tooling in this repo —
`scripts/preflight_check.sh` and `scripts/setup_cost_safety.sh` — exists
specifically to make that mistake harder to repeat, not as generic AWS
hygiene advice.

## The golden rule

**Never run anything of non-trivial cost without first running:**

```bash
AWS_PROFILE=<profile> PERSONAL_ACCOUNT_ID=<your account id> bash scripts/preflight_check.sh
```

Confirm the account BEFORE launching EC2, Fargate, SageMaker, Bedrock,
Rekognition, or Comprehend.

## Account/profile separation

The real setup uses this pattern — adapt the specifics, keep the shape:

| Profile | Account | Purpose | What it can actually do |
|---|---|---|---|
| a restricted day-to-day IAM user | personal account | daily use on the personal account | broad access (e.g. PowerUserAccess) **plus an explicit IAM deny** on Rekognition/Comprehend/Bedrock/Translate. An explicit deny always wins over any allow, including ones added later — this profile physically cannot call those services, no matter what other policy gets attached to it by mistake. |
| an admin IAM user | personal account | account administration (replaces root) | AdministratorAccess plus the same explicit deny. Used only for account-level tasks: IAM, Budgets, Organizations, CloudWatch. |
| ~~root~~ | personal account | — | Root should have **no API access key at all**. Root login is console + MFA only, never CLI/API — this is AWS's own recommendation, not a project-specific choice. |
| a sandbox profile | a separate sandbox/workshop account | the actual Bedrock/Rekognition/Comprehend/EC2 workload | This is where cost-bearing AI/ML work is supposed to run. Workshop sandboxes typically expire and need periodic renewal — if `aws sts get-caller-identity` starts failing, that's usually why. |

The explicit-deny-on-personal-account piece is the important part: it means
a bug, a copy-pasted command, or a forgotten `--profile` flag can't
accidentally run expensive AI services on the wrong account — the IAM
policy itself blocks it, independent of what the code does.

## What's actually monitored

`scripts/setup_cost_safety.sh` provisions three independent layers, so a
gap in one doesn't mean silence:

1. **AWS Budgets** — a monthly cost budget with alerts at 50%/80%/100% of
   actual spend and 100% of forecasted spend.
2. **Cost Anomaly Detection** — a per-service monitor with a small
   dollar-impact threshold, checked daily. Catches spend that's unusual for
   *any* service, even ones a budget wasn't specifically watching.
3. **CloudWatch billing alarms** — two alarms on the `AWS/Billing
   EstimatedCharges` metric (which only publishes in `us-east-1`,
   regardless of where your resources run), at 80% and 100% of the budget,
   wired to the same SNS topic as the other two.

All three notify the same email, on purpose — redundant alerting beats a
single point of failure when the cost of missing one is a four-figure bill.

## Checklist before running anything expensive

1. `AWS_PROFILE=<profile> aws sts get-caller-identity` — confirm the right account
2. Run `scripts/preflight_check.sh` — checks budget and Free Tier credits
3. If it's a workshop sandbox: confirm it hasn't expired
4. If it's the personal account: confirm the expected spend is genuinely small/free
