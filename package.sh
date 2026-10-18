#!/bin/sh
# Builds a self-contained Kueri-<version>.dmg for people who don't build from source.
# The Homebrew libraries (libpq, OpenSSL, Kerberos) and the PostgreSQL client tools
# (pg_dump, pg_restore, psql) are copied into the app, so nothing else needs installing.
set -e
cd "$(dirname "$0")"
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Kueri.app/Contents/Info.plist)
APP=Kueri.app
PQ=$(brew --prefix libpq 2>/dev/null || echo /usr/local/opt/libpq)

mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/Helpers"
for t in pg_dump pg_restore psql; do cp "$PQ/bin/$t" "$APP/Contents/Helpers/"; done
chmod u+w "$APP/Contents/Helpers/"*

# Copy every non-system library the app and helpers load (recursively) into Frameworks and
# point all references at @rpath, so the bundle never looks in /usr/local or /opt/homebrew.
python3 - "$APP" <<'PY'
import os, shutil, subprocess, sys
app = sys.argv[1]
fw = os.path.join(app, "Contents/Frameworks")
bins = [os.path.join(app, "Contents/MacOS/Kueri")] + [os.path.join(app, "Contents/Helpers", f) for f in os.listdir(os.path.join(app, "Contents/Helpers"))]

def deps(path):
    out = subprocess.run(["otool", "-L", path], capture_output=True, text=True, check=True).stdout.splitlines()[1:]
    return [l.strip().split(" (")[0] for l in out if l.strip().startswith(("/usr/local/", "/opt/homebrew/"))]

todo, copied = list(bins), {}
while todo:
    f = todo.pop()
    for d in deps(f):
        name = os.path.basename(d)
        if name not in copied:
            dst = os.path.join(fw, name)
            shutil.copy(os.path.realpath(d), dst)
            os.chmod(dst, 0o755)
            copied[name] = dst
            todo.append(dst)

def tool(*a): subprocess.run(["install_name_tool", *a], check=True, capture_output=True)
for f in bins + list(copied.values()):
    for d in deps(f):
        tool("-change", d, "@rpath/" + os.path.basename(d), f)
    if f in copied.values():
        tool("-id", "@rpath/" + os.path.basename(f), f)
        tool("-add_rpath", "@loader_path", f)
    else:
        tool("-add_rpath", "@executable_path/../Frameworks", f)
left = [f for f in bins + list(copied.values()) if deps(f)]
if left: sys.exit("still linked to Homebrew: " + ", ".join(left))
print("bundled:", ", ".join(sorted(copied)))
PY

# Inner code first, then the app (ad-hoc signature; see README for opening a downloaded copy).
codesign -s - --force "$APP/Contents/Frameworks/"*.dylib "$APP/Contents/Helpers/"*
codesign -s - --force "$APP"
"$APP/Contents/Helpers/psql" --version >/dev/null

STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "Kueri-$VERSION.dmg"
hdiutil create -quiet -volname "Kueri $VERSION" -srcfolder "$STAGE" -format UDZO "Kueri-$VERSION.dmg"
rm -rf "$STAGE"
echo "Packaged $(pwd)/Kueri-$VERSION.dmg ($(du -h "Kueri-$VERSION.dmg" | cut -f1))"
