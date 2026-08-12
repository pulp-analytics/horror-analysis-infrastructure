# horror-analysis-infrastructure

AWS orchestration for running
[horror-corpus-validation](https://github.com/pulp-analytics/horror-corpus-validation)
at scale on Step Functions + Fargate, plus the cost-safety tooling (AWS
Budgets, Cost Anomaly Detection, CloudWatch billing alarms, a pre-flight
account check) built after this project's real billing incident.

Part of the [Pulp Analytics](https://github.com/pulp-analytics) horror poster
analysis project ("The Anatomy of Fear").

**Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first** — it's explicit
about what's real (the cost-safety tooling, the dependency graph) versus
what's a new design proposed here (Step Functions + Fargate; the actual
145k-poster run used self-terminating EC2 instances instead).

## Structure

```
statemachine/
  validate_corpus.asl.json     Step Functions state machine (Amazon States
                                Language) -- mirrors horror-corpus-validation's
                                real dependency graph, running independent
                                scripts as parallel Fargate tasks
ecs/
  task-definition.json         Fargate task definition, incl. the shared
                                EFS mount every step needs (see ARCHITECTURE.md)
docker/
  Dockerfile                   Packages horror-corpus-validation's scripts/
                                by cloning it at build time
iam/
  stepfunctions_execution_role_policy.json   what the state machine can do
  fargate_execution_role_policy.json         what ECS needs to start a container
  fargate_task_role_policy.json              what the running script can do
                                              (Bedrock/Comprehend/Translate only)
scripts/
  preflight_check.sh           confirms which AWS account/profile is active
                                before anything cost-bearing runs
  setup_cost_safety.sh         provisions the Budget/Anomaly Detection/
                                CloudWatch alarms described in COST_SAFETY.md
docs/
  ARCHITECTURE.md              the design, and what's real vs. new
  COST_SAFETY.md               the real billing incident, and what's monitored
```

## Quickstart

```bash
# 1. build and push the image
docker build -t horror-validator -f docker/Dockerfile .
docker tag horror-validator:latest <your-ecr-repo>:latest
docker push <your-ecr-repo>:latest

# 2. create the EFS filesystem + access point, the three IAM roles (iam/),
#    the ECS cluster, and register ecs/task-definition.json with your own
#    ARNs filled in -- see docs/ARCHITECTURE.md for what each role needs

# 3. create the state machine from statemachine/validate_corpus.asl.json,
#    filling in the REPLACE_WITH_* placeholders

# 4. before running anything against a real AWS account:
PERSONAL_ACCOUNT_ID=<id> AWS_PROFILE=<profile> bash scripts/preflight_check.sh
PERSONAL_ACCOUNT_ID=<id> NOTIFICATION_EMAIL=<email> AWS_PROFILE=<admin profile> \
  bash scripts/setup_cost_safety.sh   # one-time

# 5. start an execution, e.g. via the console or:
aws stepfunctions start-execution --state-machine-arn <arn> --input '{
  "genre": 27, "startYear": 2020, "endYear": 2026, "limit": 100,
  "idsPath": "data/sample_input/sample_100_ids.csv",
  "verifiedPath": "data/sample_output/poster_verification.csv",
  "altTitlesPath": "data/sample_output/alt_titles.json",
  "visionPath": "data/sample_output/vision_title_check.csv",
  "languagePath": "data/sample_output/language_detection.csv",
  "translatedPath": "data/sample_output/translated_titles.csv",
  "duplicateResolutionPath": "data/sample_output/duplicate_resolution.csv",
  "posterMd5DuplicatesPath": "data/sample_output/poster_md5_duplicates.csv",
  "compilationGroupsPath": "data/sample_output/compilation_groups.csv",
  "tmdbDedupeCachePath": "data/sample_output/.tmdb_dedupe_cache.csv",
  "posterMd5CachePath": "data/sample_output/.poster_md5_cache.csv",
  "compilationCachePath": "data/sample_output/.compilation_search_cache.csv",
  "bedrockModelId": "us.amazon.nova-pro-v1:0"
}'
```

## License

MIT — see [LICENSE](LICENSE).
