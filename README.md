# horror-analysis-infrastructure

AWS orchestration for running
[horror-corpus-validation](https://github.com/pulp-analytics/horror-corpus-validation)
at scale, using Step Functions for stage ordering and **AWS Batch array
jobs** for row-level parallelism within the five scripts that scale with
corpus size — plus the cost-safety tooling (AWS Budgets, Cost Anomaly
Detection, CloudWatch billing alarms, a pre-flight account check) built
after this project's real billing incident.

Part of the [Pulp Analytics](https://github.com/pulp-analytics) horror poster
analysis project ("The Anatomy of Fear").

**Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first** — it's explicit
about what's real (the cost-safety tooling, the dependency graph) versus
what's a new design proposed here (Step Functions + Batch + Fargate; the
actual 145k-poster run used self-terminating EC2 instances instead), and
explains why only 5 of the 9 scripts get row-level sharding.

## Structure

```
statemachine/
  validate_corpus.asl.json     Step Functions state machine -- mirrors
                                horror-corpus-validation's real dependency
                                graph; 02/03/04/05/06 run as Batch array
                                jobs + a merge step, 01/07/08/09/Assemble
                                as single Fargate ECS tasks
ecs/
  task-definition.json         Fargate task def for the single-task steps,
                                incl. the shared EFS mount every step needs
batch/
  compute-environment.json     Fargate-backed Batch compute environment
  job-queue.json                
  job-definition.json          reused for all 5 shardable scripts; which
                                script + shard index run is set per
                                submission by the state machine
docker/
  Dockerfile                   Packages horror-corpus-validation's scripts/
                                (cloned at build time) plus this repo's
                                scripts/merge_shards.py
iam/
  stepfunctions_execution_role_policy.json   what the state machine can do
                                              (launch/track ECS tasks AND
                                              Batch jobs)
  fargate_execution_role_policy.json         what ECS/Batch needs to start
                                              a container (shared by both)
  fargate_task_role_policy.json              what the running script can do
                                              (Bedrock/Comprehend/Translate
                                              only; shared by both)
scripts/
  preflight_check.sh           confirms which AWS account/profile is active
                                before anything cost-bearing runs
  setup_cost_safety.sh         provisions the Budget/Anomaly Detection/
                                CloudWatch alarms described in COST_SAFETY.md
  merge_shards.py              combines N Batch array-job shard outputs
                                back into the single file the next stage
                                expects (CSV concat or JSON dict union)
docs/
  ARCHITECTURE.md              the design, what's real vs. new, and why
                                sharding applies to 5 scripts, not all 9
  COST_SAFETY.md               the real billing incident, and what's monitored
```

## Quickstart

```bash
# 1. build and push the image (build context is this repo's root, for
#    merge_shards.py -- see docker/Dockerfile)
docker build -t horror-validator -f docker/Dockerfile .
docker tag horror-validator:latest <your-ecr-repo>:latest
docker push <your-ecr-repo>:latest

# 2. create the EFS filesystem + access point, the shared IAM roles (iam/),
#    the ECS cluster + register ecs/task-definition.json, and the Batch
#    compute environment + job queue + job definition (batch/) -- see
#    docs/ARCHITECTURE.md for what each role needs and the ECS-vs-Batch
#    parameter casing trap

# 3. create the state machine from statemachine/validate_corpus.asl.json,
#    filling in the REPLACE_WITH_* placeholders

# 4. before running anything against a real AWS account:
PERSONAL_ACCOUNT_ID=<id> AWS_PROFILE=<profile> bash scripts/preflight_check.sh
PERSONAL_ACCOUNT_ID=<id> NOTIFICATION_EMAIL=<email> AWS_PROFILE=<admin profile> \
  bash scripts/setup_cost_safety.sh   # one-time

# 5. start an execution -- shardCount controls how many parallel Batch
#    array children run per shardable stage (02,03,04,05,06); shardDir is
#    a scratch subdirectory on the shared EFS mount for shard files before
#    they're merged
aws stepfunctions start-execution --state-machine-arn <arn> --input '{
  "genre": 27, "startYear": 2020, "endYear": 2026, "limit": 100,
  "shardCount": 4,
  "idsPath": "data/sample_input/sample_100_ids.csv",
  "shardDir": "data/shards",
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

For a full 145k-row run, `shardCount` is the main lever: more shards means
more concurrent Batch array children, bounded in practice by Bedrock/TMDB
rate limits rather than infrastructure — see docs/ARCHITECTURE.md for why
`02`/`03`/`04`/`05`/`06` are the ones that benefit from this and `07`/`08`/`09`
don't need it.

## License

MIT — see [LICENSE](LICENSE).
