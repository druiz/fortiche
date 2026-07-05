#!/bin/bash
# intent-doctor.sh — Live Activity / App Intents health check for Fortiche.
#
# Diagnoses the R1 failure class (Live Activity buttons silently do nothing)
# by checking every link in the chain:
#   1. app + widget appex both ship Metadata.appintents/extract.actionsdata
#      containing the Live Activity intents (CompleteSetIntent, SkipRestIntent,
#      PauseResumeIntent);
#   2. no debug-dylib stub executable (ENABLE_DEBUG_DYLIB must be NO);
#   3. linkd's appintents.sqlite3 actually indexed the bundle (canonical bundle
#      row + intent rows + effective bundle identifiers);
#   4. no fortiche rows in audit_errors (the killer signature was
#      'Failed to resolve package data ... EINVAL' on extract.packagedata).
#
# Usage:
#   intent-doctor.sh                 # first booted iPhone sim, com.davidruiz.fortiche
#   intent-doctor.sh -u <UDID>       # explicit device
#   intent-doctor.sh -b <bundle-id>  # different bundle id
#
# Exit code: 0 all checks pass, 1 any FAIL.
set -uo pipefail

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app}"
export DEVELOPER_DIR

UDID=""
BUNDLE="com.davidruiz.fortiche"
# The three intents that MUST be present in both app and widget binaries for
# Live Activity buttons to work (source of truth: Shared/LiveActivityIntents.swift).
LA_INTENTS=(CompleteSetIntent PauseResumeIntent SkipRestIntent)

while getopts "u:b:h" opt; do
  case "$opt" in
    u) UDID="$OPTARG" ;;
    b) BUNDLE="$OPTARG" ;;
    h|*) grep '^#' "$0" | head -20; exit 1 ;;
  esac
done

FAILURES=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; FAILURES=$((FAILURES+1)); }
warn() { echo "  WARN  $*"; }

# ---------------------------------------------------------------- device ----
if [[ -z "$UDID" ]]; then
  UDID=$(xcrun simctl list devices booted -j | python3 -c '
import json,sys
d=json.load(sys.stdin)
for rt, devs in d["devices"].items():
    if "iOS" not in rt: continue
    for dev in devs:
        if dev["state"]=="Booted":
            print(dev["udid"]); raise SystemExit
' )
  if [[ -z "$UDID" ]]; then
    echo "error: no booted iOS simulator found; pass -u <UDID>" >&2; exit 1
  fi
fi
DATA_PATH=$(xcrun simctl list devices -j | python3 -c '
import json,sys
u=sys.argv[1]; d=json.load(sys.stdin)
for devs in d["devices"].values():
    for dev in devs:
        if dev["udid"]==u: print(dev.get("dataPath","")); raise SystemExit
' "$UDID")
echo "== intent-doctor: device $UDID, bundle $BUNDLE =="

# ------------------------------------------------------ 1. bundle metadata --
APP=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" app 2>/dev/null)
if [[ -z "${APP:-}" || ! -d "$APP" ]]; then
  fail "app $BUNDLE is not installed on $UDID (simctl get_app_container failed)"
  echo "== verdict: FAIL (nothing else to check) =="; exit 1
fi
echo "-- app bundle: $APP"

list_actions() {  # $1 = path to a bundle containing Metadata.appintents
  python3 - "$1" <<'PY'
import json, sys, os
p = os.path.join(sys.argv[1], "Metadata.appintents", "extract.actionsdata")
if not os.path.exists(p):
    print("MISSING"); raise SystemExit
d = json.load(open(p))
acts = d.get("actions") or {}
names = sorted(acts.keys() if isinstance(acts, dict) else [a.get("identifier") for a in acts])
print(" ".join(names) if names else "EMPTY")
PY
}

check_bundle() {  # $1 = bundle path, $2 = label, $3.. = required intents
  local path="$1" label="$2"; shift 2
  local actions; actions=$(list_actions "$path")
  if [[ "$actions" == "MISSING" ]]; then
    fail "$label: Metadata.appintents/extract.actionsdata missing (App Intents metadata was not extracted at build time)"
    return
  fi
  pass "$label: extract.actionsdata present — actions: $actions"
  local i
  for i in "$@"; do
    if [[ " $actions " == *" $i "* ]]; then
      pass "$label: $i present"
    else
      fail "$label: $i MISSING from extract.actionsdata"
    fi
  done
  # The R1 incident signature: package-hosted intents emit extract.packagedata,
  # which linkd fails to resolve (EINVAL) and then indexes NOTHING.
  if [[ -e "$path/Metadata.appintents/extract.packagedata" ]]; then
    fail "$label: extract.packagedata present — an AppIntentsPackage / package-hosted intent snuck back in (R1). Move intents to the target."
  else
    pass "$label: no extract.packagedata (no package-hosted intents)"
  fi
}

check_bundle "$APP" "app" "${LA_INTENTS[@]}"

APPEX_COUNT=0
for appex in "$APP"/PlugIns/*.appex; do
  [[ -d "$appex" ]] || continue
  APPEX_COUNT=$((APPEX_COUNT+1))
  check_bundle "$appex" "appex $(basename "$appex")" "${LA_INTENTS[@]}"
done
[[ $APPEX_COUNT -eq 0 ]] && fail "no .appex found under PlugIns/ — widget extension not embedded"

# ------------------------------------------------- 2. debug-dylib stub check --
EXE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP/Info.plist" 2>/dev/null)
if ls "$APP"/*.debug.dylib >/dev/null 2>&1; then
  fail "debug dylib present ($(ls "$APP"/*.debug.dylib)) — ENABLE_DEBUG_DYLIB must stay NO (R1: linkd audit EINVAL on the stub executable)"
elif [[ -n "$EXE" ]] && otool -L "$APP/$EXE" 2>/dev/null | grep -q "debug.dylib"; then
  fail "main executable links a debug.dylib stub — ENABLE_DEBUG_DYLIB must stay NO (R1)"
else
  pass "no debug-dylib stub (ENABLE_DEBUG_DYLIB is NO)"
fi

# --------------------------------------------------------- 3. linkd's index --
DB=""
if [[ -n "$DATA_PATH" ]]; then
  DB=$(find "$DATA_PATH/Containers/Data/System" -name appintents.sqlite3 2>/dev/null | head -1)
fi
if [[ -z "$DB" ]]; then
  fail "could not locate linkd's appintents.sqlite3 under $DATA_PATH/Containers/Data/System"
else
  echo "-- linkd index: $DB"
  Q() { sqlite3 -readonly "$DB" "$1" 2>/dev/null; }

  CANON=$(Q "SELECT id FROM canonical_bundles WHERE bundleIdentifier='$BUNDLE';")
  if [[ -z "$CANON" ]]; then
    fail "linkd has NO canonical_bundles row for $BUNDLE — the bundle was never successfully indexed (relaunch the app once, then re-run; if still absent, check audit_errors below)"
  else
    pass "canonical bundle indexed (id=$CANON)"
    INTENTS=$(Q "SELECT identifier FROM intent_metadata WHERE canonicalBundleId=$CANON;" | sort | tr '\n' ' ')
    if [[ -z "$INTENTS" ]]; then
      fail "canonical bundle exists but ZERO intents indexed — this is the exact R1 end-state ('There is no metadata for CompleteSetIntent')"
    else
      pass "intents indexed: $INTENTS"
      for i in "${LA_INTENTS[@]}"; do
        [[ " $INTENTS " == *" $i "* ]] && pass "linkd knows $i" || fail "linkd is missing $i — chronod will log 'There is no metadata for $i in $BUNDLE' and the button will do nothing"
      done
    fi
    EBI=$(Q "SELECT bundleIdentifier FROM effective_bundle_identifiers WHERE bundleIdentifier LIKE '$BUNDLE%';" | tr '\n' ' ')
    if [[ "$EBI" == *"$BUNDLE.widgets"* ]]; then
      pass "effective bundle identifiers cover the widget appex: $EBI"
    else
      fail "effective_bundle_identifiers has no row for $BUNDLE.widgets (got: ${EBI:-none}) — per-bundle type mapping absent; Live Activity taps from the widget process will be dropped"
    fi
  fi

  echo "-- audit_errors rows mentioning this bundle (empty is healthy):"
  Q "SELECT identifier || ' | ' || issue || ' | ' || source FROM audit_errors
     WHERE identifier LIKE '%${BUNDLE}%' OR issue LIKE '%${BUNDLE}%' OR issue LIKE '%Fortiche%';" \
    | sed 's/^/     /'
  BADROWS=$(Q "SELECT count(*) FROM audit_errors
     WHERE identifier LIKE '%${BUNDLE}%' OR issue LIKE '%${BUNDLE}%' OR issue LIKE '%Fortiche%';")
  if [[ "${BADROWS:-0}" -gt 0 ]]; then
    fail "$BADROWS audit_errors row(s) reference this app — look for 'Failed to resolve package data' / EINVAL (R1 signature)"
  else
    pass "no audit_errors rows reference this app"
  fi
fi

# ---------------------------------------------------------------- verdict ---
echo
if [[ $FAILURES -eq 0 ]]; then
  echo "== verdict: HEALTHY — intents extracted, indexed, and mapped; Live Activity buttons should work =="
else
  echo "== verdict: $FAILURES check(s) FAILED — see fortiche-failure-archaeology (R1) for the incident and fix =="
  exit 1
fi
