# Certifying a connector on s390x — tooling companion

**For the guided walkthrough, start with the [s390x KDP Testing -
Certification guide for SMEs](https://confluentinc.atlassian.net/wiki/spaces/~62ee260c3cc20c06c8afd0ff/pages/6042779888/s390x+KDP+Testing+-+Certification+guide+for+SMEs)
on Confluence** — background, scope, infrastructure choices (Semaphore
default vs. shared-VM fallback), and the step-by-step procedure live there
and are kept current, including [Appendix A's per-connector group
list](https://confluentinc.atlassian.net/wiki/spaces/~62ee260c3cc20c06c8afd0ff/pages/6042779888/s390x+KDP+Testing+-+Certification+guide+for+SMEs#Appendix-A:-Connector-groups).

This doc is the **repo-specific companion** the `/certify-s390x` skill and
`certify-connector.sh` actually run on: exact script/file paths, VM setup
detail Confluence only summarizes, the full diagnostic table, and the
Semaphore IDs the skill triggers against. Section numbers below are
load-bearing — `SKILL.md` points at several of them directly — so don't
reorder sections without updating it.

One thing worth restating because it's easy to miss: **registering a test
in `tests.txt` is a separate, out-of-scope effort from certification
itself** (same as the Confluence guide states) — see the
`kdp-cp-validation-onboard-test` skill if that's also wanted.

## 1. Find your connector's group

Check `scripts/s390x/connector-groups.txt` first — it's a simple local
reference classifying the 85 in-scope connectors (not a CI artifact; see the
file's header). If yours isn't listed, check Appendix A of the [SME
certification guide on Confluence](https://confluentinc.atlassian.net/wiki/spaces/~62ee260c3cc20c06c8afd0ff/pages/6042779888/s390x+KDP+Testing+-+Certification+guide+for+SMEs#Appendix-A:-Connector-groups),
which is the authoritative per-connector list. If it's missing from both,
that's a real stop — ask the team rather than guessing a group, and add it
to `connector-groups.txt` once you know the answer so the next SME doesn't
re-ask.

| Group | What it means | Your effort |
|---|---|---|
| Cloud/SaaS | Calls a real cloud API, no local service container | Lowest — usually just run it |
| Group 1/2 (ready / minor fix) | Service image already has an s390x manifest, or needs a version bump | Low — check Appendix A on Confluence (linked above) for the target image tag |
| Group 4 (QEMU viable) | No native s390x image, but QEMU emulation works for functional testing | Medium — expect 2-5x slower runs, some debugging |
| Group 3b (QEMU high-risk, e.g. Oracle XE, SAP HANA) | JIT-heavy service, QEMU likely unstable | High, uncertain outcome — best-effort only, don't sink days into it |
| Group 3 (licensed, no public image) | Needs out-of-band image provisioning | Manual — talk to the team before starting, this isn't a script problem |

## 2. Branch strategy

Confluence covers the general rule (branch off `s390x-base`, which carries
the common framework fixes — CP image defaults, `:z` SELinux labels, the
Schema Registry race fix, the kcat fallback — and PR back there, not
`master`). Two things worth keeping here because they're specific to this
repo's tooling layout, not general SME guidance:

- This certification tooling (`certify-connector.sh`, `setup-vm.sh`,
  `connector-groups.txt`, this doc, the Claude Code skill) lives on
  `s390x-cert-tooling`, branched from `s390x-base` — a convenience layer for
  running the checklist, not something a connector branch needs to contain.
  Merge or rebase it in locally if you want the script/skill available, but
  don't build your connector-specific branch on top of it.
- `podman-compose`'s lack of `--quiet` support on `build` is a known issue
  but **not yet fixed on `s390x-base`** — the fix was skipped because the
  file snapshot `s390x-base` forked from didn't have `--quiet` on that line
  at all, so applying the old patch would have silently changed unrelated
  behavior. If you hit `unknown flag: --quiet` on a podman-compose host,
  that's why — re-add the probe-based guard properly against current file
  content before relying on it.

## 3. Audit and fix known issues (before running, either path)

Run the script directly for a mechanical fix pass, or drive it through the
`/certify-s390x` skill for a fuller audit-then-hand-edit pass — `SKILL.md`
explains why the skill doesn't just call `--apply-fixes` itself (coverage
is only as wide as its fixed regex/YAML patterns; a multi-stage Dockerfile,
an image behind a build `ARG`, or an unusual volume line can slip past it).
Either way, fix proactively before running either path — don't burn a
Semaphore slot or VM cycle finding out about something already knowable
ahead of time.

Using the script's own `--apply-fixes` directly (pure local repo editing,
no VM or pipeline needed yet):

```
bash scripts/s390x/certify-connector.sh <connector-dir> --apply-fixes
```

Always review the diff (`git diff`) before committing — applying
automatically isn't the same as applying unreviewed. Re-running
`--apply-fixes` is safe: already-fixed lines report "OK", not "FIX NEEDED"
again.

Once you're happy with the diff, **commit and push this branch** to
`confluentinc/kafka-docker-playground` — section 4's `KDP_BRANCH_OVERRIDE`
needs a pushed branch to point at, and this is also where the Semaphore
pipeline (if you're on that path) picks up your fixes.

What it fixes automatically (Section 3 of the design doc, condensed):

- **Any image with no s390x manifest** — Dockerfile `FROM` lines in a custom
  build *and* `image:` fields directly in `docker-compose*.yml` (most
  connectors don't build their own image at all, so this second case is the
  one that matters most often): adds `--platform=linux/amd64` /
  `platform: linux/amd64`.
- **HTTPS-fetching Dockerfile `RUN` steps** (`npm install`, `pip install`,
  `apt-get install`, `curl https://...`, etc.): prefixes
  `OPENSSL_ia32cap=0x0`, or QEMU's AES-NI emulation breaks TLS.
- **EOL base images** (`node:14`, `python:3.8`, `openjdk:11`): bumped to
  `node:20`, `python:3.12`, `eclipse-temurin:17` — they carry more QEMU
  compatibility gaps.
- **SELinux `:z` on host-path volume mounts**: added to any docker-compose
  entry mounting a host path (`./...` or `../...`), on RHEL 10 with SELinux
  enforcing (only relevant for the VM fallback — the Semaphore agent doesn't
  run with SELinux enforcing).

Things it does **not** check, that you should sanity-check yourself for
Group 4 connectors: whether the service is JIT-heavy enough that QEMU is a
bad fit in the first place. If it is, "Manual Testing: Connector
Certification Guide — s390x" on Confluence covers standing up the target
service on a real amd64 host and pointing the connector at it externally
instead of fighting QEMU.

## 4. Run it: the Semaphore pipeline (default)

**Prerequisite: the test must already be registered in `tests.txt`.** The
pipeline resolves `CP_CONNECT_TESTS_OVERRIDE` by filtering it against
`cp-connector-tests/tests.txt` in `connect-ci-cd-pipelines` — it can't run a
test it doesn't know about. **If your connector's test isn't in there yet,
run it on the shared VM instead (section 5)** — registering it into
`tests.txt` is a separate, out-of-scope onboarding effort (see the
`kdp-cp-validation-onboard-test` skill if that's also wanted), not a step in
certifying this connector.

Once registered, trigger the `run-cp-connector-selected-tests-s390x` task in
Semaphore directly against `connect-ci-cd-pipelines` with:

- `CP_CONNECT_TESTS_OVERRIDE` (required) — pipe-separated test name(s) from
  `tests.txt`, e.g. `MysqlSourceTest` or `MysqlSourceTest|SnowflakeSinkTest`.
- `CP_VERSION` / `RC_IMAGE_TAG` / `NIGHTLY_IMAGE_TAG` / `CP_RELEASE_BRANCH_OVERRIDE`
  — same image-tag resolution as the amd64 pipelines; leave unset to
  auto-detect the latest intermediate tag off `cp-server-connect:latest`.
- `KDP_REPO_OVERRIDE` / `KDP_BRANCH_OVERRIDE` — set `KDP_BRANCH_OVERRIDE` to
  the personal `s390x-base`-derived branch you pushed at the end of section
  3 (and `KDP_REPO_OVERRIDE` if it's on a fork), instead of leaving it on
  `confluentinc/kafka-docker-playground@master`, to validate your fixes
  before they're merged there.

**Credentials are handled for you.** The pipeline pulls
`connect/system-tests/CP_CONNECTOR_TEST_CREDS` from Vault and does an AWS STS
assume-role for scoped creds — the same credential source the existing
amd64 `cp-connector-tests` pipeline already uses for the full connector
list. If a connector's test already runs against that Vault secret on
amd64, you don't need to gather or forward any credentials yourself for the
s390x run either. This only breaks down for a connector whose credentials
live outside that Vault path — check with the team if you're not sure,
rather than assuming.

**Triggering via Claude Code:** the `/certify-s390x` skill triggers this
task directly through the Semaphore MCP tools and polls it to completion —
the same pattern `kdp-cp-validation-onboard-test` uses for the generic
multi-arch task — see this skill's own `SKILL.md` step 3a for the exact
calls. It shares that other task's Semaphore project
(`connect-ci-cd-pipelines`, `project_id` `8b75ea88-cb41-42ae-a69e-c8237dcbb0d5`,
org `semaphore` `6ab08ce0-d948-4a80-b8e7-748bbb9cdf64`), and
`run-cp-connector-selected-tests-s390x` itself now has a confirmed
`task_id`: `712884d6-1a50-4dcc-a591-1b5e20af2997` (PR #223 merged
2026-08-18). If `mcp__semaphore__tasks_run` isn't connected in your
session, or these IDs ever turn out stale, trigger manually from the
Semaphore UI as described above instead.

The pipeline runs on the `s1-ubuntu-24-s390x-4` agent pool, handles its own
QEMU bootstrap (the same Debian 12 bookworm `qemu-user-static` 7.2 build and
anti-`tonistiigi/binfmt` reasoning as `setup-vm.sh` — good cross-confirmation
that approach is right), installs `docker buildx` manually (not preinstalled
on this agent image — if you ever see `docker: 'buildx' is not a docker
command` on the VM fallback too, the same GitHub-release install works),
runs the test via `playground run`, and publishes a JUnit report plus
connect-container logs and `playground container display-error-all-containers`
output as Semaphore artifacts per test. A `playground run` exit code of 107
is treated as `known_issue` and 111 as `skipped` — both are non-failing
outcomes, not silent passes, so don't read a green pipeline as "every test
actually ran clean" without checking which status each one got.

`num_jobs` currently defaults to `"1"` — conservative, left over from the
old single-capacity validation pool (DP-19305) and not yet reconfirmed
against the new 10-agent GA pool (DP-19829). Don't assume you can fan out
many connectors in parallel yet; check with the team first if you want to
push on that.

One thing this pipeline does that isn't yet ported to `s390x-base`: it
comments out `KAFKA_METRIC_REPORTERS` in both
`environment/plaintext/docker-compose.yml` and `docker-compose-kraft.yml`
before running. Unlike the Schema Registry race fix in section 6, the root
cause here isn't confirmed — just observed as necessary in this pipeline.
If you hit a `KAFKA_METRIC_REPORTERS`-related startup failure on the VM
fallback that doesn't match anything else in the diagnostic table, try the
same comment-out before spending time elsewhere, and flag it to the team as
a possible `s390x-base` gap.

## 5. Fallback: the shared VM path

Use this when: a connector's test isn't registered in `tests.txt` yet; you're
doing fast, interactive Group 3b iteration; or the Semaphore pipeline is
unavailable/at capacity.

### 5.1 Get a VM and set it up (once per VM)

- The 3 shared s390x VMs are coordinated ad hoc — check with the team before
  starting so you're not colliding with another SME's run.
- The VMs have **no git access**. Copy the repo over manually (`scp`/`rsync`
  your local `s390x-base`-derived branch checkout), and copy any script
  changes back to your local clone before committing — nothing you edit
  only on the VM is safe until it's synced back. (`certify-connector.sh
  --host` does this sync for you when actually running a test — see 5.4 —
  but you still need the one-time bootstrap below done on the VM first, and
  you're still responsible for syncing any edits back before they're lost.)
- **Check what container runtime is already there before installing anything.**
  Don't assume Podman just because an earlier design doc assumed RHEL 10 —
  one of the actual shared VMs turned out to be Ubuntu with no runtime at
  all. If you have to choose:
  - **Prefer real Docker** (`docker.io` + `docker-compose-plugin`) if
    there's no rootless-by-policy requirement forcing Podman. KDP's
    compose files and `profiles:` gating were designed against Docker
    Compose — using it avoids an entire class of problems: `podman-compose`
    doesn't handle `profiles:` correctly, older Podman needs a custom
    compose-provider dispatch shim, `unqualified-search-registries`/
    `short-name-mode` need manual config, and `netavark`/`aardvark-dns`
    (Podman's DNS stack) aren't packaged for s390x at all. Docker ships its
    own embedded DNS and has none of this.
  - **If Podman is required**, don't reach for `podman-compose` (a
    third-party reimplementation) — point the real `docker-compose` binary
    at Podman's Docker-API-compatible socket instead, which is Podman's own
    documented compose story and handles `profiles:` correctly:
    ```
    export DOCKER_HOST=unix:///run/podman/podman.sock
    ```
  - If you do end up on Podman without netavark (no s390x package), the
    older CNI `dnsname` plugin is the fallback for container-name DNS
    resolution — but expect it to be slower/less reliable than Docker's or
    netavark's, which is the actual cause behind the Schema Registry race
    in the diagnostic table below (it's not a QEMU/CPU thing).
- Run the one-time bootstrap (idempotent — safe to re-run, but the QEMU
  binfmt registration is in-memory and **does not survive a VM reboot**, so
  re-run it after any restart):
  ```
  sudo bash scripts/s390x/setup-vm.sh
  ```
  This checks which runtime is present and tells you the above if neither
  is (it does not install one for you), installs the QEMU 7.2 static binary
  (Debian 12 bookworm build — not `tonistiigi/binfmt`, which crashes on
  this CPU generation), registers it with binfmt_misc, and — only if Podman
  is what's actually there — sets its short-name resolution to permissive.

### 5.2 SSH access prerequisites (required before using `--host`)

The VMs are accessed by private key, not password. `certify-connector.sh
--host` requires **non-interactive** key-based auth to already be working —
it will not prompt you for anything, and neither will Claude Code if you're
driving this through the skill. Set this up once per VM, before your first
`--host` run:

1. Get the private key for the VM through the team's normal channel (ask in
   the coordination channel referenced under "Getting unstuck" below — it is
   **not** distributed through this repo or through Claude Code).
2. Save it and lock down its permissions (SSH refuses to use an
   overly-permissive key file):
   ```
   mkdir -p ~/.ssh
   cp /path/to/downloaded-key.pem ~/.ssh/s390x-vm.pem
   chmod 600 ~/.ssh/s390x-vm.pem
   ```
3. Add a `Host` entry to `~/.ssh/config` so both you and the script can refer
   to the VM by a short alias instead of repeating the key path every time:
   ```
   Host s390x-vm-1
       HostName <vm-hostname-or-ip>      # get from the team channel
       User <your-username-on-the-vm>    # get from the team channel
       IdentityFile ~/.ssh/s390x-vm.pem
       IdentitiesOnly yes
   ```
4. Confirm it works **manually, interactively, once**, before scripting
   anything against it:
   ```
   ssh s390x-vm-1
   ```
   The first connection prompts to accept the VM's host key — accept it now,
   this way, rather than hitting that prompt inside a non-interactive script
   run later. If this logs you in with no password prompt, you're done. If
   it does prompt for a password, key-based auth isn't wired up yet — fix
   that here before trying `--host`, don't work around it.
5. Once step 4 works with zero prompts, use the alias as your `--host` value:
   ```
   bash scripts/s390x/certify-connector.sh <connector-dir> --run --host s390x-vm-1
   ```
   Prefer the config alias (`s390x-vm-1`) over a raw `user@ip` string — the
   alias is what carries the `IdentityFile`, so the script (and the skill)
   don't need any separate way to know which key to use.

### 5.3 Connector service credentials (Cloud/SaaS connectors, e.g. S3, GCS)

Some connectors need real service credentials to run at all — check the
connector's own `README.md` (e.g. `connect-aws-s3-sink` needs
`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_REGION`, exactly like it
would for a local, non-s390x run). **Do not put these in a persistent file
on the VM** (e.g. `~/.aws/credentials`) — the shared VMs use one login
across all SMEs, so anything written there sits readable by everyone else
using that VM indefinitely, not just while your test runs.

Instead, export the credentials in your own local shell (same as you would
for testing this connector anywhere else) and forward them for a single run
with `--forward-env`:

```
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_SESSION_TOKEN=...   # if using temporary credentials
export AWS_REGION=us-west-2

bash scripts/s390x/certify-connector.sh connect-aws-s3-sink --run --host s390x-vm-1 \
    --forward-env AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY,AWS_SESSION_TOKEN,AWS_REGION
```

This pipes the named vars into that one remote test run only — never written
to a file on the VM, never appearing on a command line there. It is **not**
full isolation: the shared-login model means another SME on the same VM
could technically read the forwarded values from the running process's
environment for as long as your test is executing. Two things reduce the
real risk:

- **Prefer short-lived, scoped credentials** (an assumed-role session token,
  like the Semaphore pipeline already uses) **over a long-lived IAM key** —
  if it's seen, it expires soon and can't do much.
- Treat any credential used this way as burned after the run if it's a
  long-lived key you can't easily rotate — this is exactly the exposure the
  default Semaphore path (section 4) removes, since it pulls scoped creds
  from Vault centrally instead of forwarding a personal key through a
  shared login. Prefer section 4 whenever the test is already registered.

**Watch for `$USER`-derived resource names.** Several connector scripts
(e.g. `connect-aws-s3-sink/s3-sink.sh` defaults to `pg-bucket-${USER}`)
name cloud resources after `$USER` — harmless on a normal machine, but the
shared login here means `$USER` is the *same* value for every SME on the
VM, so two people running the same connector at once can collide on one
resource. Check whether the script actually honors a pre-set override
(some don't — that's a legitimate small fix to make while certifying a
connector) before assuming `export AWS_BUCKET_NAME=... --forward-env
AWS_BUCKET_NAME` will help.

### 5.4 Running the test

```
bash scripts/s390x/certify-connector.sh <connector-dir> --run --host <alias>
```

**Where you run this matters.** QEMU only exists on the VM, so running this
anywhere else gives a meaningless result — the script refuses to actually
run the test on a non-s390x host without `--host`, so a laptop run can't
silently produce a false pass/fail.

## 6. Diagnose failures

For a Semaphore run, start from the JUnit report and the
`playground_display_error_all_containers_output.txt` / connect-container-log
artifacts the pipeline publishes per test. For a VM fallback run, the script
matches the captured log against this table automatically:

| Error | Cause | Fix |
|---|---|---|
| `no image found in manifest list for architecture s390x` | Service image has no s390x manifest | Add `--platform linux/amd64`, or use an external service |
| `Exec format error` | QEMU not registered, or rootless Podman | Run `setup-vm.sh`; use `sudo podman` |
| `qemu: uncaught target signal 11` in a JVM container | JIT-generated AVX/SSE crashes QEMU | Add `-e JAVA_TOOL_OPTIONS=-Xint` (gate on `uname -m = s390x`) |
| `ERR_SSL_SSLV3_ALERT_BAD_RECORD_MAC` in npm/Node | QEMU AES-NI emulation produces bad MACs | `OPENSSL_ia32cap=0x0` on the Dockerfile `RUN` step |
| `Permission denied` on a mounted file/dir | SELinux blocking the volume mount | Add `:z` to the volume entry |
| `cannot prompt without a TTY` on image pull | Podman short-name mode is `enforced` | Set `short-name-mode = "permissive"` in `/etc/containers/registries.conf` |
| `Bad PSW` from the QEMU binary | Wrong QEMU binary (`tonistiigi/binfmt`) | Re-run `setup-vm.sh` for the Debian bookworm build |
| Schema Registry crash-loops on a fresh environment | **Confirmed via a clean A/B re-test on a real s390x VM** (same VM, same connector, with the fix present vs absent): removing the auto-create gate reliably makes the test fail, restoring it reliably makes it pass. Root cause: Kafka auto-creates `_schemas` with the default `delete` cleanup policy, racing Schema Registry's own explicit `compact`-policy create call on startup. The *exact* trigger for why this race goes the wrong way on s390x (a working theory is Podman's CNI+dnsname DNS stack being slower than Docker's native bridge+DNS) is still not independently confirmed — what's confirmed is that the fix is necessary, not just plausible. | Handled automatically: `KAFKA_AUTO_CREATE_TOPICS_ENABLE` defaults to `false` on s390x for the startup window (`scripts/utils.sh`), then `re_enable_auto_create_topics` (`scripts/cli/src/lib/utils_function.sh`, called from `environment/plaintext/start.sh`) turns it back on once Schema Registry is confirmed up. No per-connector fix needed. |
| Disk full from an old, still-running process | An orphaned container/JVM process from a previous SME's session was never cleaned up | `pkill` does not take a PID (only a process name) — use `kill <pid>` to actually stop it, then check for other stale processes before assuming the disk itself is the problem |
| Broker fails to start / crashes early in a fresh environment, no other row matches | **Not fully confirmed** — observed as a necessary workaround in the Semaphore s390x pipeline ([PR #223](https://github.com/confluentinc/connect-ci-cd-pipelines/pull/223)); root cause not root-caused the way the Schema Registry race above is | Comment out `KAFKA_METRIC_REPORTERS: $KAFKA_METRIC_REPORTERS` in `environment/plaintext/docker-compose.yml` and `docker-compose-kraft.yml`; not yet ported to `s390x-base` — flag to the team if this fixes your run |
| `no image found in manifest list for architecture s390x` for `confluentinc/cp-kcat`, in a **ccloud-environment** test | `cp-kcat` has no s390x manifest | Handled automatically in `scripts/cli/src/commands/topic/get-number-records.sh`: on s390x, falls back to the connect image (which ships kcat) instead of `cp-kcat`. Only covers that one ad-hoc kcat container — the standing `kcat` service in `environment/plaintext/docker-compose.yml` is handled separately via the `platform: linux/amd64` QEMU pin above. Note: the plaintext-environment path most certification runs use never touches kcat at all (it execs into the broker container directly), so this fix is currently only relevant if you're running ccloud-mode tests on s390x. |

If nothing matches, read the actual log before guessing — don't apply
speculative fixes to a failure you haven't read.

## 7. Wrap up

- Open your KDP PR against `s390x-base` (not `master`, and not
  `s390x-cert-tooling`) with the Dockerfile/docker-compose fixes, to enable
  future automated runs. Link the green Semaphore run (or, if you went the
  VM fallback route for a Group 3b connector, say so explicitly) as evidence.
- If the connector's group was missing or wrong in `connector-groups.txt`,
  update it as part of this PR and flag the Confluence Appendix A entry for
  a follow-up correction — otherwise the next SME re-does your
  classification work from scratch.
- Registering the test in `connect-ci-cd-pipelines`'s `tests.txt` (so future
  runs default to Semaphore instead of the VM) is a separate, optional
  follow-up — see the `kdp-cp-validation-onboard-test` skill — not required
  to call this connector certified.

## Getting unstuck

- Coordination / VM scheduling / "is anyone else on VM 2 right now": ask in
  the team channel (see the Path Forward doc's reference thread).
- Genuinely new failure mode not in the table above, or a QEMU reliability
  call for a Group 3b/4 connector: post the log and ask before spending a
  full day on it — QEMU debugging time is explicitly capped as
  "best-effort" for the riskiest services. If QEMU itself is the blocker,
  "Manual Testing: Connector Certification Guide — s390x" on Confluence
  covers standing up the target service on a real amd64 host and pointing
  the connector at it externally instead.
