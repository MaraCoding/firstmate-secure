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

On a new machine, clone this repo and the vendor directory side by side in any
folder, install from the vendor directory, then open a new terminal so the
tools are on `PATH`. To keep the tools out of the home directory too, pass
`--prefix`:

```sh
cd /mnt/workspace   # or any folder
git clone https://github.com/MaraCoding/firstmate-secure.git firstmate
git clone https://github.com/MaraCoding/firstmate-vendor.git firstmate-vendor
firstmate/bin/fm-vendor-install.sh --airgap --prefix /mnt/workspace/fm-tools   # omit --prefix to install under ~
```

The installer finds `firstmate-vendor` beside the checkout (or `--vendor <dir>`,
or `$FM_VENDOR_DIR`). With `--prefix <dir>` every tool, the npm packages and
cache, no-mistakes and its data (`NM_HOME`) and lavish state
(`LAVISH_AXI_STATE_DIR`) live under `<dir>`; without it they go to
`~/.local/bin`, the npm global bin (a per-user prefix when the global one is
not writable) and `~/.no-mistakes`. Either way it writes one env file
(`<dir>/env.sh`, or `~/.config/firstmate/vendor-env.sh`) and adds one line to
`~/.bashrc` (and `~/.zshrc`, `~/.profile` when they exist) that sources it;
later runs reuse the same prefix. It also puts the quota-axi shim
(`bin/fm-quota-axi-shim.sh`) in front of the real quota-axi: stock quota-axi
probes every provider it finds a credential for, including GitHub Copilot by
sending the `gh` token to api.github.com; the shim pins reads to Claude and
Codex (the only providers firstmate routes between) and refuses `update` under
the airgap switch. It also seeds `config/crew-dispatch.json` from
`config-defaults/crew-dispatch.json` when the home has none (`config/` is
gitignored, so a fresh clone otherwise has no routing rules and every crewmate
gets the default harness); an existing file is never overwritten. Under the airgap switch, `bin/fm-bootstrap.sh`
names this installer for any missing vendored tool, and
`bin/fm-bootstrap.sh install` runs it instead of `curl | sh` or the public npm
registry.

The `lavish-local` source lives in the private `MaraCoding/lavish-local`; the
vendor directory already carries its packed tarball, so the install does not
need it.

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

Stock `lavish-axi`, the review surface behind `/bearings lavish`, reports every
CLI invocation to `a.kunchenguid.com` (Umami; opt-out `LAVISH_AXI_TELEMETRY=off`),
can publish artifacts to the third-party host ht-ml.app, and resolves its own
Tailscale MagicDNS name on every open. The airgapped install therefore uses
`lavish-local`, an offline replica that keeps the binary name `lavish-axi`, the
`--version` gate, the session-key derivation, the `state.json` layout and the
TOON wire shapes this repo's `bin/fm-bearings-board.sh` and
`bin/fm-procevent-lavish.sh` are written against, so no script here changes.
It ships as `npm/lavish-local-1.0.0.tgz` in the vendor directory; its own README
owns the contract table and the upstream invariants it ports. On a machine that
also has the stock package installed, `~/.local/bin/lavish-axi` must resolve to
the replica (`lavish-axi --version` prints `0.1.90-local`). The two-track
layout on the evaluation box, and how to update either track, is in the vendor
directory's `TRACKS.md`.

## Taking an upstream update

```sh
git fetch upstream
git merge upstream/main
bin/fm-test-run.sh --family pure-contract-unit    # includes fm-airgap and fm-egress-allowlist
bin/fm-egress-audit.sh -- env FM_BOOTSTRAP_DETECT_ONLY=1 bin/fm-bootstrap.sh
FM_BEARINGS_LAVISH_LIVE=1 bash tests/fm-bearings-board-lavish-live-e2e.test.sh   # with lavish-local on PATH
```

Red on the allowlist test means upstream named a new host. Read the code that
names it, decide its class, add the line, and if it is a new opt-in third
party add a refusal to its call site and a case to `tests/fm-airgap.test.sh`.
Red on the live board test, or a raised `LAVISH_AXI_MIN` / `LAVISH_AXI_BOARD_MIN`
in `bin/fm-bootstrap.sh`, means upstream now expects something newer from
Lavish; the replica's maintenance steps are in the vendor directory's
`TRACKS.md` (section "lavish-axi publishes a new version").
