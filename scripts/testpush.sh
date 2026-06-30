#!/usr/bin/env bash
# Dev loop for the iOS push-notification pipeline (simulator).
#
#   scripts/testpush.sh install   # build + install to a booted sim, launch
#   scripts/testpush.sh logs      # stream the app's push logs from the sim
#   scripts/testpush.sh fire      # simulate a silent push → drain + notify
#   scripts/testpush.sh cold      # terminate app first, then fire — proves wake
#
# The fire/cold paths need NO Firebase and NO real APNs. The iOS Simulator does NOT
# deliver background/silent (content-available) pushes, so `fire` relaunches the app
# with OBSCURA_TEST_PUSH=1, which runs the IDENTICAL
# AppDelegate -> PushCoordinator.handleSilentPush -> processPendingMessages -> PushNotifier
# path that a real FCM silent push triggers on a device. (The same as Android's debug
# TestPushReceiver.) For true end-to-end silent-push delivery you need a real device +
# the APNs key uploaded to Firebase (see App/README).
#
# `alert` fires a visible push via `simctl push` — useful to confirm APNs plumbing.
set -euo pipefail

APP_ID="com.obscuraapp.ios"
SCHEME="obscura-base"
SIM_NAME="${SIM_NAME:-iPhone 17}"
PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)/App/obscura-base"
DD="${DD:-/tmp/obscura-dd}"
PAYLOAD="$(dirname "$0")/silent-push.apns"

booted_udid() {
  xcrun simctl list devices booted | grep -Eo '[0-9A-F-]{36}' | head -1
}

ensure_booted() {
  local udid
  udid="$(booted_udid || true)"
  if [ -z "${udid:-}" ]; then
    echo "Booting $SIM_NAME…"
    xcrun simctl boot "$SIM_NAME"
    open -a Simulator
    udid="$(xcrun simctl list devices "$SIM_NAME" | grep -Eo '[0-9A-F-]{36}' | head -1)"
  fi
  echo "$udid"
}

write_payload() {
  cat > "$PAYLOAD" <<'JSON'
{
  "aps": { "content-available": 1 }
}
JSON
}

case "${1:-}" in
  install)
    UDID="$(ensure_booted)"
    echo "Building for $UDID…"
    xcrun xcodebuild -project "$PROJ_DIR/obscura-base.xcodeproj" -scheme "$SCHEME" \
      -sdk iphonesimulator -destination "id=$UDID" -derivedDataPath "$DD" build
    APP="$(/usr/bin/find "$DD/Build/Products" -name "$SCHEME.app" -maxdepth 3 | head -1)"
    echo "Installing $APP"
    xcrun simctl install "$UDID" "$APP"
    xcrun simctl launch "$UDID" "$APP_ID"
    echo "Installed + launched. Log in, add a friend, then: scripts/testpush.sh fire"
    ;;
  logs)
    UDID="$(ensure_booted)"
    xcrun simctl spawn "$UDID" log stream --level debug \
      --predicate 'eventMessage CONTAINS "[ObscuraApp]" OR eventMessage CONTAINS "[push]"'
    ;;
  fire)
    UDID="$(ensure_booted)"
    echo "Simulating silent push (relaunch with OBSCURA_TEST_PUSH=1)…"
    SIMCTL_CHILD_OBSCURA_TEST_PUSH=1 \
      xcrun simctl launch --terminate-running-process "$UDID" "$APP_ID"
    echo "Watch: scripts/testpush.sh logs"
    ;;
  alert)
    UDID="$(ensure_booted)"
    write_payload
    xcrun simctl push "$UDID" "$APP_ID" "$PAYLOAD"
    echo "Fired visible push to $APP_ID (APNs plumbing check)"
    ;;
  cold)
    UDID="$(ensure_booted)"
    echo "Terminating $APP_ID, then cold-launching with OBSCURA_TEST_PUSH=1…"
    xcrun simctl terminate "$UDID" "$APP_ID" || true
    sleep 1
    SIMCTL_CHILD_OBSCURA_TEST_PUSH=1 \
      xcrun simctl launch "$UDID" "$APP_ID"
    echo "Cold-start wake fired"
    ;;
  *)
    echo "usage: scripts/testpush.sh {install|logs|fire|alert|cold}"
    exit 1
    ;;
esac
