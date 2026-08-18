#!/usr/bin/env python3
"""Downloads an S3 object to a local path, overwriting whatever's there.

Different from fetch_and_append.py (which appends, for the
AppendKnownIds test step): this is for static reference data -- e.g.
gate 2's pre-filtered adult_tconsts list -- that should be refreshed
in full on every run, not accumulated onto across reruns of the same
EFS-persisted path.

  python3 fetch_object.py <bucket> <key> <dest_path>
"""
import sys

import boto3


def main() -> None:
    bucket, key, dest = sys.argv[1], sys.argv[2], sys.argv[3]
    body = boto3.client("s3").get_object(Bucket=bucket, Key=key)["Body"].read()
    with open(dest, "wb") as f:
        f.write(body)


if __name__ == "__main__":
    main()
