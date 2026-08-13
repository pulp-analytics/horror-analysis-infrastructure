# poster-analysis-infrastructure

AWS orchestration for running two sibling repos at scale, using Step
Functions for stage ordering and **AWS Batch array jobs** for row-level
parallelism within the scripts that scale with corpus size — plus the
cost-safety tooling (AWS Budgets, Cost Anomaly Detection, CloudWatch
billing alarms, a pre-flight account check) built after this project's
real billing incident.

Two state machines, chained by data, not by a Step Functions call:

- **`statemachine/validate_corpus.asl.json`** orchestrates
  [poster-corpus-validation](https://github.com/pulp-analytics/poster-corpus-validation)'s
  scripts 01-10, ending in `validated_corpus.csv`.
- **`statemachine/compute_metrics.asl.json`** takes that same
  `validated_corpus.csv` as its input (via `scripts/prepare_metrics_input.py`,
  a small schema adapter — see the Structure section) and orchestrates
  [poster-metrics-pipeline](https://github.com/pulp-analytics/poster-metrics-pipeline)'s
  scripts 01-13 on top of it.

Part of the [Pulp Analytics](https://github.com/pulp-analytics) horror poster
analysis project ("The Anatomy of Fear").

**Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first** — it's explicit
about what's real (the cost-safety tooling, both dependency graphs) versus
what's a new design proposed here (Step Functions + Batch + Fargate; the
actual 145k-poster run used self-terminating EC2 instances instead), and
explains why only some of each pipeline's scripts get row-level sharding.

## Structure

```
statemachine/
  validate_corpus.asl.json     poster-corpus-validation's 01-10; 02/03/04/
                                05/06 as Batch array jobs + a merge step,
                                01/07/08/09/Assemble as single Fargate
                                ECS tasks
  compute_metrics.asl.json     poster-metrics-pipeline's 01-13, downstream
                                of the above; 01/02/03/04/05/10/11 (every
                                script that scales with corpus size) as
                                Batch array jobs + a merge step, 06/07/08/
                                09/12/13 (read one merged embeddings cache,
                                vectorized, seconds regardless of corpus
                                size) as single Fargate ECS tasks -- no
                                final Assemble, this pipeline has none
ecs/
  task-definition.json         Fargate task def for validate_corpus's
                                single-task steps
  task-definition-metrics.json same, for compute_metrics -- separate
                                family/image/role, more memory (loads
                                torch models + full embeddings caches)
batch/
  compute-environment.json,
  job-queue.json,
  job-definition.json          validate_corpus's Batch resources
  compute-environment-metrics.json,
  job-queue-metrics.json,
  job-definition-metrics.json  compute_metrics's own Batch resources --
                                separate queue/compute env, CPU-only
                                (Fargate) by design; see docs/ARCHITECTURE.md
                                for the GPU tradeoff this deliberately
                                doesn't take
docker/
  Dockerfile                   Packages poster-corpus-validation's scripts/
                                (cloned at build time) plus this repo's
                                scripts/merge_shards.py
  Dockerfile.metrics            Same idea for poster-metrics-pipeline --
                                separate image, entirely different
                                dependency stack (torch/pyiqa/CLIP/SigLIP)
iam/
  stepfunctions_execution_role_policy.json,
  fargate_execution_role_policy.json,
  fargate_task_role_policy.json              validate_corpus's 3 roles
                                              (Bedrock/Comprehend/Translate
                                              + EFS)
  stepfunctions_execution_role_policy_metrics.json,
  fargate_execution_role_policy_metrics.json,
  fargate_task_role_policy_metrics.json      compute_metrics's own 3 roles
                                              -- narrower: EFS only, no
                                              Bedrock/Comprehend/Translate,
                                              no TMDB secret (poster-metrics-
                                              pipeline needs neither)
scripts/
  preflight_check.sh           confirms which AWS account/profile is active
                                before anything cost-bearing runs
  setup_cost_safety.sh         provisions the Budget/Anomaly Detection/
                                CloudWatch alarms described in COST_SAFETY.md
  merge_shards.py              combines N Batch array-job shard outputs
                                back into the single file the next stage
                                expects (CSV concat, JSON dict union, or
                                npz embedding-cache concat)
  prepare_metrics_input.py     adapts validate_corpus's validated_corpus.csv
                                into compute_metrics's id/title/year/
                                poster_path input schema
docs/
  ARCHITECTURE.md              the design, what's real vs. new, both
                                dependency graphs, and why sharding
                                applies to some scripts and not others
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

### Then, compute_metrics — steps 1-4 above are shared; step 5 differs

```bash
docker build -t poster-metrics -f docker/Dockerfile.metrics .
docker tag poster-metrics:latest <your-metrics-ecr-repo>:latest
docker push <your-metrics-ecr-repo>:latest

# create the metrics EFS access point, iam/*_metrics.json roles,
# ecs/task-definition-metrics.json, and batch/*-metrics.json -- same
# process as validate_corpus's, separate resources throughout

aws stepfunctions start-execution --state-machine-arn <metrics-arn> --input '{
  "validatedCorpusPath": "data/sample_output/validated_corpus.csv",
  "metricsInputPath": "data/sample_output/metrics_input.csv",
  "shardCount": 4,
  "shardDir": "data/metrics_shards",
  "colorPath": "data/sample_output/color_metrics.csv",
  "iqaPath": "data/sample_output/iqa_multi_score.csv",
  "nimaPath": "data/sample_output/nima_score.csv",
  "laionPath": "data/sample_output/laion_aesthetic_score.csv",
  "mediumPath": "data/sample_output/medium.csv",
  "clipEmbeddingsPath": "data/sample_output/clip_embeddings.npz",
  "siglipEmbeddingsPath": "data/sample_output/siglip_embeddings.npz",
  "censusPath": "data/sample_output/census.csv",
  "fearAxisPath": "data/sample_output/fear_axis.csv",
  "typographyPath": "data/sample_output/typography.csv",
  "genreClassifierPath": "data/sample_output/genre_classifier.csv",
  "siglipFearAxisPath": "data/sample_output/siglip_fear_axis.csv",
  "siglipCensusPath": "data/sample_output/siglip_census.csv",
  "siglipTypographyPath": "data/sample_output/siglip_typography.csv",
  "siglipGenreClassifierPath": "data/sample_output/siglip_genre_classifier.csv"
}'
```

`validatedCorpusPath` is `validate_corpus.asl.json`'s own execution's
final output — the two state machines aren't linked by a Step Functions
`arn:aws:states:::states:startExecution` call here, just by one's output
file being the other's input path, kept as two independent executions you
trigger in sequence (or wire together yourself with EventBridge/a Lambda
if you want one `start-execution` call to trigger the other automatically).

## License

MIT — see [LICENSE](LICENSE).
