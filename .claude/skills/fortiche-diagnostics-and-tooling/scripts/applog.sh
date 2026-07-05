#!/bin/bash
# applog.sh — tail or dump Fortiche's os_log output on a simulator, with the
# --level/--info traps handled for you.
#
# Why this exists: Logger.info lines are INVISIBLE by default.
#   * `log stream` shows them only with `--level info`
#   * `log show`   shows them only with `--info`
# Forgetting the flag makes a working app look silent. (docs/SPIKE-M1.5.md)
#
# Usage:
#   applog.sh                          # stream phone-app logs from the booted sim
#   applog.sh -m show -l 10m           # dump the last 10 minutes instead of streaming
#   applog.sh -u <UDID>                # pick a device (needed when >1 sim is booted)
#   applog.sh -s com.davidruiz.fortiche.watch   # watch-app subsystem
#   applog.sh -c connectivity          # filter to one Logger category
#   applog.sh -s '' -P healthd         # no subsystem filter; filter by process instead
#
# Subsystems in this repo (grep 'Logger(subsystem' to re-verify):
#   com.davidruiz.fortiche        (iOS app + FortichePack when linked into it)
#   com.davidruiz.fortiche.watch  (watch app)
# Categories: workout, mirroring, intents, connectivity, demo.
set -euo pipefail

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app}"
export DEVELOPER_DIR

UDID="booted"
SUBSYSTEM="com.davidruiz.fortiche"
CATEGORY=""
PROCESS=""
MODE="stream"
LAST="5m"

usage() { sed -n '2,20p' "$0"; exit 1; }

while getopts "u:s:c:P:m:l:h" opt; do
  case "$opt" in
    u) UDID="$OPTARG" ;;
    s) SUBSYSTEM="$OPTARG" ;;
    c) CATEGORY="$OPTARG" ;;
    P) PROCESS="$OPTARG" ;;
    m) MODE="$OPTARG" ;;
    l) LAST="$OPTARG" ;;
    h|*) usage ;;
  esac
done

# Build the predicate from whichever filters were given.
CLAUSES=()
[[ -n "$SUBSYSTEM" ]] && CLAUSES+=("subsystem == \"$SUBSYSTEM\"")
[[ -n "$CATEGORY"  ]] && CLAUSES+=("category == \"$CATEGORY\"")
[[ -n "$PROCESS"   ]] && CLAUSES+=("process == \"$PROCESS\"")
if [[ ${#CLAUSES[@]} -eq 0 ]]; then
  echo "error: need at least one of -s/-c/-P (an unfiltered stream is unusable)" >&2
  exit 1
fi
PREDICATE=$(IFS=$'\n'; printf '%s AND ' "${CLAUSES[@]}")
PREDICATE="${PREDICATE% AND }"

echo "# device=$UDID predicate: $PREDICATE" >&2

case "$MODE" in
  stream)
    # --level info is the trap: without it Logger.info never appears.
    exec xcrun simctl spawn "$UDID" log stream --level info --style compact \
      --predicate "$PREDICATE"
    ;;
  show)
    # --info is the equivalent trap for `log show`.
    exec xcrun simctl spawn "$UDID" log show --last "$LAST" --info --style compact \
      --predicate "$PREDICATE"
    ;;
  *)
    echo "error: -m must be 'stream' or 'show'" >&2; exit 1 ;;
esac
