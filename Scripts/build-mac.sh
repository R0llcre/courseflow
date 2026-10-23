#!/bin/zsh
set -eu
courseflow_root="${0:A:h:h}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
courseflow_build="${COURSEFLOW_BUILD_DIR:-$HOME/Library/Caches/CourseflowBuild}"
courseflow_configuration="${COURSEFLOW_CONFIGURATION:-Debug}"
[[ "$courseflow_configuration" == Debug || "$courseflow_configuration" == Release ]] || exit 2
cd "$courseflow_root"
xcodebuild -quiet -project Courseflow.xcodeproj -scheme Courseflow -configuration "$courseflow_configuration" \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$courseflow_build" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES ONLY_ACTIVE_ARCH=YES build
swift Scripts/verify-colors.swift "$courseflow_build/Build/Products/$courseflow_configuration/Courseflow.app"
echo "Built: $courseflow_build/Build/Products/$courseflow_configuration/Courseflow.app"
