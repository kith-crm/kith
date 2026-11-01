"""Tiny Monica API helper."""
import json
import os
import urllib.error
import urllib.request

TOK = os.environ["MONICA_API_KEY"]
BASE = os.environ.get("MONICA_URL", "http://localhost:8089") + "/api"


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        BASE + path,
        data=data,
        method=method,
        headers={
            "Authorization": "Bearer " + TOK,
            "Accept": "application/json",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        raise SystemExit(f"{method} {path} -> {e.code}: {e.read().decode()[:500]}")


def get(path):
    return call("GET", path)


def post(path, body):
    return call("POST", path, body)


def put(path, body):
    return call("PUT", path, body)


def paged(path, limit=100):
    """Yield every item of a paginated list endpoint."""
    sep = "&" if "?" in path else "?"
    page = 1
    while True:
        r = get(f"{path}{sep}limit={limit}&page={page}")
        yield from r["data"]
        if page >= r["meta"]["last_page"]:
            return
        page += 1
