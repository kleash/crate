#!/bin/bash
# Removes Crate from ~/Applications and unregisters its Finder integration. No administrator rights needed.
#   ./uninstall.sh            uninstall
#   ./uninstall.sh --dry-run  print the commands instead of running them
set -euo pipefail

dry=false
if [ "${1:-}" = "--dry-run" ]; then dry=true; fi
run() { if $dry; then echo "+ $*"; else "$@"; fi; }

app=$HOME/Applications/Crate.app
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if pgrep -xq Crate; then run pkill -x Crate; fi
if [ -d "$app" ]; then
    run pluginkit -r "$app/Contents/PlugIns/CrateQuickLook.appex" || true
    run "$lsregister" -u "$app" || true
    run rm -rf "$app"
else
    echo "Crate is not installed in ~/Applications."
fi
run /System/Library/CoreServices/pbs -update
run qlmanage -r

cat <<'EOF'
Crate is uninstalled.
macOS keeps the Quick Look extension's sandbox folder at ~/Library/Containers/com.sa.crate.quicklook.
Delete it in Finder if you like (Go ▸ Go to Folder…); Terminal is usually not allowed to.
EOF
