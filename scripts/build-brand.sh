#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
brand_build="$(mktemp -d "${TMPDIR:-/tmp}/bungbungi-brand.XXXXXX")"
trap 'rm -rf "$brand_build"' EXIT
xcrun swiftc "$repo_dir/Sources/SoriCore/BrandSymbol.swift" "$repo_dir/scripts/make-icon.swift" -o "$brand_build/make-icon"
"$brand_build/make-icon" "$@"
