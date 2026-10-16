#!/bin/sh
set -eu
cd "$(dirname "$0")"
test_dir=$(mktemp -d /tmp/dreeve-tests.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
cp DreeveIOSTests/ModelSmokeTest.swift "$test_dir/main.swift"
swiftc -module-cache-path "$test_dir/cache" DreeveIOS/Models.swift "$test_dir/main.swift" -o "$test_dir/models"
"$test_dir/models"
swiftc -module-cache-path "$test_dir/cache" DreeveIOS/Models.swift DreeveIOS/GoalEngine.swift DreeveIOS/APIClient.swift DreeveIOSTests/GearContractTest.swift -o "$test_dir/gear"
"$test_dir/gear"
swiftc -module-cache-path "$test_dir/cache" DreeveIOS/Models.swift DreeveIOS/GoalEngine.swift DreeveIOS/APIClient.swift DreeveIOS/HealthSyncCore.swift DreeveIOS/HealthFITExporter.swift DreeveIOSTests/HealthSyncContractTest.swift -o "$test_dir/health"
"$test_dir/health"

swiftc -module-cache-path "$test_dir/cache" DreeveIOS/Models.swift DreeveIOS/GoalEngine.swift DreeveIOS/APIClient.swift DreeveIOSTests/GoalSportMatchingTest.swift -o "$test_dir/goal-sports"
"$test_dir/goal-sports"

swiftc -module-cache-path "$test_dir/cache" DreeveIOS/Models.swift DreeveIOS/GoalEngine.swift DreeveIOS/APIClient.swift DreeveIOS/GoalStore.swift DreeveIOSTests/GoalsContractTest.swift -o "$test_dir/goals"
"$test_dir/goals"

swiftc -module-cache-path "$test_dir/cache" DreeveIOS/Models.swift DreeveIOS/GoalEngine.swift DreeveIOS/APIClient.swift DreeveIOS/GearImageCore.swift DreeveIOSTests/GearFeatureContractTest.swift -o "$test_dir/gear-feature"
"$test_dir/gear-feature"

swiftc -module-cache-path "$test_dir/cache" Shared/GoalWidgetData.swift DreeveIOSTests/GoalWidgetContractTest.swift -o "$test_dir/widgets"
"$test_dir/widgets"

swiftc -module-cache-path "$test_dir/cache" DreeveIOS/Models.swift DreeveIOS/GoalEngine.swift DreeveIOS/APIClient.swift DreeveIOS/Session.swift DreeveIOSTests/SessionRefreshContractTest.swift -o "$test_dir/session-refresh"
"$test_dir/session-refresh"

swiftc -module-cache-path "$test_dir/cache" DreeveIOS/Models.swift DreeveIOS/GoalEngine.swift DreeveIOS/APIClient.swift DreeveIOSTests/ActivityPhotoContractTest.swift -o "$test_dir/activity-photos"
"$test_dir/activity-photos"
