#!/usr/bin/env bash
# Copyright 2026 Ezrael
# SPDX-License-Identifier: Apache-2.0

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
readonly PROJECT_DIR

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'ERROR: falta el comando requerido: %s\n' "$1" >&2
    exit 1
  }
}

require_command bash
require_command grep
require_command shellcheck

cd -- "$PROJECT_DIR"

expected_version=$(tr -d '[:space:]' <VERSION)
script_version=$(awk -F '"' '/^readonly PROGRAM_VERSION=/{print $2; exit}' zero-launcher.sh)

if [[ -z "$expected_version" || "$expected_version" != "$script_version" ]]; then
  printf 'ERROR: VERSION=%s y PROGRAM_VERSION=%s no coinciden.\n' \
    "$expected_version" "$script_version" >&2
  exit 1
fi

grep -Fq "## $expected_version" CHANGELOG.md || {
  printf 'ERROR: CHANGELOG.md no contiene la versión %s.\n' "$expected_version" >&2
  exit 1
}

grep -Fq 'Copyright 2026 Ezrael' NOTICE || {
  printf 'ERROR: NOTICE no contiene la atribución esperada.\n' >&2
  exit 1
}

grep -Fq 'Apache License' LICENSE || {
  printf 'ERROR: LICENSE no contiene Apache-2.0.\n' >&2
  exit 1
}

bash -n zero-launcher.sh scripts/package-release.sh scripts/preflight.sh tests/test.sh
shellcheck --severity=style zero-launcher.sh scripts/package-release.sh scripts/preflight.sh tests/test.sh
bash tests/test.sh

printf 'OK: preflight completo de Zero Launcher %s.\n' "$expected_version"
