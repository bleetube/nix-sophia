#!/usr/bin/env python3
"""Bump the Sophia NLU pins in pkgs/sources.json.

The engine binary comes from the private Forgejo repo behind the HA OS add-on
(git.cicero.sh/aquila/sophia-ha-app, default branch HEAD); the integration
comes from public GitHub tags (cicero-ai/sophia-ha-integration). Credentials
for git.cicero.sh come from the netrc that nix.conf's netrc-file points at
(or --netrc), holding your Sophia download token.
"""

import argparse
import base64
import json
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[4]
SOURCES = REPO_ROOT / "pkgs/sources.json"
NETRC_HOST = "git.cicero.sh"
APP_API = f"https://{NETRC_HOST}/api/v1/repos/aquila/sophia-ha-app"
INTEGRATION_REPO = "cicero-ai/sophia-ha-integration"


def nix_netrc_path() -> Path:
    out = subprocess.run(
        ["nix", "config", "show", "netrc-file"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    if not out:
        sys.exit("nix.conf sets no netrc-file; pass --netrc")
    return Path(out)


def netrc_auth(path: Path) -> str:
    """Return a Basic auth header value for NETRC_HOST from a netrc file."""
    try:
        tokens = path.read_text().split()
    except OSError as err:
        sys.exit(f"cannot read netrc {path}: {err}")
    fields: dict[str, str] = {}
    machine = None
    it = iter(tokens)
    for tok in it:
        if tok == "machine":
            machine = next(it, None)
        elif tok in ("login", "password") and machine == NETRC_HOST:
            fields[tok] = next(it, "")
    if "login" not in fields or "password" not in fields:
        sys.exit(f"no {NETRC_HOST} entry in {path}")
    cred = f"{fields['login']}:{fields['password']}".encode()
    return "Basic " + base64.b64encode(cred).decode()


def get(url: str, auth: str | None = None) -> bytes:
    headers = {"Accept": "application/json"}
    if auth:
        headers["Authorization"] = auth
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read()


def app_raw_url(path: str, rev: str) -> str:
    return f"{APP_API}/raw/{path}?ref={rev}"


def latest_app(auth: str) -> tuple[str, str]:
    """Return (rev, version) of the add-on repo's default branch."""
    commits = json.loads(
        get(f"{APP_API}/commits?limit=1&stat=false&verification=false&files=false", auth)
    )
    rev = commits[0]["sha"]
    config = get(app_raw_url("sophia_nlu/config.yaml", rev), auth).decode()
    m = re.search(r'^version:\s*"?([^"\s]+)"?', config, re.MULTILINE)
    if not m:
        sys.exit(f"no version in sophia_nlu/config.yaml at {rev}")
    return rev, m.group(1)


def version_key(v: str) -> tuple[int, ...]:
    return tuple(int(p) for p in re.findall(r"\d+", v))


def latest_integration() -> str:
    tags = json.loads(get(f"https://api.github.com/repos/{INTEGRATION_REPO}/tags"))
    return max((t["name"] for t in tags), key=version_key)


def prefetch_file(url: str, netrc: Path) -> str:
    out = subprocess.run(
        ["nix", "store", "prefetch-file", "--json", "--option", "netrc-file", str(netrc), url],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return json.loads(out)["hash"]


def prefetch_github(tag: str) -> str:
    out = subprocess.run(
        ["nix", "flake", "prefetch", "--json", f"github:{INTEGRATION_REPO}/{tag}"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return json.loads(out)["hash"]


def new_changelog(auth: str, rev: str, since: str) -> str:
    """Return CHANGELOG.md sections newer than `since`."""
    text = get(app_raw_url("sophia_nlu/CHANGELOG.md", rev), auth).decode()
    sections = re.split(r"^(?=## )", text, flags=re.MULTILINE)
    keep = []
    for sec in sections:
        m = re.match(r"## +(\S+)", sec)
        if m and version_key(m.group(1)) > version_key(since):
            keep.append(sec.strip())
    return "\n\n".join(keep)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true", help="report versions without writing")
    ap.add_argument("--netrc", type=Path, help="netrc file (default: nix.conf netrc-file)")
    args = ap.parse_args()

    netrc = args.netrc or nix_netrc_path()
    auth = netrc_auth(netrc)
    sources = json.loads(SOURCES.read_text())
    app, integ = sources["engine"], sources["integration"]

    rev, version = latest_app(auth)
    tag = latest_integration()
    app_new = rev != app["rev"]
    integ_new = tag != integ["version"]
    print(f"engine:      pinned {app['version']} ({app['rev'][:7]}), latest {version} ({rev[:7]})")
    print(f"integration: pinned {integ['version']}, latest {tag}")

    if app_new:
        changes = new_changelog(auth, rev, app["version"])
        if changes:
            print("\n" + changes + "\n")
    if args.check or not (app_new or integ_new):
        if not (app_new or integ_new):
            print("up to date")
        return

    if app_new:
        url = app_raw_url("sophia_nlu/sophia-amd64", rev)
        app.update(version=version, rev=rev, hash=prefetch_file(url, netrc))
    if integ_new:
        integ.update(version=tag, hash=prefetch_github(tag))
    SOURCES.write_text(json.dumps(sources, indent=2) + "\n")
    print(f"updated {SOURCES.relative_to(REPO_ROOT)}")


if __name__ == "__main__":
    main()
