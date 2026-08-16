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

# Pinned to the commit that extends the same "build the ideal, don't port
# an unreproducible mechanism" approach to gates 8 (poster MD5 dedup, now
# shares gate 7's completeness cascade) and 9 (compilation collapsing, now
# scores every TMDB search candidate instead of requiring exactly one)
# (2026-08-16). GitHub's smart HTTP protocol supports fetching by exact SHA
# (not just branch/tag names) for public repos, which --depth 1 --branch
# alone does not.
ARG CORPUS_VALIDATION_REF=f3d0e76f52b307369924cb45a422e8479b644242
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
