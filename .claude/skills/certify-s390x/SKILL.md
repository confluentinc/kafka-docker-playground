---
name: certify-s390x
description: Walk an SME through certifying one KDP connector on s390x — group lookup, custom-build/Dockerfile fixes, triggering the Semaphore s390x pipeline (default) or running on a shared VM (fallback), diagnosing failures, and the branch/PR workflow. Use when the user asks to certify, port, or debug a connector for s390x/IBM Z, or mentions the s390x certification checklist.
---

# Certifying a connector on s390x

This skill automates the deterministic parts of the per-connector
certification checklist described in the ["s390x KDP Testing - Certification
guide for SMEs"](https://confluentinc.atlassian.net/wiki/spaces/~62ee260c3cc20c06c8afd0ff/pages/6042779888/s390x+KDP+Testing+-+Certification+guide+for+SMEs)
on Confluence. `scripts/s390x/certify-connector.sh` handles the parts that
are pure procedure with no judgment involved — group lookup, Dockerfile/
compose audit, image-manifest verification, running the test (over SSH, for
the VM fallback), diagnosing a failure against the known error table. See
`connect/CERTIFYING_S390X.md` for the repo-specific tooling detail (exact
paths, VM setup, diagnostic table, Semaphore IDs) that companion doc adds on
top of the Confluence guide.

**Default path is the Semaphore pipeline, not a shared VM.**
`run-cp-connector-selected-tests-s390x` in `connect-ci-cd-pipelines` (added
via PR #223) runs on the real `s1-ubuntu-24-s390x-4` agent pool with Vault
credentials already wired in. Use it for any connector whose test is already
registered in `cp-connector-tests/tests.txt`. The 3 shared s390x VMs are now
the fallback: pre-registration iteration on a brand-new connector, fast
interactive iteration on a Group 3b (QEMU high-risk) connector, or when the
pipeline itself is unavailable. Don't reach for `--host`/the VM by default —
check whether the pipeline path applies first (see Procedure step 3).

**You (not the script) apply the fixes.** The script also ships an
`--apply-fixes` flag that mechanically rewrites the common cases via fixed
regex/YAML patterns — it's there as a fast path for someone running the
script directly outside Claude Code. But its coverage is exactly as wide as
the patterns it was written for: a multi-stage Dockerfile, an image
referenced through a build `ARG`, a `platform:` key already set on a
different line, an unusual volume/compose structure — any of these can slip
past it silently. You have Read/Grep/Edit and can actually look at the file
in front of you, so don't be limited by what the script happens to handle.
Use it (without `--apply-fixes`) to get a fast, reliable *audit* — the
group, the QEMU status, and a list of findings with file/line/image — then
apply every fix yourself by reading the flagged file and editing it
directly, using the same fix recipes the script would have used (spelled
out in step 1 below) plus your own judgment for anything the audit missed
or got wrong.

**Two-host reality, only for the VM fallback: Claude Code is almost never
running on the s390x VM itself.** If you do end up on the VM fallback path,
the SME is typically driving this from their laptop (or wherever Claude Code
runs), while QEMU and the actual test run only mean something on one of the
shared s390x VMs. Never assume "the host this command runs on" is the VM —
check explicitly, because a QEMU check or test run silently executed on the
wrong host produces a meaningless but confident-looking result. This doesn't
apply to the default Semaphore path — that's triggered remotely and runs on
its own dedicated agent.

## Inputs

Ask the user (if not already given):
1. Which connector to certify — the directory name under `connect/`, e.g.
   `connect-cassandra-sink`.
2. Whether its test is already registered in `cp-connector-tests/tests.txt`
   (`connect-ci-cd-pipelines`). If they don't know, check the file yourself —
   `grep` for the connector or test name. This determines whether you can go
   straight to the default Semaphore path or need the VM fallback first.
3. Only if the VM fallback applies (test not yet registered, Group 3b
   iteration, or pipeline unavailable): their `~/.ssh/config` alias for the
   target VM (e.g. `s390x-vm-1`) — not a raw `user@host` string, since the
   alias is what carries the private key (`IdentityFile`). If they don't have
   one set up yet, point them at `connect/CERTIFYING_S390X.md` section 5.2
   ("SSH access prerequisites") and have them complete that — including the
   one manual interactive `ssh <alias>` login it requires — before coming
   back to this.
4. **Only for the VM fallback**, if the connector's README lists required
   service credentials (check `connect/<connector-dir>/README.md` — e.g.
   `connect-aws-s3-sink` needs `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/
   `AWS_REGION`): ask whether the user already has those exported in *their
   local shell* (not the VM), and get the exact env var names for
   `--forward-env`. The default Semaphore path doesn't need this at all — it
   pulls credentials from Vault itself (see `CERTIFYING_S390X.md` section 4)
   — so skip this entirely if you're not going the VM route.

## Procedure

1. **Audit with the script, fix with your own tools — proactive, not
   reactive.** Don't wait to see something fail before fixing a known
   pattern; that burns a shared VM cycle or a Semaphore pipeline slot on
   something already knowable ahead of time. Start with the audit (no
   `--apply-fixes`):
   ```
   bash scripts/s390x/certify-connector.sh <connector-dir>
   ```
   This reports the connector's group from `scripts/s390x/connector-groups.txt`,
   whether QEMU is registered *on whatever host this command runs on* (only
   meaningful if that's the s390x VM — "not s390x, skipping" is expected
   otherwise and not a real check), and a findings list: which Dockerfile
   `FROM` lines and compose `image:` fields have no confirmed s390x manifest,
   which HTTPS `RUN` steps lack `OPENSSL_ia32cap=0x0`, which base images are
   EOL, and which host-path volume mounts are missing `:z`.

   Then, for every finding — and for anything else in the same connector's
   Dockerfiles/compose files that fits these patterns but the audit didn't
   catch (multi-stage builds, ARG-based image references, a volume syntax
   the regex didn't anticipate, etc.) — **read the actual file yourself and
   apply the fix with the Edit tool**:
   - **No s390x manifest** (verify with `docker manifest inspect <image>` if
     you want to double-check the audit rather than trust it blindly): add
     `--platform=linux/amd64` right after `FROM <image>` in a Dockerfile, or
     a `platform: linux/amd64` line at the same indentation as `image:` in a
     compose service.
   - **HTTPS-fetching `RUN` step** (`npm install`, `pip install`, `apt-get
     install`, `curl https://...`, etc.) without it already: prefix the step
     with `OPENSSL_ia32cap=0x0`, e.g. `RUN OPENSSL_ia32cap=0x0 npm install`.
   - **EOL base image** (`node:14`→`20`, `python:3.8`→`3.12`, `openjdk:11`→
     `eclipse-temurin:17`): bump the tag, then re-check the OPENSSL_ia32cap
     fix above still applies — a version bump doesn't remove that need.
   - **Host-path volume mount** (`./...` or `../...`) with no SELinux label:
     append `:z` if it has no options yet, or `,z` if it already has
     options like `:ro`. Only matters for the VM fallback (SELinux
     enforcing); irrelevant on the Semaphore agent.
   - **Group 2 image-version bump** (e.g. `prom/prometheus:v2.11.1` →
     `v2.53.0`): this is a judgment call on the target version, not a
     mechanical rewrite — check the Confluence guide's Appendix A (linked in
     `CERTIFYING_S390X.md`'s header) for the recommended version before
     editing.

   After editing, `git diff` and actually look at what changed before
   moving on — applying fixes yourself doesn't mean skipping review.
   **Commit and push this branch** once you're happy with the diff — Step 3a
   needs a pushed branch to point `KDP_BRANCH_OVERRIDE` at.

   - If the connector isn't found in `connector-groups.txt`, check the
     Confluence guide's Appendix A (per-connector group list) before
     proceeding — if it's not there either, that's a real stop: ask the team
     rather than guessing a group. If it turns out to be Group 3
     (licensed/commercial, no public s390x image), tell the user this needs
     out-of-band image provisioning, not this workflow.
   - If it's a QEMU high-risk service (Oracle XE, SAP HANA — see the design
     doc's Group 3b), tell the user upfront that QEMU is best-effort and the
     outcome is uncertain, so they can decide whether to spend time on it —
     and that the VM fallback (not the pipeline) is the right tool for this
     kind of iteration.

2. **Check whether the test is registered in `tests.txt`** (from Inputs
   step 2) — this decides which path is next, nothing more.
   `CP_CONNECT_TESTS_OVERRIDE` is resolved by filtering against
   `cp-connector-tests/tests.txt` in `connect-ci-cd-pipelines`, so an
   unregistered test can't run on Semaphore. **Registering a new test is a
   separate, out-of-scope effort from this skill** — don't add a
   `tests.txt` line or open a PR against `connect-ci-cd-pipelines` as part
   of certifying this connector. If the test isn't registered, go straight
   to the VM fallback (step 3b) and stop there once it passes — that's a
   complete certification. If the user separately wants this connector
   wired into the shared CI test list going forward, point them at the
   `kdp-cp-validation-onboard-test` skill — that's a distinct task, not a
   step in this one.

3. **Run it.**

   **3a. Default: trigger the Semaphore pipeline via MCP, not the UI.**
   Same pattern as the `kdp-cp-validation-onboard-test` skill's Semaphore
   step, adapted to the s390x-specific task. No `--host`, no
   `--forward-env` — the pipeline pulls
   `connect/system-tests/CP_CONNECTOR_TEST_CREDS` from Vault and assumes a
   scoped AWS role itself.

   **Precondition (resolved 2026-08-18): the task exists.**
   [PR #223](https://github.com/confluentinc/connect-ci-cd-pipelines/pull/223)
   merged, and `run-cp-connector-selected-tests-s390x` is live at
   `https://semaphore.ci.confluent.io/projects/connect-ci-cd-pipelines/schedulers/712884d6-1a50-4dcc-a591-1b5e20af2997/just_run`.
   If a future check ever shows this task missing or renamed (re-verify with
   `gh pr view 223 --repo confluentinc/connect-ci-cd-pipelines --json state,mergedAt`
   if in doubt), fall back to triggering it by hand from that same Semaphore
   UI page and watch it yourself — there's no `workflow_id` to hand to a
   monitoring loop in that mode.

   **IDs — all three now known:**
   - **Task ID**: `712884d6-1a50-4dcc-a591-1b5e20af2997`
   - **Project ID**: `8b75ea88-cb41-42ae-a69e-c8237dcbb0d5` (`connect-ci-cd-pipelines`
     — same project as the onboarding skill's generic task, confirmed via
     `mcp__chewie__semaphore_list_workflows`)
   - **Organization ID**: `6ab08ce0-d948-4a80-b8e7-748bbb9cdf64` (org `semaphore`)

   Not yet independently verified: that this `task_id` is actually named
   `run-cp-connector-selected-tests-s390x` (the tools that would confirm
   that, `mcp__semaphore__tasks_describe`/`tasks_run`, weren't connected in
   the session that recorded this ID — it came from a Semaphore UI link).
   `tasks_describe` in step 1 below double-checks this on first live use;
   if the task it describes doesn't match, stop and re-derive via
   `mcp__chewie__semaphore_list_workflows(project_name="connect-ci-cd-pipelines", branch_name="master")`
   instead of proceeding on a wrong ID.

   **Now that you have its ID:**
   1. `mcp__semaphore__tasks_describe(mode="detailed")` first — this both
      confirms the `task_id` above actually resolves to
      `run-cp-connector-selected-tests-s390x` (per the caveat above) and
      confirms `CP_CONNECT_TESTS_OVERRIDE`'s separator.
      `CERTIFYING_S390X.md` documents it as pipe-separated based on the
      pipeline's design, but that's not independently confirmed the way the
      onboarding skill confirmed it for the generic task — verify, don't
      assume, the first time you actually use this.
   2. Build the override value: pipe-join the test name(s) confirmed in step 2
      above, e.g. `MysqlSourceTest`.
   3. **Confirm with the user before triggering** — a shared-state action,
      same as the onboarding skill.
   4. Call `mcp__semaphore__tasks_run` with `task_id`, `project_id`,
      `organization_id`, `branch=<the branch you pushed at the end of step 1>`,
      and `parameters={"CP_CONNECT_TESTS_OVERRIDE": "<pipe-joined>",
      "KDP_BRANCH_OVERRIDE": "<same branch>"}` (add `KDP_REPO_OVERRIDE` if
      it's on a fork, or `CP_VERSION`/`RC_IMAGE_TAG`/etc. from section 4's
      full parameter list if a specific CP build is needed).
   5. Capture `workflow_id` from the response, and verify it actually ran
      against your branch (not silently defaulting to `master`) via
      `mcp__chewie__semaphore_get_workflow(workflow_id=...)` — same caveat
      the onboarding skill flags for its own trigger.
   6. **Monitor it — don't fire-and-forget.** Full polling cadence, per-test
      status check (exit 107/111 are `known_issue`/`skipped`, not failures —
      a "passed" workflow can still hide one), and failure-debug procedure
      (cross-referencing `CERTIFYING_S390X.md` Section 6) are in
      `resources/monitor-semaphore-run.md`. Install the `/loop` it describes
      rather than polling ad hoc.

   **Fallback** if `tasks_run` itself fails: trigger manually from the
   Semaphore UI instead (same as the precondition's fallback above) — see
   `resources/monitor-semaphore-run.md`'s "Manual-mode fallback" note.

   **3b. Fallback: run on a shared VM.** Use this instead when the test
   isn't registered yet and you're proving it first, when doing fast
   interactive Group 3b iteration, or when the pipeline is unavailable. If
   you have the user's `~/.ssh/config` alias for the VM (from Inputs), pass
   it via `--host` and the script handles syncing the repo and running
   remotely for you:
   ```
   bash scripts/s390x/certify-connector.sh <connector-dir> --run --host <alias>
   ```
   If the connector needs service credentials (Inputs step 4), add
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
   itself can't fully prevent that on a shared account. This exposure is
   exactly what the default Semaphore path in 3a avoids — prefer it whenever
   the test is already registered.

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
   section 5.2 ("SSH access prerequisites") — a private key referenced by
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

4. **Diagnose and iterate.** For a Semaphore run (3a) triggered via MCP,
   step 3a's `/loop` already does this diagnosis when the run finishes
   (`resources/monitor-semaphore-run.md`) — this step is mainly "apply the
   fix it surfaced, then re-trigger." For a Semaphore run triggered manually
   (precondition fallback, or `tasks_run` itself failed) or a VM fallback
   run (3b): pull the JUnit report and the
   `playground_display_error_all_containers_output.txt` /
   connect-container-log artifacts (Semaphore) or the script's captured log
   (VM), and match them against the Section 6 diagnostic table in
   `CERTIFYING_S390X.md` — the VM script does this matching automatically.
   Apply the fix, re-run, repeat. If a failure doesn't match any known
   pattern, read the actual log yourself before guessing — don't apply
   speculative fixes to a failure you haven't actually read.

5. **Once it passes**, that's the certification — walk the user through
   wrapping up (see `connect/CERTIFYING_S390X.md` "Wrap up" section):
   - Confirm they're on a personal branch off `s390x-base` (not directly on
     `s390x-base`, `s390x-cert-tooling`, or `master` — `s390x-cert-tooling`
     is this skill's own home, not something a connector branch should sit
     on top of).
   - Remind them to open the KDP PR against `s390x-base`, not `master` —
     purely s390x-specific workarounds stay on `s390x-base` permanently;
     anything with backwards-compatible value gets cherry-picked to
     `master` separately.
   - Suggest linking the green Semaphore run (or noting the VM-fallback run,
     for a Group 3b connector) as evidence in the KDP PR description.
   - If the connector's group was missing or wrong in `connector-groups.txt`,
     update it as part of the same PR and flag the Confluence Appendix A
     entry for a follow-up correction.
   - If the user also wants this connector's test wired into the shared CI
     list going forward (not required to call it certified), that's the
     separate `kdp-cp-validation-onboard-test` skill, not a wrap-up item here.

## What this skill does not do

- It does not treat `certify-connector.sh`'s findings as the full list of
  what needs fixing, and it does not call `--apply-fixes` to do the editing.
  The script's checks are a starting point; you're expected to actually read
  the connector's Dockerfiles and compose files and catch what a fixed
  regex/YAML pattern can't — a multi-stage build, an image behind a build
  `ARG`, an unusual volume line, etc. — using Edit directly.
- It does not provision licensed/vendor images (Group 3) or set up an
  external service to sidestep QEMU entirely — those are manual
  infrastructure decisions, not scriptable fixes. If QEMU itself is the
  blocker, "Manual Testing: Connector Certification Guide — s390x" on
  Confluence covers standing up the target service on a real amd64 host and
  pointing the connector at it externally.
- It does not decide when to give up on a QEMU-emulated Group 3b service —
  that's a judgment call for the SME based on how much debugging time is
  justified.
- It does not manage VM access or SSH credentials — if the user doesn't have
  an SSH target for a shared VM yet, that's a coordination step (see
  `connect/CERTIFYING_S390X.md` section 5.2), not something to work around.
- It does not trigger the Semaphore pipeline via MCP if
  `mcp__semaphore__tasks_run` itself isn't connected in the current
  session, or if the IDs in step 3a ever turn out to be wrong/stale — in
  either case it falls back to telling the user which parameters to use
  manually in the Semaphore UI, same as before this capability existed.
- It does not register a connector's test in `cp-connector-tests/tests.txt`
  or open a PR against `connect-ci-cd-pipelines` — that's a separate,
  out-of-scope onboarding effort (see the `kdp-cp-validation-onboard-test`
  skill), not part of certifying a connector.
