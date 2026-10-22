#!/bin/sh
# Xcode Cloud: cada build precisa de um número maior que o último enviado ao App Store Connect.
# Usa data e hora (UTC) como número de build, então ele sempre cresce, mesmo depois de
# builds enviados à mão pelo Xcode.
set -e

if [ "$CI_XCODEBUILD_ACTION" != "archive" ]; then
    exit 0
fi

BUILD_NUMBER=$(date -u +%y%m%d%H%M)
PROJECT="$CI_PRIMARY_REPOSITORY_PATH/MangaCademy.xcodeproj/project.pbxproj"

sed -i '' -E "s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = $BUILD_NUMBER;/g" "$PROJECT"
echo "Número de build: $BUILD_NUMBER"
