#!/bin/bash
#
# One-time setup for a shared s390x RHEL 10 VM used for connector certification.
#
# Implements the same steps as the Semaphore prologue described in
# "Automated Testing: Connector Certification on s390x architecture" (Section 5.2),
# adapted to be idempotent since these VMs are long-lived and shared across SMEs
# (unlike ephemeral Semaphore agents where a fresh prologue runs every job).
#
# Usage: sudo bash scripts/s390x/setup-vm.sh
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../utils.sh 2>/dev/null || true

log() { echo "[setup-s390x-vm] $*"; }
logwarn() { echo "[setup-s390x-vm][WARN] $*" >&2; }
logerror() { echo "[setup-s390x-vm][ERROR] $*" >&2; }

if [ "$(uname -m)" != "s390x" ]
then
    logerror "this script must be run on an s390x host, detected $(uname -m)"
    exit 1
fi

if [ "$EUID" -ne 0 ]
then
    logerror "this script must be run as root (sudo bash scripts/s390x/setup-vm.sh)"
    exit 1
fi

QEMU_BINARY=/usr/local/bin/qemu-x86_64-static
QEMU_DEB_URL="https://ftp.debian.org/debian/pool/main/q/qemu/qemu-user-static_7.2+dfsg-7+deb12u18+b1_s390x.deb"

log "step 1/3: QEMU user-mode static binary (Debian 12 bookworm build)"
# NOTE: tonistiigi/binfmt is deliberately NOT used here — its QEMU binary
# crashes ("Bad PSW") on this s390x CPU generation. See Section 5 diagnostic table.
if [ -x "$QEMU_BINARY" ] && "$QEMU_BINARY" --version 2>/dev/null | grep -q "7.2"
then
    log "  qemu-x86_64-static 7.2 already installed at ${QEMU_BINARY}, skipping download"
else
    TMP_DEB="$(mktemp /tmp/qemu.XXXXXX.deb)"
    TMP_EXTRACT="$(mktemp -d /tmp/qemu-extracted.XXXXXX)"
    curl -fL -o "$TMP_DEB" "$QEMU_DEB_URL"
    dpkg-deb -x "$TMP_DEB" "$TMP_EXTRACT"
    cp "${TMP_EXTRACT}/usr/bin/qemu-x86_64-static" "$QEMU_BINARY"
    chmod +x "$QEMU_BINARY"
    rm -rf "$TMP_DEB" "$TMP_EXTRACT"
    log "  installed ${QEMU_BINARY}"
fi

log "step 2/3: binfmt_misc registration (F flag, so it stays resolvable from inside containers)"
if [ -e /proc/sys/fs/binfmt_misc/qemu-x86_64 ]
then
    if grep -q "flags:.*F" /proc/sys/fs/binfmt_misc/qemu-x86_64 2>/dev/null
    then
        log "  qemu-x86_64 already registered with F flag, skipping"
    else
        logwarn "  existing qemu-x86_64 registration is missing the F flag, re-registering"
        echo -1 > /proc/sys/fs/binfmt_misc/qemu-x86_64 2>/dev/null || true
        echo ':qemu-x86_64:M:0:\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/local/bin/qemu-x86_64-static:F' > /proc/sys/fs/binfmt_misc/register
    fi
else
    echo ':qemu-x86_64:M:0:\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/local/bin/qemu-x86_64-static:F' > /proc/sys/fs/binfmt_misc/register
    log "  registered qemu-x86_64 with F flag"
fi

log "step 3/3: podman short-name resolution (RHEL 10 requires 'permissive' for non-interactive use)"
REGISTRIES_CONF=/etc/containers/registries.conf
if grep -q 'short-name-mode = "permissive"' "$REGISTRIES_CONF" 2>/dev/null
then
    log "  short-name-mode already permissive, skipping"
elif grep -q "short-name-mode" "$REGISTRIES_CONF" 2>/dev/null
then
    sed -i 's/short-name-mode = "enforced"/short-name-mode = "permissive"/' "$REGISTRIES_CONF"
    log "  updated short-name-mode to permissive in ${REGISTRIES_CONF}"
else
    logwarn "  no short-name-mode setting found in ${REGISTRIES_CONF}, leaving untouched — verify manually if image pulls prompt for a registry"
fi

log "verification:"
cat /proc/sys/fs/binfmt_misc/qemu-x86_64 | grep "flags:" || logerror "qemu-x86_64 binfmt_misc entry not found"
"$QEMU_BINARY" --version | head -1

log "done. This registration lives in-memory and is lost on reboot — re-run this script after any VM restart."
log "next: clone/copy the kafka-docker-playground s390x branch, then run scripts/s390x/certify-connector.sh <connector-dir>"
