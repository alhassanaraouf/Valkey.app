#!/bin/bash
# Verifies a Valkey module works with one Valkey build: the server must start with the module and
# answer within 10s (an incompatible module can hang startup), module commands must return the
# expected results, and module data must survive a save + restart.
#
#   registry/scripts/check-module.sh <json|bloom> <module.dylib> <valkey-bin-dir>
set -uo pipefail
NAME="${1:?usage: $0 <json|bloom> <module.dylib> <valkey-bin-dir>}"
MODULE="${2:?module path}"
BIN="${3:?valkey bin dir}"
PORT=$((20000 + RANDOM % 20000))
DIR="$(mktemp -d)"
SERVER_PID=
cleanup() { [ -n "$SERVER_PID" ] && kill -9 "$SERVER_PID" 2>/dev/null; rm -rf "$DIR"; }
trap cleanup EXIT

cli() { "$BIN/valkey-cli" -p "$PORT" "$@" 2>&1; }
fail() { echo "FAIL ($NAME on $("$BIN/valkey-server" --version | grep -o 'v=[0-9.]*')): $*"; tail -5 "$DIR/server.log" 2>/dev/null; exit 1; }
expect() { local want="$1"; shift; local got; got="$(cli "$@")"; [ "$got" = "$want" ] || fail "$* → '$got', expected '$want'"; }

start() {
    "$BIN/valkey-server" --port "$PORT" --bind 127.0.0.1 --dir "$DIR" --daemonize no \
        --loadmodule "$MODULE" > "$DIR/server.log" 2>&1 &
    SERVER_PID=$!
    for _ in $(seq 40); do
        [ "$(cli ping)" = PONG ] && return
        kill -0 "$SERVER_PID" 2>/dev/null || fail "server exited at startup"
        sleep 0.25
    done
    fail "server didn't answer within 10s (module hung at load?)"
}
stop() { cli shutdown save >/dev/null; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=; }

start
case "$NAME" in
json)
    expect OK JSON.SET doc '$' '{"tags":["fast","open"],"n":1}'
    expect '[42]' JSON.NUMINCRBY doc '$.n' 41
    expect '["open"]' JSON.GET doc '$.tags[1]'
    stop; start
    expect '[42]' JSON.GET doc '$.n' ;;
bloom)
    expect 1 BF.ADD filter valkey
    expect 1 BF.EXISTS filter valkey
    expect 0 BF.EXISTS filter redis
    stop; start
    expect 1 BF.EXISTS filter valkey ;;
*)
    fail "unknown module $NAME" ;;
esac
stop
echo "ok: $NAME works with $("$BIN/valkey-server" --version | grep -o 'v=[0-9.]*')"
