#!/bin/bash
# mirror-trace.sh — capture the live-sync conversation from BOTH paired
# simulators at once: healthd (HK mirroring transport), chronod (Live
# Activities), WatchConnectivity, and Fortiche's own subsystems.
#
# Modes:
#   show   (default) — dump the last N minutes from both devices to files,
#                      then scan for known-good/known-bad signatures.
#   stream            — live-tail both devices with [phone]/[watch] prefixes
#                      until Ctrl-C (no signature scan).
#
# Usage:
#   mirror-trace.sh                      # auto-discover the booted+booted pair
#   mirror-trace.sh -l 10m               # window for show mode (default 5m)
#   mirror-trace.sh -m stream            # live tail
#   mirror-trace.sh -p <PHONE_UDID> -w <WATCH_UDID>
#   mirror-trace.sh -o /path/outdir      # where show mode writes capture files
#
# Reminder (R2): HK mirroring does NOT work between paired sims — expect the
# kNotFoundErr signature there. That is the documented state, not a regression.
# The WC debug transport is what should be carrying live state in the sim.
set -uo pipefail

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app}"
export DEVELOPER_DIR

MODE="show"
LAST="5m"
PHONE=""
WATCH=""
OUTDIR="${TMPDIR:-/tmp}/mirror-trace.$$"

while getopts "m:l:p:w:o:h" opt; do
  case "$opt" in
    m) MODE="$OPTARG" ;;
    l) LAST="$OPTARG" ;;
    p) PHONE="$OPTARG" ;;
    w) WATCH="$OPTARG" ;;
    o) OUTDIR="$OPTARG" ;;
    h|*) grep '^#' "$0" | head -22; exit 1 ;;
  esac
done

# ------------------------------------------------------- pair discovery -----
if [[ -z "$PHONE" || -z "$WATCH" ]]; then
  read -r PHONE WATCH PAIRSTATE <<<"$(xcrun simctl list pairs -j | python3 -c '
import json,sys
d=json.load(sys.stdin)
for pid,p in d.get("pairs",{}).items():
    ph,w = p["phone"], p["watch"]
    if ph["state"]=="Booted" and w["state"]=="Booted":
        print(ph["udid"], w["udid"], p["state"].replace(" ","")); raise SystemExit
')"
  if [[ -z "${PHONE:-}" || -z "${WATCH:-}" ]]; then
    echo "error: no pair with BOTH devices booted. Boot one:" >&2
    echo "  xcrun simctl list pairs   # pick a pair, then simctl boot each UDID" >&2
    exit 1
  fi
  echo "# pair: phone=$PHONE watch=$WATCH state=${PAIRSTATE:-?}"
  if [[ "${PAIRSTATE:-}" != *connected* ]]; then
    echo "# WARNING: pair state is '${PAIRSTATE:-unknown}', not connected — WC will not deliver" >&2
  fi
fi

# Everything relevant to live sync, one predicate per side.
PHONE_PRED='process == "healthd" OR process == "chronod" OR subsystem == "com.apple.watchconnectivity" OR subsystem == "com.davidruiz.fortiche"'
WATCH_PRED='process == "healthd" OR subsystem == "com.apple.watchconnectivity" OR subsystem == "com.davidruiz.fortiche.watch"'

if [[ "$MODE" == "stream" ]]; then
  echo "# streaming both devices (Ctrl-C to stop)…"
  xcrun simctl spawn "$PHONE" log stream --level info --style compact --predicate "$PHONE_PRED" 2>/dev/null \
    | sed -u 's/^/[phone] /' &
  P1=$!
  xcrun simctl spawn "$WATCH" log stream --level info --style compact --predicate "$WATCH_PRED" 2>/dev/null \
    | sed -u 's/^/[watch] /' &
  P2=$!
  trap 'kill $P1 $P2 2>/dev/null' INT TERM
  wait
  exit 0
fi

# ------------------------------------------------------------- show mode ----
mkdir -p "$OUTDIR"
echo "# dumping last $LAST from both sides into $OUTDIR (this takes a minute)…"
xcrun simctl spawn "$PHONE" log show --last "$LAST" --info --style compact \
  --predicate "$PHONE_PRED" >"$OUTDIR/phone.log" 2>/dev/null
xcrun simctl spawn "$WATCH" log show --last "$LAST" --info --style compact \
  --predicate "$WATCH_PRED" >"$OUTDIR/watch.log" 2>/dev/null
echo "# phone: $(wc -l <"$OUTDIR/phone.log") lines   watch: $(wc -l <"$OUTDIR/watch.log") lines"

scan() {  # $1=file $2=label $3=pattern $4=meaning
  local n; n=$(grep -c -i -E "$3" "$1" 2>/dev/null || true)
  if [[ "${n:-0}" -gt 0 ]]; then
    printf '  [%s] %4d x  %s\n' "$2" "$n" "$4"
    grep -i -E -m 2 "$3" "$1" | sed 's/^/         > /'
  fi
}

echo
echo "== known-BAD signatures found (absence of all = clean window) =="
scan "$OUTDIR/watch.log" watch 'kNotFoundErr|rapport:rdid:PairedCompanion' \
  "Rapport companion link absent — HK mirroring cannot deliver (R2; EXPECTED on paired sims)"
scan "$OUTDIR/watch.log" watch 'Code=300|Remote device is unreachable' \
  "healthd gave up delivering mirrored data (R2; expected on sims, a real bug on devices)"
scan "$OUTDIR/phone.log" phone 'no metadata for.*Intent' \
  "chronod cannot resolve a Live Activity intent — run intent-doctor.sh (R1)"
scan "$OUTDIR/phone.log" phone 'shouldCancel: YES' \
  "WC silently cancelled a send during a reachability blip (R4) — resync on sessionReachabilityDidChange must cover it"
scan "$OUTDIR/watch.log" watch 'shouldCancel: YES' \
  "WC silently cancelled a send during a reachability blip (R4)"
scan "$OUTDIR/phone.log" phone 'Failed to resolve package data|EINVAL' \
  "linkd audit failure — package-hosted intents or debug-dylib stub (R1)"

echo
echo "== app-level activity (healthy runs produce these) =="
scan "$OUTDIR/watch.log" watch 'subsystem.*fortiche|com\.davidruiz\.fortiche' \
  "Fortiche watch-side log lines in window"
scan "$OUTDIR/phone.log" phone 'com\.davidruiz\.fortiche' \
  "Fortiche phone-side log lines in window"
scan "$OUTDIR/phone.log" phone 'sessionReachabilityDidChange|reachability' \
  "WC reachability transitions (both sides resync here per R4)"
scan "$OUTDIR/watch.log" watch 'startMirroring|mirror' \
  "watch-side mirroring attempts"
scan "$OUTDIR/phone.log" phone 'workoutSessionMirroringStartHandler|mirroringStart|mirror' \
  "phone-side mirrored-session activity"

echo
echo "# full captures: $OUTDIR/phone.log  $OUTDIR/watch.log"
echo "# interpretation guide: .claude/skills/fortiche-diagnostics-and-tooling/SKILL.md"
