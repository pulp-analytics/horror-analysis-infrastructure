# Architecture

## What's real here, and what's a new design

Be precise about this, because it matters: the actual 145,492-poster corpus
run this project produced used **self-terminating EC2 instances** (a
userdata script that runs the job, then `shutdown -h now` with
`instance-initiated-shutdown-behavior terminate`) — not Step Functions,
Fargate, or Batch. That EC2 pattern is real, already-run, already-validated.

Everything in `statemachine/`, `ecs/`, `batch/`, and `iam/` is a **new,
forward-looking design** for running
[poster-corpus-validation](https://github.com/pulp-analytics/poster-corpus-validation)
at scale — not a description of what actually ran. It exists because,
comparing the two approaches directly:

- The real billing incident that motivated `docs/COST_SAFETY.md` was
  specifically an EC2 instance running on the wrong account with no hard
  stop. A Fargate/Batch task is ephemeral by construction — there's no
  long-lived instance to forget about, and no self-termination script that
  can fail to fire.
- `poster-corpus-validation`'s scripts already have an explicit,
  documented dependency graph (see its README) that its own orchestrator
  (`10_validate_corpus.py`) doesn't exploit — it runs everything
  sequentially via `subprocess.run`, one row at a time inside a single
  process, even for the full 145k-row corpus.

If you just want to run the validation once or twice, use
`poster-corpus-validation` directly — clone it, `pip install`, run
`10_validate_corpus.py`. Reach for this repo when you're running it
repeatedly, at a scale where wall-clock parallelism and unattended
monitoring start to matter.

## Two axes of parallelism, not one

An earlier version of this design only parallelized across **stages**
(letting independent scripts like `03` and `07` run concurrently instead
of strictly in sequence). That's real, but it's a modest win — at most a
handful of branches running at once. It misses the actual bottleneck: five
of the nine scripts (`02`, `03`, `04`, `05`, `06`) each loop over **every
row** of the corpus **one at a time inside a single process**, with a
`time.sleep()` between rows. For a 100-row sample that's irrelevant; for
145,492 rows it's the dominant cost by orders of magnitude — no amount of
stage-level parallelism touches it, because the slow part is inside one
stage, not between stages.

So this design parallelizes on both axes:

1. **Across stages** — a Step Functions `Parallel` state, same as before,
   for scripts that don't depend on each other.
2. **Across rows, within a stage** — an **AWS Batch array job** for the
   five scripts that scale with corpus size, splitting the row set across
   N array children that run concurrently, each handling `1/N` of the work.

### Why not all nine scripts get row-level sharding

Only `02`, `03`, `04`, `05`, `06` process every row of the corpus
independently — no row depends on any other row's result, which is exactly
what makes them safe to split arbitrarily. `07`, `08`, `09` are different:
they each first find a small set of *candidates* locally (duplicate
title+year+overview groups, shared MD5 hashes, shared poster paths) and
only do real work — a handful of TMDB API calls — on that tiny subset. In
the real full-corpus run this was ~18 duplicate-title groups, ~3
MD5-duplicate groups, ~11 compilation segments, out of 145,492 rows.
Sharding a script that already only touches a few dozen rows adds
operational complexity (Batch array job, merge step, IAM) for a stage
that's fast regardless. `01` (enumeration) and `Assemble` (the final merge)
aren't per-row loops over the candidate set at all, so sharding doesn't
apply to them either. All four of these run as single Fargate ECS tasks,
same as the earlier stage-only design.

## The dependency graph, mapped to Step Functions states

```
01 (enumerate)
  │
  ├──▶ 02 (verify_poster, BATCH ARRAY) ──┬──▶ 04 (bedrock_ocr, BATCH ARRAY) ──┬──▶ 05 (comprehend, BATCH ARRAY) ──▶ 06 (translate, BATCH ARRAY)
  │                                       │                                    └──▶ 09 (collapse_compilations, single task)
  │                                       └──▶ 08 (dedupe_poster_md5, single task)
  │
  ├──▶ 03 (fetch_alt_titles, BATCH ARRAY)
  └──▶ 07 (dedupe_tmdb_metadata, single task)
                                                                                                        │
                                             assemble (reads 02,07,08,09 outputs, single task) ◀────────┘
```

Every Batch-array box above is really two Step Functions states in
sequence: `<Script>Shards` (`arn:aws:states:::batch:submitJob.sync`, an
array job) followed by `Merge<Script>` (an `ecs:runTask.sync` running
`merge_shards.py`) — see `statemachine/validate_corpus.asl.json`. The next
stage in the graph depends on the *merged* file, never on an individual
shard's output.

## How row sharding actually works

Each of the five shardable scripts takes `--shard-index`/`--shard-count`
(added to `poster-corpus-validation` alongside this design): given the
same `--in` file, `rows[shard_index::shard_count]` is a deterministic,
disjoint partition — shard 3 of 20 always means the same rows, with no
coordination needed between shards.

A Batch array job doesn't let you pass a *different* command per child —
every child in the array runs the identical container command. The
per-child index instead comes from the `AWS_BATCH_JOB_ARRAY_INDEX`
environment variable Batch injects automatically, which is why every
Batch `Task` state's command is a `sh -c "..."` wrapper: the shell expands
`$AWS_BATCH_JOB_ARRAY_INDEX` into the actual `--shard-index` value and
output filename at container start time, something Step Functions itself
has no way to know ahead of submission (it doesn't know which index a
given child will be assigned).

`ArrayProperties.size`/`arrayProperties.size` (mind the casing — see
below) comes from the state machine's `$.shardCount` execution input, so
parallelism is a per-run choice, not hardcoded: a 100-row sample run might
use `shardCount: 4`, a full 145k-row run might use `shardCount: 100`.

### Retries happen at two levels, on purpose

`batch/job-definition.json` sets `retryStrategy: {attempts: 3}` -- Batch's
own per-child retry, so a single flaky array child (a Bedrock
`ThrottlingException`, a transient TMDB timeout) gets retried by Batch
itself without failing the whole array job. Only if a child exhausts those
3 attempts does the array job fail, which is what triggers the *state
machine's* `Retry` block on the `...Shards` state -- and even then, that
resubmits the entire array job safely, not wastefully: every array child
re-reads its own `--out` file first (the same resumability that lets you
re-run any of these scripts locally after an interruption), so a retried
run only redoes ids it doesn't already have, whether the retry came from
Batch or from Step Functions.

### `merge_shards.py`

After an array job's `.sync` state returns (meaning every child finished),
the merge step combines `N` shard files back into the single file the next
stage expects — concatenating CSVs, or unioning dicts for `03`'s JSON
output. It takes `--shard-glob` + `--expected-count` rather than an
explicit file list, specifically because the state machine doesn't know
`$.shardCount` until execution time and can't enumerate `N` filenames in a
static definition. A glob matching fewer files than `--expected-count` is
a hard failure — a shard that crashed without writing output must not be
silently treated as "zero rows contributed."

## Why Fargate/Batch tasks need a shared EFS volume

Both ECS tasks and Batch array children get their own throwaway container
filesystem. `poster-corpus-validation`'s scripts hand data to each other
through files — that only works if every task/job sees the same
filesystem. `ecs/task-definition.json` and `batch/job-definition.json`
both mount the same EFS access point at `/app/data` for exactly this
reason, including across shards: shard 3 of `04` needs to read the same
`poster_verification.csv` that the `02` merge step wrote, and the `05`
array job needs to read the `vision_title_check.csv` the `04` merge step
wrote.

## IAM: four roles

- **`iam/stepfunctions_execution_role_policy.json`** — what the state
  machine can do: launch/track both ECS tasks and Batch jobs, pass the two
  roles below to whichever one it's launching.
- **`iam/fargate_execution_role_policy.json`** — what ECS *or* Batch needs
  to start a container: pull the image, create the log stream, read the
  TMDB key from Secrets Manager. Shared between `ecs/task-definition.json`
  and `batch/job-definition.json` — same job, same permissions, regardless
  of which service launched the container.
- **`iam/fargate_task_role_policy.json`** — what the running Python code
  itself can do: Bedrock Converse, Comprehend, Translate, the EFS mount.
  Also shared between ECS and Batch, for the same reason.
- AWS Batch's own service role (what Batch uses to manage the underlying
  Fargate capacity on your behalf, referenced as `batch/compute-environment.json`'s
  `serviceRole`) — check current AWS docs before filling this in: for
  `FARGATE`-type compute environments, Batch has historically not required
  an explicit service role at all, defaulting to the service-linked role
  `AWSServiceRoleForBatch` instead. Don't hand-write a custom policy for
  this one either way.

## A casing trap worth knowing about

`statemachine/validate_corpus.asl.json`'s ECS `Task` states use PascalCase
parameter names (`Cluster`, `TaskDefinition`, `Overrides`,
`ContainerOverrides`, `Command`) because that mirrors the ECS API's own
shape. The Batch `Task` states use **lowerCamelCase**
(`jobName`, `jobQueue`, `jobDefinition`, `arrayProperties.size`,
`containerOverrides.command`) because that mirrors *Batch's* API shape
instead. Step Functions' optimized service integrations pass parameters
through with each service's native casing, not a uniform convention across
services — getting this wrong is a common, easy-to-miss source of a
`Parameter X is not supported` failure at execution time that won't show
up as a JSON syntax error.

## Model flexibility carries through

`poster-corpus-validation`'s `04_bedrock_ocr.py --model` accepts any
Bedrock model id — that's still true here, passed via `$.bedrockModelId`
in the Batch array job's command. `fargate_task_role_policy.json` lists
both Nova Pro and Nova Lite in its resource ARNs; add another model's ARN
there if you want to swap models without changing anything else.
