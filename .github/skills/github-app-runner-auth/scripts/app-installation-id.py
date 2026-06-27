#!/usr/bin/env python3
"""Derive a GitHub App installation ID from the App ID + private key.

Builds a short-lived RS256 JWT signed with the App's private key, then calls
GET /app/installations to list installations. Prints the installation id (and
account login). Optionally filter to the installation that can access --repo.

Uses PyJWT if available, else falls back to `cryptography` (same approach as
docs/16 section 3). The private key is never printed.

Usage:
  app-installation-id.py --app-id ID --private-key PATH [--repo owner/repo]
                         [--quiet]   # print only the id
Exit status: 0 on success, 1 on error (no installation / auth failure).
"""
import argparse
import base64
import json
import sys
import time
import urllib.request
import urllib.error

API = "https://api.github.com"


def make_jwt(app_id, pem_bytes):
    now = int(time.time())
    payload = {"iat": now - 60, "exp": now + 540, "iss": str(app_id)}
    try:
        import jwt  # PyJWT
        tok = jwt.encode(payload, pem_bytes, algorithm="RS256")
        return tok.decode() if isinstance(tok, bytes) else tok
    except ImportError:
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import padding

        def b64(x):
            return base64.urlsafe_b64encode(x).rstrip(b"=")

        header = {"alg": "RS256", "typ": "JWT"}
        seg = b64(json.dumps(header).encode()) + b"." + b64(json.dumps(payload).encode())
        key = serialization.load_pem_private_key(pem_bytes, None)
        sig = key.sign(seg, padding.PKCS1v15(), hashes.SHA256())
        return (seg + b"." + b64(sig)).decode()


def api_get(path, token):
    scheme = "Bearer"
    req = urllib.request.Request(
        API + path,
        headers={
            "Authorization": scheme + " " + token,
            "Accept": "application/vnd.github+json",
            "User-Agent": "github-app-runner-auth",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)


def main():
    ap = argparse.ArgumentParser(description="Derive a GitHub App installation ID.")
    ap.add_argument("--app-id", required=True)
    ap.add_argument("--private-key", required=True)
    ap.add_argument("--repo", help="owner/repo to match the installation account/owner")
    ap.add_argument("--quiet", action="store_true", help="print only the installation id")
    args = ap.parse_args()

    try:
        with open(args.private_key, "rb") as fh:
            pem = fh.read()
    except OSError as e:
        sys.stderr.write(f"ERROR: cannot read private key: {e}\n")
        sys.exit(1)

    try:
        token = make_jwt(args.app_id, pem)
    except Exception as e:  # noqa: BLE001
        sys.stderr.write(f"ERROR: could not build the App JWT: {e}\n")
        sys.exit(1)

    try:
        installs = api_get("/app/installations", token)
    except urllib.error.HTTPError as e:
        sys.stderr.write(f"ERROR: /app/installations failed: HTTP {e.code} {e.reason}\n")
        sys.stderr.write("       Check the App ID and that the private key matches the App.\n")
        sys.exit(1)

    if not installs:
        sys.stderr.write("ERROR: the App has no installations (install it on the repo/org).\n")
        sys.exit(1)

    chosen = None
    owner = args.repo.split("/")[0].lower() if args.repo else None
    for inst in installs:
        login = (inst.get("account") or {}).get("login", "")
        if owner is None or login.lower() == owner:
            chosen = inst
            break
    if chosen is None:
        sys.stderr.write(f"ERROR: no installation matches owner '{owner}'.\n")
        for inst in installs:
            sys.stderr.write(f"  available: id={inst['id']} account={(inst.get('account') or {}).get('login')}\n")
        sys.exit(1)

    if args.quiet:
        print(chosen["id"])
    else:
        print(f"installation_id={chosen['id']} account={(chosen.get('account') or {}).get('login')}")


if __name__ == "__main__":
    main()
