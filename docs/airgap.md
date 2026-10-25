# Airgap: running firstmate where nothing may leave the building

This fork adds one switch and two checks so a firstmate home can run on a
machine where the code and the conversation are under NDA.

## What leaves the machine in stock firstmate

Stock firstmate has no telemetry of its own. Everything it sends to a third
party other than the forge and the model provider is opt-in by credential:

| Destination | Turned on by | What it carries |
| --- | --- | --- |
| `myfirstmate.io` Relay | `FMX_PAIRING_TOKEN` in `.env` | public X/Discord mentions in, replies and lifecycle actions out |
| `api.typesafe.ai` dispatch classifier | `TYPESAFE_API_KEY` in `.env` or environment | the project name and the brief's intent and spec sections |
| AWS Bedrock | `config/voice-*`, `config/inbox-*` | spoken audio (voice relay), audio and questions (`fm-inbox.sh say`/`ask`) |

Stock firstmate also depends on `no-mistakes`, whose released binary ships
Umami analytics and an update check against its author's hosts. That is outside
this repository; see "Toolchain" below.

## The switch

Create an empty file `config/airgap` in the home (config/ is gitignored), or
set `FM_AIRGAP=1`. From then on every one of the three paths above refuses
before any network call, and nothing in `.env` or the environment can turn them
back on. The guard is `bin/fm-airgap-lib.sh`; the call sites are listed in its
header. Each refusal prints one line in the shape its tool already uses when it
is off, ending in `nothing sent`, and `bin/fm-bootstrap.sh` prints one
`AIRGAP: on` line at session start so the state is visible.

Removing the file turns the switch off; nothing else changes. Personal and work
homes can therefore share one fork and differ only in that file.

## The two checks

**Static.** `tests/fm-egress-allowlist.test.sh` extracts every hostname from
`bin/`, the harness directories and the skills, and fails unless each one has a
line in `docs/egress-allowlist.txt` saying what class it is. Merging upstream
cannot introduce an endpoint silently: the test goes red until someone reads
the new code and classifies the host. It also pins the set of `guarded` hosts,
so adding a fourth opt-in third party forces a matching refusal and test.

**Runtime.** `bin/fm-egress-audit.sh -- <command>` runs a command under
`strace`, reduces the trace to the distinct remote endpoints it connected to,
and judges each against the same allowlist by the name the process itself
looked up. The judge reads the lookups out of the same trace, from
systemd-resolved's local socket or from DNS packets to the `resolv.conf`
nameserver, and trusts an answer only when it arrived on a socket the process
opened to that resolver. Reverse DNS is never used to clear a host, because
the owner of a destination address controls its PTR record and could point it
at any allowlisted name; it appears only as a `ptr=` side note. An endpoint
the process never looked up (a static binary with its own resolver, or
DNS-over-HTTPS) is reported as `no lookup seen` and fails the run until a
human reads the trace. The trace, endpoint table and report are kept under
`state/egress-audit/<stamp>/` as evidence. A typical proof run:

```sh
touch config/airgap
bin/fm-egress-audit.sh -- env FM_BOOTSTRAP_DETECT_ONLY=1 bin/fm-bootstrap.sh
bin/fm-egress-audit.sh -- bin/fm-test-run.sh --family pure-contract-unit
```

Expect `verdict: clean` with only `forge` and `provider` hosts listed.

## What still talks, by design

- `gh` and `git` reach the forge. That is the job.
- The primary and every worker reach their model provider with the prompts.
- `quota-axi` reads usage from the provider APIs using the stored logins.
- Pi downloads `fd` and `ripgrep` from GitHub on first run and checks pi.dev
  for a new version unless `PI_SKIP_VERSION_CHECK=1`.
- The bearings board template imports Google Fonts when opened in a browser.

Block `myfirstmate.io`, `api.typesafe.ai`, `a.kunchenguid.com` and
`kunchenguid.github.io` at the firewall as a second layer if the machine's
policy allows a denylist; the switch does not depend on it.

## Toolchain

`bin/fm-vendor-install.sh` installs the pinned toolchain from a local
directory of tarballs instead of `curl | sh` and the public npm registry, so a
work machine never runs an installer fetched at install time. The vendor
directory holds the five `*-axi` packages and their SDK as `.tgz`, the
treehouse release tarball, and a `no-mistakes` binary rebuilt from its public
source with the analytics linker flags removed and the update check disabled
by default. The build recipe, patch and verification are documented beside the
binary (`README-no-mistakes.md` in the vendor directory). Even with the stock
binary, `NO_MISTAKES_TELEMETRY=off` and `NO_MISTAKES_NO_UPDATE_CHECK=1` in the
environment and in the daemon's systemd unit stop both calls; the rebuild makes
that unconditional.

## Taking an upstream update

```sh
git fetch upstream
git merge upstream/main
bin/fm-test-run.sh --family pure-contract-unit    # includes fm-airgap and fm-egress-allowlist
bin/fm-egress-audit.sh -- env FM_BOOTSTRAP_DETECT_ONLY=1 bin/fm-bootstrap.sh
```

Red on the allowlist test means upstream named a new host. Read the code that
names it, decide its class, add the line, and if it is a new opt-in third
party add a refusal to its call site and a case to `tests/fm-airgap.test.sh`.
