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
| no stale "the repo is private" claims | documentation that contradicts reality |

Two of those deserve emphasis:

- **Do not hand-edit a SHA in `versions.lock`.** It is the run version. Changing a pin means
  re-running both drivers and making a new `run-YYYY-MM-DD` tag. See
  [Pin discipline](README.md#pin-discipline).
- **If you add or replace a screenshot, run it through OCR before committing.** A terminal
  showing a URL or an IP will render that string into the image, and no grep will find it.

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
