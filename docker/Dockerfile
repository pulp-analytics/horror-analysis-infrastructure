# Packages horror-corpus-validation's scripts/ for the Fargate/Batch tasks
# that statemachine/validate_corpus.asl.json runs, plus this repo's own
# scripts/merge_shards.py (the merge steps between an array job and the
# next stage need it, and it isn't part of horror-corpus-validation --
# that repo has no reason to know its output might get sharded).
# horror-corpus-validation's code isn't vendored -- it's cloned at build
# time so the image always tracks whatever's actually on its main branch,
# the same repo you'd `pip install -r requirements.txt` from to run it
# locally.
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

# Pin this to a commit/tag once you've settled on a version, instead of
# always tracking main -- see docs/ARCHITECTURE.md.
ARG CORPUS_VALIDATION_REF=main
RUN git clone --depth 1 --branch "${CORPUS_VALIDATION_REF}" \
    https://github.com/pulp-analytics/horror-corpus-validation.git .

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
