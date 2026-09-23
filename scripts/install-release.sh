#!/bin/bash
# Build locally with the project's signing settings; elevate only installation.
set -euo pipefail

usage() {
    printf '%s\n' \
        'Usage: scripts/install-release.sh [--help]' \
        'Build Release and install /Applications/Tmux Agent Watch.app.' \
        'Quit all copies first, including the app running under Xcode.' \
        'Replacement requires confirmation and retains a backup. No app is launched.'
}

if [[ $# -gt 0 ]]; then
    if [[ $# -eq 1 && ( "$1" == --help || "$1" == -h ) ]]; then
        usage
        exit 0
    fi
    usage >&2
    exit 2
fi

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

[[ $(/usr/bin/uname -s) == Darwin ]] || fail 'This script requires macOS.'
[[ $EUID -ne 0 ]] || fail 'Run without sudo. Installation requests sudo only if needed.'

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
app_name='Tmux Agent Watch.app'
destination="/Applications/$app_name"
bundle_id='com.sjdhome.TmuxAgentWatch'
derived_data="$HOME/Library/Developer/Xcode/DerivedData/TmuxAgentWatch-ReleaseInstaller"

# Honor an explicit selection; otherwise prefer the selected full Xcode, with
# the standard installation as a fallback when xcode-select points to CLT.
if [[ -z ${DEVELOPER_DIR:-} ]]; then
    DEVELOPER_DIR=$(/usr/bin/xcode-select -p 2>/dev/null || true)
    if [[ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
        DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer'
    fi
fi
if [[ -d "$DEVELOPER_DIR/Contents/Developer" ]]; then
    DEVELOPER_DIR="$DEVELOPER_DIR/Contents/Developer"
fi
export DEVELOPER_DIR
[[ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]] || fail 'Set DEVELOPER_DIR to a full Xcode installation.'

require_stopped() {
    local status=0
    /usr/bin/pgrep -f '/Tmux Agent Watch\.app/Contents/MacOS/Tmux Agent Watch($| )' >/dev/null || status=$?
    case $status in
        0) fail 'Quit Tmux Agent Watch (and stop its Xcode run), then try again.' ;;
        1) ;;
        *) fail 'Could not check whether Tmux Agent Watch is running.' ;;
    esac
}

require_stopped
printf 'Building Release using %s\n' "$DEVELOPER_DIR"
/usr/bin/xcrun xcodebuild \
    -project "$root/TmuxAgentWatch.xcodeproj" -scheme TmuxAgentWatch \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data" build

built_app="$derived_data/Build/Products/Release/$app_name"
[[ -d "$built_app" ]] || fail "Build product missing: $built_app"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$built_app/Contents/Info.plist") == "$bundle_id" ]] \
    || fail 'Unexpected build product identifier.'
/usr/bin/codesign --verify --deep --strict "$built_app"

# Recheck after building: the user may have started an app in the meantime.
require_stopped
[[ ! -L "$destination" ]] || fail "Refusing to replace a symbolic link: $destination"
replace_existing=0
if [[ -e "$destination" ]]; then
    [[ -d "$destination" ]] || fail "Not an application directory: $destination"
    [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist") == "$bundle_id" ]] \
        || fail 'The installed bundle has an unexpected identifier; leaving it unchanged.'
    printf 'Replace %s and retain a backup? [y/N] ' "$destination"
    answer=''
    IFS= read -r answer || true
    case $answer in
        y|Y|yes|YES) replace_existing=1 ;;
        *) printf 'Installation cancelled. Release build remains at %s\n' "$built_app"; exit 0 ;;
    esac
fi

needs_sudo=0
if [[ ! -w /Applications ]]; then
    needs_sudo=1
    printf 'Administrator permission is required for installation only.\n'
    /usr/bin/sudo -v
fi
as_installer() {
    if [[ $needs_sudo == 1 ]]; then /usr/bin/sudo "$@"; else "$@"; fi
}

staging=''
cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$staging" ]]; then
        if as_installer /bin/test -e "$staging/previous.app"; then
            if ! as_installer /bin/test -e "$destination"; then
                if ! as_installer /bin/mv "$staging/previous.app" "$destination"; then
                    printf 'Restore failed; previous app is retained at %s/previous.app\n' "$staging" >&2
                    return 1
                fi
                printf 'Restored the previous installation.\n' >&2
            else
                printf 'Previous installation retained at %s/previous.app\n' "$staging"
                return "$status"
            fi
        fi
        as_installer /bin/rm -rf -- "$staging" || printf 'Could not remove staging directory: %s\n' "$staging" >&2
    fi
    return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# Stage on the destination filesystem before moving the existing app. A failed
# copy/verification leaves the installed app untouched; failed placement triggers rollback.
staging=$(as_installer /usr/bin/mktemp -d /Applications/.TmuxAgentWatch-install.XXXXXX)
as_installer /usr/bin/ditto "$built_app" "$staging/$app_name"
as_installer /usr/bin/codesign --verify --deep --strict "$staging/$app_name"
require_stopped
if [[ -e "$destination" || -L "$destination" ]]; then
    [[ $replace_existing == 1 && ! -L "$destination" ]] \
        || fail 'Installation destination changed; rerun to confirm replacement.'
    [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist") == "$bundle_id" ]] \
        || fail 'Installation destination changed; leaving it unchanged.'
    as_installer /bin/mv "$destination" "$staging/previous.app"
fi
as_installer /bin/mv "$staging/$app_name" "$destination"
printf 'Installed Release: %s\n' "$destination"
printf 'Launch it when ready: open "%s"\n' "$destination"
