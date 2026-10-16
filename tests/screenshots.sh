#!/usr/bin/env bash
# Render the README's screenshots from a real Quickshell, against the fake account.
#
# Real pixels, not a mockup: the widget runs in an actual layer-shell bar with the
# actual Omarchy theme, so the images cannot drift from the code the way a hand-drawn
# diagram does. The account behind them is `tests/fake_ticktick.py`, never yours —
# a screenshot of a real TickTick account in a public repo is a data leak.
#
# Needs a live Wayland session, an Omarchy install, grim and ImageMagick, so CI cannot
# run it. Run it by hand when the UI changes.
#
# Usage: tests/screenshots.sh [outdir]     (default docs/img)
set -uo pipefail
export MAGICK_THREAD_LIMIT=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL_DIR="${OMARCHY_PATH:-/usr/share/omarchy}/shell"
OUT="${1:-$ROOT/docs/img}"

fail() { printf '\033[31mFAIL\033[0m %s\n' "$1"; exit 1; }
info() { printf '\033[2m  %s\033[0m\n' "$1"; }

for tool in quickshell grim magick python3; do
  command -v "$tool" >/dev/null || fail "$tool is not installed"
done
[ -d "$SHELL_DIR/Ui" ] || fail "no Omarchy shell at $SHELL_DIR (set OMARCHY_PATH)"
[ -n "${WAYLAND_DISPLAY:-}" ] || fail "no Wayland session — this needs a running compositor"

WORK="$(mktemp -d)"
trap '[ -n "${QS_PID:-}" ] && kill "$QS_PID" 2>/dev/null; [ -n "${FAKE_PID:-}" ] && kill "$FAKE_PID" 2>/dev/null; rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

ln -s "$SHELL_DIR/Ui" "$WORK/Ui"
ln -s "$SHELL_DIR/Commons" "$WORK/Commons"
ln -s "$ROOT/qml" "$WORK/plugin"
ln -s "$ROOT/bin" "$WORK/bin"
mkdir -p "$WORK/config/ticktick" "$WORK/state"

info "starting the fake TickTick API…"
python3 - "$WORK" "$ROOT" <<'PY' > "$WORK/fake.log" 2>&1 &
import json, pathlib, sys, time
sys.path.insert(0, sys.argv[2])
from tests.fake_ticktick import Server, TOKEN, _Handler
from datetime import datetime, timedelta

# The task fake predates habits/focus; this preview only needs their read routes.
original_get = _Handler.do_GET

def preview_get(self):
    path = self.path.split("?", 1)[0]
    payloads = {
        "/open/v1/focus": [],
        "/open/v1/habit": [
            {"id": "h-water", "name": "Drink water", "status": 0,
             "goal": 8, "step": 1, "unit": "glasses", "type": "Real"},
            {"id": "h-read", "name": "Read for twenty minutes", "status": 0,
             "goal": 1, "step": 1, "type": "Boolean"},
        ],
        "/open/v1/habit/sections": [],
        "/open/v1/habit/checkins": [],
        "/open/v1/countdown": [
            {"id": "date-trip", "name": "Trip to Kyoto", "date": 20261112},
            {"id": "date-birthday", "name": "Birthday", "date": 20261208},
        ],
    }
    if path in payloads:
        self._send(200, payloads[path])
    else:
        original_get(self)

_Handler.do_GET = preview_get

work = pathlib.Path(sys.argv[1])
s = Server(); s.__enter__()
f = s.fake

def stamp(days=0, hour=9):
    when = datetime.now().astimezone().replace(
        hour=hour, minute=0, second=0, microsecond=0) + timedelta(days=days)
    return when.strftime("%Y-%m-%dT%H:%M:%S.000%z")

# A believable week: two lists in a folder, one loose, and the Inbox.
f.projects = [
    {"id": "p-uni", "name": "University work", "color": "#F5A97F", "sortOrder": 1,
     "viewMode": "list", "kind": "TASK", "permission": "write", "groupId": "g-school"},
    {"id": "p-study", "name": "Study", "color": "#A6DA95", "sortOrder": 2,
     "viewMode": "list", "kind": "TASK", "permission": "write", "groupId": "g-school"},
    {"id": "p-personal", "name": "Personal", "color": "#8AADF4", "sortOrder": 3,
     "viewMode": "list", "kind": "TASK", "permission": "write"},
]
f.groups = [{"id": "g-school", "name": "University", "sortOrder": 1}]

f.add_task(title="Renew passport", projectId=f.inbox_id, priority=5, dueDate=stamp(-3, 9))
f.add_task(title="Call the bank", projectId=f.inbox_id, dueDate=stamp(0, 14))
f.add_task(title="Submit lab report", projectId="p-uni", priority=3, dueDate=stamp(0, 18),
           content="Include the calibration table and the error analysis.",
           reminders=["TRIGGER:-PT30M"],
           items=[{"id": "i1", "title": "plot the results", "status": 1},
                  {"id": "i2", "title": "write the discussion", "status": 0},
                  {"id": "i3", "title": "proofread", "status": 0}])
f.add_task(title="Meeting notes", projectId="p-uni", kind="NOTE", dueDate=stamp(0, 11),
           content="Supervisor wants the draft by Friday.")
f.add_task(title="Read chapter 4", projectId="p-study", dueDate=stamp(0, 21), tags=["errand"])
f.add_task(title="Groceries", projectId="p-personal", dueDate=stamp(0, 19))
f.add_task(title="Book flights", projectId="p-personal", isAllDay=True, dueDate=stamp(9, 0),
           repeatFlag="RRULE:FREQ=YEARLY;INTERVAL=1")
f.add_task(title="Pack for trip", projectId="p-personal", isAllDay=True, dueDate=stamp(1, 0))
f.add_task(title="Someday idea", projectId=f.inbox_id)

(work / "base.txt").write_text(s.base)
(work / "config/ticktick/credentials.json").write_text(
    json.dumps({"access_token": TOKEN, "inbox_id": f.inbox_id}))
print("ready", s.base, flush=True)
time.sleep(240)
PY
FAKE_PID=$!

for _ in $(seq 1 50); do [ -s "$WORK/base.txt" ] && break; sleep 0.2; done
[ -s "$WORK/base.txt" ] || { cat "$WORK/fake.log"; fail "fake API never came up"; }
info "fake API at $(cat "$WORK/base.txt")"

# A real bar strip, so KeyboardPanel anchors and positions the way it does in Omarchy.
cat > "$WORK/shell.qml" <<'QML'
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "plugin" as Plugin

ShellRoot {
  id: shell

  property var widget: null
  property string shot: ""

  // A slice of the bar around the widget: the button on its own is 27px wide and
  // says nothing. In context you can see it is a bar widget with a live count.
  function announceBar(name, item) {
    if (!item) return
    var p = item.mapToItem(null, 0, 0)
    var lead = 230
    console.log("SHOT " + name + " " + Math.round(Math.max(0, p.x - lead)) + " 0 "
                + Math.round(item.width + lead + 12) + " " + Math.round(barWindow.height))
  }

  // The popup is a full-screen layer surface with the card drawn inside it at
  // `cardOrigin`, so the card's rect is the thing worth cropping to.
  function announceCard(name) {
    script.stop()
    shell.widget.open()
    cardShot.name = name
    cardShot.attempts = 0
    cardShot.restart()
  }

  Timer {
    id: cardShot
    property string name: ""
    property int attempts: 0
    interval: 200
    onTriggered: shell.captureCard(name)
  }

  function captureCard(name) {
    var w = shell.widget
    var expectedView = name === "dates" ? "countdown" : name.indexOf("manage") === 0 ? "manage" : ""
    if (expectedView !== "" && w.service.view !== expectedView) {
      console.error("SHOT wrong view for " + name + ": " + w.service.view)
      Qt.quit()
      return
    }
    if (name === "detail") {
      for (var i = 0; i < w.rows.length; i++) {
        if (String(w.rows[i].title).indexOf("lab report") >= 0) w.expandedId = String(w.rows[i].id)
      }
    }
    if (name === "narrow") {
      w.expandedId = ""
      w.service.focusPaused = true
      w.service.focusPausedLeft = 725
      w.service.focusBlocksDone = 3
      w.service.focusState = ({ phase: "long_break" })
    }
    var p = shell.widget ? shell.widget.panel : null
    if (!p || !p.open || !p.backingWindowVisible) {
      cardShot.attempts++
      if (cardShot.attempts < 20) { shell.widget.open(); cardShot.restart() }
      else console.error("SHOT capture unavailable: " + name)
      return
    }
    function resetManagement(item) {
      if (item.objectName === "sidebar") item.enabled = false
      if (item.objectName === "managementPane" && item.parent && item.parent.parent)
        item.parent.parent.contentY = name === "manage-bottom" ? Math.max(0,item.parent.parent.contentHeight-item.parent.parent.height) : 0
      var children=item.children || []
      for (var j=0;j<children.length;j++) resetManagement(children[j])
    }
    resetManagement(p.contentItem[0])
    // Capture the QML surface itself while the scripted state is held steady.
    var card = p.contentItem[0].parent.parent
    var targetPath = Quickshell.env("DIDA_SCREENSHOT_DIR") + "/" + name + ".png"
    Qt.callLater(function () {
      card.grabToImage(function (result) {
        result.saveToFile(targetPath)
        script.restart()
      })
    })
    // The card is exactly contentWidth x contentHeight; `padding` is an inset
    // applied inside it, not an outset, so adding it drags in the wallpaper.
    console.log("SHOT " + name + " " + Math.round(p.cardOrigin.x) + " " + Math.round(p.cardOrigin.y)
                + " " + Math.round(p.contentWidth) + " " + Math.round(p.contentHeight))
  }

  PanelWindow {
    id: barWindow
    anchors { top: true; left: true; right: true }
    implicitHeight: Style.bar.sizeHorizontal
    color: Color.bar.background
    // Overlay, not Top: the machine's real Omarchy bar is also a Top surface at the
    // same edge, and it would otherwise be the one that ends up in the screenshot —
    // which is both the wrong widget and somebody's actual tray. -1 opts out of the
    // real bar's exclusive zone as well, which would otherwise push this one 24px
    // down the screen and leave the crop pointing straight at it.
    exclusiveZone: -1
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "shot-bar"

    QtObject {
      id: fakeBar
      property string position: "top"
      property string fontFamily: Style.font.family
      property color foreground: Color.foreground
      property color barForeground: Color.bar.text
      property color background: Color.bar.background
      property color urgent: Color.urgent
      property bool foregroundAnimationEnabled: false
      property bool vertical: false
      property int barSize: Style.bar.sizeHorizontal
      property bool transparent: false
      property var activePopout: null
      property var clickTargets: []
      property var shell: null
      property string omarchyPath: "/usr/share/omarchy"
      function run(cmd) {}
      function runProcess(p) {}
      function showTooltip(t, text) {}
      function hideTooltip(t) {}
      function requestPopout(o) {}
      function releasePopout(o) {}
      function registerClickTarget(t) {}
      function unregisterClickTarget(t) {}
      function targetBelongsToWindow(t, w) { return false }
      function switchPanelFrom(o, d) { return false }
      function moduleWidgets(id) { return [subject] }
    }

    Row {
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.md

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "󰃰 14:32   󰂄 87%"
        color: Qt.darker(Color.bar.text, 1.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Plugin.BarWidget {
        id: subject
        anchors.verticalCenter: parent.verticalCenter
        bar: fakeBar
        moduleName: "dddaniel1.dida365"
        settings: ({ refreshIntervalSec: 86400, badgeMode: "Today", hideWhenEmpty: "false",
                     showProjectChips: "true", confirmDelete: "true", includeUndated: "true",
                     sortBy: "List" })
        Component.onCompleted: shell.widget = subject
      }
    }
  }

  // One capture per step; the shell script grabs the screen between them.
  Timer {
    id: script
    property int step: Quickshell.env("DIDA_ACCEPTANCE_ONLY") === "1" ? 14 : 0
    interval: 4000
    repeat: true
    running: true
    onTriggered: {
      var w = shell.widget
      if (!w) return
      switch (step) {
      case 0:
        shell.announceBar("bar", w)
        console.log("SHOT ready badge=" + w.badgeText + " rows=" + w.rowCount)
        break
      case 1:
        w.open()
        break
      case 2:
        shell.announceCard("popup")
        console.log("SHOT step popup")
        break
      case 3:
        // The lab report: a priority, a note beneath it, a checklist and a due time.
        for (var i = 0; i < w.rows.length; i++) {
          if (String(w.rows[i].title).indexOf("lab report") >= 0) {
            w.setCursor(i)
            w.toggleExpanded(w.rows[i].id)
          }
        }
        break
      case 4:
        shell.announceCard("detail")
        console.log("SHOT step detail")
        break
      case 5:
        w.expandedId = ""
        // Scope to one real list, so the shot shows the two-pane shape: the sidebar
        // with the folders, and a task pane scoped to the chosen list.
        var picked = null
        for (var p = 0; p < w.service.projects.length; p++) {
          var proj = w.service.projects[p]
          if (String(proj.id).indexOf("inbox") !== 0 && Number(proj.count) > 0) { picked = proj; break }
        }
        if (picked) w.openProject(String(picked.id))
        else w.setView("all")
        break
      case 6:
        shell.announceCard("lists")
        console.log("SHOT step lists")
        break
      case 7:
        w.setView("all")
        w.filtering = true
        w.service.sort = "priority"
        w.service.focusPaused = true
        w.service.focusPausedLeft = 725
        w.service.focusBlocksDone = 3
        w.service.focusState = ({ phase: "long_break" })
        w.panel.contentWidth = Style.space(600)
        break
      case 8:
        shell.announceCard("narrow")
        console.log("SHOT step narrow")
        break
      case 9:
        w.filtering = false
        w.panel.contentWidth = Style.space(680)
        w.setView("habits")
        break
      case 10:
        shell.announceCard("habits")
        console.log("SHOT step habits")
        break
      case 11:
        w.setView("today")
        w.service.focusEndsAt = 0
        w.service.focusPaused = false
        w.service.focusPausedLeft = 0
        break
      case 12:
        // Drive the actual row button; no real account is used by this harness. The
        // button is revealed on hover or under the cursor, so put the cursor on row 0.
        if (w.rowCount > 0) w.setCursor(0)
        function findFocusButton(item) {
          if (item.objectName === "taskFocusButton" && item.visible && item.enabled) return item
          var children = item.children || []
          for (var c = 0; c < children.length; c++) {
            var found = findFocusButton(children[c])
            if (found) return found
          }
          return null
        }
        var focusButton = findFocusButton(w.panel.contentItem[0])
        if (focusButton) focusButton.clicked()
        break
      case 13:
        shell.announceCard("focus")
        console.log("SHOT step focus linked=" + Boolean(w.service.focusState.taskId))
        break
      case 14:
        w.openTools("New habit",["habit"],null)
        break
      case 15:
        shell.announceCard("manage")
        console.log("SHOT step manage")
        break
      case 16:
        w.panel.contentWidth = Style.space(600)
        break
      case 17:
        shell.announceCard("manage-narrow")
        console.log("SHOT step manage-narrow")
        break
      case 18:
        shell.announceCard("manage-bottom")
        console.log("SHOT step manage-bottom")
        break
      case 19:
        w.setView("countdown")
        break
      case 20:
        shell.announceCard("dates")
        console.log("SHOT step dates")
        break
      default:
        Qt.quit()
      }
      step += 1
    }
  }
}
QML

info "rendering…"
XDG_CONFIG_HOME="$WORK/config" \
XDG_STATE_HOME="$WORK/state" \
TICKTICK_API_BASE="$(cat "$WORK/base.txt")" \
DIDA_SCREENSHOT_DIR="$OUT" \
  quickshell -n -p "$WORK/shell.qml" > "$WORK/out.log" 2>&1 &
QS_PID=$!

capture() {  # capture <name> <ready-marker>
  local name="$1" marker="$2" rect="" tries=0
  while [ $tries -lt 60 ]; do
    if grep -q "SHOT $marker" "$WORK/out.log" 2>/dev/null; then break; fi
    sleep 0.25; tries=$((tries + 1))
  done
  grep -q "SHOT $marker" "$WORK/out.log" || { cat "$WORK/out.log"; fail "no $marker marker for $name"; }
  if [ "$name" != bar ]; then
    for _ in $(seq 1 20); do [ -s "$OUT/$name.png" ] && break; sleep 0.1; done
    [ -s "$OUT/$name.png" ] || fail "rendered card capture failed for $name"
    info "wrote $OUT/$name.png"
    return
fi
  sleep 0.5
  # The geometry line is named after the image, not after the readiness marker.
  rect="$(sed -e 's/\x1b\[[0-9;]*m//g' "$WORK/out.log" \
          | grep -oE "SHOT $name [0-9]+ [0-9]+ [0-9]+ [0-9]+" | tail -1)"
  if [ -n "$rect" ]; then
    read -r _ _ x y width height <<< "$rect"
    grim -g "$x,$y ${width}x${height}" "$WORK/$name-full.png" 2>/dev/null \
      || { info "grim failed for $name"; return; }
    # `SHOT <name> x y w h` — five fields after the marker word.
    set -- $rect
    # Logical coordinates; grim writes physical pixels, so scale the crop box.
    python3 - "$WORK/$name-full.png" "$OUT/$name.png" "$3" "$4" "$5" "$6" <<'PY'
import subprocess, sys
src, dst, x, y, w, h = sys.argv[1], sys.argv[2], *map(int, sys.argv[3:7])
out = subprocess.run(["magick", "identify", "-format", "%w %h", src],
                     capture_output=True, text=True).stdout.split()
pw, ph = int(out[0]), int(out[1])
# grim already captured the logical region, including its output's scale.
scale = pw / w
box = (0, 0, pw, ph)
# The card is drawn with rounded corners over whatever is behind it, so the four
# corners are wallpaper. Mask them to transparent — which also reads correctly on
# GitHub in both light and dark themes.
# The popup card has rounded corners; the bar strip is a square slice of a full-width
# surface, so rounding it would eat pixels that are really there.
radius = max(4, int(10 * scale)) if h > 60 else 0
subprocess.run([
    "magick", src, "-crop", f"{box[2]}x{box[3]}+{box[0]}+{box[1]}", "+repage",
    "(", "+clone", "-alpha", "extract", "-draw",
    f"fill black polygon 0,0 0,{radius} {radius},0 "
    f"fill white circle {radius},{radius} {radius},0", "(", "+clone", "-flip", ")",
    "-compose", "multiply", "-composite", "(", "+clone", "-flop", ")",
    "-compose", "multiply", "-composite", ")",
    # Written at the display's physical resolution rather than downscaled: the README
    # sizes them with `width`, so a 2x source is what keeps them crisp on a HiDPI screen.
    "-alpha", "off", "-compose", "copy_opacity", "-composite", dst,
], check=True)
print(f"  wrote {dst}")
PY
  else
    # Never fall back to the whole screen: these images go in a public README, and a
    # full-screen grab of a developer's desktop is both off-topic and a data leak.
    fail "no geometry for $name — refusing to write a full-screen capture"
  fi
}

if [ "${DIDA_ACCEPTANCE_ONLY:-0}" != 1 ]; then
capture bar "bar "
capture popup "step popup"
capture detail "step detail"
capture lists "step lists"
capture narrow "step narrow"
capture habits "step habits"
capture focus "step focus"
fi
capture manage "step manage"
capture manage-narrow "step manage-narrow"
capture manage-bottom "step manage-bottom"
capture dates "step dates"

wait $QS_PID 2>/dev/null
if grep -q 'SHOT wrong view\|SHOT capture unavailable' "$WORK/out.log"; then
  cat "$WORK/out.log"
  fail "capture did not match its requested view"
fi
sed -e 's/\x1b\[[0-9;]*m//g' "$WORK/out.log" | grep -E "SHOT|qml:" | sed 's/^/  /'

ls -1 "$OUT"/*.png 2>/dev/null | sed 's/^/  /' || fail "nothing was captured"
printf '\033[32mOK\033[0m   screenshots in %s\n' "$OUT"
