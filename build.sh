#!/bin/sh
# Builds Kueri.app. Needs: Xcode CLT + `brew install libpq openssl@3`.
set -e
cd "$(dirname "$0")"
PQ=$(brew --prefix libpq 2>/dev/null || echo /usr/local/opt/libpq)
SSL=$(brew --prefix openssl@3 2>/dev/null || echo /usr/local/opt/openssl@3)
swift build -c release -Xcc -I"$PQ/include" -Xlinker -L"$PQ/lib" -Xcc -I"$SSL/include" -Xlinker -L"$SSL/lib"
APP=Kueri.app
[ -f AppIcon.icns ] || { swift icon.swift && iconutil -c icns AppIcon.iconset -o AppIcon.icns && rm -rf AppIcon.iconset; }
rm -rf $APP && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/release/Kueri $APP/Contents/MacOS/
cp AppIcon.icns $APP/Contents/Resources/
cat > $APP/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Kueri</string>
<key>CFBundleIdentifier</key><string>app.kueri</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleName</key><string>Kueri</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1.4</string>
<key>CFBundleVersion</key><string>6</string>
<key>LSMinimumSystemVersion</key><string>14.4</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Kueri connects to database servers on your local network.</string>
</dict></plist>
PL
# A stable signing identity keeps macOS permissions (Local Network) across rebuilds; ad-hoc
# signatures change with every build. Create one with: Keychain Access › Certificate Assistant ›
# Create a Certificate… (type: Code Signing), named "Kueri Local Signing"; or set KUERI_SIGN_IDENTITY.
SIGN=${KUERI_SIGN_IDENTITY:-$(security find-identity -p codesigning 2>/dev/null | grep -q '"Kueri Local Signing"' && echo "Kueri Local Signing" || echo -)}
codesign -s "$SIGN" --force $APP
echo "Built $(pwd)/$APP ($(du -sh $APP | cut -f1))"
