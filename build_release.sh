#!/bin/zsh
# Builds everything and the installer: dist/GSR24M-<version>.pkg and dist/GSR24M-<version>.pkg.sha256
# Needs the Command Line Tools only. The package is NOT signed with a Developer ID (see README).
set -e
cd "$(dirname "$0")"
ROOT=$PWD
VER=$(cat VERSION)
echo "== GSR24M $VER"
(cd gsrd && ./build.sh)
(cd hal && ./build.sh)
(cd GSRCore && swift test 2>&1 | tail -1 && ./make_app.sh && true)          # make_app.sh builds the app and the agent, both universal (GSRCore/.build/universal)
STAGE=$ROOT/dist/stage
rm -rf "$ROOT/dist"; mkdir -p "$STAGE/Applications" "$STAGE/Library/Audio/Plug-Ins/HAL" "$STAGE/Library/LaunchDaemons" "$STAGE/Library/LaunchAgents" "$STAGE/usr/local/libexec"
cp -R GSRCore/build/GSR24M.app "$STAGE/Applications/"
cp -R hal/GSR24M.driver "$STAGE/Library/Audio/Plug-Ins/HAL/"
cp gsrd/gsrd "$STAGE/usr/local/libexec/gsrd"
cp GSRCore/.build/universal/GSRMidiAgent "$STAGE/usr/local/libexec/gsrmidiagent"
cp installer/com.gsr24m.midiagent.plist "$STAGE/Library/LaunchAgents/"
cp gsrd/com.gsr24m.gsrd.plist "$STAGE/Library/LaunchDaemons/"
cp installer/uninstall.sh "$STAGE/usr/local/libexec/gsr24m-uninstall.sh"
# bundles must go exactly where we put them (no relocation to another copy found by the Installer)
pkgbuild --analyze --root "$STAGE" "$ROOT/dist/components.plist" >/dev/null
python3 - "$ROOT/dist/components.plist" <<'PY'
import plistlib, sys
p = sys.argv[1]; d = plistlib.load(open(p, 'rb'))
for c in d: c['BundleIsRelocatable'] = False; c['BundleIsVersionChecked'] = False; c['BundleOverwriteAction'] = 'upgrade'
plistlib.dump(d, open(p, 'wb'))
PY
pkgbuild --root "$STAGE" --component-plist "$ROOT/dist/components.plist" --identifier com.gsr24m.pkg --version "$VER" --install-location / --ownership recommended \
         --scripts installer/scripts "$ROOT/dist/component.pkg"
RES=$ROOT/dist/resources; mkdir -p "$RES"
sed "s/@VERSION@/$VER/g" installer/resources/welcome.html > "$RES/welcome.html"
cp installer/resources/conclusion.html "$RES/"
sed "s/@VERSION@/$VER/g" installer/distribution.xml > "$ROOT/dist/distribution.xml"
(cd dist && productbuild --distribution distribution.xml --resources resources --package-path . "GSR24M-$VER.pkg")
(cd dist && shasum -a 256 "GSR24M-$VER.pkg" > "GSR24M-$VER.pkg.sha256")
rm -rf dist/stage dist/components.plist dist/component.pkg dist/resources dist/distribution.xml
ls -la dist
cat "dist/GSR24M-$VER.pkg.sha256"
