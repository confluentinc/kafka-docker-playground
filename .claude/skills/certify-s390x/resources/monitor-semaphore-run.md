# Monitor the s390x Semaphore Run

After triggering `run-cp-connector-selected-tests-s390x` via
`mcp__semaphore__tasks_run` (SKILL.md step 3a), do **not** fire-and-forget.
Schedule a `/loop` to poll the workflow and surface a verdict — including
per-test status, since a green workflow can still hide non-pass outcomes.
This mirrors `kdp-cp-validation-onboard-test`'s monitoring pattern
(`resources/monitor-validation-run.md` in that skill), adapted for the
s390x-specific task and its diagnostic table.

## When to poll

Expect roughly the same order of magnitude as the generic multi-arch task
(10-30 minutes), possibly longer under QEMU emulation for Group 3a/3b
services. Poll every **5 minutes**.

## Loop tick

**Preferred state-read path: chewie, by workflow ID** — no `project_id`
needed:

1. Read current state via `mcp__chewie__semaphore_get_workflow(workflow_id=<captured>)`,
   then `semaphore_list_pipelines(workflow_id=...)` / `semaphore_get_pipeline(pipeline_id=...)`
   for per-pipeline state.
2. Still running → schedule the next tick.
3. `passed` at the workflow level → **don't stop here** — go to "Check
   per-test status" below before declaring victory.
4. `failed` → exit the loop and run failure-debug below.

## Check per-test status (even on a "passed" workflow)

A `playground run` exit code of `107` is `known_issue` and `111` is
`skipped` — both non-failing, but neither is "this connector's test
actually ran clean." Pull the JUnit report and the
`playground_display_error_all_containers_output.txt` / connect-container-log
artifacts the pipeline publishes per test (via the job/pipeline IDs from the
chewie calls above) and confirm your connector's specific test(s) show a
real pass, not just a non-failing exit code.

## Failure debug

When the workflow (or an individual test within it) fails:

1. Get the failing job via `mcp__chewie__semaphore_get_pipeline(pipeline_id=...)`
   → `semaphore_get_job(job_id=...)` → `semaphore_get_job_logs(job_id=...)`
   (all by ID, no `project_id` needed). Pull the last 100-200 lines, plus
   the JUnit/container-log artifacts.
2. Match against `CERTIFYING_S390X.md` Section 6's diagnostic table first —
   most s390x-specific failures (no manifest, QEMU signal 11,
   `OPENSSL_ia32cap`, SELinux `:z`, the `KAFKA_METRIC_REPORTERS` comment-out,
   the ccloud kcat fallback) are already known patterns there.
3. If nothing in Section 6 matches, check the same generic signatures the
   onboarding skill's failure-debug uses:
   - **Missing secret / unset env var** (`401`, `403`, `Authentication failed`,
     `MissingCredentialsException`) → this connector's credentials aren't in
     `CP_CONNECTOR_TEST_CREDS` yet on the s390x path either — flag to the
     team rather than guessing which key.
   - **Flaky / timeout** (`timed out waiting for`, `connection reset`) →
     worth one manual re-trigger before spending debugging time on it.
4. If still nothing matches, this is a genuinely new failure mode — read the
   raw log yourself and, once resolved, fold the cause/fix into Section 6 so
   the next SME doesn't re-debug it from scratch (per "Getting unstuck").

## Final report

| Field | Value |
|-------|-------|
| Workflow URL | (from the trigger response) |
| Workflow state | passed / failed |
| Per-test status | pass / known_issue (107) / skipped (111) / fail, per test in `CP_CONNECT_TESTS_OVERRIDE` |
| Duration | mm:ss |
| Failing job(s) | (if any) |
| Likely cause | (Section 6 row, or generic signature above) |
| Suggested next step | "Wrap up (see SKILL.md step 5)" / "Fix X and re-trigger" / "Flag to team" |

If every selected test genuinely passed (not just non-failing), tell the
user they're ready for SKILL.md's wrap-up step — there's no PR to update
here yet (the KDP PR against `s390x-base` is opened *after* this run
passes, unlike the onboarding skill's draft-PR-first flow), so just hand
back the workflow URL for them to link as evidence when they open it.

## Manual-mode fallback

If `mcp__semaphore__tasks_run` failed, wasn't connected in this session, or
the IDs in SKILL.md step 3a turn out to be wrong/stale, there's no
`workflow_id` to poll. Tell the user to trigger and watch the run manually
from the Semaphore UI instead — this file's automation doesn't
apply until that's resolved.
