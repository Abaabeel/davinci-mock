#!/usr/bin/env bash
#
# Run the CI guard suite locally, exactly as GitHub runs it.
#
# WHY THIS EXISTS
#
# The first version of .github/workflows/ci.yml was reported working after two
# of its twelve steps had been run by hand. The other ten had never executed.
# On the first real push, one of the untested ones failed, and not for the reason
# anyone expected: the step meant to catch a reproduced upstream credential was
# matching its own source line, because a grep pattern that scans a directory
# containing itself will find itself. The repository contained no credential
# and the guard was not wrong about the tree; it was wrong about the file.
#
# Two of twelve is not verification. This script runs every step, in order,
# against a bare snapshot, with the same shell and the same working directory
# the runner uses, and reports each one separately so a failure names the step
# rather than the workflow.
#
# It is a faithful simulation, not a substitute for the real runner: the
# differences are stated at the end. Run this before pushing a change to CI.
#
# USAGE
#   ./bin/ci-local.sh
#
# Runs every step against a bare snapshot of the working tree, so uncommitted
# changes are covered. Add them to the index first if a guard depends on
# `git ls-files`, which lists tracked files only.
#
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WF_REL=".github/workflows/ci.yml"

command -v python3 >/dev/null || { echo "need python3" >&2; exit 2; }
[ -f "$ROOT/$WF_REL" ] || { echo "missing $WF_REL" >&2; exit 2; }

# The suite always runs in a bare snapshot, never in the working tree.
#
# One guard asserts that the provisioner FAILS on an unprovisioned tree, and
# a pass there is the dangerous direction: it would mean the provisioner
# declares a tree ready that is not. In a provisioned working directory that
# guard inverts and reports a false failure -- which is what it did on the
# first run of this script, for a reason that had nothing to do with the
# guard. The step is only meaningful against a fresh checkout, and the runner
# always has one, so the simulation has to as well.
#
# The snapshot is a copy of the working tree, minus the heavy directories that
# are gitignored, plus .git. Carrying .git matters: the scans use `git ls-files`
# and `git log --all -p`, and a snapshot without a repository would fail them
# for a reason that is not a finding either. Copying rather than cloning means
# uncommitted edits are tested, which is the whole point of running this
# before pushing.
SNAP="$ROOT/.ci-local/snapshot"
rm -rf "$ROOT/.ci-local"
mkdir -p "$SNAP"
tar -C "$ROOT" -cf - \
  --exclude=./.git --exclude=./repos --exclude=./runtime \
  --exclude=./.ci-local --exclude=./node_modules --exclude=./logs . \
  | tar -C "$SNAP" -xf -
cp -a "$ROOT/.git" "$SNAP/.git"

cd "$SNAP"
WF="$SNAP/$WF_REL"

STEPDIR="$SNAP/.ci-local/steps"
mkdir -p "$STEPDIR"

python3 - "$WF" "$STEPDIR" <<'PY'
import sys, yaml, pathlib, re
wf, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
doc = yaml.safe_load(wf.read_text())
steps = doc['jobs']['verify']['steps']
n = 0
for s in steps:
    if 'run' not in s:
        continue
    n += 1
    name = re.sub(r'[^A-Za-z0-9]+', '-', s.get('name', f'step-{n}')).strip('-')
    (out / f'{n:02d}-{name}.sh').write_text(s['run'])
print(n)
PY

mapfile -t scripts < <(ls "$STEPDIR"/*.sh | sort)
total=${#scripts[@]}

echo
echo "==> $total steps, from $(basename "$WF")"
echo

pass=0; fail=0; failed=()
for s in "${scripts[@]}"; do
  label=$(basename "$s" .sh)
  # -e matches the runner. The step runs from the repository root.
  if out=$(bash -e "$s" 2>&1); then
    printf '  \033[32mPASS\033[0m  %s\n' "$label"
    pass=$((pass + 1))
  else
    rc=$?
    printf '  \033[31mFAIL\033[0m  %s  (exit %d)\n' "$label" "$rc"
    printf '%s\n' "$out" | sed 's/^/          | /' | head -25
    fail=$((fail + 1)); failed+=("$label")
  fi
done

echo
printf '  %d passed, %d failed, of %d\n' "$pass" "$fail" "$total"
[ "$fail" -eq 0 ] || { printf '  failed: %s\n' "${failed[*]}"; }

cat <<'NOTE'

  Differences from the real runner, all benign:
    - the runner is ubuntu-24.04; this ran on whatever host invoked it
    - tesseract is expected already installed rather than apt-installed
    - Actions annotations (::error::) print as plain text
    - the runner has no write access outside the workspace; this does

  This suite passing is necessary, not sufficient. Ten of the twelve steps
  had never been run when the workflow was first pushed, and one of those
  failed on the push. The failure modes this cannot catch are the ones that
  depend on the runner: the base image, and anything apt installs.
NOTE

[ "$fail" -eq 0 ]
