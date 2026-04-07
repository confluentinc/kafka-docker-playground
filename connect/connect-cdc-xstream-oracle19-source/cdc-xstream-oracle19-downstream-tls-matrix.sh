#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"

# Downstream TLS test matrix runner.
#
# Runs all 9 TLS combinations from the test matrix (see design spec).
# Each test invokes either the one-way (downstream-ssl) or two-way (downstream-mtls)
# script with appropriate SOURCE_TLS_MODE and DOWNSTREAM_TLS_MODE.
#
# Wallets are always separate: source and downstream each get their own wallet.
# No fallback or shared wallet support.
#
# Usage:
#   ./cdc-xstream-oracle19-downstream-tls-matrix.sh              # run all 9 tests
#   ./cdc-xstream-oracle19-downstream-tls-matrix.sh 1 2 5        # run specific tests by number
#   ./cdc-xstream-oracle19-downstream-tls-matrix.sh oneway       # run all one-way tests (1-4)
#   ./cdc-xstream-oracle19-downstream-tls-matrix.sh twoway       # run all two-way tests (5-9)

source ${DIR}/../../scripts/utils.sh

# Test matrix (separate wallets only):
# #  | Source TLS | Downstream TLS | Script
# ---|-----------|----------------|-------
# 1  | disable   | disable        | ssl
# 2  | one-way   | disable        | ssl
# 3  | disable   | one-way        | ssl
# 4  | one-way   | one-way        | ssl
# 5  | two-way   | disable        | mtls
# 6  | disable   | two-way        | mtls
# 7  | two-way   | two-way        | mtls
# 8  | one-way   | two-way        | mtls
# 9  | two-way   | one-way        | mtls

SSL_SCRIPT="${DIR}/cdc-xstream-oracle19-downstream-ssl.sh"
MTLS_SCRIPT="${DIR}/cdc-xstream-oracle19-downstream-mtls.sh"

declare -A TEST_SOURCE_TLS
declare -A TEST_DOWNSTREAM_TLS
declare -A TEST_SCRIPT

TEST_SOURCE_TLS[1]="disable";    TEST_DOWNSTREAM_TLS[1]="disable";  TEST_SCRIPT[1]="$SSL_SCRIPT"
TEST_SOURCE_TLS[2]="one-way";    TEST_DOWNSTREAM_TLS[2]="disable";  TEST_SCRIPT[2]="$SSL_SCRIPT"
TEST_SOURCE_TLS[3]="disable";    TEST_DOWNSTREAM_TLS[3]="one-way";  TEST_SCRIPT[3]="$SSL_SCRIPT"
TEST_SOURCE_TLS[4]="one-way";    TEST_DOWNSTREAM_TLS[4]="one-way";  TEST_SCRIPT[4]="$SSL_SCRIPT"
TEST_SOURCE_TLS[5]="two-way";    TEST_DOWNSTREAM_TLS[5]="disable";  TEST_SCRIPT[5]="$MTLS_SCRIPT"
TEST_SOURCE_TLS[6]="disable";    TEST_DOWNSTREAM_TLS[6]="two-way";  TEST_SCRIPT[6]="$MTLS_SCRIPT"
TEST_SOURCE_TLS[7]="two-way";    TEST_DOWNSTREAM_TLS[7]="two-way";  TEST_SCRIPT[7]="$MTLS_SCRIPT"
TEST_SOURCE_TLS[8]="one-way";    TEST_DOWNSTREAM_TLS[8]="two-way";  TEST_SCRIPT[8]="$MTLS_SCRIPT"
TEST_SOURCE_TLS[9]="two-way";    TEST_DOWNSTREAM_TLS[9]="one-way";  TEST_SCRIPT[9]="$MTLS_SCRIPT"

ALL_TESTS="1 2 3 4 5 6 7 8 9"
ONEWAY_TESTS="1 2 3 4"
TWOWAY_TESTS="5 6 7 8 9"

# Parse arguments
if [[ $# -eq 0 ]]; then
     TESTS_TO_RUN="$ALL_TESTS"
elif [[ "$1" == "oneway" ]]; then
     TESTS_TO_RUN="$ONEWAY_TESTS"
elif [[ "$1" == "twoway" ]]; then
     TESTS_TO_RUN="$TWOWAY_TESTS"
else
     TESTS_TO_RUN="$@"
fi

PASSED=()
FAILED=()

log "=========================================================="
log "  DOWNSTREAM TLS TEST MATRIX"
log "  Running tests: ${TESTS_TO_RUN}"
log "=========================================================="

for TEST_NUM in $TESTS_TO_RUN; do
     if [[ -z "${TEST_SOURCE_TLS[$TEST_NUM]}" ]]; then
          logerror "Unknown test number: $TEST_NUM"
          continue
     fi

     SRC="${TEST_SOURCE_TLS[$TEST_NUM]}"
     DS="${TEST_DOWNSTREAM_TLS[$TEST_NUM]}"
     SCRIPT="${TEST_SCRIPT[$TEST_NUM]}"

     log "=========================================================="
     log "  TEST #${TEST_NUM}: source=${SRC}, downstream=${DS}"
     log "  Script: $(basename $SCRIPT)"
     log "=========================================================="

     export SOURCE_TLS_MODE="$SRC"
     export DOWNSTREAM_TLS_MODE="$DS"
     export WALLET_SETUP="separate"

     set +e
     bash "$SCRIPT"
     EXIT_CODE=$?
     set -e

     if [[ $EXIT_CODE -eq 0 ]]; then
          log "TEST #${TEST_NUM} PASSED (source=${SRC}, downstream=${DS})"
          PASSED+=($TEST_NUM)
     else
          logerror "TEST #${TEST_NUM} FAILED (source=${SRC}, downstream=${DS})"
          FAILED+=($TEST_NUM)
     fi

     # Cleanup between tests
     log "Cleaning up containers for next test..."
     docker rm -f sourcedb downstreamdb 2>/dev/null || true
     docker network prune -f 2>/dev/null || true
     sleep 5
done

log "=========================================================="
log "  MATRIX RESULTS"
log "=========================================================="
log "  Passed: ${PASSED[*]:-none} (${#PASSED[@]}/${#PASSED[@]}+${#FAILED[@]})"
if [[ ${#FAILED[@]} -gt 0 ]]; then
     logerror "  Failed: ${FAILED[*]} (${#FAILED[@]})"
     exit 1
else
     log "  All tests passed!"
fi
