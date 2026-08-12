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

# --- container runtime check (does NOT auto-install anything) ---
#
# An earlier VM in this fleet had no container runtime at all, and the
# default assumption ("these are RHEL 10 / rootful Podman 5.x", per the
# design doc) turned out not to hold -- it was Ubuntu with nothing
# installed. Installing Podman there instead of Docker cost real time:
# podman-compose doesn't support `profiles:` correctly, needed a custom
# compose-provider dispatch shim since that Podman version predates native
# `podman compose`, and Podman's own registries.conf (unqualified-search-
# registries, short-name-mode) needed manual configuration -- none of which
# are real problems, they're Podman-specific setup that Docker doesn't have.
# Real Docker Engine ships its own embedded DNS (no netavark/aardvark-dns
# packaging gap to work around either) and is what KDP's compose files and
# `profiles:` gating were actually designed against.
#
# This script does not install either runtime for you -- package
# availability and any rootless-by-policy requirement are yours to check.
# Guidance:
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1
then
    log "container runtime: Docker with compose plugin found, good -- nothing to do here"
    HAVE_PODMAN=0
elif command -v podman >/dev/null 2>&1
then
    log "container runtime: Podman found, no Docker"
    logwarn "if Podman isn't a hard requirement (e.g. rootless-by-policy), installing"
    logwarn "docker.io + docker-compose-plugin instead avoids the whole class of"
    logwarn "podman-compose/profiles:/registries.conf issues below -- worth checking"
    logwarn "before continuing with Podman."
    logwarn "if Podman IS required: prefer pointing the real docker-compose (v1/v2)"
    logwarn "at Podman's Docker-API-compatible socket over podman-compose --"
    logwarn "  export DOCKER_HOST=unix:///run/podman/podman.sock"
    logwarn "-- this is Podman's own documented compose story, handles 'profiles:'"
    logwarn "correctly, and needs no custom dispatch shim."
    HAVE_PODMAN=1
else
    logerror "no container runtime found (checked for docker, podman)"
    logerror "prefer installing docker.io + docker-compose-plugin -- see the"
    logerror "comment above this check for why. Install that (or Podman, if"
    logerror "required) yourself, then re-run this script."
    exit 1
fi

QEMU_BINARY=/usr/local/bin/qemu-x86_64-static
QEMU_DEB_POOL_URL="https://ftp.debian.org/debian/pool/main/q/qemu/"

log "step 1/3: QEMU user-mode static binary (Debian 12 bookworm build)"
# NOTE: tonistiigi/binfmt is deliberately NOT used here — its QEMU binary
# crashes ("Bad PSW") on this s390x CPU generation. See Section 5 diagnostic table.
if [ -x "$QEMU_BINARY" ] && "$QEMU_BINARY" --version 2>/dev/null | grep -q "7.2"
then
    log "  qemu-x86_64-static 7.2 already installed at ${QEMU_BINARY}, skipping download"
else
    # Debian's pool only keeps the LATEST rebuild of a given point release --
    # a hardcoded filename here has already rotted once (+b1 pruned, replaced
    # by +b3, with no redirect). Look up whatever the current 7.2.x s390x
    # build actually is instead of pinning an exact filename that will go
    # stale again. (A fully immutable alternative is snapshot.debian.org, at
    # the cost of never picking up point-release security fixes within 7.2 --
    # not used here since the failure mode we've actually hit is pruning, not
    # a need for a frozen snapshot.)
    QEMU_DEB_FILENAME=$(curl -fsL "$QEMU_DEB_POOL_URL" | grep -oE 'qemu-user-static_7\.2[^"]*_s390x\.deb' | sort -V | tail -1)
    if [ -z "$QEMU_DEB_FILENAME" ]
    then
        logerror "could not find a qemu-user-static 7.2.x s390x package at ${QEMU_DEB_POOL_URL}"
        logerror "check that URL manually -- Debian may have moved past the 7.2 line entirely"
        exit 1
    fi
    log "  found ${QEMU_DEB_FILENAME} in the Debian pool"
    TMP_DEB="$(mktemp /tmp/qemu.XXXXXX.deb)"
    TMP_EXTRACT="$(mktemp -d /tmp/qemu-extracted.XXXXXX)"
    curl -fL -o "$TMP_DEB" "${QEMU_DEB_POOL_URL}${QEMU_DEB_FILENAME}"
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

if [ "$HAVE_PODMAN" -eq 1 ]
then
    log "step 3/3: podman registries.conf (short-name resolution + unqualified-search-registries)"
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

    # KDP images (confluentinc/*, vdesabou/*, ...) are referenced by short name
    # throughout the repo's docker-compose files and Dockerfiles; without this,
    # podman refuses to resolve them ("no unqualified-search registries are
    # defined").
    if grep -qE '^\s*unqualified-search-registries\s*=' "$REGISTRIES_CONF" 2>/dev/null
    then
        log "  unqualified-search-registries already set, skipping"
    else
        echo 'unqualified-search-registries = ["docker.io"]' >> "$REGISTRIES_CONF"
        log "  added unqualified-search-registries = [\"docker.io\"] to ${REGISTRIES_CONF}"
    fi
else
    log "step 3/3: skipped (Docker detected, no Podman registries.conf to configure)"
fi

log "verification:"
cat /proc/sys/fs/binfmt_misc/qemu-x86_64 | grep "flags:" || logerror "qemu-x86_64 binfmt_misc entry not found"
"$QEMU_BINARY" --version | head -1

log "done. This registration lives in-memory and is lost on reboot — re-run this script after any VM restart."
log "next: clone/copy the kafka-docker-playground s390x branch, then run scripts/s390x/certify-connector.sh <connector-dir>"
