#!/bin/zsh
# Builds the given products (default: GSRApp GSRMidiAgent) for Apple silicon and for Intel and joins them with lipo into .build/universal/<product>, ad-hoc signed.
# SwiftPM can only build two architectures in one go with Xcode; the command line tools build one at a time, hence the two passes and the lipo.
set -e
cd "$(dirname "$0")"
PRODUCTS=("$@"); [ ${#PRODUCTS[@]} -eq 0 ] && PRODUCTS=(GSRApp GSRMidiAgent)
mkdir -p .build/universal
for p in $PRODUCTS; do
  swift build -c release --product $p --arch arm64 --scratch-path .build/arm64
  swift build -c release --product $p --arch x86_64 --scratch-path .build/x86_64
  A=$(swift build -c release --arch arm64 --scratch-path .build/arm64 --show-bin-path)
  X=$(swift build -c release --arch x86_64 --scratch-path .build/x86_64 --show-bin-path)
  lipo -create -output .build/universal/$p "$A/$p" "$X/$p"
  codesign --force --sign - .build/universal/$p
  echo "$p: $(lipo -archs .build/universal/$p)"
done
