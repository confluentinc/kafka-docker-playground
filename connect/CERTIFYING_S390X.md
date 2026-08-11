# Certifying a connector on s390x — SME one-pager

Status as of 2026-08-10. Source docs (fuller detail, read if something here
is unclear): *s390x Connector Certification — Current Status and Path
Forward* and *Automated Testing: Connector Certification on s390x
architecture*.

**Near-term path: VM-based, not Semaphore.** Semaphore capacity was just
resolved (10 agents), but Vault access is still blocked, so any test needing
secrets can't run there yet. Until that lands, certification happens on the
3 shared s390x VMs described below. A POC pipeline already exists in
`connect-ci-cd-pipelines` ([PR #213](https://github.com/confluentinc/connect-ci-cd-pipelines/pull/213))
and will take over as the primary path once Vault access is available and
the POC is generalized beyond its current single-connector scope — that work
happens in that repo, not here.

## 1. Get a VM and set it up (once per VM)

- The 3 shared s390x VMs are coordinated ad hoc — check with the team before
  starting so you're not colliding with another SME's run.
- The VMs have **no git access**. Copy the repo over manually (`scp`/`rsync`
  your local `s390x` branch checkout), and copy any script changes back to
  your local clone before committing — nothing you edit only on the VM is
  safe until it's synced back. (`certify-connector.sh --host` does this sync
  for you when actually running a test — see section 4 — but you still need
  the one-time bootstrap below done on the VM first, and you're still
  responsible for syncing any edits back before they're lost.)
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

### SSH access prerequisites (required before using `--host`)

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

### Connector service credentials (Cloud/SaaS connectors, e.g. S3, GCS)

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
  like the real CI pipeline already uses) **over a long-lived IAM key** —
  if it's seen, it expires soon and can't do much.
- Treat any credential used this way as burned after the run if it's a
  long-lived key you can't easily rotate — this workflow is a stopgap until
  Vault access unblocks the Semaphore path (see the top of this doc), which
  removes the shared-VM exposure entirely.

**Also set a unique `AWS_BUCKET_NAME`.** `s3-sink.sh` defaults to
`pg-bucket-${USER}` if you don't set one — but the shared login means `$USER`
is the *same* value for every SME on that VM, so two people running the
default at once will collide on one bucket. Export and forward your own
`AWS_BUCKET_NAME` (add it to the `--forward-env` list above) to avoid this.

## 2. Branch strategy

- All the common framework fixes (CP image defaults, `:z` SELinux labels,
  `podman-compose --quiet` probe, etc.) live on the `s390x` base branch.
  Branch off **that**, not `master`.
- Make your connector-specific changes on your personal branch, get the test
  passing, then PR back to `s390x`.
- Purely s390x-specific workarounds (QEMU flags, platform pins) stay on
  `s390x` permanently. Anything with general backwards-compatible value
  (e.g. a genuine bug fix) gets cherry-picked to `master` separately — flag
  it in your PR description if you think something qualifies.

## 3. Find your connector's group

Check `scripts/s390x/connector-groups.txt` first — it's a simple local
reference classifying the 85 in-scope connectors (not a CI artifact; see the
file's header). If yours isn't listed, check `s390x-image-analysis.md`
directly for the full rationale.

| Group | What it means | Your effort |
|---|---|---|
| Cloud/SaaS | Calls a real cloud API, no local service container | Lowest — usually just run it |
| Group 1/2 (ready / minor fix) | Service image already has an s390x manifest, or needs a version bump | Low — check `s390x-image-analysis.md` for the target image tag |
| Group 4 (QEMU viable) | No native s390x image, but QEMU emulation works for functional testing | Medium — expect 2-5x slower runs, some debugging |
| Group 3b (QEMU high-risk, e.g. Oracle XE, SAP HANA) | JIT-heavy service, QEMU likely unstable | High, uncertain outcome — best-effort only, don't sink days into it |
| Group 3 (licensed, no public image) | Needs out-of-band image provisioning | Manual — talk to the team before starting, this isn't a script problem |

## 4. Run the certification checklist

Use the script directly, or drive it through the `/certify-s390x` Claude
Code skill — but they apply fixes differently, and it matters which one
you're using:

- **Script's `--apply-fixes`**: mechanical, fixed regex/YAML patterns. Fast
  and fine for the common cases, but its coverage is exactly as wide as
  those patterns — a multi-stage Dockerfile, an image behind a build `ARG`,
  an unusual volume line can slip past it silently.
- **The Claude Code skill**: runs the script *without* `--apply-fixes` for
  the audit, then reads the flagged files itself and applies fixes with
  full context, catching things the fixed patterns don't anticipate. If
  you're working through Claude Code, prefer this over telling it to just
  run `--apply-fixes`.

Either way, **don't do a plain audit first and only fix things after they
fail on the VM** — that burns a VM cycle on something already knowable
ahead of time. Fix proactively, before running.

Using the script's own `--apply-fixes` directly:

```
# 1. Audit AND fix in one pass (local repo edit, no VM needed yet):
bash scripts/s390x/certify-connector.sh <connector-dir> --apply-fixes

# 2. Actually run the test — from your laptop, targeting the VM over SSH:
bash scripts/s390x/certify-connector.sh <connector-dir> --run --host sme@<s390x-vm-hostname>

# ...or, if you're already SSH'd into the VM yourself, just:
bash scripts/s390x/certify-connector.sh <connector-dir> --run --apply-fixes
```

**Where you run this matters.** QEMU only exists on the VM, so running step
2 anywhere else gives a meaningless result — the script refuses to actually
run the test on a non-s390x host without `--host`, so a laptop run can't
silently produce a false pass/fail. Step 1 (audit + fix) is fine to run
locally either way, since it's pure repo editing.

Always review the diff (`git diff`) before committing — applying
automatically isn't the same as applying unreviewed. Re-running
`--apply-fixes` is safe: already-fixed lines report "OK", not "FIX NEEDED"
again.

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
  enforcing.

Things it does **not** check, that you should sanity-check yourself for
Group 4 connectors: whether the service is JIT-heavy enough that QEMU is a
bad fit in the first place (Section 4.3's QEMU-vs-external-service
tradeoff).

## 5. Diagnose failures

The script matches your test's failure output against this table
automatically; here it is for quick reference:

| Error | Cause | Fix |
|---|---|---|
| `no image found in manifest list for architecture s390x` | Service image has no s390x manifest | Add `--platform linux/amd64`, or use an external service |
| `Exec format error` | QEMU not registered, or rootless Podman | Run `setup-vm.sh`; use `sudo podman` |
| `qemu: uncaught target signal 11` in a JVM container | JIT-generated AVX/SSE crashes QEMU | Add `-e JAVA_TOOL_OPTIONS=-Xint` (gate on `uname -m = s390x`) |
| `ERR_SSL_SSLV3_ALERT_BAD_RECORD_MAC` in npm/Node | QEMU AES-NI emulation produces bad MACs | `OPENSSL_ia32cap=0x0` on the Dockerfile `RUN` step |
| `Permission denied` on a mounted file/dir | SELinux blocking the volume mount | Add `:z` to the volume entry |
| `cannot prompt without a TTY` on image pull | Podman short-name mode is `enforced` | Set `short-name-mode = "permissive"` in `/etc/containers/registries.conf` |
| `Bad PSW` from the QEMU binary | Wrong QEMU binary (`tonistiigi/binfmt`) | Re-run `setup-vm.sh` for the Debian bookworm build |
| Schema Registry crash-loops on a fresh environment | Kafka auto-creates `_schemas` with the default `delete` cleanup policy, racing Schema Registry's own explicit `compact`-policy create call. **Not a QEMU/CPU-emulation issue** (not reproduced on a fast native-Docker setup) — the actual trigger observed was Podman's CNI+dnsname networking stack being slow/less reliable than Docker's native bridge+DNS, giving the race enough of a window to go the wrong way | Handled automatically: `KAFKA_AUTO_CREATE_TOPICS_ENABLE` defaults to `false` on s390x for the startup window (`scripts/utils.sh`), then `re_enable_auto_create_topics` (`scripts/cli/src/lib/utils_function.sh`, called from `environment/plaintext/start.sh`) turns it back on once Schema Registry is confirmed up. This removes the race rather than just narrowing it — no per-connector fix needed. If you're on Podman and still hit this, see the Podman-vs-Docker note in Section 1. |
| Disk full from an old, still-running process | An orphaned container/JVM process from a previous SME's session was never cleaned up | `pkill` does not take a PID (only a process name) — use `kill <pid>` to actually stop it, then check for other stale processes before assuming the disk itself is the problem |

If nothing matches, read the actual log before guessing — don't apply
speculative fixes to a failure you haven't read.

## 6. Wrap up

- Open your KDP PR against `s390x` (not `master`) with the Dockerfile/
  docker-compose fixes.
- Separately, register (or confirm) the connector's test in
  `connect-ci-cd-pipelines`'s `cp-connector-tests/tests.txt` with your email
  as owner — that's the real, shared test list CI reads from, and how
  ownership is tracked. That's a different repo/PR from this one.
- Once both land, it's part of the certified set — no separate sign-off step.

## Getting unstuck

- Coordination / VM scheduling / "is anyone else on VM 2 right now": ask in
  the team channel (see the Path Forward doc's reference thread).
- Genuinely new failure mode not in the table above, or a QEMU reliability
  call for a Group 3b/4 connector: post the log and ask before spending a
  full day on it — QEMU debugging time is explicitly capped as
  "best-effort" in the design doc for the riskiest services.
