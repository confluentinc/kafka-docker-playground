#!/bin/bash
#
# Deterministic per-connector certification checklist for s390x.
#
# Implements Steps 1-5 of "Automated Testing: Connector Certification on
# s390x architecture" Section 5.4/5.5:
#   1. Identify the connector's group
#   2. Confirm QEMU emulation is set up (if applicable)
#   3. Check for custom image builds and known Dockerfile issues
#   4. Run the connector test
#   5. Diagnose failures against the known error table
#
# Usage:
#   scripts/s390x/certify-connector.sh <connector-dir> [test-script.sh] [--run] [--apply-fixes] [--host <ssh-target>] [--forward-env VAR1,VAR2,...]
#
# Examples:
#   scripts/s390x/certify-connector.sh connect-http-sink
#   scripts/s390x/certify-connector.sh connect-cassandra-sink --apply-fixes
#   scripts/s390x/certify-connector.sh connect-http-sink http_no_auth.sh --run --host sme@s390x-vm-2
#   scripts/s390x/certify-connector.sh connect-aws-s3-sink --run --host s390x-vm-1 \
#       --forward-env AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY,AWS_SESSION_TOKEN,AWS_REGION
#
# --run          actually execute the test script and capture output for Step 5 diagnosis.
# --apply-fixes  mechanically apply every fix Step 3's fixed regex/YAML
#                patterns can find, across every docker-compose*.yml and any
#                custom-build Dockerfile in the connector directory:
#                --platform=linux/amd64 on images with no s390x manifest (in
#                FROM lines AND compose `image:` fields), OPENSSL_ia32cap=0x0
#                on HTTPS-fetching Dockerfile RUN steps, :z on docker-compose
#                host-path volume mounts, and EOL base image bumps
#                (node:14->20, python:3.8->3.12, openjdk:11->eclipse-temurin:17).
#                This is a fast path for running the script directly outside
#                Claude Code -- its coverage is only as wide as these fixed
#                patterns (a multi-stage Dockerfile, an ARG-based image
#                reference, an unusual volume syntax can slip past it). The
#                certify-s390x Claude Code skill does NOT rely on this flag:
#                it runs the script WITHOUT --apply-fixes for the audit, then
#                applies fixes itself via Read/Edit on the actual files, so
#                it isn't limited to what these patterns anticipate. Either
#                way, the goal is to catch these BEFORE a VM run, not react
#                to them one error at a time -- always review the diff
#                before committing.
# --host <ssh-target>
#                IMPORTANT: wherever this script runs is where Step 2's QEMU
#                check and Step 4's test execution happen. If you're invoking
#                this from a laptop, CI runner, or any host that is NOT the
#                target s390x VM (e.g. driving it through Claude Code on your
#                own machine), you MUST pass --host so those steps run on the
#                actual VM instead of silently checking/running against the
#                wrong machine. When set, this rsyncs the current repo state
#                to ~/kafka-docker-playground on <ssh-target> and re-invokes
#                itself there over ssh with --host stripped, streaming output
#                back. Steps 1 and 3 (group lookup, Dockerfile/compose audit)
#                are pure repo inspection and work fine without --host from
#                any machine with network access to the image registries.
# --forward-env VAR1,VAR2,...
#                For connectors that need real service credentials (e.g. AWS
#                for a Cloud/SaaS connector): forwards the named env vars,
#                read from THIS host's environment, into the single remote
#                invocation triggered by --host. Values are piped over stdin
#                into the remote shell, never placed on its command line and
#                never written to a file there -- they exist only for the
#                lifetime of that one test run. Only meaningful with --host;
#                ignored otherwise (the vars are already in your environment
#                locally). This is NOT a substitute for per-VM secrets
#                management: the shared s390x VMs use one login for all SMEs,
#                so anything forwarded here is still readable by another SME
#                on the same VM for as long as the process is running (via
#                /proc/<pid>/environ under the shared account) -- prefer
#                short-lived, narrowly-scoped credentials (e.g. an assumed-role
#                session token) over long-lived static keys, same as the real
#                CI pipeline already does. See connect/CERTIFYING_S390X.md.
#
# This script only handles what's deterministic. Group 3 (licensed, no public
# image) and Group 3b (QEMU high-risk, e.g. Oracle XE/SAP HANA) connectors
# still need manual judgment — see connect/CERTIFYING_S390X.md.
set -uo pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
REPO_ROOT="$( cd "${DIR}/../.." >/dev/null && pwd )"
GROUPS_FILE="${DIR}/connector-groups.txt"

log()      { echo "[certify] $*"; }
logwarn()  { echo "[certify][WARN] $*" >&2; }
logerror() { echo "[certify][ERROR] $*" >&2; }
section()  { echo; echo "== $* =="; }

CONNECTOR_DIR="${1:-}"
if [ -z "$CONNECTOR_DIR" ]
then
    logerror "usage: $0 <connector-dir> [test-script.sh] [--run] [--apply-fixes] [--host <ssh-target>]"
    exit 1
fi
shift

TEST_SCRIPT=""
RUN_TEST=0
APPLY_FIXES=0
HOST=""
FORWARD_ENV=""
REMOTE_ARGS=("$CONNECTOR_DIR")
while [ $# -gt 0 ]
do
    case "$1" in
        --run) RUN_TEST=1; REMOTE_ARGS+=("--run") ;;
        --apply-fixes) APPLY_FIXES=1; REMOTE_ARGS+=("--apply-fixes") ;;
        --host)
            shift
            HOST="${1:-}"
            [ -z "$HOST" ] && { logerror "--host requires a value (e.g. --host sme@s390x-vm-2)"; exit 1; }
            ;;
        --forward-env)
            shift
            FORWARD_ENV="${1:-}"
            [ -z "$FORWARD_ENV" ] && { logerror "--forward-env requires a comma-separated var list (e.g. --forward-env AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY,AWS_SESSION_TOKEN)"; exit 1; }
            ;;
        *.sh) TEST_SCRIPT="$1"; REMOTE_ARGS+=("$1") ;;
        *) logwarn "ignoring unrecognized argument: $1" ;;
    esac
    shift
done

if [ -n "$HOST" ]
then
    log "--host ${HOST} given: this host ($(uname -n 2>/dev/null || echo unknown)) is not the target s390x VM"
    if ! command -v rsync >/dev/null 2>&1
    then
        logerror "rsync is required for --host but was not found locally"
        exit 1
    fi

    # BatchMode=yes disables all interactive prompts (password, passphrase,
    # unknown host key). This script is meant to run non-interactively (e.g.
    # invoked by Claude Code), and no caller here can answer an SSH prompt --
    # without this, a missing key would just hang until it times out instead
    # of failing with a clear, actionable error. Auth itself is never handled
    # by this script: it relies entirely on whatever key-based auth you
    # already have set up for this host (ssh-agent, ~/.ssh/config). This
    # script never asks for, stores, or transmits a password/passphrase.
    SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
    PREFLIGHT_LOG="$(mktemp /tmp/certify-ssh-preflight.XXXXXX.log)"
    if ! ssh "${SSH_OPTS[@]}" "$HOST" true 2>"$PREFLIGHT_LOG"
    then
        logerror "cannot reach ${HOST} non-interactively over SSH"
        logerror "$(cat "$PREFLIGHT_LOG")"
        logerror "this script never prompts for a password -- set up passwordless"
        logerror "key-based access yourself first (ssh-copy-id, or add the key to"
        logerror "ssh-agent with ssh-add), and confirm 'ssh ${HOST}' works with no"
        logerror "prompt before retrying with --host. If this is the first time"
        logerror "connecting, also do one interactive 'ssh ${HOST}' manually to"
        logerror "accept its host key -- do not disable host key checking."
        rm -f "$PREFLIGHT_LOG"
        exit 1
    fi
    rm -f "$PREFLIGHT_LOG"
    log "SSH preflight OK (non-interactive, key-based auth confirmed)"

    log "syncing repo to ${HOST}:~/kafka-docker-playground and re-running there..."
    rsync -az -e "ssh ${SSH_OPTS[*]}" --exclude '.git' "${REPO_ROOT}/" "${HOST}:~/kafka-docker-playground/"

    # Build the exports (if any) as a string BEFORE touching ssh, so secret
    # values never appear as a command-line argument to ssh, rsync, or the
    # remote shell -- they travel only in the piped stdin body below and are
    # exported inside the remote bash process, not written to any file.
    ENV_SCRIPT=""
    if [ -n "$FORWARD_ENV" ]
    then
        IFS=',' read -r -a FORWARD_ENV_VARS <<< "$FORWARD_ENV"
        for v in "${FORWARD_ENV_VARS[@]}"
        do
            if [ -n "${!v:-}" ]
            then
                ENV_SCRIPT+="export $v=$(printf '%q' "${!v}")"$'\n'
            else
                logwarn "--forward-env: ${v} is not set locally, skipping"
            fi
        done
        log "forwarding ${#FORWARD_ENV_VARS[@]} env var(s) to ${HOST} for this run only (not persisted, see --forward-env docs above)"
    fi

    REMOTE_SCRIPT="${ENV_SCRIPT}cd ~/kafka-docker-playground && bash scripts/s390x/certify-connector.sh ${REMOTE_ARGS[*]}"
    ssh "${SSH_OPTS[@]}" "$HOST" bash -s <<< "$REMOTE_SCRIPT"
    exit $?
fi

CONNECT_PATH="${REPO_ROOT}/connect/${CONNECTOR_DIR}"
if [ ! -d "$CONNECT_PATH" ]
then
    logerror "no such connector directory: connect/${CONNECTOR_DIR}"
    exit 1
fi

# ---------------------------------------------------------------------------
section "Step 1: identify the connector's group"
# ---------------------------------------------------------------------------
GROUP=""
if [ -f "$GROUPS_FILE" ]
then
    MATCH="$(grep -E "^${CONNECTOR_DIR}:" "$GROUPS_FILE" | head -1)"
    if [ -n "$MATCH" ]
    then
        echo "  $MATCH"
        GROUP="$(echo "$MATCH" | sed -E 's/^[^:]+:\s*//')"
        case "$GROUP" in
            Group\ 3*)
                logwarn "Group 3 (licensed/no public image) — this needs manual, out-of-band image provisioning, not this script's checklist. See connect/CERTIFYING_S390X.md."
                ;;
        esac
    else
        logwarn "connect-${CONNECTOR_DIR#connect-} not found in scripts/s390x/connector-groups.txt"
        logwarn "check Appendix A of the SME certification guide on Confluence before proceeding; if it's missing there too, ask the team rather than guessing a group"
    fi
else
    logwarn "scripts/s390x/connector-groups.txt not found, skipping group lookup"
fi

# ---------------------------------------------------------------------------
section "Step 2: confirm QEMU emulation is set up"
# ---------------------------------------------------------------------------
if [ "$(uname -m)" = "s390x" ]
then
    if [ -e /proc/sys/fs/binfmt_misc/qemu-x86_64 ] && grep -q "flags:.*F" /proc/sys/fs/binfmt_misc/qemu-x86_64 2>/dev/null
    then
        log "qemu-x86_64 registered with F flag — OK"
    else
        logerror "qemu-x86_64 is NOT registered with the F flag on this host"
        logerror "run: sudo bash scripts/s390x/setup-vm.sh"
    fi
    log "KDP branch HEAD: $(git -C "$REPO_ROOT" log --oneline -1 2>/dev/null || echo 'unknown (not a git checkout?)')"
else
    log "host arch is $(uname -m), not s390x — skipping QEMU checks (this looks like a non-s390x dev machine)"
    if [ "$RUN_TEST" -eq 1 ]
    then
        logerror "--run was requested but this host is not s390x and --host was not given"
        logerror "running the test here would silently execute on the wrong architecture and give a meaningless pass/fail"
        logerror "re-run with --host <ssh-target-for-the-s390x-vm>, or run this script directly on the VM"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
section "Step 3: check for known image/build/volume issues (proactive, not reactive)"
# ---------------------------------------------------------------------------
# Every check here mirrors a failure mode that has actually been hit on a
# real s390x VM run (see connect/CERTIFYING_S390X.md's diagnostic table).
# The whole point of this step is to apply these BEFORE a VM run costs time
# on them, not to wait and react to the error -- that's why --apply-fixes
# is meant to be used by default, not as an afterthought.

check_image_arch() {
    # prints one of: s390x | no-s390x | unknown
    local image="$1"
    if ! command -v docker >/dev/null 2>&1
    then
        echo unknown
        return
    fi
    local arches
    arches=$(docker manifest inspect "$image" 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(' '.join(m['platform']['architecture'] for m in d.get('manifests',[])))
except Exception:
    print('')
" 2>/dev/null)
    if echo "$arches" | grep -qw s390x
    then
        echo s390x
    elif [ -n "$arches" ]
    then
        echo no-s390x
    else
        echo unknown
    fi
}

apply_compose_platform_fix() {
    # Inserts 'platform: linux/amd64' right after the image: line at $2 in
    # $1, matching its indentation. No-op if already present on the next
    # line (idempotent across re-runs).
    local file="$1" lineno="$2"
    python3 - "$file" "$lineno" <<'PYEOF'
import sys
path, lineno = sys.argv[1], int(sys.argv[2])
with open(path) as f:
    lines = f.readlines()
idx = lineno - 1
indent = len(lines[idx]) - len(lines[idx].lstrip(' '))
if idx + 1 < len(lines) and lines[idx + 1].strip() == 'platform: linux/amd64':
    sys.exit(0)
lines.insert(idx + 1, ' ' * indent + 'platform: linux/amd64\n')
with open(path, 'w') as f:
    f.writelines(lines)
PYEOF
}

apply_selinux_z_fix() {
    # Adds :z (or ,z if other options already present) to any docker-compose
    # host-path bind mount (./..., ../...) that doesn't already have it.
    # Rewrites the whole file in one pass to avoid line-number drift.
    local file="$1"
    python3 - "$file" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()
pattern = re.compile(r'^(\s*-\s*\.{1,2}/[^:\n]+:[^:\n]+)(:([^:\n]*))?\s*\n?$')
changed = False
for i, line in enumerate(lines):
    m = pattern.match(line)
    if not m:
        continue
    prefix, _, opts = m.groups()
    if opts is not None and 'z' in [o.strip() for o in opts.split(',')]:
        continue
    newline = f"{prefix}:{opts},z\n" if opts else f"{prefix}:z\n"
    if newline != line:
        lines[i] = newline
        changed = True
if changed:
    with open(path, 'w') as f:
        f.writelines(lines)
print('changed' if changed else 'unchanged')
PYEOF
}

COMPOSE_FILES=$(find "$CONNECT_PATH" -maxdepth 2 -iname "docker-compose*.yml" 2>/dev/null)
BUILD_DIRS=""
if [ -n "$COMPOSE_FILES" ]
then
    for f in $COMPOSE_FILES
    do
        if grep -q "^\s*build:" "$f"
        then
            log "custom build declared in $(realpath --relative-to="$REPO_ROOT" "$f")"
            CTX=$(grep -A2 "^\s*build:" "$f" | grep -oE "context:\s*\S+" | awk '{print $2}' | head -1)
            [ -z "$CTX" ] && CTX="."
            BUILD_DIR="$(cd "$(dirname "$f")/${CTX}" 2>/dev/null && pwd)"
            [ -n "$BUILD_DIR" ] && BUILD_DIRS="${BUILD_DIRS} ${BUILD_DIR}"
        fi
    done
fi

if [ -z "$(echo "$BUILD_DIRS" | tr -d ' ')" ]
then
    log "no 'build:' sections found — this connector doesn't build its own image"
else
    for BUILD_DIR in $BUILD_DIRS
    do
        DOCKERFILE="${BUILD_DIR}/Dockerfile"
        [ -f "$DOCKERFILE" ] || continue
        REL_DOCKERFILE="$(realpath --relative-to="$REPO_ROOT" "$DOCKERFILE")"
        log "inspecting ${REL_DOCKERFILE}"

        # --- Check 3a: base image s390x manifest ---
        BASE_IMAGE=$(grep -m1 -iE "^FROM" "$DOCKERFILE" | awk '{print $2}')
        HAS_PLATFORM=$(grep -m1 -iE "^FROM\s+--platform" "$DOCKERFILE" || true)
        if [ -n "$BASE_IMAGE" ]
        then
            ARCH_STATUS=$(check_image_arch "$BASE_IMAGE")
            if [ -n "$HAS_PLATFORM" ]
            then
                log "  3a OK: FROM already pins --platform (${HAS_PLATFORM})"
            elif [ "$ARCH_STATUS" = "s390x" ]
            then
                log "  3a OK: ${BASE_IMAGE} already publishes an s390x manifest, no --platform needed"
            else
                logwarn "  3a FIX NEEDED: ${BASE_IMAGE} has no confirmed s390x manifest (status: ${ARCH_STATUS})"
                logwarn "    -> add --platform=linux/amd64 to: FROM ${BASE_IMAGE}"
                if [ "$APPLY_FIXES" -eq 1 ]
                then
                    sed -i.bak -E "s#^FROM ${BASE_IMAGE}#FROM --platform=linux/amd64 ${BASE_IMAGE}#" "$DOCKERFILE"
                    log "    applied. Backup at ${DOCKERFILE}.bak"
                fi
            fi
        fi

        # --- Check 3b: RUN steps doing HTTPS requests ---
        HTTPS_RUN_LINES=$(grep -nE "^\s*RUN " "$DOCKERFILE" | grep -E "npm install|pip install|mvn|gradle|apt-get install|yum install|curl https|wget https")
        if [ -n "$HTTPS_RUN_LINES" ]
        then
            echo "$HTTPS_RUN_LINES" | while IFS=: read -r lineno rest
            do
                if echo "$rest" | grep -q "OPENSSL_ia32cap"
                then
                    log "  3b OK (line ${lineno}): already sets OPENSSL_ia32cap=0x0"
                else
                    logwarn "  3b FIX NEEDED (line ${lineno}): HTTPS RUN step without OPENSSL_ia32cap=0x0"
                    logwarn "    -> ${rest}"
                    if [ "$APPLY_FIXES" -eq 1 ]
                    then
                        sed -i.bak -E "${lineno}s#^(\s*RUN )#\1OPENSSL_ia32cap=0x0 #" "$DOCKERFILE"
                        log "    applied at line ${lineno}. Backup at ${DOCKERFILE}.bak"
                    fi
                fi
            done
        else
            log "  3b OK: no HTTPS-fetching RUN steps found"
        fi

        # --- Check 3c: EOL base image ---
        NEW_BASE_IMAGE=""
        case "$BASE_IMAGE" in
            node:14*|node:14)     NEW_BASE_IMAGE="node:20" ;;
            python:3.8*)          NEW_BASE_IMAGE="python:3.12" ;;
            openjdk:11*)          NEW_BASE_IMAGE="eclipse-temurin:17" ;;
        esac
        if [ -n "$NEW_BASE_IMAGE" ]
        then
            logwarn "  3c FIX NEEDED: ${BASE_IMAGE} is EOL, prefer ${NEW_BASE_IMAGE}"
            if [ "$APPLY_FIXES" -eq 1 ]
            then
                sed -i.bak -E "s#${BASE_IMAGE}#${NEW_BASE_IMAGE}#" "$DOCKERFILE"
                log "    applied. Backup at ${DOCKERFILE}.bak"
                logwarn "    re-verify 3b's OPENSSL_ia32cap fix still applies -- version bumps don't remove that requirement"
            fi
        else
            log "  3c OK: ${BASE_IMAGE} not a known EOL base"
        fi
    done
fi

# --- Check 3d: docker-compose `image:` fields (applies regardless of build:) ---
# Most connectors don't build a custom image at all -- they reference a
# third-party image directly in docker-compose*.yml. This is the check that
# matters for the majority of Group 4 connectors.
for f in $COMPOSE_FILES
do
    REL_F="$(realpath --relative-to="$REPO_ROOT" "$f")"
    while IFS=: read -r lineno rest
    do
        IMAGE=$(echo "$rest" | sed -E 's/^\s*image:\s*//' | tr -d '"'"'"'' | xargs)
        # skip CP images and anything using unresolved compose variables --
        # not a concrete image reference to check, and CP images already
        # have their own s390x-aware selection in scripts/utils.sh
        case "$IMAGE" in
            *'${'*) continue ;;
        esac
        [ -z "$IMAGE" ] && continue
        NEXT_LINE=$(sed -n "$((lineno + 1))p" "$f")
        if echo "$NEXT_LINE" | grep -q "^\s*platform:\s*linux/amd64\s*$"
        then
            log "  3d OK (line ${lineno}, ${REL_F}): ${IMAGE} already pinned to platform: linux/amd64"
            continue
        fi
        ARCH_STATUS=$(check_image_arch "$IMAGE")
        if [ "$ARCH_STATUS" = "s390x" ]
        then
            log "  3d OK (line ${lineno}, ${REL_F}): ${IMAGE} already publishes an s390x manifest"
        else
            logwarn "  3d FIX NEEDED (line ${lineno}, ${REL_F}): ${IMAGE} has no confirmed s390x manifest (status: ${ARCH_STATUS})"
            logwarn "    -> add 'platform: linux/amd64' to this service"
            if [ "$APPLY_FIXES" -eq 1 ]
            then
                apply_compose_platform_fix "$f" "$lineno"
                log "    applied"
            fi
        fi
    # Processed bottom-to-top (tac) so that inserting a 'platform:' line for
    # one match doesn't shift the line numbers of matches still to be
    # processed above it in the same file -- top-to-bottom would corrupt
    # the file on a second match after the first insertion grows it by a line.
    done < <(grep -nE "^\s*image:\s*\S+" "$f" | tac)
done

# --- Check 3e: SELinux :z on docker-compose host-path volume mounts ---
for f in $COMPOSE_FILES
do
    REL_F="$(realpath --relative-to="$REPO_ROOT" "$f")"
    # \.{1,2}/ matches both ./ and ../ -- this repo's docker-compose files
    # predominantly use ../../ (parent-relative), not ./, so matching only
    # a single dot here would silently miss most real volume mounts.
    UNLABELED=$(grep -nE "^\s*-\s*\.{1,2}/.*:.*[^z]$|^\s*-\s*\.{1,2}/[^:]*:[^:]*$" "$f" | grep -v ":z" | grep -v ":ro,z" || true)
    if [ -n "$UNLABELED" ]
    then
        logwarn "  3e FIX NEEDED: missing SELinux ':z' relabel in ${REL_F} (RHEL10 SELinux-enforcing hosts only):"
        echo "$UNLABELED" | sed 's/^/    /'
        if [ "$APPLY_FIXES" -eq 1 ]
        then
            RESULT=$(apply_selinux_z_fix "$f")
            log "    applied (${RESULT})"
        fi
    else
        log "  3e OK: ${REL_F} — no unlabeled host-path volume mounts"
    fi
done

if [ "$APPLY_FIXES" -eq 0 ]
then
    logwarn "ran in audit-only mode -- re-run with --apply-fixes to apply all of the above proactively instead of finding out on the VM"
fi

# ---------------------------------------------------------------------------
section "Step 4: run the connector test"
# ---------------------------------------------------------------------------
if [ -z "$TEST_SCRIPT" ]
then
    TEST_SCRIPT=$(find "$CONNECT_PATH" -maxdepth 1 -iname "*.sh" ! -iname "stop.sh" ! -iname "*mtls*" ! -iname "*ssl*" | sort | head -1)
    [ -n "$TEST_SCRIPT" ] && TEST_SCRIPT="$(basename "$TEST_SCRIPT")"
    [ -n "$TEST_SCRIPT" ] && log "guessed default test script: ${TEST_SCRIPT} (pass one explicitly if this is wrong)"
fi

if [ -z "$TEST_SCRIPT" ]
then
    logerror "could not find a default test script in connect/${CONNECTOR_DIR} — pass it explicitly"
    exit 1
fi

TEST_SCRIPT_PATH="${CONNECT_PATH}/${TEST_SCRIPT}"
if [ ! -f "$TEST_SCRIPT_PATH" ]
then
    logerror "no such test script: connect/${CONNECTOR_DIR}/${TEST_SCRIPT}"
    exit 1
fi

if [ "$RUN_TEST" -eq 0 ]
then
    log "dry run (pass --run to execute). Would run: bash connect/${CONNECTOR_DIR}/${TEST_SCRIPT}"
    exit 0
fi

LOG_FILE="$(mktemp /tmp/certify-s390x.XXXXXX.log)"
log "running: bash connect/${CONNECTOR_DIR}/${TEST_SCRIPT}  (log: ${LOG_FILE})"
set +e
(cd "$CONNECT_PATH" && bash "./$TEST_SCRIPT") > "$LOG_FILE" 2>&1
TEST_STATUS=$?
set -e

if [ "$TEST_STATUS" -eq 0 ]
then
    log "PASS: connect/${CONNECTOR_DIR}/${TEST_SCRIPT}"
    exit 0
fi

logerror "FAIL (exit ${TEST_STATUS}): connect/${CONNECTOR_DIR}/${TEST_SCRIPT} — diagnosing below"

# ---------------------------------------------------------------------------
section "Step 5: diagnose failure"
# ---------------------------------------------------------------------------
declare -a PATTERNS=(
    "no image found in manifest list for architecture s390x|Service image has no s390x manifest|Add --platform linux/amd64 in the Dockerfile, or point the test at an external service"
    "Exec format error|QEMU not registered, or rootless Podman in use|Run scripts/s390x/setup-vm.sh; use sudo podman"
    "qemu: uncaught target signal 11|JIT-generated AVX/SSE instructions crash QEMU|Add -e JAVA_TOOL_OPTIONS=-Xint to the JVM container (gate on uname -m = s390x)"
    "ERR_SSL_SSLV3_ALERT_BAD_RECORD_MAC|QEMU AES-NI emulation produces invalid MACs|Add OPENSSL_ia32cap=0x0 to the Dockerfile RUN step making the HTTPS request"
    "Permission denied|SELinux blocking a host-mounted volume|Add :z to the -v flag or docker-compose volume entry"
    "cannot prompt without a TTY|Podman short-name-mode is 'enforced'|Set short-name-mode = \"permissive\" in /etc/containers/registries.conf (see scripts/s390x/setup-vm.sh)"
    "Bad PSW|Wrong QEMU binary (tonistiigi/binfmt instead of Debian bookworm build)|Re-run scripts/s390x/setup-vm.sh to install the correct qemu-x86_64-static"
)

MATCHED=0
for entry in "${PATTERNS[@]}"
do
    IFS='|' read -r pattern cause fix <<< "$entry"
    if grep -qiE "$pattern" "$LOG_FILE"
    then
        MATCHED=1
        echo "  MATCH: \"${pattern}\""
        echo "    cause: ${cause}"
        echo "    fix:   ${fix}"
    fi
done

if [ "$MATCHED" -eq 0 ]
then
    logwarn "no known pattern matched — this isn't one of the deterministic Section 5.5 failures."
    logwarn "inspect the log manually: ${LOG_FILE}"
    logwarn "if this looks like a QEMU reliability issue (Group 3a/3b service), see 'Manual Testing: Connector Certification Guide - s390x' on Confluence for the external-service fallback before spending more time debugging emulation."
fi

exit "$TEST_STATUS"
