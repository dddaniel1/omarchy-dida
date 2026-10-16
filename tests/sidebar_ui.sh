#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-/tmp/opencode/dida-sidebar-acceptance}"
mkdir -p "$OUT/captures" "$OUT/config"
ln -sfn /usr/share/omarchy/shell/Ui "$OUT/Ui"
ln -sfn /usr/share/omarchy/shell/Commons "$OUT/Commons"
ln -sfn "$ROOT/qml" "$OUT/plugin"
cp "$ROOT/tests/qml/tst_sidebar.qml" "$OUT/tst_sidebar.qml"
cat > "$OUT/shell.qml" <<'QML'
import QtQuick
import Quickshell
ShellRoot {
  FloatingWindow {
    visible: true
    implicitWidth: 260
    implicitHeight: 620
    Loader { anchors.fill:parent; source:"tst_sidebar.qml" }
  }
  Timer { interval:15000; running:true; onTriggered:{ console.error("ACCEPTANCE FAIL timeout"); Qt.quit() } }
}
QML
env -u WAYLAND_DISPLAY XDG_CONFIG_HOME="$OUT/config" QT_QPA_PLATFORM=offscreen timeout 20 quickshell -p "$OUT/shell.qml" > "$OUT/run.log" 2>&1
cat "$OUT/run.log"
grep -q 'ACCEPTANCE COMPLETE' "$OUT/run.log"
! grep -q 'ACCEPTANCE FAIL' "$OUT/run.log"
if grep -E 'ERROR|WARN' "$OUT/run.log" | grep -v 'does not support setting window masks'; then
  exit 1
fi
