#!/bin/bash
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_dir"
configuration=${1:-Debug}
case "$configuration" in Debug|Release) ;; *) printf '%s\n' "Expected Debug or Release" >&2; exit 2 ;; esac
output_dir=${2:-"$repo_dir/build/ci"}
mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd)
mkdir -p "$output_dir/logs"

# Never request Apple credentials or provisioning in CI. Personal Team builds
# remain local-only; downloaded iPhone products require the user's own signing.
settings=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO 'DEVELOPMENT_TEAM=')
if [[ "${GITHUB_REF_TYPE:-}" == tag ]]; then
  version=$(python3 - "${GITHUB_REF_NAME:?}" <<'PYVERSION'
import re, sys
match = re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?", sys.argv[1])
if match is None:
    sys.exit("Release tags must look like v1.2.3 or v1.2.3-beta.1")
print(".".join(match.groups()))
PYVERSION
  )
  build_number=${GITHUB_RUN_NUMBER:-1}
  [[ "$build_number" =~ ^[0-9]+$ ]] || { printf '%s\n' 'Invalid build number' >&2; exit 2; }
  settings+=("MARKETING_VERSION=$version" "CURRENT_PROJECT_VERSION=$build_number")
fi

./run_tests.sh 2>&1 | tee "$output_dir/logs/tests.log"
for sdk in iphonesimulator iphoneos; do
  if [[ "$sdk" == iphonesimulator ]]; then
    destination='generic/platform=iOS Simulator'
  else
    destination='generic/platform=iOS'
  fi
  xcodebuild -project DreeveIOS.xcodeproj -scheme DreeveIOS \
    -configuration "$configuration" -sdk "$sdk" -destination "$destination" \
    -derivedDataPath "$output_dir/derived-$sdk" \
    "${settings[@]}" build 2>&1 | tee "$output_dir/logs/$sdk.log"
done

python3 scripts/package_build.py \
  --simulator-app "$output_dir/derived-iphonesimulator/Build/Products/$configuration-iphonesimulator/DreeveIOS.app" \
  --iphone-app "$output_dir/derived-iphoneos/Build/Products/$configuration-iphoneos/DreeveIOS.app" \
  --output-dir "$output_dir/dist"
