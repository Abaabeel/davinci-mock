#!/usr/bin/env bash
# Seed the value sets the DTR questionnaires need.
#
# Why this exists: rendering a questionnaire in dtr is a $questionnaire-package
# call to CRD, and QuestionnairePackageOperation.java:333 throws if it cannot
# resolve every valueSet in the library's DataRequirements. Unresolved means
# "go ask VSAC", and VSAC wants an API key. So the card itself builds fine (the
# order-sign hook never expands a value set) and then the questionnaire dies
# with:
#
#   Failed to find ValueSet for URL: http://cts.nlm.nih.gov/fhir/ValueSet/2.16.840.1.113762.1.4.1219.35
#   Is the VSAC_API_KEY set and valid?
#
# A key is free but needs a human account, so by default we pre-seed the cache
# from the public tx.fhir.org instead. Same terminology, no signup.
#
# The trap this script exists to avoid: a plain
#   /r4/ValueSet?url=...
# returns the value set UNEXPANDED (expansion.contains == 0). Dropping that in
# the cache satisfies the lookup, so the error disappears and you get a
# questionnaire with zero answer options -- which looks like a working mock and
# is quietly wrong. Hence the $expand operation and the assertion below.
set -uo pipefail
source "$(dirname "$0")/env.sh"

CACHE="${VSAC_CACHE_DIR:-/root/.cache/davinci-mock/vsac-cache}"
LIB="$DAVINCI_ROOT/repos/CRD/server/CDS-Library"
TX="https://tx.fhir.org/r4/ValueSet/\$expand?url=http://cts.nlm.nih.gov/fhir/ValueSet"

# The HomeBloodGlucoseMonitor order-sign questionnaire. Without these three the
# demo path is dead, so they are asserted rather than merely attempted.
REQUIRED="2.16.840.1.113762.1.4.1219.35 2.16.840.1.113762.1.4.1219.85 2.16.840.1.113762.1.4.1219.94"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m  !!\033[0m %s\n' "$*"; }

[ -d "$LIB" ] || { warn "CDS-Library missing at $LIB - run bin/clone.sh first"; exit 1; }
mkdir -p "$CACHE"

# OIDs are discovered from the library rather than hardcoded, so a library
# refresh that adds a questionnaire does not silently need a new list here.
mapfile -t OIDS < <(
  grep -rhoE '"valueSet" *: *"http[^"]+"' "$LIB" 2>/dev/null \
    | sed 's/.*: *"//; s/"//' \
    | grep -oE 'ValueSet/[0-9.]+' | sed 's|ValueSet/||' | sort -u
)
[ "${#OIDS[@]}" -gt 0 ] || { warn "no valueSet references found in the library"; exit 1; }

# A cached file only counts if it is genuinely expanded. Written as a -c
# one-liner rather than a heredoc on purpose: fetch_one is export -f'd so xargs
# can run it in a child bash, and a heredoc inside an exported function loses
# its body on re-parse, which made every single value set look "unexpanded".
VS_EXPANDED='import json,sys
v=json.load(open(sys.argv[1]))
sys.exit(0 if v.get("resourceType")=="ValueSet" and len(v.get("expansion",{}).get("contains",[]))>0 else 1)'

usable() { [ -s "$1" ] || return 1; python3 -c "$VS_EXPANDED" "$1" 2>/dev/null; }

todo=(); for oid in "${OIDS[@]}"; do
  usable "$CACHE/ValueSet-R4-$oid.json" || todo+=("$oid")
done

if [ "${#todo[@]}" -eq 0 ]; then
  ok "value sets already seeded (${#OIDS[@]} in $CACHE)"
else
  say "seeding ${#todo[@]} of ${#OIDS[@]} value sets into $CACHE"
  export CACHE TX VS_EXPANDED
  fetch_one() {
    local oid="$1" tmp="$CACHE/ValueSet-R4-$1.json.part"
    if curl -fsS -m 60 "$TX/$oid" -o "$tmp" 2>/dev/null; then
      if python3 -c "$VS_EXPANDED" "$tmp" 2>/dev/null; then
        mv "$tmp" "$CACHE/ValueSet-R4-$oid.json"; echo "seeded $oid"
      else rm -f "$tmp"; echo "unexpanded $oid"; fi
    else
      rm -f "$tmp"; echo "unreachable $oid"
    fi
  }
  export -f fetch_one
  printf '%s\n' "${todo[@]}" | xargs -P 6 -I{} bash -c 'fetch_one "$@"' _ {} \
    > "$CACHE/.last-seed" 2>/dev/null
  printf '  %s\n' "$(sort "$CACHE/.last-seed" | uniq -c | sed 's/^ *//' | tr '\n' ' ')" | sed 's/^/  /'
  echo
fi

miss=""
for oid in $REQUIRED; do
  usable "$CACHE/ValueSet-R4-$oid.json" || miss="$miss $oid"
done
if [ -n "$miss" ]; then
  warn "required value sets still missing:$miss"
  warn "the dtr questionnaire will 500. Either re-run this script, or set"
  warn "VSAC_API_KEY to a free key from https://vsac.nlm.nih.gov and restart."
  exit 1
fi
ok "required value sets present (HomeBloodGlucoseMonitor questionnaire)"
