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
#   scripts/s390x/certify-connector.sh <connector-dir> [test-script.sh] [--run] [--apply-fixes] [--host <ssh-target>]
#
# Examples:
#   scripts/s390x/certify-connector.sh connect-http-sink
#   scripts/s390x/certify-connector.sh connect-cassandra-sink --apply-fixes
#   scripts/s390x/certify-connector.sh connect-http-sink http_no_auth.sh --run --host sme@s390x-vm-2
#
# --run          actually execute the test script and capture output for Step 5 diagnosis.
# --apply-fixes  apply the safe, deterministic fixes found in Step 3 (Dockerfile
#                --platform / OPENSSL_ia32cap, and :z on docker-compose volume
#                mounts). Always review the diff before committing.
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
    # shellcheck disable=SC2029 -- REMOTE_ARGS is intentionally expanded client-side
    ssh -t "${SSH_OPTS[@]}" "$HOST" "cd ~/kafka-docker-playground && bash scripts/s390x/certify-connector.sh ${REMOTE_ARGS[*]}"
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
        logwarn "treat as an ungrouped/new connector — classify it manually against s390x-image-analysis.md before proceeding"
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
section "Step 3: check for custom image builds"
# ---------------------------------------------------------------------------
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
    log "no 'build:' sections found — this connector doesn't build its own image, skip to Step 4"
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
            ARCHES=""
            if command -v docker >/dev/null 2>&1
            then
                ARCHES=$(docker manifest inspect "$BASE_IMAGE" 2>/dev/null | python3 -c \
                  "import json,sys
try:
    d=json.load(sys.stdin)
    print([m['platform']['architecture'] for m in d.get('manifests',[])])
except Exception:
    print('unknown')" 2>/dev/null)
            fi
            if [ -n "$HAS_PLATFORM" ]
            then
                log "  3a OK: FROM already pins --platform (${HAS_PLATFORM})"
            elif [ -n "$ARCHES" ] && echo "$ARCHES" | grep -q "s390x"
            then
                log "  3a OK: ${BASE_IMAGE} already publishes an s390x manifest, no --platform needed"
            else
                logwarn "  3a FIX NEEDED: ${BASE_IMAGE} has no s390x manifest (arches: ${ARCHES:-could not check, is docker/podman available?})"
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
        case "$BASE_IMAGE" in
            node:14*|node:14)     logwarn "  3c: ${BASE_IMAGE} is EOL, prefer node:18 or node:20" ;;
            python:3.8*)          logwarn "  3c: ${BASE_IMAGE} is EOL, prefer python:3.11 or python:3.12" ;;
            openjdk:11*)          logwarn "  3c: ${BASE_IMAGE} is EOL, prefer eclipse-temurin:17 or eclipse-temurin:21" ;;
            *)                    log "  3c OK: ${BASE_IMAGE} not a known EOL base" ;;
        esac
    done
fi

# --- SELinux :z check on docker-compose volume mounts (applies regardless of build:) ---
for f in $COMPOSE_FILES
do
    UNLABELED=$(grep -nE "^\s*-\s*\./.*:.*[^z]$|^\s*-\s*\./[^:]*:[^:]*$" "$f" | grep -v ":z" | grep -v ":ro,z" || true)
    if [ -n "$UNLABELED" ]
    then
        REL_F="$(realpath --relative-to="$REPO_ROOT" "$f")"
        logwarn "possible missing SELinux ':z' relabel in ${REL_F} (RHEL10 SELinux-enforcing hosts only):"
        echo "$UNLABELED" | sed 's/^/    /'
        if [ "$APPLY_FIXES" -eq 1 ]
        then
            logwarn "  --apply-fixes does not auto-edit docker-compose volume mounts (too easy to mis-rewrite YAML) — apply manually, see connect/CERTIFYING_S390X.md"
        fi
    fi
done

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
bash "$TEST_SCRIPT_PATH" > "$LOG_FILE" 2>&1
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
    logwarn "if this looks like a QEMU reliability issue (Group 3a/3b service), see the QEMU-vs-external-service tradeoff in the design doc before spending more time debugging emulation."
fi

exit "$TEST_STATUS"
