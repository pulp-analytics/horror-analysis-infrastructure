# Packages poster-corpus-validation's scripts/ for the Fargate/Batch tasks
# that statemachine/validate_corpus.asl.json runs, plus this repo's own
# scripts/merge_shards.py (the merge steps between an array job and the
# next stage need it, and it isn't part of poster-corpus-validation --
# that repo has no reason to know its output might get sharded).
# poster-corpus-validation's code isn't vendored -- it's fetched at build
# time by exact commit SHA (not a moving branch), so every image build is
# reproducible: two builds with the same CORPUS_VALIDATION_REF pull the
# exact same code, regardless of what's since landed on main. Override with
# --build-arg CORPUS_VALIDATION_REF=<sha> to build against a newer commit;
# `git ls-remote https://github.com/pulp-analytics/poster-corpus-validation.git main`
# gets you the current tip when you're ready to move the pin forward.
#
# Build context is THIS repo's root (for merge_shards.py):
#   docker build -t horror-validator -f docker/Dockerfile .
#
# Every step in the state machine (01-10, plus the merge steps) uses this
# same image; which script runs is decided by the container command
# override in the ASL definition, not by anything baked into the image.
FROM python:3.12-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Pinned to the commit that fixes a real bug in 10_validate_corpus.py, the
# orchestrator that actually merges gates 7-9 into excluded_ids.csv: gate 8
# (poster MD5) ran its exclusion block before gate 9 (compilation
# collapse), so on the real Sheets of Gore pair it silently excluded the
# correct canonical entry and kept the wrong segment -- exactly backwards.
# Gate 9 now always runs first and its confirmed canonical ids are
# protected from gates 7/8's exclusions (2026-08-16). GitHub's smart HTTP
# protocol supports fetching by exact SHA (not just branch/tag names) for
# public repos, which --depth 1 --branch alone does not.
ARG CORPUS_VALIDATION_REF=7bbe171682091a7b6d49814494004194e0a1de67
RUN git init -q . \
    && git remote add origin https://github.com/pulp-analytics/poster-corpus-validation.git \
    && git fetch --depth 1 origin "${CORPUS_VALIDATION_REF}" \
    && git checkout -q FETCH_HEAD

RUN pip install --no-cache-dir -r requirements.txt

COPY scripts/merge_shards.py /app/merge_shards.py

# TMDB_API_KEY and the AWS credentials for Bedrock/Comprehend/Translate come
# from the Fargate task definition's environment/secrets and the task role
# respectively (see iam/fargate_task_role_policy.json) -- nothing here.
#
# No ENTRYPOINT/CMD on purpose: every ECS RunTask call in
# statemachine/validate_corpus.asl.json supplies the full command (starting
# with "python3" itself) via ContainerOverrides, since which script to run
# is a per-step decision, not something the image should default to. This
# default CMD only matters if you run the image directly without an
# override -- it just proves the image built correctly.
CMD ["python3", "--version"]
