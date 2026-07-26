#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
project="$repo_root/apps/ios/Litter.xcodeproj"
scheme="PCCDeviceTests"
device_name="${PCC_DEVICE_NAME:-Aeon}"
mode="${1:---smoke}"
timestamp="$(date +%Y%m%d-%H%M%S)"
artifact_dir="${PCC_TEST_ARTIFACT_DIR:-$repo_root/artifacts/pcc-device-tests/$timestamp}"
result_bundle="$artifact_dir/PCCDeviceTests.xcresult"
log_file="$artifact_dir/xcodebuild.log"

mkdir -p "$artifact_dir"

sdk_version="$(xcrun --sdk iphoneos --show-sdk-version)"
if [[ "$sdk_version" != 27.* ]]; then
    echo "PCC tests require the iOS 27 SDK; selected SDK is $sdk_version." >&2
    echo "Set DEVELOPER_DIR to the Xcode 27 beta developer directory and retry." >&2
    exit 2
fi

case "$mode" in
    --preflight)
        tests=(
            "PCCDeviceTests/PrivateCloudComputeDeviceTests/testPreflightReportsAvailabilityAndQuota"
        )
        ;;
    --smoke)
        tests=(
            "PCCDeviceTests/PrivateCloudComputeDeviceTests/testPreflightReportsAvailabilityAndQuota"
            "PCCDeviceTests/PrivateCloudComputeDeviceTests/testMinimalStreamingResponse"
        )
        ;;
    --tools)
        tests=(
            "PCCDeviceTests/PrivateCloudComputeDeviceTests/testPreflightReportsAvailabilityAndQuota"
            "PCCDeviceTests/PrivateCloudComputeDeviceTests/testRequiredToolCallCompletes"
        )
        ;;
    --course-plan)
        tests=(
            "PCCDeviceTests/PrivateCloudComputeDeviceTests/testPreflightReportsAvailabilityAndQuota"
            "PCCDeviceTests/PrivateCloudComputeDeviceTests/testLearnfoldCoursePlanToolBoundary"
        )
        ;;
    --all)
        tests=(
            "PCCDeviceTests/PrivateCloudComputeDeviceTests/testPreflightReportsAvailabilityAndQuota"
            "PCCDeviceTests/PrivateCloudComputeDeviceTests/testMinimalStreamingResponse"
            "PCCDeviceTests/PrivateCloudComputeDeviceTests/testRequiredToolCallCompletes"
            "PCCDeviceTests/PrivateCloudComputeDeviceTests/testLearnfoldCoursePlanToolBoundary"
        )
        ;;
    *)
        echo "Usage: $0 [--preflight|--smoke|--tools|--course-plan|--all]" >&2
        exit 2
        ;;
esac

only_testing=()
for test_name in "${tests[@]}"; do
    only_testing+=("-only-testing:$test_name")
done

echo "Running PCC device tests on '$device_name' with iOS SDK $sdk_version"
echo "Artifacts: $artifact_dir"

set +e
xcodebuild test \
    -project "$project" \
    -scheme "$scheme" \
    -configuration Debug \
    -destination "platform=iOS,name=$device_name" \
    -allowProvisioningUpdates \
    -resultBundlePath "$result_bundle" \
    "${only_testing[@]}" \
    COMPILER_INDEX_STORE_ENABLE=NO \
    2>&1 | tee "$log_file"
status=${PIPESTATUS[0]}
set -e

if [[ -d "$result_bundle" ]]; then
    xcrun xcresulttool get test-results summary \
        --path "$result_bundle" \
        >"$artifact_dir/summary.json" || true
    xcrun xcresulttool export attachments \
        --path "$result_bundle" \
        --output-path "$artifact_dir/attachments" || true
fi

echo "PCC device test exit status: $status"
echo "Log: $log_file"
echo "Result bundle: $result_bundle"
exit "$status"
