#!/usr/bin/env bash
#
# app-token.sh — prove the GitHub App auth chain for runners.
#
# Derives the installation ID (unless given), mints an installation access token,
# and — given --repo — mints a runner registration-token with it. This proves the
# App can authorize runner registration (what ARC and self-hosted runners need).
#
# Usage:
#   app-token.sh --app-id ID --private-key PATH [options]
# Options:
#   --installation-id N   installation id (default: derive via app-installation-id.py)
#   --repo owner/repo     also mint a runner registration-token for this repo
#   --print               print the token values (default: report success only)
#   --help
# The private key and token values are never echoed unless you pass --print.

set -uo pipefail

APP_ID=""; PRIVATE_KEY=""; INSTALL_ID=""; REPO=""; PRINT="false"
HERE="$(cd "$(dirname "$0")" && pwd)"
IDSCRIPT="$HERE/app-installation-id.py"
API="https://api.github.com"

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --app-id) APP_ID="${2:?}"; shift 2;;
    --private-key) PRIVATE_KEY="${2:?}"; shift 2;;
    --installation-id) INSTALL_ID="${2:?}"; shift 2;;
    --repo) REPO="${2:?}"; shift 2;;
    --print) PRINT="true"; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 2;;
  esac
done

[ -n "$APP_ID" ] && [ -n "$PRIVATE_KEY" ] || { echo "ERROR: --app-id and --private-key required" >&2; usage; exit 2; }
[ -f "$PRIVATE_KEY" ] || { echo "ERROR: private key not found: $PRIVATE_KEY" >&2; exit 1; }
for b in python3 curl; do command -v "$b" >/dev/null 2>&1 || { echo "ERROR: '$b' not found" >&2; exit 1; }; done

# 1. Installation id.
if [ -z "$INSTALL_ID" ]; then
  echo ">>> Deriving installation id..."
  INSTALL_ID="$(python3 "$IDSCRIPT" --app-id "$APP_ID" --private-key "$PRIVATE_KEY" ${REPO:+--repo "$REPO"} --quiet)" \
    || { echo "ERROR: could not derive installation id" >&2; exit 1; }
fi
echo ">>> Installation id: $INSTALL_ID"

# 2. Build the App JWT (reuse the python signer) and mint an installation token.
APP_JWT="$(python3 - "$APP_ID" "$PRIVATE_KEY" <<'PY'
import sys, time, json, base64
app_id, pem_path = sys.argv[1], sys.argv[2]
pem = open(pem_path, "rb").read()
now = int(time.time())
payload = {"iat": now-60, "exp": now+540, "iss": str(app_id)}
try:
    import jwt
    t = jwt.encode(payload, pem, algorithm="RS256")
    print(t.decode() if isinstance(t, bytes) else t)
except ImportError:
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding
    b = lambda x: base64.urlsafe_b64encode(x).rstrip(b"=")
    seg = b(json.dumps({"alg":"RS256","typ":"JWT"}).encode()) + b"." + b(json.dumps(payload).encode())
    sig = serialization.load_pem_private_key(pem, None).sign(seg, padding.PKCS1v15(), hashes.SHA256())
    print((seg + b"." + b(sig)).decode())
PY
)"
[ -n "$APP_JWT" ] || { echo "ERROR: could not build App JWT" >&2; exit 1; }
AUTH_SCHEME=Bearer

INST_RESP="$(curl -sS -X POST \
  -H "Authorization: ${AUTH_SCHEME} ${APP_JWT}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "$API/app/installations/${INSTALL_ID}/access_tokens")"
INST_TOK="$(printf '%s' "$INST_RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))' 2>/dev/null)"
if [ -z "$INST_TOK" ]; then
  echo "ERROR: installation access token request failed:" >&2
  printf '%s\n' "$INST_RESP" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("  "+d.get("message",str(d)))' 2>/dev/null >&2 || true
  exit 1
fi
echo ">>> Minted an installation access token ✅"

# 3. Optionally mint a runner registration-token (proves runner authorization).
REG_TOK=""
if [ -n "$REPO" ]; then
  REG_RESP="$(curl -sS -X POST \
    -H "Authorization: ${AUTH_SCHEME} ${INST_TOK}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$API/repos/${REPO}/actions/runners/registration-token")"
  REG_TOK="$(printf '%s' "$REG_RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))' 2>/dev/null)"
  if [ -z "$REG_TOK" ]; then
    echo "ERROR: registration-token request failed (App needs Administration: read & write):" >&2
    printf '%s\n' "$REG_RESP" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("  "+d.get("message",str(d)))' 2>/dev/null >&2 || true
    exit 1
  fi
  echo ">>> Minted a runner registration-token for $REPO ✅ (App-auth chain verified)"
fi

if [ "$PRINT" = "true" ]; then
  echo "installation_token=${INST_TOK}"
  [ -n "$REG_TOK" ] && echo "registration_token=${REG_TOK}"
else
  echo ">>> (token values withheld; pass --print to display them)"
fi
