#!/bin/bash
# Builds the spike: helper binary and the AudioServerPlugIn bundle, ad-hoc signed. No installation.
set -e
cd "$(dirname "$0")"
clang -O1 -Wall -Wextra -arch arm64 -o gsr24m-spike-helper helper.c
rm -rf GSRSpike.driver
mkdir -p GSRSpike.driver/Contents/MacOS
clang -O1 -Wall -Wextra -arch arm64 -bundle -o GSRSpike.driver/Contents/MacOS/GSRSpike plugin.c -framework CoreAudio -framework CoreFoundation
cp Info.plist GSRSpike.driver/Contents/Info.plist
codesign --force --sign - gsr24m-spike-helper
codesign --force --sign - GSRSpike.driver
codesign --verify --verbose=2 GSRSpike.driver
echo built
