#!/bin/bash
# QuietHosts installer
#
#   ./install.sh               build with your own signing identity, verify, install to /Applications, launch
#   ./install.sh --build-only  build ./build/QuietHosts.app without installing
#   ./install.sh --uninstall   remove QuietHosts' hosts entries, its helper and the app
#
# Needs macOS 14+, Apple Silicon and Xcode 16+ with an Apple ID signed in
# (Xcode › Settings › Accounts). A free Apple ID works.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="QuietHosts"
BUNDLE_ID="com.quiethosts.QuietHosts"
HELPER_ID="com.quiethosts.helper"
BUILT_APP="build/$APP_NAME.app"
INSTALLED_APP="/Applications/$APP_NAME.app"
LOCAL_CONFIG="Config/Local.xcconfig"

if [[ -t 1 ]]; then B=$'\033[1m'; G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; X=$'\033[0m'; else B=; G=; R=; Y=; D=; X=; fi
step() { printf "\n${B}▸ %s${X}\n" "$1"; }
ok()   { printf "  ${G}✓${X} %s\n" "$1"; }
warn() { printf "  ${Y}!${X} %s\n" "$1"; }
die()  { printf "\n  ${R}✗ %s${X}\n" "$1" >&2; shift; for line in "$@"; do printf "    %s\n" "$line" >&2; done; exit 1; }
ask()  { local reply; printf "  %s [y/N] " "$1"; read -r reply </dev/tty || reply=""; [[ "$reply" =~ ^[Yy] ]]; }

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; }

MODE="install"; SKIP_TESTS=0
for arg in "$@"; do
  case "$arg" in
    --build-only) MODE="build" ;;
    --uninstall)  MODE="uninstall" ;;
    --skip-tests) SKIP_TESTS=1 ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "Unknown option: $arg" "Run ./install.sh --help" ;;
  esac
done

# Runs a command in the background with a spinner; output goes to a log.
spin() {
  local label="$1" log="$2"; shift 2
  "$@" >"$log" 2>&1 &
  local pid=$! frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
  while kill -0 "$pid" 2>/dev/null; do
    if [[ -t 1 ]]; then printf "\r  ${D}%s${X} %s" "${frames:i++%10:1}" "$label"; fi
    sleep 0.1
  done
  [[ -t 1 ]] && printf "\r\033[K"
  wait "$pid"
}

# ── Uninstall ────────────────────────────────────────────────────────────────
uninstall() {
  printf "${B}Uninstall QuietHosts${X}\n"
  local app="$INSTALLED_APP"
  [[ -d "$app" ]] || app="$HOME/Applications/$APP_NAME.app"
  [[ -d "$app" ]] || die "QuietHosts isn’t installed in /Applications."
  echo "  This removes QuietHosts’ entries from /etc/hosts, its background helper and the app."
  echo "  Your own hosts entries are kept."
  ask "Continue?" || { echo "  Cancelled."; exit 0; }

  step "Removing hosts entries and helper"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  sleep 1
  "$app/Contents/MacOS/$APP_NAME" --uninstall || die "Stopped before deleting anything." \
    "Fix the problem above and run ./install.sh --uninstall again."

  step "Removing the app"
  rm -rf "$app"
  ok "Deleted $app"
  if [[ -d "$HOME/Library/Application Support/QuietHosts" ]] && ask "Also delete your lists, exceptions and settings?"; then
    rm -rf "$HOME/Library/Application Support/QuietHosts"
    ok "Deleted ~/Library/Application Support/QuietHosts"
  fi
  if [[ -d "/Library/Application Support/QuietHosts" ]] && ask "Also delete hosts-file backups (needs your password)?"; then
    sudo rm -rf "/Library/Application Support/QuietHosts" && ok "Deleted /Library/Application Support/QuietHosts"
  fi
  printf "\n${G}${B}QuietHosts has been removed.${X}\n"
}

# ── Requirements ─────────────────────────────────────────────────────────────
check_requirements() {
  step "Checking your Mac"
  local macos; macos="$(sw_vers -productVersion)"
  [[ "${macos%%.*}" -ge 14 ]] || die "QuietHosts needs macOS 14 or later (you have $macos)."
  [[ "$(uname -m)" == "arm64" ]] || die "QuietHosts is built for Apple Silicon Macs."
  ok "macOS $macos on Apple Silicon"

  if ! xcodebuild -version >/dev/null 2>&1; then
    if [[ "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* && -d /Applications/Xcode.app ]]; then
      die "Xcode is installed but not selected." "Run: sudo xcode-select -s /Applications/Xcode.app"
    fi
    die "Xcode is required (it’s free)." "Install it from the App Store: https://apps.apple.com/app/xcode/id497799835" \
      "Open it once to finish setup, then run ./install.sh again."
  fi
  local xcode; xcode="$(xcodebuild -version | awk 'NR==1 {print $2}')"
  [[ "${xcode%%.*}" -ge 16 ]] || die "Xcode 16 or later is required (you have $xcode)." "Update Xcode from the App Store."
  ok "Xcode $xcode"
}

# ── Signing identity ─────────────────────────────────────────────────────────
# Prints "TEAMID|Team name" for every Apple Development certificate in the keychain.
list_teams() {
  security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | sort -u |
  while IFS= read -r cn; do
    local subject team org
    subject="$(security find-certificate -c "$cn" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || true)"
    team="$(printf '%s' "$subject" | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p')"
    org="$(printf '%s' "$subject" | sed -n 's/.*[,/] *O *= *\([^,/]*\).*/\1/p')"
    [[ -n "$team" ]] && printf '%s|%s\n' "$team" "${org:-$cn}"
  done | sort -u
}

choose_team() {
  step "Choosing a signing identity"
  local teams count team=""
  teams="$(list_teams)"
  count="$(printf '%s' "$teams" | grep -c . || true)"
  if [[ "$count" -eq 0 ]]; then
    die "No “Apple Development” signing certificate found." \
      "QuietHosts must be signed by you so its helper can trust it. It’s free:" \
      "  1. Open Xcode › Settings… › Accounts and add your Apple ID." \
      "  2. Select your team › Manage Certificates… › + › Apple Development." \
      "Then run ./install.sh again."
  fi

  if [[ -n "${QH_TEAM:-}" ]]; then
    team="$QH_TEAM"
  elif [[ -f "$LOCAL_CONFIG" ]]; then
    team="$(sed -n 's/^DEVELOPMENT_TEAM *= *\([A-Z0-9]\{10\}\).*/\1/p' "$LOCAL_CONFIG")"
  fi
  if [[ -n "$team" ]] && ! printf '%s\n' "$teams" | grep -q "^$team|"; then
    warn "Team $team has no Apple Development certificate in your keychain; choosing again."
    team=""
  fi

  if [[ -z "$team" && "$count" -eq 1 ]]; then
    team="${teams%%|*}"
  elif [[ -z "$team" ]]; then
    echo "  You have certificates for more than one team:"
    local i=1 line
    while IFS= read -r line; do printf "    %d) %s (%s)\n" "$i" "${line#*|}" "${line%%|*}"; i=$((i + 1)); done <<<"$teams"
    local choice; printf "  Which one should sign QuietHosts? [1] "; read -r choice </dev/tty || choice=1
    choice="${choice:-1}"
    [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "$count" ]] || die "Invalid choice."
    team="$(printf '%s\n' "$teams" | sed -n "${choice}p" | cut -d'|' -f1)"
  fi

  printf 'DEVELOPMENT_TEAM = %s\n' "$team" >"$LOCAL_CONFIG"
  TEAM="$team"
  ok "Signing as $(printf '%s\n' "$teams" | grep "^$team|" | cut -d'|' -f2) ($team)"
}

# ── Build ────────────────────────────────────────────────────────────────────
build() {
  mkdir -p build
  if [[ "$SKIP_TESTS" -eq 0 ]]; then
    step "Running tests"
    if spin "Testing the core engine…" build/tests.log bash -c "cd Packages/QuietHostsCore && swift test"; then
      ok "$(grep -E 'Test run with' build/tests.log | sed 's/^.*Test run/Test run/' | tail -1)"
    else
      grep -E "✘|error:" build/tests.log | head -20 >&2 || true
      die "Tests failed (full log: build/tests.log)."
    fi
  fi

  step "Building QuietHosts"
  if ! spin "Compiling (about a minute)…" build/xcodebuild.log \
      xcodebuild -project QuietHosts.xcodeproj -scheme QuietHosts -configuration Release \
      -derivedDataPath build/DerivedData clean build; then
    grep -E "error:" build/xcodebuild.log | sort -u | head -15 >&2 || true
    if grep -q "No signing certificate\|doesn't match any valid certificate\|No certificate" build/xcodebuild.log; then
      die "Xcode couldn’t find your signing certificate." "Check Xcode › Settings › Accounts, then run ./install.sh again."
    fi
    die "The build failed (full log: build/xcodebuild.log)."
  fi
  rm -rf "$BUILT_APP"
  ditto build/DerivedData/Build/Products/Release/$APP_NAME.app "$BUILT_APP"
  ok "Built $BUILT_APP"

  step "Verifying signatures"
  codesign --verify --deep --strict "$BUILT_APP" || die "The app’s signature is invalid."
  codesign -v -R="anchor apple generic and identifier \"$BUNDLE_ID\" and certificate leaf[subject.OU] = \"$TEAM\"" "$BUILT_APP" \
    || die "The app isn’t signed by team $TEAM."
  codesign -v -R="anchor apple generic and identifier \"$HELPER_ID\" and certificate leaf[subject.OU] = \"$TEAM\"" \
    "$BUILT_APP/Contents/MacOS/QuietHostsHelper" || die "The helper isn’t signed by team $TEAM."
  if codesign -d --entitlements - "$BUILT_APP" "$BUILT_APP/Contents/MacOS/QuietHostsHelper" 2>/dev/null | grep -q get-task-allow; then
    die "The build has debugging entitlements, so the helper would refuse it."
  fi
  ok "App and helper are signed by your team"
}

install_app() {
  step "Installing"
  [[ -w /Applications ]] || die "Can’t write to /Applications. Log in as an administrator and try again."
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  sleep 1
  rm -rf "$INSTALLED_APP"
  ditto "$BUILT_APP" "$INSTALLED_APP"
  ok "Installed $INSTALLED_APP"
  open "$INSTALLED_APP"
  ok "Launched. Look for the QuietHosts icon (a circle with a bar) in your menu bar"
  cat <<MSG

${G}${B}Almost done: one step left.${X}
  Click the ${B}QuietHosts icon${X} in the menu bar › ${B}Set Up…${X}, then switch QuietHosts on in
  System Settings › General › Login Items & Extensions. That’s it.

  To remove QuietHosts later:  ./install.sh --uninstall
MSG
}

case "$MODE" in
  uninstall) uninstall ;;
  build)     check_requirements; choose_team; build; printf "\n${G}✓ Built %s${X}\n" "$BUILT_APP" ;;
  install)   check_requirements; choose_team; build; install_app ;;
esac
