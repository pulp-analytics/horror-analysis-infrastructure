# horror-analysis-infrastructure

AWS infrastructure and orchestration for running large-scale image analysis
jobs (EC2 shard launching, SageMaker Processing, Bedrock batch enrichment)
plus cost-safety tooling: AWS Budgets, Cost Anomaly Detection, CloudWatch
billing alarms, and a pre-flight account/profile check to avoid running
cloud workloads against the wrong AWS account.

Part of the [Pulp Analytics](https://github.com/pulp-analytics) horror poster
analysis project ("The Anatomy of Fear").

## License

MIT — see [LICENSE](LICENSE).
