#!/bin/bash
# Builds the plug-in bundle, the development stand-in (devsim) and the offline harness. No installation.
set -e
cd "$(dirname "$0")"
# universal (Apple silicon and Intel); ARCHS="-arch arm64" builds for this Mac only, faster
F="-O1 -Wall -Wextra ${ARCHS:--arch arm64 -arch x86_64}"
clang $F -o devsim devsim.c
rm -rf GSR24M.driver
mkdir -p GSR24M.driver/Contents/MacOS
clang $F -bundle -o GSR24M.driver/Contents/MacOS/GSR24M plugin.c -framework CoreAudio -framework CoreFoundation
cp Info.plist GSR24M.driver/Contents/Info.plist
clang $F -o harness harness.c -framework CoreAudio -framework CoreFoundation
codesign --force --sign - devsim harness
codesign --force --sign - GSR24M.driver
codesign --verify --verbose=2 GSR24M.driver
echo built
