# Contributing

Thanks for looking. Two things will save you a lot of time.

## If you are an AI agent

Read **[`AGENTS.md`](AGENTS.md)** instead. It is self-contained: it tells you how to provision,
start, verify and report on the stack, lists the credentials (there are none you need to
supply), and documents the traps that produce convincing but wrong results.

## If you are a human

**Read [`TEST-FLOW.md`](TEST-FLOW.md) first.** It is the full runbook — every endpoint, every
command, and a per-symptom troubleshooting table. `README.md` is the overview.

The two commands that define "working":

```bash
./bin/demo.sh               # 12/12 — API surface
python3 bin/e2e-browser.py  # 14/14 — real browser, all the way to a PAS decision
```

They are not redundant. `demo.sh` posts its own `Claim`; the browser path is driven by dtr,
which builds the `Claim` itself and only submits it from a panel that appears after you press
**Proceed To Prior Auth**. Neither driver can cover the other.

## Before you open a pull request

CI will run, and some of it will fail for reasons that are easy to trip:

| Guard | What it stops |
|---|---|
| `bash -n bin/*.sh` | a shell script that does not parse |
| JSON fixtures parse | a truncated or hand-edited fixture |
| `provision.sh --check` fails on a bare tree | the provisioner quietly declaring an unprovisioned tree ready |
| `provision.sh --check` fails on a wrong SHA | a pin that no longer matches what was actually built |
| no token patterns | a committed credential |
| no host or tool fingerprints | your LAN address, Windows username or scratch-path habits leaking into a public repo |
| upstream credential stays `<redacted>` | republishing someone else's hardcoded secret |
| no fingerprints in git history | a leak that is fixed in the tip but still reachable in an old commit |
| screenshots OCR'd, 4 segmentation modes | a host address rendered as *pixels* into a PNG — invisible to every text scan, and the exact thing that happened during review |
| code fences balanced | a truncated markdown file |
| no stale "this repo is not public yet" claims | documentation that contradicts reality |
| every guard is proven able to fail | a guard that cannot fail, passing |

Two of those deserve emphasis:

- **Do not hand-edit a SHA in `versions.lock`.** It is the run version. Changing a pin means
  re-running both drivers and making a new `run-YYYY-MM-DD` tag. See
  [Pin discipline](README.md#pin-discipline).
- **If you add or replace a screenshot, run it through OCR before committing.** A terminal
  showing a URL or an IP will render that string into the image, and no grep will find it.

### Run the suite yourself

Do not push a change to CI and find out whether it works from a failure email. Both scripts
run the identical commands, locally, against a throwaway snapshot of the tree:

```bash
./bin/ci-local.sh       # all 14 steps, each reported separately
./bin/ci-selftest.sh    # plants one leak per guard, asserts each is caught
```

`ci-local.sh` matters because a workflow step that has never executed is a guess. The first
version of this file's own suite was reported working after two of twelve steps had been run
by hand; the untested one failed on the first push.

`ci-selftest.sh` matters because a guard that has only ever *passed* is indistinguishable from
a broken one — and four of these guards were broken that way. One matched its own source
line, another could never fire because of a single missing letter in a regular expression,
and five treated a `grep` error as a clean result. Each is written up in that script's
header, because the pattern repeats: **a guard that scans a directory containing itself must
be tested against that directory, not against a list of strings.** That applies to the test
data too, which is why the planted leaks in `ci-selftest.sh` are assembled from fragments.

Not every guard fails by something being *added*, though. The non-root-path guard fails when
a line is absent, so its case deletes one — an `!!` marker in the case table. If you add a
guard whose failure mode is a missing thing, add a deleting case; appending cannot test it.

If you add a guard, add a case for it. A guard with no case is a guard nobody has tested.

```bash
# what CI's image check does, if you want it locally
sudo apt-get install -y tesseract-ocr
for f in $(git ls-files 'docs/**/*.png'); do
  for psm in 3 6 11 12; do
    tesseract "$f" - --psm $psm 2>/dev/null | grep -E '172\.22\.71\.96|10\.0\.3\.1|sardar|FirstName'
  done
done
```

## Reporting a security problem

Do not open a public issue. See [`SECURITY.md`](SECURITY.md), which also explains which
"findings" are the documented design and should not be reported at all.

## Licence

MIT. See [`LICENSE`](LICENSE). No upstream DaVinci code is redistributed here — `bin/provision.sh`
clones it at pinned SHAs, so upstream licences apply to it.
