#!/usr/bin/env bash
# Pushes the runtime half of backend/.env into one SSM SecureString parameter.
#
#   make aws-secrets
#
# One parameter holding a JSON map, not one per value: the deployed box wants the whole
# environment in a single call at boot. Standard tier is free and holds 4 KB.
#
# Values are never printed. Only key names are echoed.

set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROFILE=${AWS_PROFILE_NAME:-personal}
REGION=${AWS_REGION_NAME:-ap-southeast-2}
PARAMETER_NAME=${PARAMETER_NAME:-/nandex/app-env}

[ -f backend/.env ] || { echo "error: backend/.env is missing." >&2; exit 1; }

python3 - "$PARAMETER_NAME" "$PROFILE" "$REGION" <<'PY'
import json, re, subprocess, sys
from pathlib import Path

parameter_name, profile, region = sys.argv[1:4]

# Excluded on purpose. These authenticate CI to GitHub, Terraform, Render and Netlify;
# nothing running in a container needs them, and a runtime secret that carries them
# turns a container compromise into a supply-chain one.
CI_ONLY = {"TF_API_TOKEN", "RENDER_API_KEY", "NETLIFY_API_TOKEN", "NETLIFY_TOKEN"}

# Recording is off and vas is not deployed, so its credentials are not runtime config.
def excluded(key: str) -> bool:
    return key in CI_ONLY or key.startswith("VAS_")

env = {}
for line in Path("backend/.env").read_text().splitlines():
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    k, v = line.split("=", 1)
    k, v = k.strip(), v.strip()
    if not v or excluded(k):
        continue
    env[k] = v

payload = json.dumps(env, sort_keys=True, separators=(",", ":"))
if len(payload.encode()) > 4096:
    sys.exit(f"{len(payload.encode())} bytes is over the 4 KB standard-tier limit")

def aws(*args, stdin=None):
    return subprocess.run(
        ["aws", *args, "--profile", profile, "--region", region],
        input=stdin, capture_output=True, text=True,
    )

r = aws("ssm", "put-parameter", "--name", parameter_name, "--type", "SecureString",
        "--tier", "Standard", "--overwrite", "--value", payload)

if r.returncode != 0:
    sys.exit(f"failed: {r.stderr.strip()[:300]}")

print(f"wrote {parameter_name} with {len(env)} keys ({len(payload.encode())} bytes):")
for k in sorted(env):
    print("   ", k)
PY
