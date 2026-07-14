#!/bin/bash
# SessionStart hook: install the build dependencies PostgreSQL needs from source.
#
# The cloud (web) execution container ships without flex, so every attempt to
# build the backend fails with a "flex ... not found" / "you need flex" error.
# This installs flex plus the other packages configure requires by default
# (bison, ICU, readline, zlib, pkg-config, ...) so the source tree builds
# out of the box.
set -euo pipefail

# Only run in the remote (Claude Code on the web) environment; a developer's
# local machine already has its own toolchain.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# Fast path: if flex is already present the container cache is warm, so skip
# the (slow) apt-get run. This keeps the hook idempotent and cheap on resume.
if command -v flex >/dev/null 2>&1; then
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive

# Prefer sudo when we are not root; on the web container we usually are root.
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
fi

echo "Installing PostgreSQL build dependencies (flex, bison, ICU, ...)"

$SUDO apt-get update -qq

# Core requirements for a default ./configure && make build:
#   flex, bison        - scanner/parser generators (the missing flex is the
#                        error we are fixing)
#   gcc, make          - C toolchain (usually present, listed for completeness)
#   libicu-dev         - ICU, required by default (configure fails without it)
#   pkg-config         - used by configure to locate ICU and other libraries
#   libreadline-dev    - psql line editing (default build expects it)
#   zlib1g-dev         - pg_dump compression (default build expects it)
#   perl               - build scripts and many generated files
$SUDO apt-get install -y -qq --no-install-recommends \
  flex \
  bison \
  gcc \
  make \
  libicu-dev \
  pkg-config \
  libreadline-dev \
  zlib1g-dev \
  perl

echo "PostgreSQL build dependencies installed:"
flex --version || true
bison --version | head -1 || true
