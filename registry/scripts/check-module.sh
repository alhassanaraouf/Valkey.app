#!/bin/bash
# Verifies a Valkey module works with one Valkey build: the server must start with the module and
# answer within 10s (an incompatible module can hang startup), module commands must return the
# expected results, and module data must survive a save + restart.
# WITH_MODULE: another module to load first (search also checks indexing JSON when it is the json module).
#
#   registry/scripts/check-module.sh <json|bloom|search> <module.dylib> <valkey-bin-dir>
set -uo pipefail
NAME="${1:?usage: $0 <json|bloom|search> <module.dylib> <valkey-bin-dir>}"
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
# Like expect, for results that show up asynchronously (search indexes in background threads).
eventually() {
    local want="$1"; shift; local got
    for _ in $(seq 20); do got="$(cli "$@")"; [ "$got" = "$want" ] && return; sleep 0.25; done
    fail "$* → '$got', expected '$want'"
}

start() {
    "$BIN/valkey-server" --port "$PORT" --bind 127.0.0.1 --dir "$DIR" --daemonize no \
        ${WITH_MODULE:+--loadmodule "$WITH_MODULE"} --loadmodule "$MODULE" > "$DIR/server.log" 2>&1 &
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
module_name=$(case "$NAME" in bloom) echo bf ;; *) echo "$NAME" ;; esac)
cli MODULE LIST | grep -qx "$module_name" || fail "MODULE LIST doesn't list $module_name"
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
    expect 1 BF.INFO filter ITEMS
    stop; start
    expect 1 BF.EXISTS filter valkey
    expect 1 BF.INFO filter ITEMS ;;
search)
    # Vectors are FLOAT32 blobs; "AAAA" is the float 12.08 and "CCCC" 195.3, which keeps them printable.
    expect OK FT.CREATE idx ON HASH PREFIX 1 doc: SCHEMA title TEXT tag TAG \
        vec VECTOR HNSW 6 TYPE FLOAT32 DIM 2 DISTANCE_METRIC L2
    expect 3 HSET doc:1 title "hello valkey" tag fast vec AAAAAAAA
    expect 3 HSET doc:2 title "goodbye world" tag slow vec CCCCCCCC
    eventually $'1\ndoc:1\ntitle\nhello valkey' FT.SEARCH idx '*=>[KNN 1 @vec $v]' PARAMS 2 v AAAAAAAA RETURN 1 title DIALECT 2
    expect $'1\ndoc:1\ntitle\nhello valkey' FT.SEARCH idx '@title:hello' RETURN 1 title
    expect $'1\ndoc:2\ntitle\ngoodbye world' FT.SEARCH idx '@tag:{slow}' RETURN 1 title
    cli FT.INFO idx | grep -A1 -x num_docs | grep -qx 2 || fail "FT.INFO idx: num_docs isn't 2"
    if [[ "${WITH_MODULE:-}" == *json* ]]; then
        expect OK JSON.SET j:1 '$' '{"name":"alpha","vec":[12,12]}'
        expect OK JSON.SET j:2 '$' '{"name":"beta","vec":[100,100]}'
        expect OK FT.CREATE jidx ON JSON PREFIX 1 j: SCHEMA '$.name' AS name TEXT \
            '$.vec' AS vec VECTOR FLAT 6 TYPE FLOAT32 DIM 2 DISTANCE_METRIC L2
        eventually $'1\nj:1\nname\nalpha' FT.SEARCH jidx '*=>[KNN 1 @vec $v]' PARAMS 2 v AAAAAAAA RETURN 1 name DIALECT 2
        eventually $'1\nj:2\nname\nbeta' FT.SEARCH jidx '@name:beta' RETURN 1 name
    fi
    stop; start
    eventually $'1\ndoc:1\ntitle\nhello valkey' FT.SEARCH idx '*=>[KNN 1 @vec $v]' PARAMS 2 v AAAAAAAA RETURN 1 title DIALECT 2
    expect $'1\ndoc:1\ntitle\nhello valkey' FT.SEARCH idx '@title:hello' RETURN 1 title
    if [[ "${WITH_MODULE:-}" == *json* ]]; then
        eventually $'1\nj:1\nname\nalpha' FT.SEARCH jidx '*=>[KNN 1 @vec $v]' PARAMS 2 v AAAAAAAA RETURN 1 name DIALECT 2
        expect OK FT.DROPINDEX jidx
    fi
    expect OK FT.DROPINDEX idx
    expect '' FT._LIST ;;
*)
    fail "unknown module $NAME" ;;
esac
stop
echo "ok: $NAME works with $("$BIN/valkey-server" --version | grep -o 'v=[0-9.]*')"
