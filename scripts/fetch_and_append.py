#!/usr/bin/env python3
"""Downloads an S3 object and appends its raw bytes to a local file.

Used by the state machine's AppendKnownIds step to append known,
human-labeled test ids onto whatever Enumerate's fresh TMDB sample
produced -- avoids fragile nested shell/Python quoting for a one-line
S3-fetch-and-append that boto3 (already in the image) can do directly.

  python3 fetch_and_append.py <bucket> <key> <dest_path>
"""
import sys

import boto3


def main() -> None:
    bucket, key, dest = sys.argv[1], sys.argv[2], sys.argv[3]
    body = boto3.client("s3").get_object(Bucket=bucket, Key=key)["Body"].read()
    with open(dest, "ab") as f:
        f.write(body)


if __name__ == "__main__":
    main()
