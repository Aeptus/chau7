#!/bin/bash
# Run pure Core tests without compiling, linking, or launching Chau7.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package_dir="$(dirname "$script_dir")"
export CHAU7_CORE_TESTS_ONLY=1
exec swift test --package-path "$package_dir" \
    --scratch-path "$package_dir/.build/core-tests" \
    --jobs "${CHAU7_SWIFT_JOBS:-2}" "$@"
