#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export CSFX_START_COMMAND="node build" CSFX_INSTALL_COMMAND="npm ci" CSFX_BUILD_COMMAND="npm run build"
export CSFX_BUILD_ENV='{"API_URL":"https://api.test"}' CSFX_CONTAINER_PORT=3000
export CSFX_IMAGE_REF="sites.csfx.invalid/site-1:abcd1234"
export CSFX_CALLBACK_TOKEN=x CSFX_DEPLOYMENT_ID=d CSFX_CALLBACK_URL=http://localhost

# shellcheck source=../entrypoint.sh
source "$ROOT/entrypoint.sh"
LOG_FILE=$WORK/log OFFSET_FILE=$WORK/offset
PROJECT_DIR=$WORK/project
mkdir -p "$PROJECT_DIR"
touch "$PROJECT_DIR/package.json" "$PROJECT_DIR/package-lock.json" "$PROJECT_DIR/index.js"

fail_test() {
    echo "FAIL: $1" >&2
    exit 1
}

line_of() {
    grep -n -m1 -- "$2" "$1" | cut -d: -f1
}

node_dockerfile || fail_test "node_dockerfile rejected a buildable project"
layered="$PROJECT_DIR/$LAYERED_DOCKERFILE"
full="$PROJECT_DIR/$FULL_COPY_DOCKERFILE"

grep -q '^COPY package.json package-lock.json \./$' "$layered" || fail_test "manifests are not copied on their own"
! grep -q 'index.js' "$layered" || fail_test "source leaked into the manifest layer"
[ "$(line_of "$layered" '^COPY package.json')" -lt "$(line_of "$layered" '^RUN corepack enable')" ] || fail_test "manifests must precede install"
[ "$(line_of "$layered" '^RUN corepack enable')" -lt "$(line_of "$layered" '^COPY \. \.$')" ] || fail_test "install must precede the source copy"
[ "$(line_of "$layered" '^COPY \. \.$')" -lt "$(line_of "$layered" '^RUN npm run build')" ] || fail_test "source copy must precede build"
[ "$(line_of "$full" '^COPY \. \.$')" -lt "$(line_of "$full" '^RUN corepack enable')" ] || fail_test "fallback must copy the source first"
grep -q '^ARG API_URL$' "$layered" || fail_test "build environment is missing"

collect_kaniko_arguments
joined=" ${KANIKO_ARGS[*]} "
for expected in "--cache=true" "--cache-repo sites.csfx.invalid/site-1" "--snapshot-mode=redo"; do
    [[ "$joined" == *" $expected "* || "$joined" == *" $expected"* ]] || fail_test "kaniko argument $expected missing"
done
[[ "$joined" != *"site-1:abcd1234"* ]] || fail_test "cache repository must not carry the image tag"

if [[ "$(date +%s%3N)" =~ ^[0-9]+$ ]]; then
    PHASES_FILE=$WORK/phases
    : >"$PHASES_FILE"
    timed clone_ms sleep 0.05
    timed install_ms true
    phases=$(phases_json)
    [ "$(jq -r '.clone_ms >= 50' <<<"$phases")" = "true" ] || fail_test "clone phase was not measured"
    [ "$(jq -r 'has("install_ms")' <<<"$phases")" = "true" ] || fail_test "install phase is missing"
    timed build_ms false && fail_test "timed must keep the exit status"
    [ "$(jq -r 'has("build_ms")' <<<"$(phases_json)")" = "true" ] || fail_test "failed phases must still be measured"

else
    echo "skip: phase timing needs GNU date"
fi

echo "ok"
