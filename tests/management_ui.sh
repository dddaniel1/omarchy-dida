#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-/tmp/opencode/dida-management-acceptance}"
mkdir -p "$OUT/captures" "$OUT/qs"
ln -sfn /usr/share/omarchy/shell/Ui "$OUT/qs/Ui"
ln -sfn /usr/share/omarchy/shell/Commons "$OUT/qs/Commons"
ln -sfn "$ROOT/qml" "$OUT/plugin"
cp "$ROOT/tests/qml/tst_management.qml" "$OUT/tst_management.qml"
cat > "$OUT/shell.qml" <<'QML'
import QtQuick
import Quickshell
ShellRoot {
  FloatingWindow {
    visible: true
    implicitWidth: 680
    implicitHeight: 420
    Loader { anchors.fill:parent; source:"tst_management.qml" }
  }
  Timer { interval:30000; running:true; onTriggered:{ console.error("ACCEPTANCE FAIL timeout"); Qt.quit() } }
}
QML
ln -sfn /usr/share/omarchy/shell/Ui "$OUT/Ui"
ln -sfn /usr/share/omarchy/shell/Commons "$OUT/Commons"
env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen timeout 40 quickshell -p "$OUT/shell.qml" > "$OUT/run.log" 2>&1
cat "$OUT/run.log"
grep -q 'ACCEPTANCE COMPLETE' "$OUT/run.log"
! grep -q 'ACCEPTANCE FAIL' "$OUT/run.log"
if grep -E 'ERROR|WARN' "$OUT/run.log" | grep -v 'does not support setting window masks'; then
  exit 1
fi
