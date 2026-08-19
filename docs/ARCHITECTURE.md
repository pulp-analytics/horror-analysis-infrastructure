# Architecture

## What's real here, and what's a new design

Be precise about this, because it matters: the actual 145,492-poster corpus
run this project produced used **self-terminating EC2 instances** (a
userdata script that runs the job, then `shutdown -h now` with
`instance-initiated-shutdown-behavior terminate`) — not Step Functions,
Fargate, or Batch. That EC2 pattern is real, already-run, already-validated.

Everything in `statemachine/`, `ecs/`, `batch/`, and `iam/` started as a
**new, forward-looking design** for running
[poster-corpus-validation](https://github.com/pulp-analytics/poster-corpus-validation)
at scale — not a description of what produced the real 145,492-poster
corpus, which used the EC2 pattern above. That design is now **live-tested
end-to-end**: deployed into a real AWS Workshop Studio sandbox account
(EFS + Secrets Manager + Batch compute environment/queue/job definition +
ECS task definition + Step Functions state machine, all wired to real
ARNs, no placeholders) and run to a real `ExecutionSucceeded`, 2026-08-16
— `Enumerate` → the `IndependentGates` parallel branches (including two
AWS Batch array jobs, `FetchAltTitlesShards` and `VerifyPosterShards` →
`BedrockOCRShards` → `ComprehendLanguageShards`/`TranslateTitlesShards`) →
`Assemble`, in ~9.6 minutes wall-clock. `Assemble`'s own CloudWatch log
confirms real work, not just a clean exit: `{'genre': 27, 'total_input':
5074, 'excluded': 0, 'validated': 5074, 'elapsed_seconds': 0.2}`.

Getting there live-tested — and fixed — four real bugs in
`statemachine/validate_corpus.asl.json` that no prior review had caught,
because the design had never actually been exercised before:
1. `Task` states had no `ResultPath`, so each ECS/Batch call's own result
   silently replaced the flowing input, dropping fields (`$.shardCount`,
   `$.idsPath`, ...) later states needed.
2. `Parallel` states had the exact same problem and needed the exact same
   fix — `IndependentGates`, `AfterVerify`, `AfterBedrock` all overwrote
   the input with an array of each branch's own output.
3. `batch:submitJob`'s Parameters used the API's own camelCase
   (`jobName`/`jobQueue`/`jobDefinition`) — Step Functions' native Batch
   integration needs PascalCase (`JobName`/`JobQueue`/`JobDefinition`).
4. `${AWS_BATCH_JOB_ARRAY_INDEX}` (braced, for the shell to expand at
   container runtime) collided with `States.Format`'s own `{}` placeholder
   syntax, which has no brace-escaping — fixed by renaming the shard
   filename convention to put a non-identifier character (`-`) around the
   index instead of relying on braces.

None of this changes the recommendation below — it's still a new design,
still not what the real corpus run used — but "new design, never
exercised" and "new design, live-tested and now working" are different
claims, and this section should say which one is true. Comparing the two
approaches directly, the reasons this design exists at all:

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

## Extending to poster-metrics-pipeline

Everything above orchestrates `poster-corpus-validation`. This section
covers `statemachine/compute_metrics.asl.json`, which orchestrates
`poster-metrics-pipeline`'s 13 scripts (color, perceptual quality, CLIP,
SigLIP) as a second, downstream stage — same infrastructure pattern
(Step Functions + Batch array jobs + Fargate + `merge_shards.py`), applied
to a different repo with a different real dependency graph.

### The connection between the two repos is real, but wasn't glued together anywhere until now

`poster-corpus-validation`'s final output, `validated_corpus.csv`
(`id,title,original_title,release_date,poster_path,...`), is almost
exactly `poster-metrics-pipeline`'s expected `--in` schema
(`id,title,year,poster_path`) — the only gap is `release_date` vs. `year`,
a one-line derivation. `scripts/prepare_metrics_input.py` does exactly
that and nothing else — verified live against the real
`validated_corpus.csv` sample (95/95 rows converted, 0 dropped), and the
resulting file was confirmed to run correctly through
`poster-metrics-pipeline`'s `01_color_metrics.py` end to end. This glue
belongs in this repo, not in either pipeline repo — neither one has a
reason to know the other's column names on its own.

### Why the split here is "all 7 scale with corpus size" vs. corpus-validation's "5 of 9 do"

`poster-corpus-validation`'s `07`/`08`/`09` skip sharding because they
only touch a small set of *candidate* rows found locally first (see
above). `poster-metrics-pipeline` has no equivalent "small candidate set"
step — every metric script computes something for *every* poster in the
corpus, no exceptions. So the split here uses a different, but analogous,
criterion: does the per-poster cost come from real model inference
(network-bound TMDB fetch + CPU/GPU-bound neural net forward pass, the
kind of cost that scales linearly and benefits from parallel workers) or
from a single vectorized matrix operation over the whole corpus at once
(the kind of cost numpy already parallelizes internally, where splitting
across containers just adds coordination overhead for no benefit)?

```
PrepareInput (adapter, single Fargate task)
  │
  ├──▶ 01 (color_metrics, BATCH ARRAY)         ─┐
  ├──▶ 02 (iqa_multi_score, BATCH ARRAY)         │
  ├──▶ 03 (nima_score, BATCH ARRAY)              │  wave 1 -- independent
  ├──▶ 04 (laion_aesthetic_score, BATCH ARRAY)   │  of each other, each
  ├──▶ 10 (clip_medium, BATCH ARRAY)             │  scales with corpus size
  ├──▶ 05 (clip_embed, BATCH ARRAY) ──▶ merge ──┐│
  └──▶ 11 (siglip_embed, BATCH ARRAY) ─▶ merge ─┼┘
                                                  │
                        ┌─────────────────────────┘
                        │
  06/07/08/09 (single Fargate tasks, read merged clip_embeddings.npz)
  12/13       (single Fargate tasks, read merged siglip_embeddings.npz)
```

`01`-`05` and `10`-`11` (7 scripts) each loop over every poster
independently, fetching its image and running a real model forward pass
(pyiqa, NIMA, LAION's CLIP ViT-L/14, CLIP ViT-B/32, or SigLIP) — the exact
same "one row at a time inside a single process" cost profile that
motivated sharding `poster-corpus-validation`'s 5 scripts in the first
place, so they get the same treatment: Batch array job + merge step.

`06`/`07`/`08`/`09`/`12`/`13` (6 scripts) don't touch poster images at
all — they read one already-built embeddings cache (a few hundred
thousand small vectors) and compute cosine similarities against a handful
of text prototypes, a single `vecs @ prototypes.T` numpy call covering
every poster in one process. Confirmed live in `poster-metrics-pipeline`'s
own testing: 99 posters processed in about two seconds; the same
operation over a 145k-poster corpus is a bigger matrix, not a slower
per-row loop — no per-row cost to parallelize, so these run as single
Fargate tasks, gated only on whichever embedding merge they depend on.

### No final Assemble step, unlike validate_corpus

`poster-corpus-validation` ends in one gate script (`10_validate_corpus.py
--assemble-only`) that reads every branch's output and produces one
verdict. `poster-metrics-pipeline` has no equivalent — each of its 13
scripts computes an independent per-poster metric and writes its own
output file (see that repo's own Scope note: no cross-metric aggregation
happens inside it, that's a front-end/presentation concern). So
`compute_metrics.asl.json` just ends after wave 2's `Parallel` state —
there's nothing left to assemble.

### GPU is a real option this design doesn't take, on purpose

All seven wave-1 scripts run real neural-net inference and would finish
meaningfully faster on a GPU (Fargate itself has zero GPU support at all —
this would mean a Batch compute environment backed by EC2 GPU instances,
e.g. the `g4dn`/`g5` families, instead of `batch/compute-environment-metrics.json`'s
Fargate-only setup). This design defaults to CPU/Fargate anyway, for the
same reason `docs/COST_SAFETY.md` exists: this project's one real
infrastructure incident was a long-lived, un-terminated instance, and an
EC2 GPU fleet left scaled up is a strictly more expensive version of that
same risk. If wall-clock time at full 145k-poster scale turns out to be
the actual bottleneck, switching `batch/compute-environment-metrics.json`'s
`type` and adding GPU `resourceRequirements` to
`batch/job-definition-metrics.json` is the documented next step — not
something silently assumed here.

## `compute_metrics.asl.json`, extended and live-tested (2026-08-19)

Everything above described `compute_metrics.asl.json` covering
`poster-metrics-pipeline`'s scripts 01-13 as a "new design, never
exercised" — the same caveat the top of this document makes about
`validate_corpus.asl.json` before *its* live test. That's no longer true
for either state machine. When `poster-metrics-pipeline` grew scripts
14-21 (faces, geometric composition, depth, saliency, pose,
creature/weapon detection — see that repo's own README/docs/RESULTS.md),
`compute_metrics.asl.json` was extended to match (14 wave-1 branches now,
up from 7; `FaceExpression` added as an 7th wave-2 branch, gated on
`MergeFaceDetect` instead of an embeddings merge) — real new
infrastructure (ECR repo, EFS filesystem/access point, IAM roles, Batch
compute environment/queue/job definition, ECS cluster/task definition,
state machine), deployed into the same Workshop Studio sandbox account as
the validator, and run to a real `ExecutionSucceeded` on
`poster-metrics-pipeline`, 2026-08-19, ~12 minutes wall-clock for an
8-poster sample — every one of the 22 output files landed on EFS with a
real row per poster (composition scores, depth maps, pose keypoints,
face boxes/expressions, saliency peaks, creature/weapon detections with
real bounding boxes, etc.), confirmed by reading them back off EFS
through a one-off verification ECS task, not just trusting a green
Step Functions status.

**ARM64, not x86_64**: `poster-metrics-pipeline`'s dependency stack
(torch, tensorflow, transformers, ultralytics, pyiqa) took over 55
minutes of wall-clock just for `pip install` when built for `linux/amd64`
on Apple Silicon via QEMU emulation — bad enough that the emulated build
wedged the local Docker daemon entirely partway through and needed a full
Docker Desktop restart to recover. Fargate has supported ARM64 (Graviton)
for years, so the fix was building natively for `arm64` instead — no
emulation, and Graviton is generally cheaper on Fargate too. This means
`ecs/task-definition-metrics.json`'s live-deployed task definition and
`batch/job-definition-metrics.json`'s live-deployed job definition both
carry `"runtimePlatform": {"cpuArchitecture": "ARM64", ...}`, which
their checked-in templates don't (same "template stays generic, deployed
reality documented here" pattern as everything else in this file) — copy
that block in if you rebuild this from the templates.

**Real bugs found getting there, same spirit as the four already listed
above for `validate_corpus.asl.json`** — this ASL had never actually been
exercised before, so it silently carried the same classes of bug, plus
two new ones specific to the image:

5. **Missing `ResultPath`, same as bug #1** — every `Task`/`Parallel`
   state in `compute_metrics.asl.json` was missing `ResultPath`, so each
   ECS/Batch call's own result (a large ECS task-description object)
   silently replaced the flowing state input instead of being discarded,
   the exact same failure mode bug #1 above describes for
   `validate_corpus.asl.json`. Fixed identically: `"ResultPath": null`
   on all 38 `Task`/`Parallel` states.
6. **Batch `submitJob` camelCase, same as bug #3** — `jobName`/
   `jobQueue`/`jobDefinition`/`arrayProperties`/`command` (the Batch API's
   own casing) instead of Step Functions' required
   `JobName`/`JobQueue`/`JobDefinition`/`ArrayProperties`/`Command.$`.
   `aws stepfunctions validate-state-machine-definition` catches this
   directly (`SCHEMA_VALIDATION_FAILED`) — worth running before any live
   deploy, not just before *this* one.
7. **`${AWS_BATCH_JOB_ARRAY_INDEX}` brace collision, same as bug #4** —
   identical to `validate_corpus.asl.json`'s fix: dropped the braces
   (`$AWS_BATCH_JOB_ARRAY_INDEX`) and switched the shard filename
   convention from `shard_${...}_name` (braces plus an adjacent
   underscore — `States.Format`'s intrinsic can't parse the braces, and
   even unbraced, a literal underscore right after the variable name
   would make bash look for a differently-named variable) to
   `shard-$AWS_BATCH_JOB_ARRAY_INDEX-name` (dashes, which aren't valid in
   a bash identifier, so the variable name ends there unambiguously).
8. **`opencv-python` vs. `opencv-python-headless`, new to this image** —
   `requirements.txt` lists plain `opencv-python` (for `14_face_detect.py`'s
   YuNet), but something else in the graph (`ultralytics`, transitively,
   for `19_pose_dynamism.py`) pulls in `opencv-python-headless` too — both
   packages write into the *same* `site-packages/cv2/` path, so whichever
   installs last physically wins on disk regardless of what either
   package's own metadata claims. Here the GUI build won, and since
   `python:3.12-slim` has no X11 libs, anything that imports `cv2` (e.g.
   `17_depth_estimation.py`'s torch.hub-loaded MiDaS transform) crashed
   with `ImportError: libxcb.so.1: cannot open shared object file`.
   `pip uninstall -y opencv-python` alone made it worse — one package's
   uninstall deleted the shared `cv2/` directory outright, breaking
   *every* script that imports `cv2` (`ModuleNotFoundError: No module
   named 'cv2'`) — the fix needed a second step, force-reinstalling the
   headless build afterward so `cv2/`'s actual files come back.
9. **`opencv-contrib-python-headless`, not plain `-headless`** — one
   more layer: `16_geometric_composition.py`'s
   `cv2.saliency.StaticSaliencySpectralResidual_create()` lives in
   OpenCV's *contrib* modules, which plain `opencv-python-headless`
   doesn't include at all (`module 'cv2' has no attribute 'saliency'`) —
   never surfaced until bug #8 was fixed and this code path was finally
   reachable. `opencv-contrib-python-headless` is a strict superset (core
   + contrib, still no GUI deps), so it replaces `opencv-python-headless`
   outright rather than needing both. See `docker/Dockerfile.metrics`'s
   own comments for the exact live-tested reasoning on both.
10. **`ModuleNotFoundError: No module named 'pkg_resources'`, new to this
    image** — `02_iqa_multi_score.py`'s `clipiqa` metric (via `pyiqa`)
    imports the `openai-clip` package (`import clip`, distinct from
    `open_clip_torch`, also present here for 05/11's CLIP/SigLIP
    scripts), whose vendored `clip.py` does `from pkg_resources import
    packaging` — a legacy idiom recent `setuptools` (84.0.0 here) no
    longer supports, having dropped `pkg_resources` per PEP 632. Fixed by
    pinning `setuptools<81` as an explicit post-install step, restoring
    `pkg_resources` without touching `openai-clip`'s own (unmaintained
    upstream) source.

Bugs 8-10 all live as extra `RUN` layers appended *after*
`RUN pip install -r requirements.txt` in `docker/Dockerfile.metrics`, on
purpose: Docker's build cache keys each layer off everything before it,
so as long as `requirements.txt`'s content and the pinned
`METRICS_PIPELINE_REF` don't change, that one `pip install` layer (the
single most expensive step in this whole image, well over 30 minutes on
its own) stays cached and reused across rebuilds — each of bugs 8-10 was
found and fixed with a rebuild that only re-ran its own new small layer
(seconds, not tens of minutes), not the full install, because none of
them required touching anything upstream of it.
