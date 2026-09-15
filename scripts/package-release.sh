#!/usr/bin/env bash
# Copyright 2026 Ezrael
# SPDX-License-Identifier: Apache-2.0

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
readonly PROJECT_DIR
OUTPUT_DIR=${1:-"$PROJECT_DIR/dist"}

mkdir -p -- "$OUTPUT_DIR"
install -m 0755 "$PROJECT_DIR/zero-launcher.sh" "$OUTPUT_DIR/zero-launcher.sh"

(
  cd -- "$OUTPUT_DIR"
  sha256sum zero-launcher.sh >zero-launcher.sh.sha256
  sha256sum --check --status zero-launcher.sh.sha256
)

printf 'OK: artefactos creados en %s\n' "$OUTPUT_DIR"
