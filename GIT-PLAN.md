# Git plan — the minimal point and the run version

Written 2026-09-27, after `bin/e2e-browser.py` went 14/0 for the fourth consecutive run and
`bin/demo.sh` 12/12. Planning only: **no repo exists yet** (`davinci-mock/` is not a git repo, and
neither is anything it contains that isn't one of the six clones).

> **STATUS: EXECUTED 2026-09-27; REWRITTEN 2026-09-28 for publication.** Steps 0–6 are done.
> The remote is **`https://github.com/Abaabeel/davinci-mock`**, created private (verified via the
> API, not just the `--private` flag) and prepared for public release. 30 files, `.git` ~2.2 MB.
> Cloning it into an empty directory yields a tree whose `provision.sh --check` reports exactly
> its 8 missing inputs and exits 1 — so it is a rebuild path, not documentation.
>
> **History was rewritten, not amended.** The published tag pointed at a commit whose tree still
> contained the build host's real LAN IP (in text *and* rendered into a screenshot), a Windows
> username and a WSL distro GUID. All four commits were rewritten with `git-filter-repo`, the
> screenshot blob was replaced with a redacted copy, and the `run-2026-09-27` tag was **deleted
> rather than re-pointed**. See [Post-publication scrub](#post-publication-scrub) — including why
> the rewrite is necessary but not sufficient.
> What actually happened, and the places the plan was wrong:
>
> - **Identity.** The commit was first made under a placeholder identity I invented, then re-attributed
>   to the address in the developer's `~/.gitconfig` before pushing. That address was a work
>   mailbox rather than a GitHub-verified one, so GitHub would have shown the commits as
>   unverified contributions — and publishing would have made a live mailbox permanently
>   world-readable. Both were fixed before publication: see
>   [the author-email reversal](#the-author-email-reversal) below.
> - **Credentials.** `git` had no credential helper, so the first push failed with
>   `could not read Username for 'https://github.com'`. Fixed with a **repo-local**
>   `credential.helper = !gh auth git-credential` rather than `gh auth setup-git`, so nothing in
>   your global `~/.gitconfig` changed. `gh` itself was already authenticated via `GH_TOKEN` in
>   `~/.zshrc`.
> - **Repository visibility is not a secret scan.** I checked the pushed tree and full
>   history for `ghp_`/`github_pat_`/`hf_`/`cfut_`/`sk-` patterns before calling this
>   done: clean. None of the developer's own tokens are in the repo, and this document
>   deliberately does not record where they are kept.
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
> - One doc bug fixed along the way: `TEST-FLOW.md` and `investigation-log.md` recorded the browser
>   patient's id as `0M987954001AZ`; `logs/prior-auth.log` says `0M987654001AZ`.

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

## 6. Push — DONE

Remote: **`https://github.com/Abaabeel/davinci-mock`**, created private and confirmed private via the
API rather than trusting the `--private` flag. `master` tracks `origin/master`. There is no run tag
on the remote: the `run-2026-09-27` tag and the commit it dereferenced were removed as part of the
publication scrub, so that nothing on the remote resolves to pre-scrub content.

Two things that had to be sorted out first:

- **The commit was attributed to a placeholder identity I had invented.** `~/.gitconfig` says
  `Abaabeel <<your-git-email>>`, so the local override was dropped and the commit re-authored and
  re-committed as that identity before it was ever pushed. Note that address is a work address, not a
  GitHub-verified one, so GitHub may show the commit as an unverified contributor until the email is
  added to the account — worth doing if you want the attribution to link.
- **Plain `git` could not authenticate.** The first push died with
  `could not read Username for 'https://github.com'` — no credential helper, and no TTY to prompt on.
  `gh` was already authenticated (`GH_TOKEN` in `~/.zshrc`), so the fix was to hand its credentials to
  git. Deliberately **repo-local**:
  `git config --local credential.helper '!gh auth git-credential'`
  rather than `gh auth setup-git`, which would have rewritten the global `~/.gitconfig`. Your global
  config is untouched.

Before calling it done I checked the pushed tree *and* the full history for `ghp_`, `github_pat_`,
`hf_`, `cfut_` and `sk-` token patterns: clean. None of the developer's own tokens are in the
repository, and the location of the developer's personal token store is deliberately not recorded
here. Visibility is not a substitute for running the check — a repository one push away from public
is exactly when the check matters.

Note what the payload would expose if it ever went public. The committed default is
`ADVERTISE_HOST=localhost` and `CORS_ORIGINS` lists localhost origins, which is correct for a private
repo. But the stack binds **`0.0.0.0` on all six ports** the moment it is up — including a mock FHIR
server and PAS with `BYPASS_AUTH=true`. `TEST-FLOW.md` §11 documents reaching it from the LAN
(`ADVERTISE_HOST=192.0.2.10 bin/up.sh`, verified working from Chromium) and Windows' firewall is
the only thing stopping it. These are scripts, not secrets, but they are a working recipe for an
unauthenticated FHIR server, and that is a different risk class from ordinary source — hence private.

## 7. Resolved and remaining

1. ~~**Remote** — private GitHub, or somewhere else?~~ **Resolved: private GitHub, `Abaabeel/davinci-mock`.**
2. **Toolchain: pin to exact patch versions, or track upstream?** `runtime/jdk17` is Temurin
   `17.0.20.1+1`; upstream 17.x has moved on. Exact pins mean a rebuild in six months needs that old
   JDK, which `versions.lock` supplies by URL and checksum — so it is a fetch, not a problem. This
   project went with **exact**, and that choice is what makes the tag reproducible.
3. **Should the 9 e2e screenshots be committed at all?** Committed, on the argument that
   `09-pas-decision.png` is the only proof the browser leg works. The cost is now measured rather
   than assumed: **five** of the nine are unreproducible and dirty the worktree on every run
   (`08` and `09` always, `02`/`04`/`07` often; `09` is the least stable, because it can
   capture `Loading...` instead of the expanded JSON pane). An earlier claim of "exactly two"
   was written before a full run and is corrected here and in `AGENTS.md`. See §2.

## 8. Post-publication scrub

The repository was created private and is being prepared for public release. That changed the
cost of everything in this file, so the history was rewritten rather than merely amended.

### What was found

A full scan of all tracked files *and* every blob in every commit, plus OCR of all 13 PNGs at
four tesseract page-segmentation modes each, found:

| Class | Count | Where |
|---|---|---|
| A scratch directory named after the tool that wrote it | 48 | `PLAN.md`, `SOURCES.md`, `investigation-log.md` |
| The build host's real LAN address, as text | 51 | `bin/`, `TEST-FLOW.md`, `GIT-PLAN.md`, the realm fixture |
| The same address, **rendered as pixels** | 1 PNG | `09-pas-decision.png`, inside the ClaimResponse payload |
| A second LAN address | 8 | realm fixture redirect URIs |
| A Windows username and a WSL distro GUID | 18 | `TEST-FLOW.md` §7a |
| A hardcoded python path belonging to the build machine | 20 | `bin/demo.sh`, `bin/e2e-browser.py`, docs |

The screenshot is the one worth remembering. `09-pas-decision.png` shows the PAS base URL
inside the JSON the browser received, so the host address was **in the image**. No text scan
can see it; `git grep` for the address returned nothing and the tree looked clean. OCR found it
in one pass. It is now a permanent CI step, because that class of leak is otherwise invisible
until someone with a text editor opens the PNG.

### What was done

- All five commits rewritten with `git-filter-repo`: text substitutions plus a
  `--file-info-callback` that swapped the screenshot blob for a redacted copy, because
  `--replace-text` cannot reach binary content.
- Replacements were chosen so the result stays truthful: the LAN address became `192.0.2.10`
  (RFC 5737 TEST-NET-1) and the second became `203.0.113.10` (TEST-NET-3), rather than
  collapsing both onto one value and producing duplicate redirect URIs.
- The `run-2026-09-27` tag was **deleted, not re-pointed.** A published tag is never moved —
  that is what makes it a record. Since the commit it named had to change, the honest move was
  to remove the record and tag the next certified run.
- The rewritten HEAD tree is byte-identical to the reviewed and pushed tree. The rewrite changed
  history and nothing else.
- `SECURITY.md` records the finding that a hardcoded credential exists in the pinned upstream
  PAS, with the value redacted. Republishing someone else's secret is a disclosure that earns
  nothing.

### Why rewriting was necessary and is not sufficient

Deleting a tag and force-pushing removes the *references*. It does not remove the *objects*.
GitHub continues to serve unreachable objects to anyone who knows the SHA:

```bash
$ git fetch origin 721037be61175c6fbec6ad83e574e53c9643ff7c   # no ref points here
$ git cat-file -p 721037b:investigation-log.md | grep -c '[o]pencode'
12
```

This was verified, not assumed, and it is why the scrub is not considered finished while the
repository is still private. The only reliable remedies are **deleting and recreating the
repository** — trivial here, at 0 stars, 0 forks, 0 watchers, 0 issues and one day old — or
asking GitHub Support to purge the unreachable objects. Do the recreate *before* flipping
visibility, not after.

### The lesson worth keeping

Repository visibility is not a security control. A private repository is not a substitute for
running the scan, and a force-push is not a substitute for removing the objects. Both of those
cost a full afternoon here, and both were found by checking rather than by reasoning.

### The author-email reversal

The author's own work address was initially **kept**, on the reasoning that correct attribution
of one's own work outweighs the address not appearing. That is a defensible position for a
private repository, and it was implemented rather than argued with: the address was allowlisted
in `.github/scan-allow.txt`, the trade-off was written down, and the reversal was documented so
it stayed a deliberate choice instead of drifting into an accident.

Publication overturned it. A live mailbox becomes world-readable and harvestable the moment a
repository is public, and there is no scrub for a public repository's history — the exposure is
permanent and the only remedy afterwards is rewriting and re-publishing, which is the expensive
version of the operation. The commits would also have rendered as unverified contributions.

So the decision was reversed **while the repository was still private**, at the cost of two
`git filter-branch` passes over nine commits:

1. `--env-filter` rewrote author and committer name and email to
   `Abaabeel <Abaabeel@users.noreply.github.com>` — a GitHub-verified address that preserves
   attribution without exposing a mailbox.
2. `--tree-filter` rewrote the address out of *file contents* in earlier commits. Metadata-only
   rewriting is not sufficient: the string also lived in `GIT-PLAN.md` prose, in a `ci.yml`
   comment, and in `scan-allow.txt`, and all three would have been readable on a public
   repository regardless of what the commit headers said.

Verified afterwards across all 103 objects in the repository: zero blobs containing the address,
zero occurrences in any diff, and `noreply` as the only author and committer identity present.

`git-filter-repo` was tried first and crashed on a bytes/str `TypeError` while dumping commit
objects — the messages in this history contain em-dashes, and filter-repo's message-encoding path
chokes on them. `git filter-branch` was used instead because it never rewrites message bytes,
which is all that was needed here. The crash is worth remembering as the reason to have both
tools in mind: the "better" one was not the right one for a metadata-only change over
non-ASCII commit messages.

Two smaller lessons from the same pass:

- **`git checkout -- <file>` restores from the index, not from `HEAD`.** A file that had been
  `git add`ed with test content came back still containing the test content, and the next
  `git add -A` committed it. Undoing a staged change needs `git restore --staged --worktree`, or
  `git reset -q <file>` first. This is how a planted canary ended up in a published file.
- **The guard that should have caught it was not the one that did.** The scan did flag the
  address; it was flagged in step 7 on a tree containing no credential, because step 7 was
  matching its own source. See [the CI guard suite](#the-ci-guard-suite) in `CONTRIBUTING.md`.
