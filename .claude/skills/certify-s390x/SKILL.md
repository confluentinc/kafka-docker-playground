---
name: certify-s390x
description: Walk an SME through certifying one KDP connector on s390x — group lookup, custom-build/Dockerfile fixes, running the test, diagnosing failures, and the branch/PR workflow. Use when the user asks to certify, port, or debug a connector for s390x/IBM Z, or mentions the s390x certification checklist.
---

# Certifying a connector on s390x

This skill automates the deterministic parts of the per-connector certification
checklist from "Automated Testing: Connector Certification on s390x
architecture" (Section 5.4/5.5), using `scripts/s390x/certify-connector.sh` as
the underlying engine. See `connect/CERTIFYING_S390X.md` for the plain-prose
version of this same workflow.

**Two-host reality: Claude Code is almost never running on the s390x VM
itself.** The SME is typically driving this from their laptop (or wherever
Claude Code runs), while QEMU and the actual test run only mean something on
one of the shared s390x VMs. Never assume "the host this command runs on" is
the VM — check explicitly (see Inputs and Procedure step 1 below), because a
QEMU check or test run silently executed on the wrong host produces a
meaningless but confident-looking result.

## Inputs

Ask the user (if not already given):
1. Which connector to certify — the directory name under `connect/`, e.g.
   `connect-cassandra-sink`.
2. Whether they intend to actually run the test in this session, and if so,
   their `~/.ssh/config` alias for the target VM (e.g. `s390x-vm-1`) — not a
   raw `user@host` string, since the alias is what carries the private key
   (`IdentityFile`). If they don't have one set up yet, point them at
   `connect/CERTIFYING_S390X.md` section 1 ("SSH access prerequisites") and
   have them complete that — including the one manual interactive `ssh
   <alias>` login it requires — before coming back to this. If they only
   want the audit (group lookup + Dockerfile/compose checks), no VM/SSH
   access is needed yet.
3. **If the connector's README lists required service credentials** (check
   `connect/<connector-dir>/README.md` — e.g. `connect-aws-s3-sink` needs
   `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_REGION`): ask whether the
   user already has those exported in *their local shell* (not the VM). If
   so, get the exact env var names so you can pass them via `--forward-env`
   in step 3 below. If they don't have credentials at all yet, that's a
   prerequisite to sort out before running — don't proceed to a `--run`
   that's guaranteed to fail on missing creds.

## Procedure

1. **Dry-run audit — safe to run from any machine.** Run:
   ```
   bash scripts/s390x/certify-connector.sh <connector-dir>
   ```
   This reports (a) the connector's group from `scripts/s390x/connector-groups.txt`,
   (b) whether QEMU is registered *on whatever host this command runs on* —
   if that's not the s390x VM, this will correctly report "not s390x,
   skipping," which is expected and not a real check yet — and (c) any custom
   Docker builds with known issues (missing `--platform=linux/amd64`, missing
   `OPENSSL_ia32cap=0x0` on HTTPS `RUN` steps, EOL base images, missing `:z`
   SELinux relabels on docker-compose volume mounts).

   - If the connector isn't found in `connector-groups.txt`, check
     `s390x-image-analysis.md` for its group manually before proceeding — if
     it's Group 3 (licensed/commercial, no public s390x image), stop and tell
     the user this needs out-of-band image provisioning, not this workflow.
   - If it's a QEMU high-risk service (Oracle XE, SAP HANA — see the design
     doc's Group 3b), tell the user upfront that QEMU is best-effort and the
     outcome is uncertain, so they can decide whether to spend time on it.

2. **Apply the safe fixes.**
   - Dockerfile fixes (`--platform`, `OPENSSL_ia32cap`) are safe to apply
     automatically: re-run with `--apply-fixes`, or apply them yourself with
     the Edit tool if you want to review each change first — the script's
     dry-run output tells you the exact line and fix.
   - `:z` SELinux relabels on docker-compose volume mounts are flagged but
     *not* auto-applied (YAML volume syntax varies too much to safely
     regex-rewrite) — read the flagged file and add `:z` (or `,z` if other
     options are already present) to each host-mounted volume entry yourself
     with the Edit tool.
   - Image-version bumps (e.g. `prom/prometheus:v2.11.1` → `v2.53.0`,
     `cassandra:3.0` → `cassandra:4.1`) aren't auto-detected — if the group
     lookup says Group 2 ("minor image version change needed"), check
     `s390x-image-analysis.md` for the target version and edit
     `docker-compose*.yml` directly.

3. **Run the test — this is where the VM matters.** If you have the user's
   `~/.ssh/config` alias for the VM (from Inputs), pass it via `--host` and
   the script handles syncing the repo and running remotely for you:
   ```
   bash scripts/s390x/certify-connector.sh <connector-dir> --run --host <alias>
   ```
   If the connector needs service credentials (from Inputs step 3), add
   `--forward-env` with the exact var names, comma-separated — do not read or
   echo their values yourself, just pass the names through:
   ```
   bash scripts/s390x/certify-connector.sh connect-aws-s3-sink --run --host <alias> \
       --forward-env AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY,AWS_SESSION_TOKEN,AWS_REGION
   ```
   This forwards those vars from the user's local shell into that one remote
   run only (see the script's own `--forward-env` header comment for exactly
   how — piped over stdin, never on a command line, never written to disk on
   the VM). It is *not* full isolation: these VMs share one login across all
   SMEs, so anything forwarded is still technically readable by another SME
   on the same VM while the process runs (via `/proc/<pid>/environ` under the
   shared account). Tell the user this plainly rather than implying it's
   fully private, and prefer a short-lived/scoped credential (e.g. an
   assumed-role session token) over a long-lived static key if they have a
   choice — this shrinks how bad it is if it's seen, since the forwarding
   itself can't fully prevent that on a shared account.

   If you're already running this command directly on the s390x VM (e.g. the
   user has an interactive Claude Code session open over SSH to the VM
   itself), omit `--host` (and `--forward-env` — just export the vars in that
   session yourself, no forwarding needed) — the script detects it's already
   on s390x and runs locally.

   If neither applies (no VM access yet, no alias given), **stop here** and
   tell the user this step needs a real s390x VM — do not attempt to run the
   test locally to "see what happens." The script itself will refuse to run
   on a non-s390x host without `--host`, but don't rely on that guard as the
   plan; ask for VM access first.

   **Auth: never handled by you or the script.** `--host` requires the
   non-interactive key-based access set up in `connect/CERTIFYING_S390X.md`
   section 1 ("SSH access prerequisites") — a private key referenced by
   `IdentityFile` in an `~/.ssh/config` `Host` entry, verified once with a
   manual `ssh <alias>` login. The script preflights this with a
   non-interactive (`BatchMode=yes`) check and fails fast with a clear error
   if it can't connect, rather than hanging on a password prompt neither you
   nor the script can answer. If that preflight fails:
   - **Never ask the user to paste a password or private key into chat** —
     that would put a credential in the conversation transcript, which is
     exactly what key-based SSH auth exists to avoid.
   - Point them at the CERTIFYING_S390X.md prerequisites section and have
     them complete it, then confirm `ssh <alias>` works with zero prompts
     before retrying `--host`.
   - If it's a brand-new host, they need one manual interactive `ssh <alias>`
     first to accept its host key. Do not suggest disabling host key checking
     to work around this — that removes protection against a spoofed host.

4. **Diagnose and iterate.** On failure, the script matches the log against
   the Section 5.5 diagnostic table and prints a cause + fix. Apply the fix,
   re-run, repeat. If a failure doesn't match any known pattern, read the
   captured log yourself (path printed by the script) before guessing —
   don't apply speculative fixes to a failure you haven't actually read.

5. **Once it passes**, walk the user through wrapping up (see
   `connect/CERTIFYING_S390X.md` "Wrap up" section):
   - Confirm they're on a personal branch off the `s390x` base branch (not
     directly on `s390x` or `master`).
   - Remind them to open the KDP PR against `s390x`, not `master` — purely
     s390x-specific workarounds stay on `s390x` permanently; anything with
     backwards-compatible value gets cherry-picked to `master` separately.
   - Separately, the connector's test needs registering (owner + path) in
     `connect-ci-cd-pipelines`'s `cp-connector-tests/tests.txt` — that's the
     real, shared CI test list, in a different repo. This skill doesn't do
     that for them; just point it out.

## What this skill does not do

- It does not provision licensed/vendor images (Group 3) or set up external
  services (Option B from the QEMU-vs-external-service tradeoff) — those are
  manual infrastructure decisions, not scriptable fixes.
- It does not decide when to give up on a QEMU-emulated Group 3b service —
  that's a judgment call for the SME based on how much debugging time is
  justified.
- It does not manage VM access or SSH credentials — if the user doesn't have
  an SSH target for a shared VM yet, that's a coordination step (see
  `connect/CERTIFYING_S390X.md` section 1), not something to work around.
