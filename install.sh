#!/bin/bash
# Installs Crate into ~/Applications and registers its Finder integration (Open With, Services, Quick Look).
# No administrator rights needed.
#   ./install.sh                     installs build/Crate.app (from ./build.sh), else a Crate.app next to this script
#   ./install.sh path/to/Crate.app   installs that app
#   ./install.sh --dry-run [app]     prints the commands instead of running them
set -euo pipefail

usage() { echo "usage: $0 [--dry-run] [path/to/Crate.app]" >&2; exit 2; }
dry=false
src=
for arg in "$@"; do
    case $arg in
        --dry-run) dry=true ;;
        -*) usage ;;
        *) if [ -n "$src" ]; then usage; fi; src=$arg ;;
    esac
done
# A relative path means relative to where the script was started, not to the script's folder.
case $src in ""|/*) ;; *) src=$PWD/$src ;; esac
cd "$(dirname "$0")"
run() { if $dry; then echo "+ $*"; else "$@"; fi; }

if [ -z "$src" ]; then
    if [ -d build/Crate.app ]; then src=build/Crate.app; else src=Crate.app; fi
fi
dest=$HOME/Applications/Crate.app
appex=$dest/Contents/PlugIns/CrateQuickLook.appex
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

version=$(sw_vers -productVersion)
IFS=. read -r major minor _ <<< "$version"
if (( major < 13 || (major == 13 && ${minor:-0} < 1) )); then
    echo "Crate needs macOS 13.1 or later; this Mac has macOS $version." >&2
    exit 1
fi
if [ ! -x "$src/Contents/MacOS/Crate" ]; then
    echo "No Crate.app at $src. Build it first with ./build.sh, or pass the path to a prebuilt Crate.app." >&2
    exit 1
fi
src=$(cd "$src" && pwd)

# Quit a running Crate so the new copy is the one that runs.
if pgrep -xq Crate; then
    run pkill -x Crate
    $dry || for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq Crate || break; sleep 0.5; done
fi
run mkdir -p "$HOME/Applications"
if [ "$src" != "$dest" ]; then
    run rm -rf "$dest"
    run ditto "$src" "$dest"
fi
# A downloaded, ad-hoc signed app that is still quarantined is reported as "damaged" on macOS 15 and later.
run xattr -dr com.apple.quarantine "$dest"
run "$lsregister" -f -R "$dest"
# Forget the copy we installed from, so Finder's Open With and Services use the installed one. lsregister fails
# (-10814) when that copy was never registered, which is fine.
if [ "$src" != "$dest" ]; then run "$lsregister" -u "$src" 2>/dev/null || true; fi
# Quick Look extension: register it and make sure it is enabled.
run pluginkit -a "$appex"
run pluginkit -e use -i com.sa.crate.quicklook
run /System/Library/CoreServices/pbs -update
run qlmanage -r
run qlmanage -r cache

cat <<'EOF'

Crate is installed in ~/Applications.

  Open an archive     Right-click it in Finder ▸ Open With ▸ Crate (Get Info ▸ "Open with" ▸ Change All
                      makes Crate the default), or drop it on Crate's Dock icon or Welcome window.
  Make an archive     Drop files or folders on Crate, or choose File ▸ New Archive… in Crate.
  Finder services     Select files or folders, right-click ▸ Services (some macOS versions: Quick Actions)
                      ▸ Compress with Crate. On archives: Open with Crate, Extract Here with Crate.
                      If they are missing, turn them on in System Settings ▸ Keyboard ▸ Keyboard Shortcuts…
                      ▸ Services ▸ Files and Folders.
  Quick Look          Select an archive in Finder and press Space to see the files inside.

EOF
run open "$dest"
