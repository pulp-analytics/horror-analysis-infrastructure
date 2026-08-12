# Architecture

## What's real here, and what's a new design

Be precise about this, because it matters: the actual 145,492-poster corpus
run this project produced used **self-terminating EC2 instances** (a
userdata script that runs the job, then `shutdown -h now` with
`instance-initiated-shutdown-behavior terminate`) — not Step Functions or
Fargate. That EC2 pattern is real, already-run, already-validated.

The Step Functions + Fargate design in this repo (`statemachine/`, `ecs/`,
`iam/`) is a **new, forward-looking design** for running
[horror-corpus-validation](https://github.com/pulp-analytics/horror-corpus-validation)
at scale — not a description of what actually ran. It exists because,
comparing the two approaches directly:

- The real billing incident that motivated `docs/COST_SAFETY.md` was
  specifically an EC2 instance running on the wrong account with no hard
  stop. A Fargate task launched by Step Functions is ephemeral by
  construction — there's no long-lived instance to forget about, and no
  self-termination script that can fail to fire.
- `horror-corpus-validation`'s scripts already have an explicit,
  documented dependency graph (see its README) with real parallel
  branches that its own orchestrator (`10_validate_corpus.py`) doesn't
  exploit — it runs everything sequentially via `subprocess.run`. Step
  Functions' `Parallel` state is a natural fit for that graph, with retry
  policies and visual execution history as a side benefit.

If you just want to run the validation once or twice, use
`horror-corpus-validation` directly — clone it, `pip install`, run
`10_validate_corpus.py`. Reach for this repo when you're running it
repeatedly, at a scale where wall-clock parallelism and unattended
monitoring start to matter.

## The dependency graph, mapped to Step Functions states

`horror-corpus-validation`'s real dependencies (not the order its own
orchestrator happens to run them in):

```
01 (enumerate)
  │
  ├──▶ 02 (verify_poster) ──┬──▶ 04 (bedrock_ocr) ──┬──▶ 05 (comprehend) ──▶ 06 (translate)
  │                          │                        └──▶ 09 (collapse_compilations)
  │                          └──▶ 08 (dedupe_poster_md5)
  │
  ├──▶ 03 (fetch_alt_titles)
  └──▶ 07 (dedupe_tmdb_metadata)
                                                                              │
                                    assemble (reads 02,07,08,09 outputs) ◀───┘
```

`statemachine/validate_corpus.asl.json` mirrors this exactly:

- `Enumerate` (01) runs alone first — everything else needs its output.
- `IndependentGates` is a `Parallel` state with three branches: `03`, `07`,
  and a `02`-rooted branch — none of the three need each other.
- Inside the `02` branch, `AfterVerify` is itself a `Parallel` state for
  `04` and `08` — the only two steps that download the poster image, and
  so the only two that actually need `02`'s verified=1 result.
- Inside `04`'s branch, `AfterBedrock` is a nested `Parallel` for `05→06`
  and `09` — both only need `04`'s `vision_title_check.csv`.
- `Assemble` runs `10_validate_corpus.py --assemble-only` last, after
  every branch above has finished — it only reads files, it doesn't
  re-run 01-09 itself (that flag exists in `horror-corpus-validation`
  specifically for this use case).

Every `Task` state uses `arn:aws:states:::ecs:runTask.sync`, so Step
Functions blocks on each Fargate task actually finishing (not just
launching) before moving on — required for the dependency ordering above
to mean anything.

## Why Fargate tasks need a shared EFS volume

Step Functions launches each script as its **own** Fargate task, each with
its own throwaway container filesystem. `horror-corpus-validation`'s
scripts hand data to each other through files (`04` writes
`vision_title_check.csv`, `05` reads it) — that only works if every task
sees the same filesystem. `ecs/task-definition.json` mounts one EFS access
point at `/app/data` on every task for exactly this reason; without it,
`05_comprehend_language.py` would start with an empty `data/` directory and
immediately fail to find `04`'s output. This is the one piece of the
design that has no equivalent in running the scripts locally in one
process, where they obviously already share a filesystem.

## IAM: three roles, not one

- **`iam/stepfunctions_execution_role_policy.json`** — what the state
  machine itself can do (launch/track ECS tasks, pass the two roles below
  to ECS).
- **`iam/fargate_execution_role_policy.json`** — what ECS needs to *start*
  a container: pull the image from ECR, create the CloudWatch log stream,
  read the TMDB API key from Secrets Manager to inject as an env var.
- **`iam/fargate_task_role_policy.json`** — what the running Python code
  itself can do: call Bedrock Converse, Comprehend, Translate, and mount
  the EFS volume. Nothing else — no S3, no EC2, no IAM.

Keeping these separate means the code that's actually processing untrusted
poster images and calling three different AI services never has broader
permissions than exactly those three API calls plus the shared disk.

## Model flexibility carries through

`horror-corpus-validation`'s `04_bedrock_ocr.py --model` accepts any
Bedrock model id — that's still true here. `fargate_task_role_policy.json`
lists both Nova Pro and Nova Lite in its resource ARNs; add another
model's ARN there and pass `--model` in the `BedrockOCR` state's command
override if you want to swap models without changing the image.
