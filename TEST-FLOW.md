# DaVinci Prior Auth Mock — Complete End-to-End Test Flow
A step-by-step script that a user can follow, verbatim, to reproduce everything
we validated: the frozen API path (`demo.sh`, 12 assertions) **and** the interactive
browser path through to a PAS decision (`e2e-browser.py`, 14 assertions).

This assumes you're in the project directory and the shell is bash/zsh. All
commands are idempotent and avoid /tmp where possible.

> **If you just cloned this repo, start at §0.** Nothing under `repos/` or
> `runtime/` is in git — 1.2 GB of upstream clones and a 337 MB toolchain are
> excluded on purpose, and re-created by `bin/provision.sh` from `versions.lock`.
> Skipping §0 and running `bin/up.sh` will fail on a missing CDS-Library.

## Prerequisites
Reference system: **Ubuntu 24.04.5 LTS, x86_64, glibc 2.39, 12 vCPU, 7 GB RAM** — see
`README.md` §Requirements for the full table of provisioned and system versions.

1. Ubuntu 24.04 LTS or a close relative. Any modern glibc Linux works; Windows and macOS do not.
2. `ss`, `curl`, `python3`, `unzip`, `git`, `node` (major 22) and a system JDK **21** (for
   Keycloak) are available. `bin/provision.sh` checks each and prints the install line if missing.
3. Enough disk for the toolchain: **~2.5 GB** for `runtime/` (Temurin JDK 17 + Maven) and
   `repos/` (1.2 GB), plus Keycloak (~190 MB, default `/opt/keycloak`). The Gradle/Maven
   caches, the VSAC cache and Keycloak are deliberately kept **off** the project folder —
   see §12 and `bin/env.sh` — so put them on fast local disk.
4. Clone onto a normal **ext4** filesystem, not a virtualised or network mount. A 9p/DrvFs
   mount was measured ~260× slower for small-file writes (2000 files: 9.85 s vs 0.04 s) and
   roughly triples the cold-start time.
5. Run every command below from the repository root.

## 0. Provision the inputs (fresh clone only)

This repo is the *orchestration*, not the payload. The six upstream repos, the JDK, Maven and
Keycloak are all excluded from git and re-created from `versions.lock`, which pins every one of them
by full 40-char SHA with a checksum.

```bash
./bin/provision.sh            # clone what is missing, verify what is present
./bin/provision.sh --check    # verify only, never downloads; exit 1 if anything is missing
```

A healthy tree looks like this — the first run of a fresh clone reports 8 missing:

```
== 1/4  upstream clones ==
  ok   CDS-Library             560403a97a4c50248713fad90314faaeeff7977d
  ok   CRD                     43547c4e69052df4d3532972e4bd03f8d5317d13
  ok   crd-request-generator   87e98bf9af4fb528b624171edbe702880e325c59
  ok   dtr                     7acf79a6f89bfe9e88c30e9d4b531f647ce09c41
  ok   prior-auth              848f28c11d8efb4e253b70cfbbc485acf9acd1a0
  ok   test-ehr                e3f07ce4d81063e99e475cccaedba93becb8ef1d
== 2/4  JDK 17.0.20.1+1  ->  runtime/jdk17 ==   ok present Temurin-17.0.20.1+1
== 3/4  Maven 3.9.9  ->  runtime/maven ==      ok present Apache Maven 3.9.9
== 4/4  Keycloak 26.7.4 + Node 22 + JDK 21 ==   ok present at /opt/keycloak
```

Three things it deliberately does *not* do, because each has bitten this project:

- **It does not install Node or the JDK 21.** Both are system-level here; it asserts them and tells
  you the `apt-get` line if absent. Keycloak needs **JDK 21** even though the stack runs on 17,
  because `kc.sh` runs `$JAVA_HOME/bin/java` and `bin/env.sh` points `JAVA_HOME` at 17 — `bin/up.sh`
  overrides it per-service for exactly that reason.
- **It does not place the CDS-Library.** Where each service expects it is service-specific and
  getting it wrong is a hard boot exit; that logic is in `bin/up.sh`, not here.
- **It does not reuse `bin/clone.sh`'s "already cloned" answer.** `clone.sh` exits 0 for a checkout
  at *any* commit, so a stale clone is invisible to it. `provision.sh` re-verifies all six SHAs
  itself and, on a mismatch, prints the exact `git fetch` line to repair it. Run `--check` after any
  manual `git` work inside `repos/`.

**Pin discipline:** `versions.lock` is the run version. Do not bump a SHA to "catch up with
upstream" without re-running both drivers in §5/§6 and making a new tag. The published run version
is `run-2026-09-27`.

## 1. Clean slate (optional but safest)
```bash
cd /path/to/davinci-mock      # the repository root
./bin/down.sh --purge
```
Expected: all six stack ports become free, on-disk PAS/DTR state purged.

## 2. Cold start (build only if needed, then launch all six)
```bash
./bin/up.sh --reset
```
This does:
- Clears PAS `repos/prior-auth/databaseData/` and DTR `repos/dtr/databaseData/` (recreates the latter so lowdb can write safely)
- Sets per-service heaps and CORS; never exports a global `PORT`
- Starts Keycloak (8180), test-ehr (8080), CRD (8090), PAS (9015), DTR (3005), crg (3001)
- Seeds the VSAC value-set cache so dtr questionnaires can render (see §12)
- One-time npm builds for DTR/crg if `node_modules` are missing
- Post-flight assertions:
  - dtr has a registered client in `databaseData/db.json`
  - CRD advertises `order-sign-crd`
  - PAS has seeded itself (Rules table > 0)
  - the VSAC cache is readable at the *concatenated* path crd actually builds (§12)

Expected end block:
```
SERVICE                  PORT   PROBE                              STATE
---------------------------- ------ ------------------                 ------
test-ehr                 8080   http://localhost:8080/fhir/metadata UP
crd                      8090   http://localhost:8090/r4/cds-services UP
prior-auth               9015   http://localhost:9015/fhir/metadata UP
dtr                      3005   http://localhost:3005/             UP
crd-request-generator    3001   http://localhost:3001/             UP
==> post-flight checks (green readiness is not the same as a working stack)
  ok dtr client registered: [...]
  ok crd advertises order-sign-crd
  ok pas seeded itself (39 rules)
```

Total cold start ~5-6 minutes on a slow/virtualised mount; 2-4 minutes on local ext4. On
the very first run, add the one-off npm install and webpack builds for dtr and crg
(20-40 min on a 9p mount). Be patient.

## 3. Quick sanity probes (manual)
```bash
# Readiness
curl -s -o /dev/null -w 'test-ehr metadata: %\{http_code\}\n' http://localhost:8080/fhir/metadata
curl -s -o /dev/null -w 'CRD cds-services: %\{http_code\}\n' http://localhost:8090/r4/cds-services
curl -s -o /dev/null -w 'PAS metadata:     %\{http_code\}\n' http://localhost:9015/fhir/metadata
curl -s -o /dev/null -w 'DTR root:         %\{http_code\}\n' http://localhost:3005/
curl -s -o /dev/null -w 'CRG root:         %\{http_code\}\n' http://localhost:3001/

# CRD advertises the hook
curl -s http://localhost:8090/r4/cds-services | grep -c 'order-sign-crd'

# PAS self-seeded
curl -s http://localhost:9015/fhir/debug/Rules | grep -c '<tr>'
curl -s http://localhost:9015/fhir/debug/Client | grep -c '<tr>'

# DTR has a client registered
curl -s http://localhost:3005/clients | python3 -m json.tool
```
Expected: all 200s; `order-sign-crd` count >=1; Rules rows >=40 (header + 39); Clients rows >=2; DTR `/clients` non-empty.

## 4. Interactive browser path (the mock EHR UI) — VERIFIED WORKING in Chromium
Open in a browser: `http://localhost:3001/` (all six services bind `0.0.0.0`, so this also
works from any browser on the same host). Exact sequence, as driven end-to-end:

1. Click **`PATIENT SELECT`**. A modal lists patients (pat015, pat1234, pat014, pat016, pat013…).
2. In the **pat013 tile** (Vlad Quinton, 69, male), use its `Select a request...` dropdown and
   choose **`E0607 (DeviceRequest) Home blood glucose monitor`**. Each patient tile has its own
   dropdown, so pick the one in the pat013 tile.
3. Click **`Click to select this patient`** on that same tile. The modal closes and the header
   fills in: `pat013 / Vlad Quinton / 69 / male / E0607 HCPCS`, and the Prefetched list shows
   `Coverage/cov013`, `DeviceRequest/devreq037`, `Practitioner/pra1234`, `Patient/pat013`,
   `Practitioner/pra-hfairchild`.
4. Click **`SUBMIT TO CRD AND DISPLAY CARDS`**. Wait ~10-20s (CRD rule evaluation).
5. The card renders:
   ```
   Documentation Required
   Launch DTR to complete the required questionnaire(s):
   COMPLETE HOMEBLOODGLUCOSEMONITORORDER IN DTR
   Summary: Home Blood Glucose Monitor: Documentation Required.
   ```
   Screenshot: `docs/screenshots/01-crd-card.png`
6. Clicking `COMPLETE HOMEBLOODGLUCOSEMONITORORDER IN DTR` opens a new tab, lands on the real
   Keycloak login page, and after signing in (`dtr` / `dtr-demo`) the questionnaire renders.
   Screenshots: `docs/screenshots/04-keycloak-login.png`, `03-dtr-questionnaire.png`.
   (The historical failure at this point, an empty `:8180`, is
   `02-dtr-launch-failure.png` — diagnosis in §7, install in §12.)
7. Fill the form, then click **`PROCEED TO PRIOR AUTH`**. This is the button that was missing
   from every earlier write-up, and it is what actually reaches PAS — see §13.

Everything through the card and into the dtr form is browser-driven and works. The form arrives
un-prefilled, because CRD cannot resolve three CQL expression references in
`HomeBloodGlucoseMonitorRule` (see the end of §12) — fill the fields in and it is a usable
questionnaire. `bin/e2e-browser.py` does the filling and the last three steps for you; §13 has the
mechanics.

## 5. Direct API path — the frozen demo (recommended, deterministic, no browser)
This is the same path the demo script automates. Each step can be run by hand.

### 5a. Confirm the demo patient/order exist
```bash
# Patient (note: Quinton is the FAMILY name; birthDate is 1956-12-01)
curl -s http://localhost:8080/fhir/Patient/pat013 | python3 -c 'import json,sys;d=json.load(sys.stdin);n=d["name"][0];print(n["given"],n["family"],d.get("birthDate"),d.get("gender"))'
# Expected: ['Vlad', 'Alan', 'Nestor'] Quinton 1956-12-01 male

# The draft order that the prefetch submits
curl -s http://localhost:8080/fhir/DeviceRequest/devreq037 | python3 -c 'import json,sys;d=json.load(sys.stdin);print("status:",d["status"],"| subject:",d["subject"]["reference"],"| insurance:",d["insurance"][0]["reference"])'
# Expected: status: draft | subject: Patient/pat013 | insurance: Coverage/cov013

# That Coverage, and the fact pat013 has exactly one
curl -s http://localhost:8080/fhir/Coverage/cov013 | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["resourceType"],d["id"],d["status"])'
# Expected: Coverage cov013 active
curl -s "http://localhost:8080/fhir/Coverage?beneficiary=Patient/pat013" | python3 -c 'import json,sys;print("coverages:",json.load(sys.stdin).get("total"))'
# Expected: coverages: 1
```
Note: `Coverage/351` and `ServiceRequest/402` do **not** exist in this FHIR server
(HAPI-2001). If you see those in older notes, they are stale.

### 5b. Step 1 — CRD returns a card (order-sign-crd)
```bash
curl -s -o state/card.json -w 'HTTP %{http_code}\n' \
  -H 'Content-Type: application/json' \
  -d @fixtures/order-sign-prefetch.json \
  http://localhost:8090/r4/cds-services/order-sign-crd
```
Then:
```bash
python3 - <<'PY'
import json
c=json.load(open('state/card.json'))['cards'][0]
print('summary      :', c['summary'])
print('indicator    :', c['indicator'])
for s in c.get('suggestions',[]):
    for a in s.get('actions',[]):
        def walk(e):
            if isinstance(e,dict):
                if e.get('url')=='questionnaire': return e.get('valueCanonical')
                for v in e.values():
                    r=walk(v)
                    if r: return r
            elif isinstance(e,list):
                for v in e:
                    r=walk(v)
                    if r: return r
        for ext in (a.get('resource',{}) or {}).get('extension',[]) or []:
            q=walk(ext)
            if q: print('questionnaire:', q)
PY
```
Expected:
```
summary      : Home Blood Glucose Monitor: Documentation Required.
indicator    : info
questionnaire: http://localhost:8090/fhir/r4/Questionnaire/HomeBloodGlucoseMonitorOrder
```

### 5c. Step 1b — The SMART launch handshake (what the "Launch DTR" button does first)
The mock EHR UI (crg) POSTs to the FHIR server's Launch endpoint before opening DTR:
```bash
curl -sL -X POST -H 'Content-Type: application/json' \
  -d '{"launchUrl":"http://localhost:3005/launch","parameters":{"patient":"pat013"}}' \
  http://localhost:8080/test-ehr/r4/_services/smart/Launch
```
Expected: `{"launch_id":"<uuid>"}` (HTTP 200 after following one 307).
The URL the browser will open is:
```
http://localhost:3005/launch?launch=<launch_id>&iss=http://localhost:8080/test-ehr/r4
```

### 5d. Step 2 — PAS `$submit` the provider bundle
The file `repos/prior-auth/src/test/resources/bundle-items.json` is the provider's
two-item prior-auth request (two auth items) for `pat013`/glucose monitor.
```bash
curl -s -o state/claimresponse.json -w 'HTTP %{http_code}\n' \
  -H 'Content-Type: application/fhir+json' \
  -d @repos/prior-auth/src/test/resources/bundle-items.json \
  'http://localhost:9015/fhir/Claim/$submit'
```
Then:
```bash
python3 - <<'PY'
import json
d=json.load(open('state/claimresponse.json'))
for e in d.get('entry',[]):
    r=e.get('resource',{})
    if r.get('resourceType')=='ClaimResponse':
        print('outcome      :', r.get('outcome'))
        print('disposition  :', r.get('disposition'))
        print('preAuthRef   :', r.get('preAuthRef'))
        print('items        :', len(r.get('item',[])))
PY
```
Expected: HTTP 201, `disposition: Pending`, `items: 2`, and a `preAuthRef` (write it down — call it `<PREAUTH>`).

### 5e. Step 3 — Watch the async decision land (PENDING → GRANTED)
PAS schedules its decision on a timer (`DELAY=15000` ms). Two ways to watch it:

Option A (browser): open `http://localhost:9015/fhir/debug/ClaimResponse` and refresh.
You will see two rows for your `<PREAUTH>`: the newest first (granted) and the older
(pending, outcome A4 → A1). Sort is newest-first.

Option B (script, deterministic) — this is the reliable assertion:
```bash
PREAUTH='<paste-the-preAuthRef-here>'
for i in $(seq 1 30); do
  STATE=$(curl -s http://localhost:9015/fhir/debug/ClaimResponse \
    | python3 -c "
import re,sys
h=sys.stdin.read(); ref='$PREAUTH'
for row in h.split('<tr>'):
    if ref in row:
        m=re.search(r'\"disposition\"\s*:\s*\"(\w+)\"',row)
        if m: print(m.group(1).upper()); break
")
  echo "poll $i: $STATE"
  [ "$STATE" = "GRANTED" ] && break
  sleep 2
done
```
Expected: `GRANTED` within roughly 7–10 polls (~12–20s). The 15s `DELAY` is fixed; the
spread is just polling granularity against the timer. On the final row the outcome flips
A4→A1 (complete) and the disposition is `Granted`.

## 6. One-command version of §5b–§5e
`bin/demo.sh` performs steps 5b–5e with an assertion at every stage and exits non-zero on
any failure. Use this as your regression test:
```bash
./bin/demo.sh
```
Expected:
```
PASS  12 assertions, 0 failures
      card      Home Blood Glucose Monitor: Documentation Required.
      preAuth   <uuid>
      granted   GRANTED after 9 polls
```

## 7. The DTR browser hop — how it was diagnosed, and why the trace below now succeeds
**Corrected after a real browser trace (Playwright/Chromium).** An earlier version of this
document blamed the 404s on OAuth being absent. That is only half the story, and the true
remedy is different.

What the browser actually does, captured request by request:

```
GET  :3005/launch?launch=<id>&iss=…                     -> 200
GET  :3005/js/launch.bundle.js                          -> 200
GET  :3005/clients/                                     -> 200   (DTR resolves client "app-login")
GET  :8080/test-ehr/r4/.well-known/smart-configuration  -> 404   (fhirclient probes here)
GET  :8080/test-ehr/r4/metadata                         -> 200   (fhirclient RECOVERS via CapabilityStatement)
GET  :8080/test-ehr/auth?response_type=code&client_id=app-login&scope=launch…
                                                            -> 302  to
GET  http://localhost:8180/realms/BurdenReduction/protocol/openid-connect/auth?…
                                                            -> ERR_CONNECTION_REFUSED
=> browser lands on chrome-error://chromewebdata/  (blank error page)
```

So the 404 on smart-configuration is **survivable** — fhirclient falls back to the FHIR
CapabilityStatement and still finds an authorization URL. The real and only blocker is the last
hop: **nothing is listening on :8180**.

That address is hardcoded in the FHIR server, and its `/auth` proxy redirects there
unconditionally, regardless of the `use_oauth: false` flag
(`repos/test-ehr/src/main/resources/application.yaml:87-91`):

```yaml
realm: BurdenReduction
use_oauth: false
oauth_token:       http://localhost:8180/realms/BurdenReduction/protocol/openid-connect/token
oauth_authorize:   http://localhost:8180/realms/BurdenReduction/protocol/openid-connect/auth
proxy_authorize:   http://localhost:8080/test-ehr/auth
```

This is precisely the 7th service the original 7-service design included and that the mock
dropped. **To make the browser DTR form work, start Keycloak on :8180 with a `BurdenReduction`
realm and an `app-login` client** (public client, redirect URI `http://localhost:3005/index`,
plus the FHIR-side redirect). Keycloak's own dev-mode H2 needs no external database.
Do NOT write a bespoke OAuth stub — test-ehr's `/auth` proxies to the Keycloak URL verbatim, so
a stub would have to impersonate that exact realm path anyway.

**Status: INSTALLED 2026-09-27 — the "deliberately not installed" decision below was WRONG and is
kept only as the record of the mistake.** The reasoning was that nothing in the API path needs a
token, so Keycloak could wait until the browser DTR form was wanted. But the browser form *is* the
demo, and `demo.sh` passed 12/12 the whole time `:8180` was refusing connections: absence of a
failure in the tests you ran is not evidence of absence in the paths you didn't run. See §12 for the
install and `investigation-log.md` §4.9 for the full correction. The original plan was:

1. Download and unpack Keycloak (~400–600 MB) under `runtime/`.
2. `kc.sh start-dev` on **:8180** with a `BurdenReduction` realm (dev-mode H2, no external DB).
3. Create public client **`app-login`**, redirect URI `http://localhost:3005/index` (plus
   whatever the FHIR-side callback needs).
4. Add launch/stop to `bin/up.sh` / `bin/down.sh` and include :8180 in `STACK_PORTS`.

As built, step 1 went to ext4 (`/opt/keycloak`) instead of `runtime/`, because C: was at 99 %.
5. Re-run the browser trace (§7) to prove the DTR questionnaire actually opens and submits.

## 7a. Host-specific: reclaiming disk on a WSL2 dev box

> **Not needed on a plain Ubuntu install.** Kept as a record of the host this was built on,
> where the checkout sat on a 100 %-full Windows `C:` drive and the toolchain did not fit.
> On a normal ext4 filesystem, let `bin/provision.sh` use its defaults and skip this
> section entirely.

Filling C: is a shared-cost trap on that box, and the numbers are worth recording:

- **WSL never returns vhdx space to Windows automatically.** Freeing 8.1 GB inside the
  filesystem (npm cache 9.7 G → 1.6 G) moved C: from 385 MB to *332 MB* — it went **down**.
  Only a vhdx compact gives the space back.
- **Stale WSL swap files sit in Windows Temp** and are worth real space. Eight were found
  (`%LOCALAPPDATA%\Temp\<guid>\swap.vhdx`); seven were dead, totalling 2.1 GB, and were deleted.
  The live session's file is the one whose mtime is within the last hour — **never delete that
  one**. Guard with an age check, e.g.:
  ```bash
  for f in /mnt/c/Users/<you>/AppData/Local/Temp/*/swap.vhdx; do
    age=$(( $(date +%s) - $(stat -c %Y "$f") ))
    [ "$age" -lt 3600 ] && echo "SKIP live: $f" || rm -f "$f"
  done
  ```
- The ext4 vhdx measured 7.0 GB while the freed cache measured 8.1 GB, so those two numbers
  disagree. Do not trust either; measure C: after compacting.

To reclaim the in-filesystem space, run from **Windows** (PowerShell as Administrator) —
this stops the stack, so do it between runs. Substitute your own WSL distro GUID; the one
below is from the machine this was built on and is not meaningful elsewhere:

```powershell
wsl --shutdown
# then either:
Optimize-VHD -Path "$env:LOCALAPPDATA\wsl\{<distro-guid>}\ext4.vhdx"
# or, without the Hyper-V module:
diskpart
  select vdisk file="$env:LOCALAPPDATA\wsl\{<distro-guid>}\ext4.vhdx"
  attach vdisk readonly
  compact vdisk
  detach vdisk
  exit
# restart WSL, then: bin/up.sh --reset
```

## 8. Troubleshooting quick-reference
| Symptom | Cause | Fix |
|---|---|---|
| `up.sh` ERR "refusing to start: stale process owns a stack port" | A JVM from a previous run survived | `bin/down.sh` (it sweeps ports), then retry |
| PAS debug tables all 0 rows | A zombie PAS held the H2 file; new PAS couldn't open it | `bin/down.sh --purge` then `bin/up.sh --reset` |
| dtr `/clients` is `[]` | `repos/dtr/databaseData/` missing (lowdb won't mkdir) | fixed in `up.sh --reset`; if you see it, re-run `up.sh` |
| Card says "Documentation Required" with no DTR link | questionnaire canonical absent (CDS library or CRD path issue) | check `logs/crd.log`; verify `repos/CRD/server/CDS-Library/` exists |
| `$submit` returns 500 | PAS DB not up or rules missing | check `logs/prior-auth.log`; `curl :9015/fhir/debug/Rules` |
| Demo hangs at "poll async disposition" | PAS timer didn't fire | check `logs/prior-auth.log` for `generateAndStoreClaimResponse` |
| Disposition stays `PENDING` forever | Same as above; timer not running | see prior row |
| UI loads but every request fails **from another machine only** | `REACT_APP_*` never reached crg, so the UI fell back to the `localhost` URLs baked into the bundle at build time | `curl :3001/env-config` must name `$ADVERTISE_HOST`; restart with `ADVERTISE_HOST=<ip> bin/up.sh` (§11) |
| Remote browser gets 403 on `:8090` | origin not in the CORS allowlist | `env.sh` derives `CORS_ORIGINS` from global IPv4s; re-run `up.sh` after changing it |
| dtr questionnaire 500s: *"Is the VSAC_API_KEY set and valid?"* | CRD could not resolve a valueSet in the library's DataRequirements | `bin/seed-valuesets.sh`; the cache path **must end in a slash** (crd concatenates it with the filename, no separator) |
| Keycloak says *"Invalid parameter: redirect_uri"* | test-ehr's `security.auth_redirect_host` was set to a bare hostname | leave it EMPTY — `AuthProxy.java:170` then derives `scheme://host:port` from the incoming request, which is correct for any host |
| keycloak will not start on JDK 17 | `env.sh` pins `JAVA_HOME` to the project's JDK 17, and `kc.sh` runs `$JAVA_HOME/bin/java` | `up.sh` overrides `JAVA_HOME` to the system JDK 21 for that service only |
| `/env-config` names localhost but you opened the UI by IP | `REACT_APP_*` never reached crg, so it fell back to the build-time baked values | pass them through in `up.sh`; check `curl :3001/env-config` (§11) |
| `up.sh` fails on a missing CDS-Library or JDK | fresh clone: `repos/` and `runtime/` are not in git | `./bin/provision.sh` (§0), then `./bin/provision.sh --check` to confirm |
| `provision.sh` reports a SHA mismatch | someone moved a checkout in `repos/` by hand | `clone.sh`'s "already cloned" cannot detect this; take the `git fetch` line `provision.sh` prints |
| `git push` → `could not read Username for 'https://github.com'` | `git` has no credential helper and no TTY to prompt on | `git config --local credential.helper '!gh auth git-credential'` — repo-local on purpose, so your global `~/.gitconfig` is not rewritten |
| `git status` dirty on some PNGs after `e2e-browser.py` | expected: `08`/`09` always (runtime Claim id + wall clock), and `02`/`04`/`07` often. A green run does **not** reproduce the committed set byte-for-byte | `git checkout -- docs/screenshots/e2e/` to restore the committed good pass; not a regression |

## 9. Port map (for firewalls / conflicts)
| Service | Port | What it is |
|---|---|---|
| test-ehr | 8080 | mock FHIR R4 server (in-memory H2) |
| CRD | 8090 | coverage rules + CDS Hooks |
| PAS | 9015 | prior auth; own H2 on disk; `$submit` |
| Keycloak | 8180 | realm `BurdenReduction`, client `app-login`; the auth hop the DTR browser path needs (§7, §12) |
| DTR | 3005 | SMART app (React/Node) |
| crd-request-generator | 3001 | mock EHR UI (React/Node) |
| (unrelated) Next.js | 3000 | not part of this stack; must not be touched |

## 10. One-paragraph summary
1. `down.sh --purge` → `up.sh --reset` (cold, ~5-6 min, 6 UP + post-flight green)
2. `demo.sh` → 12 assertions pass: card returned, questionnaire canonical present, SMART launch_id issued, `$submit` 201 with 2 items, `PENDING` → `GRANTED` on the timer
3. `e2e-browser.py` → 14 assertions pass: the same flow driven through a real browser — crg at `:3001` → `pat013` + glucose order → card → DTR launch → real Keycloak login page (`dtr` / `dtr-demo`) → questionnaire filled → **Proceed To Prior Auth** → PAS `201` → `Pending` → `Granted`. This is the leg `demo.sh` cannot reach, because here the Claim is built by dtr, not by the test script.

## 11. Reaching the stack from another machine (`0.0.0.0`)

All six services bind `0.0.0.0`. Verify by deriving the port list rather than hardcoding it — a
hardcoded list is exactly how `:8180` came up "missing" once already, because Keycloak was not in
the string:

```bash
source bin/env.sh && ss -ltnp | grep -E ":($(echo "$STACK_PORTS" | tr '|' '|'))[[:space:]]"
```

`env.sh` also adds every global IPv4 in every stack port to `CORS_ORIGINS`. That is necessary but
**not sufficient** — the browser decides which host to call, and the UI is handed its backend
URLs at runtime.

```bash
# discover this host's LAN address
ip -4 -o addr show scope global | awk '{print $4}'
# => 192.168.1.50/24

# default: advertise localhost (correct for a browser on the same machine)
bin/up.sh

# LAN mode: advertise the address the remote browser will actually dial
ADVERTISE_HOST=192.0.2.10 bin/up.sh
```

In LAN mode the UI at `http://192.0.2.10:3001` works end to end (verified in Chromium from
that origin: `pat013` + E0607 → "Home Blood Glucose Monitor: Documentation Required.", 20 of 20
backend calls to the LAN address).

### The trap worth knowing about

crg's `server.js` serves `/env-config` straight from `process.env.REACT_APP_*` and **deletes any
key that is null**. `up.sh` used to launch crg with only `NODE_ENV`/`PORT`, so every key was
null, every key was dropped, and the UI silently fell back to the `localhost:8080`/`localhost:8090`
values baked into the webpack bundle at build time. `up.sh` now passes the `REACT_APP_*` values
through explicitly. Symptom if this ever regresses: the page loads, the patient list even
populates when the browser happens to be on the same host, and only a *remote* browser finds every
call aimed at its own localhost. Check `curl :3001/env-config` — if it does not name the advertised
host, the vars are not reaching the process.

`REACT_APP_INITIAL_CLIENT` is derived from the same `ADVERTISE_HOST` on purpose: the SMART `iss`
the UI sends must equal the client name DTR registered, otherwise DTR's `clients[iss]` lookup finds
neither the issuer nor a `default` entry and refuses to launch. Both entries coexist in
`/clients` after a mode switch, so flipping back and forth is safe.

### Firewall
Nothing in the stack opens ports — that is the host firewall's job (`ufw`, `firewalld`, or
whatever is in front of it). If a second machine cannot connect, allow inbound
3001/3005/8080/8090/9015 and prefer a scoped allow for the specific subnet over a blanket
rule, since this exposes a mock FHIR server and PAS.

## 12. Keycloak + the VSAC value-set cache (what the dtr hop actually needs)

The dtr browser hop is a three-party dance, and two of the three parties are easy
to mistake for optional:

```
crg :3001  ──▶  test-ehr /auth  ──▶  Keycloak :8180  ──▶  login  ──▶  back to :3005
   (card)        (OAuth proxy)      (realm + client)
```

`use_oauth: false` in test-ehr's `application.yaml` does **not** make the proxy
optional. The card builds fine without any of this — the order-sign hook never
expands a value set — so the stack looks completely healthy right up until you
click through, and then it fails.

### Install (once)

Keycloak is deliberately **not** in this project folder: it defaults to
`$KEYCLOAK_HOME` (`/opt/keycloak`) on local disk rather than the project tree, so a slow or
nearly-full checkout filesystem cannot strand it. `bin/provision.sh` does this for you and
verifies the result; the manual equivalent is:

```bash
curl -L -o kc.zip \
  https://github.com/keycloak/keycloak/releases/download/26.7.4/keycloak-26.7.4.zip
unzip -q kc.zip -d /opt && mv /opt/keycloak-26.7.4 /opt/keycloak && rm kc.zip
```

Needs **JDK 21**; `up.sh` points `JAVA_HOME` at `/usr/lib/jvm/java-21-openjdk-amd64`
for that one service, because `env.sh` otherwise pins the project's JDK 17 and
`kc.sh` runs `$JAVA_HOME/bin/java`.

Realm and client come from `fixtures/keycloak/BurdenReduction-realm.json` (copied
into `$KEYCLOAK_HOME/data/import/` on every `up.sh`; import only fires when the
realm is absent). It defines:

- realm `BurdenReduction`, `sslRequired: none`, strict-hostname off so both
  `localhost:8180` and `<lan-ip>:8180` work
- public client `app-login` (PKCE `S256`), plus `app-token` for test-ehr itself
- **26 SMART client scopes.** Without them Keycloak rejects the authorize request
  outright, because the scope list the UI sends
  (`launch user/Observation.read patient/Coverage.read …`) is not standard OIDC.
- test user **`dtr` / `dtr-demo`**

```bash
curl :8180/realms/BurdenReduction/.well-known/openid-configuration   # 200 = realm is there
```

### The value-set cache

`$questionnaire-package` throws on the first valueSet it cannot resolve
(`QuestionnairePackageOperation.java:333`), and "cannot resolve" means "ask
VSAC", and VSAC wants an API key. `bin/seed-valuesets.sh` pre-seeds the 65 value
sets the library references from the public `tx.fhir.org` instead — no signup.

```bash
./bin/seed-valuesets.sh     # ~30 s cold, then a no-op; asserts the 3 the demo needs
```

**The trap:** `…/r4/ValueSet?url=…` returns the value set **unexpanded**
(`expansion.contains == 0`). Caching that silences the error and yields a
questionnaire with **zero answer options** — a mock that looks right and is
quietly wrong. The seeder uses the `$expand` operation and refuses to write a
file unless `expansion.contains > 0`.

**The other trap:** both file stores build the cache path by plain string
concatenation — `CdsConnectFileStore.java:315` and `LocalFileStore.java:171` do
`getValueSetCachePath() + filename`, no separator. Upstream's default
`ValueSetCache/` ends in a slash by luck, so a tidy override without one yields
`/root/.cache/davinci-mock/vsac-cacheValueSet-R4-<oid>.json` and every lookup
misses while the boot log cheerfully reports all 65 as added. `env.sh` therefore
forces the trailing slash, and `up.sh` asserts the concatenated path is readable.

### Verified end to end

From `http://192.0.2.10:3001` in Chromium: card → DTR launch → **real Keycloak
login page** → sign in → `http://192.0.2.10:3005/index` → the
*Home Blood Glucose Monitor Order* questionnaire renders with real value-set
content (e.g. *"Type 2 diabetes mellitus with diabetic nephropathy — E11.21"*,
*"COPD, unspecified — J44.9"*). Screenshots: `docs/screenshots/04-keycloak-login.png`,
`03-dtr-questionnaire.png`.

One known blemish remains, and it is **not** one of the above: dtr shows
*"Problems occurred while prefilling this request"* because CRD cannot resolve the
CQL expression references `ALTERNATIVE_THERAPY`, `RESULT_QuestionnaireAdditionalUri`
and `RESULT_QuestionnairePARequestUri` in `HomeBloodGlucoseMonitorRule`. The form
loads and is fillable; it just arrives empty. This was present in the CRD log
before any of the Keycloak work and looks like an upstream library-loading gap.

If you would rather use a real VSAC key, set `VSAC_API_KEY` and it takes
precedence over the cache.

## 13. The last leg: how the browser path actually reaches PAS

For a long time every write-up stopped at "the questionnaire renders", and the
last log line in the session was `POST /fhir/R4/questionnaireresponse` → stored.
PAS had never seen a claim from the browser. It turns out the missing step is one
button, and the reason it was easy to miss is that **dtr, not the EHR, submits the
claim**.

`QuestionnaireForm.outputResponse("completed")` — wired to the **`PROCEED TO PRIOR
AUTH`** button — does three things in order (`QuestionnaireForm.jsx:1369-1508`):

1. builds `priorAuthBundle` from the launch-context bundle, unshifting
   `insurer`, `managingOrg`, `facility`, the `DeviceRequest` and the
   `QuestionnaireResponse`;
2. constructs a `Claim` from scratch — `use: preauthorization`, one `item` whose
   `productOrService` comes from the order, `insurance` pointing at the
   `Coverage`, `supportingInfo` referencing the `QuestionnaireResponse`;
3. calls `setPriorAuthClaim(bundle)`, which makes `App.jsx:813` **replace the whole
   form** with `<PriorAuth claimBundle={...} />`.

That panel has its own **`Submit`** button, and only that button POSTs
`Claim/$submit` (`PriorAuth.jsx:556`). So the flow is: form → *Proceed To Prior
Auth* → claim panel → *Submit*. No third service is involved, and there is no
"send to PAS" control anywhere in crg or test-ehr.

Verified end to end, 2026-09-27:

```
crg :3001  pat013 + E0607 -> card "Documentation Required"
  -> dtr :3005 launch -> Keycloak :8180 (dtr / dtr-demo) -> questionnaire
  -> fill 17 required questions -> PROCEED TO PRIOR AUTH
  -> dtr builds the Claim -> Submit
  -> POST :9015/fhir/Claim/$submit   HTTP 201  disposition=Pending outcome=queued
  -> $inquire x3                     disposition=Granted
```

Server side, `logs/prior-auth.log`, same run — the 15 s `DELAY` timer as always:

```
16:40:39.835  POST /Claim/$submit fhir+JSON
16:40:39.918  generateAndStoreClaimResponse(c37fe4f8…/0M987654001AZ, disposition: PENDING)
16:40:54.960  generateAndStoreClaimResponse(46204484…/0M987654001AZ, disposition: GRANTED)
```

### Running it

```bash
python3 bin/e2e-browser.py            # 14 assertions, ~3 min
python3 bin/e2e-browser.py --headed   # watch it
```

Playwright 1.58 with its bundled Chromium is already in `~/venv`. On failure it
dumps `docs/screenshots/e2e/`: numbered screenshots, `body-at-failure.txt`, and
`form-container.html` / `form-fields.json` (the rendered LForms DOM).

### Four things that will bite anyone writing this again

**The prior-auth base URL is wrong on any non-localhost origin.**
`PriorAuth.jsx:34` picks it with
`window.location.hostname === "localhost" ? "http://localhost:9015/fhir" : "https://prior-auth.davinci.hl7.org/fhir"`.
So from a LAN origin (`:3005` on `192.0.2.10`, the mode in §11) the panel
offers the **public** PAS, not yours. The `Select PriorAuth Endpoint` text field
is editable, so the test overwrites it with the page's own host. A demo should
not rely on someone noticing that.

**The claim is not prefilled, and neither are the dates.** LForms renders text
inputs as `id="<linkId>/1/1"`, but the date pickers are ng-zorro
`<nz-date-picker>` elements that put `id="<linkId>/1/1"` on the **wrapper** and
leave the inner input with only a generated `ng-tns-*` class. Filling them by
document index looks reasonable and is wrong: the widget re-renders as each date
commits, so `nth(1)`, `nth(2)` and `nth(3)` were stale by the time they were
typed and three of the five dates silently never landed. Nothing complains. Target
`nz-date-picker[id^="<linkId>"] input` and press `Enter` to commit.

**Verify the form from the QuestionnaireResponse, not from the inputs.** The
choice widgets are AjaxAutocomplete (`.lhc-tools-searchResults` popup, inside
`lhc-autocomplete`), and the multi-select ones replace the input with a selected
list — so a chosen answer never appears in `input_value()`. The only honest check
is to read back what LForms itself thinks the answer is:

```js
window.LForms.Util.getFormFHIRData('QuestionnaireResponse', 'R4', '#formContainer')
```

`e2e-browser.py` asserts all 17 required linkIds are present in that structure
before it clicks anything. That check is what caught the three missing dates.

**Do not select the patient tile by its centre.** The tile is a row —
`[Patient Info (onClick) | Divider | Request Selection]` — and the "Click to
select this patient" caption is inside the *Patient Info* box while the request
dropdown is in a **sibling**. So the row is the only common ancestor, and
clicking its centre hits the Divider. Two earlier attempts failed here in
 instructive ways: a Playwright `div.filter(...)` chain matched a different
patient and selected pat015, and a JS "innermost ancestor containing the id"
climb walked past the tile into the whole grid — whose text also contains
`pat013` — so the centre-click landed mid-grid on pat015 again. What works is
tagging the DOM in JS: climb from the `pat013` text node to the row (identified by
holding exactly one request dropdown *and* the caption), then tag the
`Patient Information` ancestor separately and click that.

### Also worth knowing

- **PAS needs no CORS configuration.** It has no `addCorsMappings` at all, and
  answers with `Access-Control-Allow-Origin: *`, preflight included. Checked
  because dtr's submit is cross-origin and the source suggested a blocker; there
  isn't one.
- **The claim carries a different patient id.** PAS logs show
  `0M987654001AZ`, not `pat013` — dtr builds the bundle from the SMART launch
  context, and that `Patient` is the one the context carried. Expected, not a bug.
- **One value set still 404s** in the browser console:
  `cts.nlm.nih.gov/fhir/ValueSet/2.16.840.1.113762.1.4.1219.84`. It does not stop
  the flow, and the form still has real options, but it is the residue of the
  unresolved-CQL blemish above.
