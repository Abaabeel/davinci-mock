# Git plan — the minimal point and the run version

Written 2026-09-27, after `bin/e2e-browser.py` went 14/0 for the fourth consecutive run and
`bin/demo.sh` 12/12. Planning only: **no repo exists yet** (`davinci-mock/` is not a git repo, and
neither is anything it contains that isn't one of the six clones).

> **STATUS: EXECUTED 2026-09-27.** Steps 0–5 are done; step 6 (push) is not, because there is no
> remote. What actually happened, and the two places the plan was wrong:
>
> - `versions.lock` + `bin/provision.sh` written. The **Temurin build number is `+1`, not `+8`** —
>   upstream ships both a `17.0.20+8` and a `17.0.20.1+1`, so `17.0.20.1` alone does not identify
>   an artefact. Confirmed against `runtime/jdk17/release`
>   (`IMPLEMENTOR_VERSION="Temurin-17.0.20.1+1"`). All three download URLs and their checksums
>   verified live before being written down.
> - `bin/provision.sh --check` was the one genuinely useful guard, and building it found **two
>   bugs in the script itself**, both now fixed: it exited 0 while printing "inputs are complete"
>   on a tree with 9 missing inputs, and it created `runtime/downloads` in a mode that promises
>   never to download.
> - **`bin/clone.sh` cannot be trusted to enforce its own pin.** It exits 0 with
>   `[x] already cloned` for a checkout at *any* commit, so `provision.sh` re-verifies every SHA
>   itself. This is the whole reason §0.1 said a fresh clone was documentation rather than a
>   rebuild, and it is worse than that: a *stale* clone was also undetectable.
> - Result: one commit, 30 files, `.git` = **2.2 MB** (not 2.4), tagged `run-2026-09-27`.
>   Verified by cloning the tag into an empty directory: `provision.sh --check` there reports
>   exactly its 8 missing inputs (6 repos + JDK + Maven) and exits 1, finding Keycloak only
>   because `/opt/keycloak` is shared ext4 outside the repo.
> - One doc bug fixed along the way: `TEST-FLOW.md` and `investigation-log.md` recorded the browser
>   patient's id as `0M987954001AZ`; `logs/prior-auth.log` says `0M987654001AZ`.
>
> **Still open: §6, the push. It needs a remote URL from you, and my recommendation stands —
> private.** The stack binds `0.0.0.0` on all six ports and PAS runs `BYPASS_AUTH=true`, so this
> payload is a working recipe for an unauthenticated FHIR server. Say the word and it is
> `git remote add origin <url> && git push -u origin run-2026-09-27`.

---

## 0. The constraint that decides everything

```
Filesystem      Size  Used Avail Use%  Mounted on
C:\             222G  220G  2.1G  100%  /mnt/c
/dev/sdd       1007G  200G  756G   21%  /
```

**C: has 2.1 GB free.** `repos/` (1.2 GB) and `runtime/` (337 MB) therefore cannot be committed —
which is the right outcome anyway, since both are other people's code and re-derivable artefacts.
This is not a compromise forced by the disk; it is the correct shape for the repo. The disk just
removes the option of being tempted.

## 1. One gap to close before the first commit

The six upstream SHAs currently exist **only as prose** — in the tables in `SOURCES.md` and
`PLAN.md`. `bin/clone.sh` accepts a SHA as an argument, and **nothing calls it with the six**:

```
$ grep -rn "clone.sh" bin/ | grep -v ^bin/clone.sh
bin/env.sh:53:#  ...wiped by the next bin/clone.sh...
bin/seed-valuesets.sh:38:#  ...run bin/clone.sh first...
bin/up.sh:177:#  ...lost on the next bin/clone.sh...
```

Three comments, no caller. So a fresh clone of this repo would be **documentation, not a run
version** — you could read how the stack was built but not rebuild it. Closing this is a
prerequisite for the commit, not a follow-up.

### 1a. `versions.lock`

Machine-readable, and the single source of truth. `SOURCES.md` and `PLAN.md` should be reduced to
*pointing at* this file rather than restating it, so the pins cannot drift:

```
# upstream sources -- name<TAB>org/repo<TAB>full-40-char-sha
CDS-Library        HL7-DaVinci/CDS-Library             560403a...
CRD                HL7-DaVinci/CRD                     43547c4...
crd-request-generator HL7-DaVinci/crd-request-generator 87e98bf...
dtr                HL7-DaVinci/dtr                     7acf79a...
prior-auth         HL7-DaVinci/prior-auth              848f28c...
test-ehr           HL7-DaVinci/test-ehr                e3f07ce...
```

It must also pin the four things that are **not** git repos and are currently recorded only in
source comments, because losing any of them breaks the stack:

| what | pin | why it matters |
|---|---|---|
| Keycloak | 26.7.4, unpacked at `/opt/keycloak` | on ext4, not in this folder — C: was 100 % full. Not in git, not re-cloned by `clone.sh` |
| JDK for CRD/PAS/test-ehr | Temurin **17.0.20.1** at `runtime/jdk17` | `env.sh:20` hardcodes `JAVA_HOME` |
| JDK for Keycloak | **21** (`/usr/lib/jvm/java-21-openjdk-amd64`) | `kc.sh` runs `$JAVA_HOME/bin/java`, and `env.sh` otherwise pins 17. See `up.sh`'s per-service override |
| PAS `DELAY` | `15000` | every PENDING → GRANTED in the logs is +15 s because of it |

### 1b. `bin/provision.sh`

Thin driver, so "build the stack" is one command rather than a checklist in prose:

```bash
#!/usr/bin/env bash
# Provision everything the stack needs except this repo. Idempotent.
# 1. clone the 6 upstream repos at their pinned SHAs (bin/clone.sh, shallow)
# 2. unpack the pinned JDK + Maven into runtime/
# 3. install Keycloak at the pinned version into $KEYCLOAK_HOME
# 4. assert each step, because every one of these fails *silently* later
set -euo pipefail
...  # loop over versions.lock -> bin/clone.sh <name> <org/repo> <sha>
```

The "fails silently later" clause is the point. Every one of these has already cost a debugging
session: a CDS-Library in the wrong directory is a hard exit at boot, a `PORT` exported globally
hijacks dtr while the stack still probes green, a `VSAC_CACHE_DIR` without its trailing slash
reports all 65 value sets added and then misses every lookup. Provisioning asserts, and does not
defer the checking to first boot.

## 2. What goes in, what stays out

Measured, not estimated.

| path | size | in git? | why |
|---|---|---|---|
| `bin/` | 80 K | **yes** | 7 scripts — this *is* the run version |
| `PLAN.md` `SOURCES.md` `TEST-FLOW.md` `investigation-log.md` `GIT-PLAN.md` | 152 K | **yes** | the record, including every correction |
| `fixtures/` | 8 K | **yes** | `order-sign-prefetch.json`, `keycloak/BurdenReduction-realm.json` |
| `docs/screenshots/*.png` | 672 K | **yes** | the 4 curated shots: card, launch failure, questionnaire, Keycloak login |
| `docs/screenshots/e2e/*.png` | 1.4 M | **yes** | the 9 from the last green run. `09-pas-decision.png` is the **only** artefact of a browser-driven claim that exists anywhere |
| `docs/screenshots/e2e/*.html *.json *.txt` | 92 K | no | `form-container.html` is 83 KB of generated LForms markup, rewritten on every run |
| `repos/` | **1.2 G** | no | 6 upstream clones. Other people's code; re-creatable from `versions.lock` |
| `runtime/` | **337 M** | no | Temurin JDK 17 + Maven 3.9.9. Re-downloadable |
| `logs/` `pids/` `state/` | 1.9 M | no | runtime; `state/demo/*.json` is a by-product of `demo.sh` |

Result: **`.git` ≈ 2.4 MB.**

Committing the e2e PNGs is a deliberate exception to "don't commit generated output". They are
generated, but they are regenerated *identically* on a green run, and they are the evidence for the
one claim no log line makes on its own — that a browser, not a script, produced a claim PAS accepted.
`e2e-browser.py` clears the directory at the start of each run precisely so that a committed set is
always a coherent single run rather than a mix of good and failed passes.

> **Correction, found by committing them: they are *not* regenerated identically.** Two of the nine
> differ byte-for-byte on every green run — `08-pas-submitted.png` (+237 bytes) and
> `09-pas-decision.png` (−1113 bytes) — because both render a runtime Claim id and a wall-clock
> time. The other seven are stable. So **a green run always leaves `git status` dirty on exactly
> those two files.** That is the cost of committing the evidence, and it is worth knowing about
> before it looks like something broke. `git checkout -- docs/screenshots/e2e/` clears it. The
> alternative — gitignoring all nine — loses `09-pas-decision.png`, which is the only artefact of a
> browser-driven claim anywhere in the project, so they stay committed.

**No patches to upstream code need carrying.** Verified across all six clones:

```
CDS-Library          tracked-modified=0  untracked=0
CRD                  tracked-modified=0  untracked=0
crd-request-generator tracked-modified=0  untracked=0
dtr                  tracked-modified=1  untracked=1   #  D databaseData/.gitkeep
prior-auth           tracked-modified=0  untracked=0
test-ehr             tracked-modified=0  untracked=0
```

`dtr`'s two entries are runtime noise (lowdb created real files in `databaseData/`; webpack wrote
`public/js/`), not edits. The local customisations that *do* exist are all in the CDS-Library
*placement* rules inside `up.sh` — which live in this repo, and so travel with it.

## 3. `.gitignore`

```gitignore
# upstream clones -- re-create with bin/provision.sh from versions.lock
/repos/

# toolchain -- re-download; 337 MB of Temurin JDK and Maven
/runtime/

# runtime state
/logs/
/pids/
/state/

# the e2e PNGs ARE committed (they are the evidence for the browser leg) but the
# generated diagnostics alongside them are not
/docs/screenshots/e2e/*.html
/docs/screenshots/e2e/*.json
/docs/screenshots/e2e/*.txt

# never commit a node_modules or a build dir, even if one appears
node_modules/
build/
dist/
.gradle/
*.class
```

The `node_modules/`, `build/`, `dist/` lines are belt-and-braces: everything they would match today
is already excluded by the rules above, but they cost nothing and they are exactly what accidentally
gets added when someone runs `up.sh` from inside a clone.

The commit command therefore needs the screenshots named explicitly rather than swept up by
`git add docs/`, because `git add docs/screenshots/` would also stage the 92 KB of generated markup
that the ignore rules are there to keep out:

## 4. The minimal point

**One commit.** Not a reconstructed history.

```bash
git init
git add .gitignore versions.lock bin/ fixtures/ '*.md'
git add docs/screenshots/*.png docs/screenshots/e2e/*.png
git commit -m "DaVinci prior auth mock: 6 services, browser E2E to a PAS decision"
```

It is the smallest commit from which this is true:

```
bin/up.sh && bin/demo.sh          # 12/12
        bin/e2e-browser.py       # 14/14
```

Skipping the history is deliberate. The value of a baseline here is that it reproduces, not that it
can be bisected — there is no bug tracker, no issue history and no prior version of this stack that
ever ran. Reconstructing a linear history of "then it was 5 services, then Keycloak came back"
would be 4 commits of narrative with no rollback anyone would use.

## 5. The run version

**An annotated tag on that commit**, not a branch.

```bash
git tag -a run-2026-09-27 -m "6 services boot; demo.sh 12/12; e2e-browser.py 14/14.
  Claim submitted by dtr from the browser, PAS 201, Pending -> Granted."
```

A branch implies the stack moves forward from here and can be moved to. It cannot, without a
deliberate re-pin of all six SHAs plus a JDK and a Keycloak version — which is a new commit and a new
tag, not a branch tip. A tag says exactly one thing: *this SHA is the version that ran green*, and
the message carries the evidence so nobody has to trust the tag name.

Worth carrying in the same commit, since they define "ran green": the two driver invocations, the
six ports, and the two known blemishes (the unresolvable CQL refs in `HomeBloodGlucoseMonitorRule`,
and the one value set that still 404s). A run version whose known failures are undocumented is a
trap for whoever runs it next.

## 6. Push

**Blocked on one decision: there is no remote.** `git remote -v` is empty; the project has never
been a repo.

Before naming one, note what is in the payload and what it would expose. The committed default is
`ADVERTISE_HOST=localhost` and `CORS_ORIGINS` lists localhost origins, which is correct for a private
repo. But the stack binds **`0.0.0.0` on all six ports** the moment it is up — including a mock FHIR
server and PAS with `BYPASS_AUTH=true`. `TEST-FLOW.md` §11 documents how to reach it from the LAN
(`ADVERTISE_HOST=192.0.2.10 bin/up.sh`, verified working from Chromium) and Windows' firewall is
the only thing stopping it. So: **private repo, or nothing.** These are scripts, not secrets, but
they are a working recipe for an unauthenticated FHIR server, and that is a different risk class
from ordinary source.

Sequence once a remote is named:

```bash
git remote add origin <url> && git push -u origin run-2026-09-27
```

## 7. Open questions

1. **Remote** — private GitHub, or somewhere else? Nothing is pushed until this is answered.
2. **Toolchain: pin to exact patch versions, or track upstream?** `runtime/jdk17` is
   17.0.20.1; Temurin 17.x has moved on. Exact pins mean a rebuild in six months needs an old JDK;
   loose pins mean a rebuild is not the thing you tested. This plan assumes exact.
3. **Should the 9 e2e screenshots be committed at all?** §2 commits them, on the argument that
   `09-pas-decision.png` is the only proof the browser leg works. The counter-argument is that
   `e2e-browser.py` regenerates them on demand and a reviewer can just run it. Committing them
   makes the repo 1.4 MB heavier and pins an artefact of *this* Chromium build.
