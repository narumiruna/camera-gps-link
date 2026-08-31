set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

xcode_dev_dir := "/Applications/Xcode.app/Contents/Developer"
ios_project := "ios/CameraGPSLink/CameraGPSLink.xcodeproj"
ios_target := "CameraGPSLink"
ios_scheme := "CameraGPSLink"
ios_smoke := "/tmp/CameraGPSLinkSmoke"
ios_test_device_name := "CameraGPSLink Tests"
ios_test_destination := "platform=iOS Simulator,name=" + ios_test_device_name + ",OS=latest"

[default]
all: check

# Show available recipes
list:
    just --list

# Run the full local iOS verification gate
check: source-line-check ios-check

# Reject Swift program sources over 1000 lines
source-line-check:
    bash scripts/check_source_lines.sh

# Open the iOS app project in Xcode
ios-open:
    open {{ios_project}}

# Run the Swift DD11 protocol and location policy smoke test
ios-smoke:
    swiftc ios/CameraGPSLink/CameraGPSLink/SonyProtocol.swift ios/CameraGPSLink/CameraGPSLink/SonyLocationProfile.swift ios/CameraGPSLink/CameraGPSLink/SonyLocationSessionPlan.swift ios/CameraGPSLink/CameraGPSLink/LocationProvider.swift ios/CameraGPSLink/CameraGPSLinkTests/main.swift -o {{ios_smoke}}
    {{ios_smoke}}

# Type check all Swift sources
ios-typecheck:
    swiftc -typecheck ios/CameraGPSLink/CameraGPSLink/*.swift

# Lint iOS plist/project XML files
ios-lint-project:
    plutil -lint ios/CameraGPSLink/CameraGPSLink/Info.plist ios/CameraGPSLink/CameraGPSLink.xcodeproj/project.pbxproj
    xmllint --noout ios/CameraGPSLink/CameraGPSLink.xcodeproj/xcshareddata/xcschemes/CameraGPSLink.xcscheme

# Build the iOS target for Simulator
ios-build-sim:
    DEVELOPER_DIR={{xcode_dev_dir}} xcodebuild -project {{ios_project}} -target {{ios_target}} -sdk iphonesimulator -configuration Debug build

# Compile the iOS target for device without code signing
ios-build-device-nosign:
    DEVELOPER_DIR={{xcode_dev_dir}} xcodebuild -project {{ios_project}} -target {{ios_target}} -sdk iphoneos -configuration Debug CODE_SIGNING_ALLOWED=NO build

# Create a project-dedicated simulator so concurrent XCUITest suites cannot steal focus
ios-test-prepare:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! DEVELOPER_DIR={{xcode_dev_dir}} xcrun simctl list devices available | grep -Fq '{{ios_test_device_name}} ('; then
        runtime=$(DEVELOPER_DIR={{xcode_dev_dir}} xcrun simctl list runtimes available | awk '/^iOS / { runtime=$NF } END { print runtime }')
        test -n "$runtime"
        DEVELOPER_DIR={{xcode_dev_dir}} xcrun simctl create '{{ios_test_device_name}}' com.apple.CoreSimulator.SimDeviceType.iPhone-17 "$runtime" >/dev/null
    fi

# Run the iOS XCTest unit suite
[no-exit-message]
ios-unit-test: ios-test-prepare
    DEVELOPER_DIR={{xcode_dev_dir}} xcodebuild test -project {{ios_project}} -scheme {{ios_scheme}} -destination '{{ios_test_destination}}' -only-testing:CameraGPSLinkUnitTests

# Run the iOS XCUITest suite
[no-exit-message]
ios-ui-test: ios-test-prepare
    DEVELOPER_DIR={{xcode_dev_dir}} xcodebuild test -project {{ios_project}} -scheme {{ios_scheme}} -destination '{{ios_test_destination}}' -only-testing:CameraGPSLinkUITests

# Run all iOS XCTest suites, resetting the dedicated simulator between test hosts
[no-exit-message]
ios-test:
    DEVELOPER_DIR={{xcode_dev_dir}} xcrun simctl delete '{{ios_test_device_name}}' >/dev/null 2>&1 || true
    just ios-unit-test
    DEVELOPER_DIR={{xcode_dev_dir}} xcrun simctl delete '{{ios_test_device_name}}' >/dev/null 2>&1 || true
    just ios-ui-test

# Run all iOS compile/smoke/test checks
ios-check: ios-smoke ios-typecheck ios-lint-project ios-build-sim ios-build-device-nosign ios-test

# Show Xcode destinations for the app scheme
ios-destinations:
    DEVELOPER_DIR={{xcode_dev_dir}} xcodebuild -showdestinations -project {{ios_project}} -scheme {{ios_scheme}}

# Launch the installed iOS app on a USB-connected device and attach console output
ios-console device="00008140-0001588C017B001C":
    DEVELOPER_DIR={{xcode_dev_dir}} xcrun devicectl device process launch --device {{device}} --console dev.narumi.cameragpslink

# Remove local build/test artifacts
clean:
    rm -rf ios/CameraGPSLink/build {{ios_smoke}}
