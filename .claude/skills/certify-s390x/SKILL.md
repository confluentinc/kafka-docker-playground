---
name: certify-s390x
description: Walk an SME through certifying one KDP connector on s390x — group lookup, custom-build/Dockerfile fixes, running the test, diagnosing failures, and the branch/PR workflow. Use when the user asks to certify, port, or debug a connector for s390x/IBM Z, or mentions the s390x certification checklist.
---

# Certifying a connector on s390x

This skill automates the deterministic parts of the per-connector certification
checklist from "Automated Testing: Connector Certification on s390x
architecture" (Section 5.4/5.5), using `scripts/s390x/certify-connector.sh` as
the underlying engine. It is meant to be run by a connector SME with Claude
Code, on an s390x VM (or against the repo for the audit-only steps, from any
machine). See `connect/CERTIFYING_S390X.md` for the plain-prose version of
this same workflow.

## Inputs

Ask the user (if not already given) which connector to certify — the
directory name under `connect/`, e.g. `connect-cassandra-sink`.

## Procedure

1. **Dry-run audit.** Run:
   ```
   bash scripts/s390x/certify-connector.sh <connector-dir>
   ```
   This reports (a) the connector's group from `scripts/s390x/connector-groups.txt`,
   (b) whether QEMU is registered on this host, and (c) any custom Docker
   builds with known issues (missing `--platform=linux/amd64`, missing
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

3. **Run the test.** Once fixes are applied and you're on an s390x host with
   QEMU registered:
   ```
   bash scripts/s390x/certify-connector.sh <connector-dir> --run
   ```
   If not on s390x, tell the user this step needs to happen on one of the
   shared VMs (see `connect/CERTIFYING_S390X.md` for VM access) and stop here
   — do not attempt to fake or skip validation.

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
