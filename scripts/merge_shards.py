#!/usr/bin/env python3
"""Merge N shard output files from an AWS Batch array job (see
docs/ARCHITECTURE.md) back into the single file the next stage in a state
machine expects as its --in. Shared by both
statemachine/validate_corpus.asl.json (poster-corpus-validation) and
statemachine/compute_metrics.asl.json (poster-metrics-pipeline) -- same
merge problem, same tool, regardless of which repo's scripts produced the
shards.

Three formats, matching the shapes each pipeline's shardable scripts
produce:

  --format csv    concatenate N CSVs with the same header into one
                   (poster-corpus-validation's 02/04/05/06; poster-metrics-
                   pipeline's 01/02/03/04/10)
  --format json   union N {id: {...}} objects into one dict, keyed by id
                   (poster-corpus-validation's 03_fetch_alt_titles.py --
                   each shard covers a disjoint set of ids, so this is a
                   plain dict union, not a deep merge)
  --format npz    concatenate N (ids, vecs) embedding caches into one
                   (poster-metrics-pipeline's 05_clip_embed.py and
                   11_siglip_embed.py -- each shard is a partial
                   {ids: int array, vecs: float16 array} .npz over a
                   disjoint id range, same resumable-cache shape the
                   scripts themselves read/write locally)

Every shard is expected to exist -- pass either an explicit --shards list,
or --shard-glob with --expected-count (the state machine uses the glob
form, since an AWS Batch array job's shard count is a runtime parameter of
the execution, not something the state machine definition can hardcode a
file list for). Either way, fewer files than expected is a hard error
instead of silently merging a partial result -- a shard that crashed
without writing output should fail this step loudly, not get treated as
having produced zero rows.

  python3 merge_shards.py --format csv --shards shard_0.csv shard_1.csv shard_2.csv --out merged.csv
  python3 merge_shards.py --format json --shards shard_0.json shard_1.json --out merged.json
  python3 merge_shards.py --format npz --shards shard_0.npz shard_1.npz --out merged.npz
  python3 merge_shards.py --format csv --shard-glob 'data/shard_*_poster_verification.csv' --expected-count 20 --out merged.csv
"""
from __future__ import annotations

import argparse
import csv
import glob
import json
from pathlib import Path

# numpy is only imported inside merge_npz(), not at module level -- the
# validate_corpus.asl.json Dockerfile only installs poster-corpus-
# validation's requirements.txt (no numpy in there), and never calls
# --format npz. Keeping the import lazy means that image doesn't need a
# dependency it never uses, and only the compute_metrics Dockerfile (which
# clones poster-metrics-pipeline, already requiring numpy) needs it.


def merge_csv(shard_paths: list[Path], out_path: Path) -> int:
    fieldnames: list[str] | None = None
    rows: list[dict] = []
    for p in shard_paths:
        with p.open(newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            if fieldnames is None:
                fieldnames = reader.fieldnames
            elif reader.fieldnames != fieldnames:
                raise ValueError(f"{p} has fieldnames {reader.fieldnames}, expected {fieldnames}")
            rows.extend(reader)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames or [])
        w.writeheader()
        w.writerows(rows)
    return len(rows)


def merge_json(shard_paths: list[Path], out_path: Path) -> int:
    merged: dict = {}
    for p in shard_paths:
        shard = json.loads(p.read_text(encoding="utf-8"))
        overlap = set(merged) & set(shard)
        if overlap:
            raise ValueError(f"{p} has {len(overlap)} id(s) already present in an earlier shard "
                              f"(shards should be disjoint) -- first few: {sorted(overlap)[:5]}")
        merged.update(shard)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(merged, indent=2), encoding="utf-8")
    return len(merged)


def merge_npz(shard_paths: list[Path], out_path: Path) -> int:
    import numpy as np

    ids_parts: list = []
    vecs_parts: list = []
    seen: set = set()
    for p in shard_paths:
        z = np.load(p)
        ids = z["ids"]
        overlap = set(int(x) for x in ids) & seen
        if overlap:
            raise ValueError(f"{p} has {len(overlap)} id(s) already present in an earlier shard "
                              f"(shards should be disjoint) -- first few: {sorted(overlap)[:5]}")
        seen.update(int(x) for x in ids)
        ids_parts.append(ids)
        vecs_parts.append(z["vecs"])
    out_path.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(out_path, ids=np.concatenate(ids_parts), vecs=np.concatenate(vecs_parts))
    return len(seen)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--format", choices=["csv", "json", "npz"], required=True)
    ap.add_argument("--shards", nargs="+", type=Path, help="explicit list of shard files")
    ap.add_argument("--shard-glob", help="glob pattern matching shard files, as an alternative to --shards "
                                          "(e.g. for a shard count only known at execution time)")
    ap.add_argument("--expected-count", type=int, help="required with --shard-glob: fail if the glob "
                                                         "matches fewer files than this")
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()

    if bool(args.shards) == bool(args.shard_glob):
        raise SystemExit("pass exactly one of --shards or --shard-glob")

    if args.shard_glob:
        if not args.expected_count:
            raise SystemExit("--shard-glob requires --expected-count")
        shard_paths = sorted(Path(p) for p in glob.glob(args.shard_glob))
        if len(shard_paths) != args.expected_count:
            raise SystemExit(f"--shard-glob {args.shard_glob!r} matched {len(shard_paths)} file(s), "
                              f"expected {args.expected_count} -- refusing to merge a partial result")
    else:
        shard_paths = args.shards
        missing = [p for p in shard_paths if not p.exists()]
        if missing:
            raise SystemExit(f"missing shard file(s), refusing to merge a partial result: {missing}")

    if args.format == "csv":
        n = merge_csv(shard_paths, args.out)
    elif args.format == "json":
        n = merge_json(shard_paths, args.out)
    else:
        n = merge_npz(shard_paths, args.out)

    print(f"wrote {args.out} ({n} rows/ids from {len(shard_paths)} shards)")


if __name__ == "__main__":
    main()
