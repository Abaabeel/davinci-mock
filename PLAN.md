# DaVinci Prior Auth — E2E Mock Stack

**Goal:** a locally-runnable mock of the HL7 DaVinci prior authorization flow (CRD → DTR → PAS),
good enough to demo in front of an audience, structured so the fake pieces can later be swapped
for real ones.

**Status:** Phases 0, 1 and 2 complete. **All 6 services run natively from this folder, and the
full CRD → DTR → PAS chain is verified end to end in a real browser** — card, SMART launch, Keycloak
login, questionnaire, and a `Claim` that dtr builds for itself, accepted by PAS at `201` and
resolved `Pending` → `Granted`. Phases 3–4 not started.
**Date:** 2026-09-27 (Phase 2b; see `investigation-log.md` §4)

---

## 0b. Phase 2b result — six services, and the browser chain closed

Phase 2's five services are joined by **Keycloak 26.7.4 on `:8180`**. It was originally retired on
the reasoning that nothing in the stack asks it for a token. That was wrong: not one *API-level*
test needs a token, so the stack stayed green with `:8180` dead and only failed when a browser
clicked through. Details and the full correction in `investigation-log.md` §4.

| svc | port | what it now proves |
|---|---|---|
| test-ehr | 8080 | FHIR 4.0.1 + the OAuth proxy that fronts Keycloak |
| crd | 8090 | `order-sign-crd` returns the Documentation Required card |
| pas | 9015 | `$submit` 201, CQL rules decide `Pending` → `Granted` on the 15 s timer |
| dtr | 3005 | SMART app: login, questionnaire, **and the Claim that reaches PAS** |
| crg | 3001 | the mock EHR UI that drives the demo |
| keycloak | 8180 | realm `BurdenReduction`, client `app-login`, user `dtr`/`dtr-demo` |

Two drivers, and they are not redundant — they submit *different* claims:

```
bin/demo.sh              12 assertions   API only; posts bundle-items.json itself
bin/e2e-browser.py       14 assertions   real browser; dtr builds the Claim
```

`e2e-browser.py` is the one that closes the flow, because **dtr, not the EHR, submits the claim**:
`PROCEED TO PRIOR AUTH` builds a `Claim` from the QuestionnaireResponse and swaps the form for a
panel whose `Submit` button is the only thing in the stack that POSTs `Claim/$submit` from a
browser. Nothing in crg or test-ehr references PAS at all, which is why this leg was never
discovered by reading those two repos.

Three things Phase 2b added to this plan:

- **`security.auth_redirect_host` must stay empty.** `AuthProxy.java:170` uses it as the whole
  `scheme://host:port`; a bare hostname yields a redirect Keycloak rejects. Empty means "derive from
  the request", which is also DHCP-proof.
- **`VSAC_CACHE_DIR` must keep its trailing slash**, and a value set must never be cached
  unexpanded. Both file stores concatenate the cache path with no separator, and an unexpanded entry
  silences the error while yielding a questionnaire with zero answer options.
- **Keycloak lives on ext4 at `/opt/keycloak`, not in this folder** (the original host's checkout volume was nearly full), needs JDK 21,
  and gave `down.sh` a second ownership root.

---

## 0. Phase 2 result — reproducible from this folder, nothing in /tmp

`/tmp/davinci-scratch` was wiped between sessions, so the whole stack now lives in this folder:
`runtime/` (JDK 17, Maven 3.9.9), `repos/` (6 SHA-verified clones), `bin/` (`env.sh`, `up.sh`,
`down.sh`, `clone.sh`), `logs/`, `pids/`, `state/`. One command brings the stack up:

```
bin/up.sh              # 5 services, dependency order, real readiness probes
bin/up.sh --reset      # …and clear PAS H2 + DTR lowdb first
bin/down.sh [--purge]
```

All five verified up, and the two silent-failure steps re-proved: the CRD card
(`Home Blood Glucose Monitor: Documentation Required.` + `update` action, HTTP 200) and
`$submit` → HTTP 201, 2 items with authorization numbers → `PENDING` → `GRANTED` at +15.2 s.

Three things Phase 2 changed in this plan, all recorded in `investigation-log.md` §3:

- **CDS-Library goes in `CRD/server/`, not the repo root** — `bootRun`'s CWD is the `server`
  subproject (`Dockerfile:25`), and CRD needs the **whole** library, not just `CRD-DTR/`.
  Two hard exits (`CRD-DTR/` then `Examples/`) if you get this wrong.
- **dtr honours `PORT` over `REACT_APP_SERVER_PORT`** (`bin/www:21`), so a global `PORT` for crg
  hijacks dtr onto the same port and crg then dies on `EADDRINUSE` — while the stack still probes
  green, because dtr answers `/` with 200. Never export `PORT` globally.
- **Item 18 needed a second fix: CORS.** Upstream `corsOrigins` is `3000, 3002, 3005` and does not
  include 3001, so crg-on-3001 is browser-blocked by CRD. `env.sh` sets `CORS_ORIGINS` accordingly.

**The 9p tax is the real constraint on this host.** `/mnt/c` is ~260× slower than ext4 for
small-file writes (measured) and has ~11 GB free. Repos and toolchain stay here; Gradle/Maven
caches go to ext4. Every timing in this plan is therefore an **under**estimate: test-ehr cold start
314 s (not 25–40 s), `npm ci` 12–14 min, order-sign card 15.7 s (not 2.7 s).


---

## 0. Phase 1 result — all five services up, CRD returns a real card

| svc | port | probe | result |
|---|---|---|---|
| test-ehr | 8080 | `GET /fhir/metadata` | 200, FHIR 4.0.1 |
| crd | 8090 | `GET /r4/cds-services` | 200, one service `order-sign-crd` |
| pas | 9015 | `GET /fhir/metadata` | 200, CapabilityStatement 4.0.1 |
| dtr | 3005 | `GET /`, `GET /launch` | 200, 200 |
| crg | 3001 | `GET /`, `GET /public_keys` | 200, 200 |

No configuration was needed anywhere: the request generator's shipped `src/properties.json`
already points at `http://localhost:8090/r4/cds-services`, `order-sign-crd`,
`http://localhost:8080/test-ehr/r4` and `http://localhost:3005/launch`, and DTR's `bin/dev`
already hardcodes `http://localhost:8080/test-ehr/r4::app-login`. That the upstream defaults are
already exactly this native topology is the strongest evidence that five services on one host is
the intended shape.

**The demo's coverage-requirements step works.** `POST /r4/cds-services/order-sign-crd` with
`pat013` + `devreq037` (`E0607`) returns HTTP 200 in 2.7 s with a `dtr-clin` card:

> **Home Blood Glucose Monitor: Documentation Required.**
> Documentation Required, please complete form via Smart App link.
> suggestion: "Save Update To EHR" → `update` action carrying `ext-coverage-information`

That card is the hand-off into DTR, so the CRD half of the flow is done. Two things are still
open: **DTR → PAS has not been driven end to end** (needs the browser), and **67 VSAC value sets
are still missing** (item 19). Details in `investigation-log.md` §1–§2.

---

## 0. Phase 0 result — PASS

Local `$submit` works. The 2022 bug note is definitively obsolete.

```
POST /fhir/Claim/$submit  (src/test/resources/bundle-prior-auth.json)
  -> HTTP 201 Created, 3570 bytes, 0.17s
  -> Bundle profile-pas-response-bundle
     ClaimResponse profile-claimresponse
       status=active  outcome=queued  disposition=Pending
       preAuthRef=e45c42fa-fc8e-45e1-8a57-47c64790cf0a
       requestor=Practitioner/pra1234   patient=Patient/pat013
```

And the CQL rules engine genuinely ran — both submissions transitioned PENDING → GRANTED exactly
15s later, matching `DELAY=15000`:

```
12:14:41.632  PENDING   e45c42fa…/pat013
12:14:56.662  GRANTED   663f8786…/pat013          (Timer-0, +15s)
12:16:23.308  PENDING   6c914b41…/98765400001AZ
12:16:38.412  GRANTED   46913083…/98765400001AZ    (Timer-1, +15s)
```

### Findings that change the plan

**1. "Pending" is not a bug — it is the fixture.** `bundle-prior-auth.json` has **0 Claim items**,
and the log says so:

```
WARN ClaimResponseFactory::determineDisposition:Request had no items to compute
     disposition from. Returning in pended by default
```

**2. `bundle-items.json` is the better demo fixture** — it has 2 Claim items and produced
per-item extensions including `extension-authorizationNumber`, which renders far better in the
CRG UI. Disposition still starts Pending (the rules legitimately return Pending), then goes
GRANTED. **Use this instead of `bundle-prior-auth.json`.**

**3. Fix #7 is validated.** With `debug=true` as an env var,
`POST /fhir/debug/PopulateDatabaseTestData` → 200 and `POST /fhir/debug/PopulateRules` → 200.
The `-Pdebug` Gradle property would *not* have enabled either.

**4. There is no read-back endpoint.** `GET /fhir/ClaimResponse/{id}` → 404. `$inquire` is
`POST /fhir/Claim/$inquire` (mapped at `/Claim`, **not** `/ClaimResponse`) and demands a specific
Bundle: first entry a `Claim` with **both** `provider` and `insurer`, plus a `Patient` carrying an
**`identifier`** (a bare `patient.reference` is rejected with *"Required elements were not found in
inquiry Bundle"*). **For Phase 4 assertions, read `/fhir/debug/ClaimResponse` instead** — it returns
an HTML table of the whole table and is trivially parseable.

**5. Environment:** no container runtime available, so PAS was run natively on a non-invasive
Temurin 17 tarball. The system Gradle is **4.4.1** and fails immediately on
`allowInsecureProtocol` in `build.gradle` — the wrapper (8.14.2) is mandatory. `prior-auth`
master = `848f28c11d8efb4e253b70cfbbc485acf9acd1a0` (2026-07-22). Startup: **3.6 seconds**.

**6. Benign startup noise:** `JdbcSQLIntegrityConstraintViolationException: Unique index or primary
key violation: "PUBLIC.PRIMARY_KEY_4 ON PUBLIC.RULES(SYSTEM, CODE)"` — devtools' double
`restartedMain` re-populates the Rules table. Non-fatal; rules still load. Ignore it, or build
without devtools.

### Full endpoint map (for the Phase 4 harness)

| Path | Class |
|---|---|
| `POST /fhir/Claim/$submit` | `ClaimEndpoint` |
| `POST /fhir/Claim/$inquire` | `ClaimInquiryEndpoint` |
| `/fhir/ClaimResponse` | `ClaimResponseEndpoint` |
| `/fhir/Bundle` | `BundleEndpoint` |
| `/fhir/Subscription` | `SubscriptionEndpoint` |
| `/fhir/metadata` | `Metadata` — unauthenticated, usable as a liveness probe |
| `/fhir/debug/*` | `DebugEndpoint` — `PopulateDatabaseTestData`, `PopulateRules`, `ReleaseClaim`, `Convert`, `ConvertAll`, table views, `/$expunge` |
| `/fhir/auth/*` | `AuthEndpoint` (PAS has its own OAuth, does not use Keycloak) |
| `/.well-known/*` | `WellKnownEndpoint` |

### Consequence for the plan

Assumption 1 holds, so **no stub fallback is needed**. `PLAN.md` §6 Phase 0 can be struck, and
Phase 4 can assert against `/fhir/debug/ClaimResponse` rather than `$inquire`. The stub fallback
in §8 is retired.


---

## 1. Acceptance criteria

One command, on a clean machine, unattended, produces this:

1. All 6 services reach ready with no console intervention, probed on real FHIR endpoints
2. Browser → `http://localhost:3001/ehr-server/reqgen` → select R4 → patient `pat013` → `E0607` → Submit
   (**`:3001`, not `:3000`** — see item 18; `:3000` is taken on this host)
3. A coverage-requirements card appears **with a working DTR link** (a dead link here is the
   single most likely visible failure — see fix #5)
4. "Open Form" launches DTR, **through a real Keycloak login page** at `:8180` (`dtr` /
   `dtr-demo`) — *this criterion originally said "no login step, because no Keycloak is in the
   path". That was wrong; see `investigation-log.md` §4.9.* The Questionnaire then loads. It
   arrives **un-prefilled** — CRD cannot resolve three CQL references in
   `HomeBloodGlucoseMonitorRule` — so it must be filled in.
5. **`PROCEED TO PRIOR AUTH`** → dtr builds the Claim → its own panel's **Submit** → the
   ClaimResponse renders with a disposition, then `Pending` → `Granted` on the 15 s timer
6. The whole thing is repeatable after a full state reset


Steps 3 and 5 are where silent failures live. A card that renders with a dead DTR link, or a
PAS response that renders empty, both *look* like a passing demo. And step 4 is where the stack
looks healthy right up until it fails: nothing in the *API* path needs Keycloak, so `:8180` can
be dead and every other criterion still passes.

---

## 2. Scope

### In (6 services, no container runtime)

Authoritative host ports taken from `prior-auth/docker-compose.yml`. Repos and SHAs verified
2026-09-26. **This section originally read "5 services, no Keycloak" — corrected 2026-09-27, see
§0b and `investigation-log.md` §4.** Keycloak `:8180` is in scope because the DTR hop needs a real
OAuth authorization server; §4.9 records why that was not obvious.

| Service | Port | Repo @ pinned SHA | Native run | Evidence |
|---|---|---|---|---|
| test-ehr | 8080 | `HL7-DaVinci/test-ehr` @ `e3f07ce4d81063e99e475cccaedba93becb8ef1d` (2025-09-18) | `mvn spring-boot:run` | READ |
| crd | 8090 | `HL7-DaVinci/CRD` @ `43547c4e69052df4d3532972e4bd03f8d5317d13` (2026-07-21) | `./gradlew server:bootRun` | READ |
| dtr | 3005 | `HL7-DaVinci/dtr` @ `7acf79a6f89bfe9e88c30e9d4b531f647ce09c41` (2026-07-22) | `npm start` | READ |
| crd-request-generator | **3001** (3000 taken) | `HL7-DaVinci/crd-request-generator` @ `87e98bf9af4fb528b624171edbe702880e325c59` (2026-01-12) | `npm start` | READ |
| prior-auth | 9015 | `HL7-DaVinci/prior-auth` @ `848f28c11d8efb4e253b70cfbbc485acf9acd1a0` (2026-07-22) | `./gradlew bootRun` | **BOOT ✅** |

**Repo-name correction:** the DTR repo is `HL7-DaVinci/dtr`, **not** `hlseven/davinci-dtr` as
several upstream docs and this plan previously stated. `davinci-dtr` 404s.

**Port correction:** **3000 is crd-request-generator, not CRG.** There is no separate CRG service
in the upstream compose; earlier drafts of this plan conflated the Coverage Requirements Guide
with the request-generator UI.

### Keycloak is dropped — 7 services become 5

This was the single biggest simplification, and it falls out of three config defaults:

| Service | Config | Value | Consequence |
|---|---|---|---|
| test-ehr | `src/main/resources/application.yaml:88` | `use_oauth: false` | no OAuth server needed |
| crd | `server/src/main/resources/application.yml:34` | `checkJwt: false` | no bearer token needed |
| prior-auth | own `/auth/register` + `/auth/token` against an H2 `Client` table | — | PAS never used Keycloak |

So nothing in the 5-service stack consumes a Keycloak token. What that buys:

- **No legacy Keycloak at all.** It would have been the worst native citizen on the board: the
  compose image is JBoss/WildFly-based (`/opt/jboss/keycloak/standalone/data`), and
  `keycloak-server-dist:4.8.3` is **404** on Maven Central — **6.0.1 is the last WildFly dist**
  (HTTP 200), and it requires **Java 8**. That meant a second JDK tarball for an EOL runtime.
- **One fewer JVM** (~1 GB).
- **One fewer thing to break on demo day** — the realm import, the `alice` user, the admin
  console click-through, fix items 15 and 13's Keycloak half.
- This box is **x86_64**, so the old arm64 worry was moot anyway.

If OAuth ever *is* needed (e.g. swapping test-ehr for a real EHR), reach for
Keycloak 6.0.1 + a Java 8 tarball, or better: move test-ehr to a modern `keycloak-spring-boot-adapter`
or drop the `use_oauth` coupling entirely. That is a separate exercise.

### Out (3 services)

| Service | Why excluded |
|---|---|
| `prior-auth-client` | demo UI for PAS. crd-request-generator already displays the ClaimResponse, so this is redundant for a demo. Port 9090. |
| `fhir-x12` | FHIR↔X12 278 converter. Only needed for real X12 transport, not for a FHIR-level demo. Port 8085. |
| `fhir-x12-frontend` | UI for the above. Also carries fix #16 (broken `BACKEND_URL`). Port 3015. |

All three are leaf/optional. Re-adding them is a native process launch like any other.

### Not a single process — a supervisor, not a monolith

Deliberately **not** one process. 3 JVMs + 2 Node with different lifecycles must stay separate:
one crash must not kill-loop the rest, and each needs its own readiness signal. `up.sh` starts
them as independent background processes with per-service PID files and logs, polls each health
endpoint, and prints a status table. `down.sh` stops them in reverse order and clears the H2
files. That reproduces compose's *behaviour* without a container runtime.

### Resources — this is the real constraint

**Only ~3 GB of the box's 7 GB is available** (`free -g`: 4 used, 3 available). Upstream's 8 GB
minimum is not reachable here, so per-JVM caps are mandatory, not optional:

| Service | `-Xmx` | why |
|---|---|---|
| prior-auth | 768m | proven at 1g; 768m is enough for the demo path |
| crd | 640m | Quarkus + Hibernate; the fattest of the three |
| test-ehr | 512m | HAPI FHIR JPA starter, but small dataset |
| dtr | 256m | Node, `--max-old-space-size=256` — **runtime only**; the webpack *build* needs 1280m or it core-dumps |
| crd-request-generator | 256m | Node, `--max-old-space-size=256` |

Total ~2.4 GB of heap plus ~600 MB of runtime overhead. Watch it on first bring-up; if CRD OOMs,
drop test-ehr to 384m — nothing in the demo path needs a large heap.


---

## 3. Assumptions

1. ~~**The local PAS submit bug is fixed.**~~ **PROVEN by Phase 0.** The 2022-05-04 note at
   `prior-auth/DockerLocalSetupGuide.md:311` is obsolete: `POST /fhir/Claim/$submit` returns
   **HTTP 201** with a valid `ClaimResponse` on master, and the CQL engine reaches **GRANTED**.
2. ~~**Offline-capable, no `VSAC_API_KEY`.**~~ **DISPROVED in Phase 1.** CRD's 12 topics and 30
   CQL files do load without a key, and rules still evaluate — but `valueSetCachePath:
   ValueSetCache/` is not shipped, so **67 distinct value sets** fail with `not found in cache
   dir`, and there is no way to fill that cache offline: the OIDs are VSAC-internal "durable"
   identifiers that `tx.fhir.org` (empty bundle) and `terminology.hl7.org` (404) both refuse.
   A demo that breaks on a third-party API is a bad demo, so this still needs solving — via a key
   or a pre-seeded `ValueSetCache/` committed alongside the CDS-Library checkout. See item 19.
3. ~~**Legacy Keycloak pinned.**~~ **Retired — Keycloak is not in the stack.** See §2. Nothing
   consumes a Keycloak token (`use_oauth: false`, `checkJwt: false`, PAS has its own `/auth`), so
   the EOL WildFly distro and its Java 8 requirement disappear with it.
4. **Browser runs on the same host as the stack.** So published ports plus the existing
   `localhost:PORT` defaults work untouched, and **no reverse proxy is needed**. Every upstream
   default is already localhost-rooted because upstream only ever supported single-host.
5. **No container runtime.** No Docker/Podman/Nerdctl/Buildah on this box, and none is wanted.
   Everything runs as ordinary background processes off unpacked tarballs — no system-wide
   installs, which is also why the toolchain is provisioned in Phase 1 rather than assumed.


---

## 4. The source document is ~4 years stale

`Setting-up-CRD_DTR_PAS-2.pdf` (8 pages) is a competent 2020-era manual. Its stated prerequisites
are not merely outdated — they are **below the current minimums**, so the from-source path fails
immediately on any machine.

| PDF says | Reality on `master` (2026-09) |
|---|---|
| Java 8 or 11 | **17** (corretto), HAPI FHIR 8.2.1 requires 11+ |
| Node 12+ | **22**, ESM-only, React 19, Express 5 |
| Gradle 5.6.2 or 6.3 | **8.14.2** (wrapper). `Dockerfile.dev` and CI still say 6.9 — stale, wrapper wins. The *system* Gradle here is 4.4.1 and dies on `allowInsecureProtocol` |
| `./standalone.sh -Djboss.socket.binding.port-offset=100` | **Moot** — Keycloak dropped. Worth recording anyway: Keycloak ≥17 is Quarkus, and `standalone.sh`/`/opt/jboss` are gone. The last WildFly dist is 6.0.1 |
| Edit `webpack.config.dev.js` line 19, `https: false` | File does not exist. Server is HTTP-only by construction |
| Manually visit `:3005/register` to add the EHR | `REACT_APP_INITIAL_CLIENT=<iss>::app-login` |
| `gradle loadData` | test-ehr is Maven now, self-seeds on boot, idempotent |
| 5 repos, `gradle bootRun` in 6 terminals | Repos are right but the build tools are mixed: **Gradle for CRD/PAS, Maven for test-ehr, npm for dtr/CRG**. test-ehr ships no `mvnw` |
| Register a Keycloak user, get a bearer token | **Unnecessary** — `use_oauth: false`, `checkJwt: false` |
| Patient "Vlad Quinton" (`pat013`), `E0424` | family `Q`, given `Vlad`. Working demo fixture is `E0607` |

Also: **PAS's port moved**, 9000 in the PDF → 9015 now.

Useful consequence: `prior-auth/docker-compose.yml` is still the best available inventory of the
9 upstream services, their ports and their wiring. It is used here as *documentation* — the
authoritative port map in §2 is lifted from it — but it is not executed.


---

## 5. The 16-item fix list

Ordered roughly by how quietly each one breaks things.

| # | Svc | Item | Now | Fix |
|---|---|---|---|---|
| ~~1~~ | ~~all~~ | image tags | `smalho01234/*:latest`; PAS built from `dev` not `master` | **MOOT** — no images. Superseded by clone-at-pinned-SHA |
| ~~2~~ | ~~all~~ | `depends_on` | none anywhere | **MOOT** — no compose. `up.sh` starts in dependency order and polls real health endpoints |
| 3 | crd | `LOCALDB_PATH` | — | ✅ **already correct on current master** — `localDb.path: CDS-Library/CRD-DTR/` has the trailing slash. **Validated: 12/12 topics load.** Still CWD-relative, so `server:bootRun` must run from the repo root |
| 4 | crd | health probe | `/actuator/health` permanently `DOWN` | ✅ **validated** — `MANAGEMENT_HEALTH_ELASTICSEARCH_ENABLED=false` → `{"status":"UP"}` |
| 5 | crd | `LAUNCHURL` | relative → 404 | absolute self-URL |
| 6 | pas | CWD-relative paths | `config.properties` + `CreateDatabase.sql` resolve against CWD | run from the repo root; `up.sh` must set CWD per service |
| 7 | pas | seeding | disabled in prod image | `debug=true` **env var**, not `-Pdebug` — ✅ **validated in Phase 0** |
| 8 | pas | auth | token juggling | `BYPASS_AUTH=true` — ✅ **validated in Phase 0** |
| 9 | pas | `TOKEN_BASE_URI` | `localhost:9015` | correct as-is; override only if the stack goes remote |
| 10 | crg | `db.json` | pre-created as `{}` in the Dockerfile | ✅ **moot natively** — no Dockerfile, so no pre-seeded `{}`. `/public_keys` returns 200 as shipped |
| 11 | crg | `ORDER_SELECT`/`ORDER_SIGN` | `.env.example` has full URLs | ✅ **already correct** — `src/properties.json` ships full URLs: `cds_service: http://localhost:8090/r4/cds-services`, `order_sign: order-sign-crd`, `ehr_server: http://localhost:8080/test-ehr/r4`, `launch_url: http://localhost:3005/launch` |
| 12 | dtr | persistence | none | set `REACT_APP_*` env; data dir is CWD-relative |
| 13 | dtr | client registration | manual `/register` | ✅ **already correct** — `bin/dev` hardcodes `http://localhost:8080/test-ehr/r4::app-login`, which is exactly our test-ehr |
| ~~14~~ | ~~keycloak~~ | ~~zero users in realm JSON~~ | — | **MOOT** — Keycloak dropped |
| ~~15~~ | ~~keycloak~~ | ~~JBoss legacy, EOL~~ | — | **MOOT** — Keycloak dropped |
| 16 | dropped svcs | `BACKEND_URL` | `localhost:8085` | moot while excluded |

Net: **16 items → 11 live**, of which #7, #8, #10, #11 and #13 are already proven fixed and #3/#4
are validated. **#3 needs no change at all** — the trailing slash is present upstream.

### Phase 1 additions (items 17–19, found by running it)

| # | Svc | Item | Impact | Fix |
|---|---|---|---|---|
| 17 | test-ehr | 16 seed files legitimately use `codeCodeableConcept` | **none — do not "fix" it** | `DeviceRequest.code` is the `code[x]` **choice** type (`Reference(Device)` or `CodeableConcept`), so the CodeableConcept branch's JSON name is `codeCodeableConcept`. HAPI's lenient parser round-trips it, so a GET looks fine. Renaming it to `code` makes HAPI log `Unknown element 'code'` and **drop it**, which silently breaks the whole CRD path |
| 18 | crg | `:3000` already taken on this host | request generator will not start | an unrelated Next.js app owns `:3000` → `EADDRINUSE`. Run CRG on **`PORT=3001`** and rebuild the frontend so the bundled `public_keys` points at `3001`. Freeing `:3000` is the alternative if the documented ports matter more. **Two halves, both required:** (a) the port move, and (b) CRD's `corsOrigins` allowlist is `3000, 3002, 3005` — **3001 is absent**, so the browser is CORS-blocked. Set `CORS_ORIGINS` on CRD. **And do not export `PORT` globally** — dtr's `bin/www:21` reads `process.env.PORT` *before* `REACT_APP_SERVER_PORT`, so dtr lands on 3001 too and crg then dies on `EADDRINUSE` while the stack still probes green |
| 19 | crd | `ValueSetCache/` absent → **67 value sets** unavailable | rules gated on them will not match | **A VSAC API key is required.** The OIDs are VSAC-internal "durable" ids: `tx.fhir.org` returns an empty bundle and `terminology.hl7.org` 404s, so they cannot be resolved publicly. Assumption 2 in §3 is now **disproved** |

### Readiness probes — corrected

| svc | probe | note |
|---|---|---|
| test-ehr `:8080` | `GET /fhir/metadata` | ~50 s cold after `mvn clean`, faster warm |
| crd `:8090` | `GET /r4/cds-services` | **not `/metadata`** — CRD is a CDS Hooks server, not a FHIR server. `/metadata` and `/cds-services` both 404 |
| crd `:8090` | `GET /actuator/health` | only valid with `MANAGEMENT_HEALTH_ELASTICSEARCH_ENABLED=false` |
| pas `:9015` | `GET /fhir/metadata` | CapabilityStatement, `fhirVersion: 4.0.1`. **No actuator** — `/actuator/health` is 404 |
| dtr `:3005` | `GET /` and `GET /launch` | both 200 |
| crg `:3001` | `GET /` and `GET /public_keys` | both 200; serves `<title>CRD Request Generator</title>` |

### The four that fail *silently* — do these first

**#3 `LOCALDB_PATH` trailing slash.** `CommonFileStore.java:630`:
```java
String cqlFileLocation = localPath + topic + "/" + fhirVersion + "/files/";
```
No separator is inserted. Omit the trailing slash and CRD loads **2 of 126 rules**. Measured:

| value | rules loaded | CQL misses | fatal? |
|---|---|---|---|
| `.../CRD-DTR` | 2 | 52 | no |
| `.../CRD-DTR/` | **126** | 0 | no |

It does not crash. It starts, advertises all six CDS services, answers HTTP 200, and evaluates
nothing. A partial pass that looks like success.

**#4 CRD reports `DOWN` forever.** Inherits HAPI's Elasticsearch health contributor but runs on
H2, so the indicator can never pass. Observed serving 126 rules and correct cards while
`{"status":"DOWN"}`. A readiness probe on `/actuator/health` kill-loops a perfectly healthy
service — which is exactly what a naive compose healthcheck would do. Probe `/r4/cds-services`
instead: CRD is a CDS Hooks server, so `/metadata` is a 404.

**#6 PAS resolves everything against CWD.** `config.properties` and `CreateDatabase.sql` are
CWD-relative, so the app only works when CWD is the repo root. Upstream papered over this with a
volume mount that pointed at the wrong directory for the prod image. Natively this is simpler *and*
stricter: `up.sh` must `cd` to each repo root before launching, and there is no path to get wrong.

**#10 CRG public-key store is broken as shipped.** Upstream's Dockerfile pre-creates `db.json` as
`{}`, but `server.js` only seeds the correct shape if the file is *absent*:
```js
if (!fs.existsSync(DATA_FILE)) { fs.writeFileSync(DATA_FILE, JSON.stringify({ public_keys: [] }, null, 2)); }
```
So `data.public_keys` is `undefined` and the key-registration endpoint 500s, silently breaking the
JWT signing flow. Natively the file simply won't exist, so **this defect does not reproduce** — but
keep the check in case the data dir is ever seeded from a fixture.

### #7 the Gradle-property trap — ✅ now validated

Upstream's prod `CMD ["./gradlew", "bootRun", "-Pdebug"]` sets a **Gradle** property, which only
enables the JDWP agent. It does **not** enable app debug mode, which needs the env var
`debug=true` or the CLI arg `debug`. So `POST /fhir/debug/PopulateDatabaseTestData` returns 400
against the shipped image.

**Phase 0 confirmed the distinction empirically**, which is the only reason to trust it:

| invocation | `PopulateDatabaseTestData` | `PopulateRules` |
|---|---|---|
| `debug=true` as env var | **200** | **200** |
| `-Pdebug` (Gradle property) | 400 | 400 |

`up.sh` therefore exports `debug=true` in the environment and does **not** pass `-Pdebug` for this
purpose. (`dockerRunnerDev.sh` happens to get it right: `gradle bootRun -Pdebug --args='debug'` —
belt and braces, since the `--args='debug'` is what actually works.)


### #5 launch URL must be absolute

`CdsService.java:492-499` branches on `isAbsolute()`. The relative branch prepends
`applicationBaseUrl.getFile()` (which is `/fhir/r4`), producing a 404:

```
LAUNCHURL=/smart/launch.html
  -> card link: http://localhost:8090/fhir/r4/smart/launch.html   HTTP 404
LAUNCHURL=http://localhost:8090/smart/launch.html
  -> card link: http://localhost:8090/smart/launch.html          HTTP 200
```

Absolute is passed through verbatim. Also note `appendParamsToSmartLaunchUrl: false` in
`application.yml:53` — the DTR link carries **no** `iss`/`patientId`/`template` params, so the
questionnaire opens contextless unless that is also set true.

---

## 6. Phases

### Phase 0 — smoke test — ✅ DONE, PASSED

See §0. Local `$submit` returns HTTP 201 with a valid ClaimResponse, and the CQL engine reaches
GRANTED. No stub fallback required.

### Phase 1 — pin & provision the toolchain

No images to build or pull. Clone all 5 repos at the SHAs in §2, then provision a **non-invasive**
toolchain — unpacked tarballs under `~/.local/` or `/tmp`, nothing installed system-wide:

| Tool | Version | Why | Status |
|---|---|---|---|
| Temurin JDK | 17.0.20.1 | builds CRD + PAS; Java 8/11 cannot | ✅ at `/tmp/davinci-scratch/jdk17` |
| Node | 22.23.1 | runs dtr + crd-request-generator | ✅ already present |
| Maven | 3.9.9 | builds test-ehr — **it ships no wrapper** | ⬜ tarball, HTTP 200 verified |
| Gradle | wrapper only | system Gradle is **4.4.1** and fails on `allowInsecureProtocol` | ✅ use `./gradlew` |

The Maven wrapper gap is the one real surprise: test-ehr has a `pom.xml` and no `mvnw`, so
`mvn spring-boot:run` needs a real Maven. Unpack `apache-maven-3.9.9-bin.tar.gz` and put it on
`PATH` for the session.

`dtr` is **pure Node** (`"type": "module"`, `node ./bin/prod`), not a Quarkus/JVM service — one
fewer JVM than the docs imply. Its port comes from `REACT_APP_SERVER_PORT` (default 3005).

Also land, per service: **CRD needs the whole pinned `CDS-Library` at `CRD/server/CDS-Library/`**
(`server:bootRun`'s CWD is the `server` subproject — see §0 Phase 2), and PAS needs
`CDS-Library/PriorAuth/` at its **repo root**. **dtr needs no CDS-Library checkout at all** — it
fetches the Questionnaire from the FHIR server at runtime (`src/cdex.js:158`). An earlier draft of
this plan said otherwise and was wrong.

### Phase 2 — native bring-up — ✅ DONE

`bin/up.sh` starts the 5 processes in dependency order (test-ehr → crd → prior-auth → dtr →
crd-request-generator), each in its **own process group** via `setsid`, with its own log, PID file
and `-Xmx` cap from §2. It polls the real readiness endpoints — not actuator, which is CRD defect #4:

| Service | Readiness probe | Result |
|---|---|---|
| test-ehr | `GET :8080/fhir/metadata` | 200 |
| crd | `GET :8090/r4/cds-services` | 200 |
| prior-auth | `GET :9015/fhir/metadata` | 200 |
| dtr | `GET :3005/` | 200 |
| crd-request-generator | `GET :3001/` | 200 |

All five confirmed up, and the whole chain re-proved. `bin/down.sh` stops them in reverse order,
killing the process *group* (a plain `kill` leaves Gradle daemons and webpack children holding the
ports), then optionally purges state.

Fix items 1–12 are landed, but **most were already correct upstream**: #3 (trailing slash present),
#5 (CRD master now ships an absolute `launchUrl: http://localhost:3005/launch`), #10 (no Dockerfile,
so no pre-seeded `{}`), #11 and #13 (both already point at this exact topology). The ones that
actually needed action are #4, #7, #8, #18 — all in `bin/env.sh` / `bin/up.sh`.

**One-time build step:** both Node services serve a *prebuilt* bundle in production mode, so
`up.sh` runs `npm run buildFrontendProd` (dtr) and `npm run build` (crg) once, gated on the output
existing. dtr's webpack build needs `--max-old-space-size=1280`; at the §2 runtime cap of 256 MB it
core-dumps with a heap OOM. `node_modules` must sit in the repos, so both are needed on 9p.


### Phase 3 — de-manualize *(demo-critical)*

Land fix items 13–15. Every remaining manual step is a demo-day failure:

- `REACT_APP_INITIAL_CLIENT` so nobody visits `/register`
- `debug=true` + `BYPASS_AUTH=true` so seeding is automatic (both **validated in Phase 0**)
- ~~`alice`/`alice` in the realm JSON~~ — **retired with Keycloak**

### Phase 4 — demo script + reset

Freeze one working path end-to-end, then make it repeatable. Reset is `down.sh` plus deleting the
H2 data dirs (`prior-auth/`, `crd/server/target/database`, test-ehr's H2 file) — without that you
cannot recover from a half-finished run, and demo attendees click through state and leave it dirty.
Assert outcomes against `GET :9015/fhir/debug/ClaimResponse`, per §0.


---

## 7. Demo-specific hardening

A demo has the opposite failure profile from CI: **CI breaks loudly, a demo breaks by looking
fine.** Most of the fix list matters *more* for this consumer, not less.

- **Freeze the verified fixture.** `pat013` (Q Vlad) + `DeviceRequest` **E0607**, with `order-sign`
  prefetching `deviceRequestBundle` + `coverageBundle` + `patient`. Confirmed returning a live
  card. Do *not* use the PDF's `E0424`; the doc's patient data is mangled.
- **Silence CRD's `DOWN` healthcheck** before ever running this in front of anyone — and prefer
  `/metadata` over `/actuator/health` in the first place, so there is no misleading red to ignore.
- **Add a reset path.** Demo attendees click through state and leave it dirty.
- **Pre-warm data, not network.** Seed once at bring-up, serve from H2. No VSAC calls, no VSAC
  latency, nothing to fail.
- **Document the swap points.** "Mock for the real thing" implies test-ehr gets replaced by a
  real EHR later. Keep every upstream endpoint in one visible env block so that swap is a config
  change, not a code change.
- **Rehearse the 15-second wait.** PAS dispositions are asynchronous: `$submit` returns
  `queued`/`Pending` and the real disposition lands ~15s later via the DELAY timer (§0). An
  audience watching a spinner will assume it broke. Either narrate the wait or have the demo
  pre-submitted so the finished ClaimResponse is already on screen.


---

## 8. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| ~~Local PAS submit still broken~~ | — | **Retired.** Phase 0 passed; local submit returns HTTP 201 and reaches GRANTED. |
| VSAC-dependent behaviour expected by the demo path | Empty/partial cards | Assumption 2: offline-capable, bundled rules only |
| ~~Legacy Keycloak unusable on arm64~~ | — | **Retired.** Keycloak is not in the stack; nothing consumes a token |
| Only ~3 GB RAM available of 7 GB | OOM kills a JVM mid-demo | Per-JVM `-Xmx` caps in §2, total ~2.4 GB. Drop test-ehr to 384m if CRD OOMs |
| dtr + crd-request-generator on Node 22 | ESM/React 19 breakage the PDF never saw | Pin Node via the tarball already provisioned; both are `"type": "module"` with no `engines` field, so nothing self-documents the requirement |
| test-ehr has no Maven wrapper | `mvn` not on this box | Unpack Maven 3.9.9 tarball in Phase 1 (HTTP 200 verified) |
| System Gradle is 4.4.1 | `build.gradle:6` fails instantly | Always `./gradlew`; never bare `gradle` |
| `dtr` undeclared `debug` dependency | Image fails to boot after a dep change | Track it; builds fine today |
| CRD test fixtures broken upstream | Misleading if you rely on them | `deviceRequestPrefetch.json` no longer works; use the seed-data request in `investigation-log.md` |
| Demo fixture with 0 Claim items | Disposition is always Pending, looks unrewarding | Use `bundle-items.json` instead — 2 items, per-item authorization numbers |
| No read-back endpoint on PAS | Phase 4 has nothing to assert against | Use `GET /fhir/debug/ClaimResponse` (HTML table). `$inquire` needs provider + insurer + a Patient `identifier`. |


---

## 9. Two open notes

1. **`CDS-Library/PriorAuth/` layout mismatch.** `CDS-Library@master` flattened `PriorAuth/` to
   `HomeBloodGlucoseMonitorPriorAuthRule.cql`, while CRD still expects the
   `<topic>/R4/files/<topic>Rule-x.y.z.cql` shape that `CRD-DTR/` still uses. Pointing CRD's
   `LOCALDB_PATH` at `PriorAuth/` yields **0 of 4 topics**. This does not affect the plan — CRD
   uses `CRD-DTR/` for its own rules and PAS embeds `PriorAuth/` for its own — but it does mean
   CRD cannot serve PA-specific rules. Pin CDS-Library if that is ever wanted.
2. **`prior-auth`'s README "Configuration Notes" is stale**, describing files (`src/components/…`,
   a LogicaHealth `tokenUri` in `Metadata.java`) that do not exist on `master`. Belongs to the
   `dev` branch era. Do not follow it.
