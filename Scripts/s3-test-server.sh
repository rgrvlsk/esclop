#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# A local S3 server for the upload tests: moto (pinned, in a virtual environment under the build
# directory) with authentication on, so a request signed with the wrong secret is refused
# (SignatureDoesNotMatch) as a real service would. No account and no network beyond installing
# moto once.
#
#   Scripts/s3-test-server.sh start   starts it on a free port on 127.0.0.1 and prints one JSON
#                                     line: endpoint, bucket, accessKeyID, secret (throwaway), pid.
#                                     With ESCLOP_S3_OWNER=PID it stops when that process ends
#                                     (the test run that shares one server across its tests).
#   Scripts/s3-test-server.sh stop PID
#   Scripts/s3-test-server.sh install installs moto only (CI does it before the tests)
#
# Needs python3. The keys are made by the server for this run and mean nothing anywhere else.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOTO_VERSION=5.2.5
VENV="${ESCLOP_SCRATCH_PATH:-$ROOT/.build}/s3-test-moto-$MOTO_VERSION"

install() {
  [ -x "$VENV/bin/moto_server" ] && return 0
  # One installer at a time: tests may start servers side by side.
  local lock="$VENV.lock"
  mkdir -p "$(dirname "$VENV")"
  until mkdir "$lock" 2>/dev/null; do sleep 0.5; done
  trap 'rmdir "$lock" 2>/dev/null || true' EXIT
  if [ ! -x "$VENV/bin/moto_server" ]; then
    rm -rf "$VENV"
    python3 -m venv "$VENV" >&2
    "$VENV/bin/pip" install --quiet --disable-pip-version-check "moto[server]==$MOTO_VERSION" >&2
  fi
  rmdir "$lock" 2>/dev/null || true
  trap - EXIT
}

case "${1:-}" in
  stop)
    kill "${2:?usage: Scripts/s3-test-server.sh stop PID}" 2>/dev/null || true
    exit 0
    ;;
  install) install; exit 0 ;;
  start) install ;;
  *) echo "usage: Scripts/s3-test-server.sh start|stop PID|install" >&2; exit 2 ;;
esac
port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
log="$(mktemp "${TMPDIR:-/tmp}/s3-test-server.XXXXXX")"
# The first three requests (make a user, give it a key and a policy) need no signature; every
# request after them is checked.
INITIAL_NO_AUTH_ACTION_COUNT=3 nohup "$VENV/bin/moto_server" -H 127.0.0.1 -p "$port" > "$log" 2>&1 &
pid=$!
if [ -n "${ESCLOP_S3_OWNER:-}" ]; then
  owner=$ESCLOP_S3_OWNER
  nohup bash -c "while kill -0 $owner 2>/dev/null && kill -0 $pid 2>/dev/null; do sleep 1; done; kill $pid 2>/dev/null" > /dev/null 2>&1 &
fi
for _ in $(seq 1 300); do
  curl -fs -o /dev/null "http://127.0.0.1:$port/moto-api/" 2>/dev/null && break
  kill -0 "$pid" 2>/dev/null || { cat "$log" >&2; exit 1; }
  sleep 0.1
done
"$VENV/bin/python" - "$port" "$pid" <<'PY'
import boto3, json, sys
port, pid = sys.argv[1], int(sys.argv[2])
endpoint = f"http://127.0.0.1:{port}"
iam = boto3.client("iam", endpoint_url=endpoint, region_name="us-east-1", aws_access_key_id="setup", aws_secret_access_key="setup")
iam.create_user(UserName="esclop-tests")
key = iam.create_access_key(UserName="esclop-tests")["AccessKey"]
iam.put_user_policy(UserName="esclop-tests", PolicyName="all", PolicyDocument=json.dumps(
    {"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Action": "*", "Resource": "*"}]}))
s3 = boto3.client("s3", endpoint_url=endpoint, region_name="us-east-1",
                  aws_access_key_id=key["AccessKeyId"], aws_secret_access_key=key["SecretAccessKey"])
s3.create_bucket(Bucket="esclop-tests")
print(json.dumps({"endpoint": endpoint, "bucket": "esclop-tests", "accessKeyID": key["AccessKeyId"],
                  "secret": key["SecretAccessKey"], "pid": pid}))
PY
