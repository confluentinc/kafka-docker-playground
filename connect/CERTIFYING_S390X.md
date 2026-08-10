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
- Run the one-time bootstrap (idempotent — safe to re-run, but the QEMU
  binfmt registration is in-memory and **does not survive a VM reboot**, so
  re-run it after any restart):
  ```
  sudo bash scripts/s390x/setup-vm.sh
  ```
  This installs the QEMU 7.2 static binary (Debian 12 bookworm build — not
  `tonistiigi/binfmt`, which crashes on this CPU generation), registers it
  with binfmt_misc, and sets podman's short-name resolution to permissive.

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

Use the script (or the `/certify-s390x` Claude Code skill, which wraps the
same logic and walks you through applying fixes and the PR flow).

**Where you run this matters.** If you're working from your laptop (e.g.
driving this through a local Claude Code session) rather than an SSH session
already open on the VM, the audit steps are fine to run locally, but the
actual test run is not — QEMU only exists on the VM, so running there is the
only way the result means anything. Use `--host` to have the script sync the
repo and run remotely for you:

```
# 1. Audit only — reports group, QEMU status (of wherever this runs), and Dockerfile issues
bash scripts/s390x/certify-connector.sh <connector-dir>

# 2. Apply the safe, deterministic fixes it found (local repo edit, no VM needed)
bash scripts/s390x/certify-connector.sh <connector-dir> --apply-fixes

# 3. Actually run the test — from your laptop, targeting the VM over SSH:
bash scripts/s390x/certify-connector.sh <connector-dir> --run --host sme@<s390x-vm-hostname>

# ...or, if you're already SSH'd into the VM yourself, just:
bash scripts/s390x/certify-connector.sh <connector-dir> --run
```

The script refuses to actually run the test on a non-s390x host without
`--host` — that guard exists so a laptop run can't silently produce a
meaningless pass/fail against the wrong architecture.

What it checks automatically (Section 3 of the design doc, condensed):

- **Custom Docker builds** (`build:` in `docker-compose*.yml`): does the base
  image have an s390x manifest? If not, needs `FROM --platform=linux/amd64
  <image>`.
- **HTTPS-fetching `RUN` steps** (`npm install`, `pip install`, `apt-get
  install`, `curl https://...`, etc.): needs `OPENSSL_ia32cap=0x0` prefixed,
  or QEMU's AES-NI emulation breaks TLS.
- **EOL base images** (`node:14`, `python:3.8`, `openjdk:11`): flagged for
  upgrade — they carry more QEMU compatibility gaps.
- **SELinux `:z` on volume mounts**: flagged but not auto-fixed — add `:z`
  yourself to any docker-compose entry mounting a host path, on RHEL 10 with
  SELinux enforcing.

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
