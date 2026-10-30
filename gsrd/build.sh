#!/bin/bash
# Builds gsrd and the ring checker. No installation.
set -e
cd "$(dirname "$0")"
# universal (Apple silicon and Intel); ARCHS="-arch arm64" builds for this Mac only, faster
F="-O1 -Wall -Wextra ${ARCHS:--arch arm64 -arch x86_64}"
clang $F -o gsrd gsrd.c gsr_midi.c -framework IOKit -framework CoreFoundation -lm
clang $F -o ringcheck ringcheck.c -lm
clang $F -o gsrctl gsrctl.c
clang $F -o gsrmidi gsrmidi.c
clang $F -o midi_test midi_test.c gsr_midi.c && ./midi_test
clang $F -o ringprobe ringprobe.c
codesign --force --sign - gsrd ringcheck gsrctl ringprobe gsrmidi
echo built
