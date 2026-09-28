# AGENTS.md — operating instructions for an AI agent

You have been pointed at this repository and asked to install and run it. This file is
self-contained. Read it end to end, then execute the numbered steps in order. You should not
need to read `README.md`, `PLAN.md` or `investigation-log.md` first — they are for humans, and
several of them contain superseded reasoning that will mislead you.

## What this is

A locally-runnable mock of the HL7 DaVinci prior-authorization flow: **CRD → DTR → PAS**.
Six upstream DaVinci services run as ordinary background processes. No container runtime.

Success looks like this, and only this: a human opens <http://localhost:3001/>, clicks through
a coverage card, logs in at a Keycloak login page, fills a questionnaire, presses
**Proceed To Prior Auth**, and watches a claim go `Pending` then `Granted` in the browser.

## Hard rules

1. **No credentials exist and none are needed.** Do not ask the user for a token, an API key,
   an account or a `.env` file. There is nothing to supply. See "Credentials" below for the
   complete inventory — if something is not in that table, it is a bug, not a missing input.
2. **Do not edit `versions.lock`.** It is the pin set and the de facto run version. A changed
   SHA invalidates every result you report.
3. **Do not use `/tmp`** for anything belonging to this project. It has been wiped once and
   took the entire toolchain with it. Build artefacts, caches and scratch all go under the
   repository or under `/root/.cache/davinci-mock/`.
4. **Never export a global `PORT`.** See trap 1. `bin/up.sh` passes `PORT` per service.
5. **Never `pkill -f <pattern>`** on this box. See trap 5. It will match the shell running it.
6. **Do not delete or move a published git tag.** A tag is the record of a certified run.
7. **Report only what you verified.** If a driver did not run, say so. A plausible claim that
   was not measured is worse than an honest gap.

## Credentials — the complete inventory

Everything the stack authenticates against, in full. There is nothing else.

| What | Value | Source | Action needed |
|---|---|---|---|
| Keycloak admin | `admin` / `admin` | default in `bin/env.sh`, used once at boot to import the realm | none |
| Keycloak demo user | `dtr` / `dtr-demo` | `fixtures/keycloak/BurdenReduction-realm.json` | none — `e2e-browser.py` types it |
| Keycloak client secret | `#replaceMe#` | same fixture; a literal upstream placeholder | none |
| PAS FHIR client | none | PAS runs `BYPASS_AUTH=true`, issues its own token from H2 | none |
| GitHub | none | the repository is public; anonymous clone works | none |
| `VSAC_API_KEY` | absent | optional; without it 67 value sets do not resolve | none — omit it |

The stack needs no secrets because the two services that could demand them are configured not
to: PAS runs with `BYPASS_AUTH=true`, and CRD runs `use_oauth: false` with `checkJwt: false`.
Keycloak exists solely so the DTR launch performs a real OIDC redirect through a real login
page, which is what makes the browser path genuinely end to end.

The only external fetches are the six **public** upstream DaVinci repositories and their
Maven/npm dependencies, all pinned to exact SHAs in `versions.lock`.

## Step 1 — check the host

```bash
. /etc/os-release; echo "$PRETTY_NAME"        # expect Ubuntu 24.04 LTS
node --version                                # expect v22.x  (provision.sh asserts this)
ls /usr/lib/jvm/                              # need a JDK 21 for Keycloak
python3 --version
df -h .                                       # need ~3 GB free
free -h                                       # 7 GB total is the working minimum
```

If Node is missing or the wrong major, stop and say so. Neither upstream `package.json`
declares `engines`, so the wrong major does not fail cleanly — it produces opaque ESM errors
much later, and the agent will waste a cycle blaming something else.

## Step 2 — provision

```bash
./bin/provision.sh
./bin/provision.sh --check      # MUST report "all inputs present" and exit 0
```

This installs nothing system-wide. It unpacks a checksum-verified Temurin JDK 17 to
`runtime/jdk17`, Maven to `runtime/maven`, Keycloak to `$KEYCLOAK_HOME` (default
`/opt/keycloak`), and clones the six upstream repos at their pinned SHAs. You do not need a
system JDK 17 — only Keycloak needs a system JDK 21.

`--check` is the real gate. If it exits non-zero, the run cannot succeed; report its output
verbatim rather than proceeding. Note that a green `--check` proves the *inputs* are present —
it says nothing about whether the services start. Those are different failures and you should
not conflate them.

Expect 10–20 minutes, and do not assume a timeout means failure. A cold first start that builds
two React frontends is genuinely slow. If you must bound it, allow at least 40 minutes for
`up.sh --reset` before concluding anything is wrong.

## Step 3 — start

```bash
./bin/up.sh
```

Then confirm all six are actually up — **do not trust the script's own summary**, because
`up.sh` can report success while a service is wedged. Use the same probes `up.sh` uses, which
are the endpoints that actually answer rather than the ones you would guess:

```bash
while read -r name port route; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:$port$route" || echo 000)
  printf '  %-12s %s  %s  %s\n' "$name" "$port" "$code" "$route"
done <<'EOF'
keycloak     8180 /realms/BurdenReduction/.well-known/openid-configuration
test-ehr     8080 /fhir/metadata
crd          8090 /r4/cds-services
prior-auth   9015 /fhir/metadata
dtr          3005 /
crg          3001 /
EOF
```

All six must be `200`. Note the paths: `/fhir/metadata` on 8080 and 9015, not `/metadata`, and
`/r4/cds-services` on 8090. A `404` on those means you guessed the path, **not** that the
service is down. `3001` is the one that matters most: crg serves its runtime URLs from
`/env-config`, so if that is missing the browser will call the wrong hosts even though `/` works.

A `200` on all six is necessary and not sufficient. `up.sh` also runs post-flight checks —
dtr's `/clients` being non-empty, CRD actually advertising the `order-sign-crd` hook, the
value-set cache being reachable at CRD's concatenated path. Read its output; those are the
failures a naive probe waves through.

A `000` on `8180` almost always means Keycloak never imported the realm. The usual cause is
JDK 21 missing — `kc.sh` runs `$JAVA_HOME/bin/java`, and `env.sh` points `JAVA_HOME` at the
provisioned JDK 17, so `up.sh` has to override it per service. It is handled, but if you see
Keycloak fail, check that override first.

## Step 4 — verify

Both drivers. Both are required; neither covers the other.

```bash
./bin/demo.sh              # 12 assertions, API only    -> 12 passed, 0 failed
python3 bin/e2e-browser.py # 14 assertions, real browser -> 14 passed, 0 failed
```

`demo.sh` covers the API surface. It **cannot** cover the browser leg, and this is the single
most important thing to know about this repository: *dtr submits the Claim, not the EHR.*
Pressing **Proceed To Prior Auth** makes dtr's `QuestionnaireForm.outputResponse("completed")`
build a `Claim` from the QuestionnaireResponse, hand it to a `PriorAuth` panel, and only that
panel's `Submit` issues the `Claim/$submit` from the browser. Nothing in crg or test-ehr
references PAS at all, so grepping those two repositories for the PAS port returns nothing and
the browser leg looks impossible. It is not. `demo.sh` posts its own Claim and therefore can
never cover it; the two drivers submit *different* claims and neither is redundant.

`e2e-browser.py` needs Playwright, which the stack itself does not:

```bash
pip install playwright && playwright install chromium --with-deps
```

If that install is unavailable, report the API result (12/12) and state plainly that the
browser leg was not run. Do not infer it from `demo.sh`.

## Step 5 — report

State, explicitly:

- both driver results as pass counts, not adjectives;
- which services answered and on which ports;
- anything you could not verify, and why.

Then hand the user <http://localhost:3001/> and the browser walkthrough in `README.md`.

## Step 6 — stopping

```bash
./bin/down.sh              # stop all six
./bin/down.sh --purge      # also drop PAS and DTR state
```

`down.sh` sweeps the six ports and verifies ownership before killing anything, because the
recorded PIDs are not reliable: `mvn spring-boot:run` execs a separate JVM and Gradle
`bootRun` runs in a daemon tree, so the recorded process can die while its children keep the
port bound. Trust the port sweep, not the PID file. It leaves unrelated services alone — there
is a Next.js app on `:3000` on some machines that must survive.

## Traps that produce convincing but wrong results

These are ordered by how much time they cost. Most of them make something *look* healthy.

1. **A global `PORT=3001`** intended for crg silently drags dtr onto 3001, because dtr's
   `bin/www` reads `PORT` *before* `REACT_APP_SERVER_PORT`. crg then dies `EADDRINUSE` — and
   the stack still probes green, because dtr answers `/` with 200. Always pass `PORT` per
   service, never export it.
2. **`up.sh` reporting success.** It probes. See step 3; probe independently.
3. **A green `demo.sh` with Keycloak dead.** Every API-level test in this repo runs with
   `use_oauth: false` and `checkJwt: false`, so nothing asks Keycloak for a token. The stack
   will pass 12/12 with `:8180` completely dead and only fail on the first browser click.
   Absence of failure in the tests you ran is not evidence of absence in the paths you did not
   run.
4. **A green run that is not reproducible.** `e2e-browser.py` clears
   `docs/screenshots/e2e/` at the start of every run, so a green run always leaves
   `git status` dirty on some PNGs — 08 and 09 always, and 02/04/07 often. This is expected.
   `git checkout -- docs/screenshots/e2e/` restores the committed set. Do not commit whatever
   the last run produced, and do not report the dirty tree as a problem.
5. **`pkill -f <pattern>`** matches the command line of the shell invoking it, so it kills the
   agent's own shell — and takes a service down as collateral. Kill by PID, or use a pattern
   the invoking command cannot match. This has already happened here once.
6. **The VSAC cache directory losing its trailing slash.** Both file stores build the cache
   path by plain string concatenation, with no separator. Without the slash every value set
   misses while the boot log cheerfully reports all 65 as added, and you get a questionnaire
   with zero answer options. `env.sh` enforces the slash; do not remove that.
7. **CDS-Library placement is per-service and getting it wrong is a hard exit.** CRD needs the
   *whole* library at `repos/CRD/server/CDS-Library/`. PAS needs only `PriorAuth/`, at
   `repos/prior-auth/CDS-Library/`. Do not run `embedCdsLibrary` — it deletes the directory and
   re-clones unpinned master.
8. **CORS.** Upstream's `corsOrigins` list is 3000/3002/3005 and does **not** include 3001, so
   a browser on 3001 is CORS-blocked by CRD. `env.sh` sets `CORS_ORIGINS`, and relaxed binding
   *replaces* the whole list rather than appending — so if you override it, you must re-list
   every origin you still need.
9. **`security.auth_redirect_host` must stay empty** in the Keycloak realm config. Upstream
   uses the value as the full `scheme://host:port` prefix, so a bare hostname produces a
   `redirect_uri` with no scheme and Keycloak rejects it. Empty means "derive from the
   request", which is both correct and DHCP-proof.
10. **The realm needs 26 SMART client scopes** or Keycloak rejects the `authorize` request
    outright. The scope list the DTR UI sends is not standard OIDC, so this is not guessable.

## Known, accepted limitations

State these if asked; do not try to fix them.

- CRD cannot resolve the CQL references `ALTERNATIVE_THERAPY`,
  `RESULT_QuestionnaireAdditionalUri` and `RESULT_QuestionnairePARequestUri` in
  `HomeBloodGlucoseMonitorRule`, so the dtr form arrives un-prefilled. Upstream defect.
- Without a `VSAC_API_KEY`, 67 value sets do not resolve and value-set-gated CDS rules cannot
  fire.
- The full prior-auth decision takes about 15 seconds (`DELAY=15000` in `env.sh`).
- Linux only. Windows and macOS are not supported.

## If something is genuinely wrong

Before escalating, re-run `./bin/provision.sh --check`. A surprising share of "the stack is
broken" reports are actually a missing input, a service that never finished building, or one
of the ten traps above. `TEST-FLOW.md` has the full runbook and a per-symptom table; `logs/`
has one log per service. Quote the actual error text — do not paraphrase a failure you have
not read.
