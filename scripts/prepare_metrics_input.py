#!/usr/bin/env python3
"""Adapts poster-corpus-validation's final output (validated_corpus.csv,
from 10_validate_corpus.py) into the --in schema every poster-metrics-
pipeline script expects: id,title,year,poster_path.

This glue lives here, not in either pipeline repo, on purpose: the two
repos' schemas are a near-exact match already (both have id/title/
poster_path verbatim) -- the only gap is validated_corpus.csv's
release_date (e.g. "2004-08-01") where metrics-pipeline wants a plain
year column. That's a one-line derivation, not a real transformation, and
it's specific to this orchestration design connecting the two repos --
neither repo has a reason to know about the other's column names on its
own, so this adapter is where that assumption belongs, not baked into
either pipeline's own scripts.

  python3 prepare_metrics_input.py --in data/sample_output/validated_corpus.csv --out data/sample_output/metrics_input.csv

Rows with no release_date (a handful of TMDB entries genuinely have none)
are dropped, not given a placeholder year -- every poster-metrics-pipeline
script merges on year for its --validate mode's title+year lookups, so a
fabricated year would silently break that, not just leave a metric blank.
"""
from __future__ import annotations

import argparse
import csv
from pathlib import Path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="in_path", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    in_path = Path(args.in_path)
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    n_in = n_out = n_no_date = n_no_poster = 0
    with in_path.open(newline="", encoding="utf-8") as f_in, \
         out_path.open("w", newline="", encoding="utf-8") as f_out:
        reader = csv.DictReader(f_in)
        writer = csv.DictWriter(f_out, fieldnames=["id", "title", "year", "poster_path"])
        writer.writeheader()
        for row in reader:
            n_in += 1
            release_date = (row.get("release_date") or "").strip()
            poster_path = (row.get("poster_path") or "").strip()
            if not release_date:
                n_no_date += 1
                continue
            if not poster_path:
                n_no_poster += 1
                continue
            writer.writerow({
                "id": row["id"],
                "title": row["title"],
                "year": release_date[:4],
                "poster_path": poster_path,
            })
            n_out += 1

    print(f"wrote {out_path}: {n_out}/{n_in} rows "
          f"({n_no_date} dropped for no release_date, {n_no_poster} for no poster_path)")


if __name__ == "__main__":
    main()
