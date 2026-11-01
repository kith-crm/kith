"""Validate identity observed after the real packaged Kith endpoint."""

import json
from pathlib import Path
import sys

path, expected_client, expected_peer, expected_status = sys.argv[1:]
lines = Path(path).read_text().splitlines()
status = next(int(line.strip().split()[1]) for line in lines if line.strip().startswith("HTTP/"))
headers = {}
for line in lines:
    name, separator, value = line.strip().partition(":")
    if separator:
        headers[name.lower()] = value.strip()

assert status == int(expected_status), (path, status, expected_status)
assert headers["x-pr44-verified-client"] == expected_client, (path, headers)
assert headers["x-pr44-socket-peer"] == expected_peer, (path, headers)
Path(path).with_suffix(".json").write_text(
    json.dumps({"probe": Path(path).stem, "client": expected_client, "peer": expected_peer, "status": status}) + "\n"
)
