#!/bin/sh
set -eu
cd "$(dirname "$0")"
test_dir=$(mktemp -d /tmp/dreeve-tests.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
cp DreeveIOSTests/ModelSmokeTest.swift "$test_dir/main.swift"
swiftc -module-cache-path "$test_dir/cache" DreeveIOS/Models.swift "$test_dir/main.swift" -o "$test_dir/models"
"$test_dir/models"
swiftc -module-cache-path "$test_dir/cache" DreeveIOS/Models.swift DreeveIOS/APIClient.swift DreeveIOSTests/GearContractTest.swift -o "$test_dir/gear"
"$test_dir/gear"
swiftc -module-cache-path "$test_dir/cache" DreeveIOS/Models.swift DreeveIOS/APIClient.swift DreeveIOS/HealthSyncCore.swift DreeveIOSTests/HealthSyncContractTest.swift -o "$test_dir/health"
"$test_dir/health"
