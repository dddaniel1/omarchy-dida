#!/usr/bin/env bash
# Load the widget in a real Quickshell and fail on any QML error or warning.
#
# This is the only check that exercises the QML at runtime. `qmllint` parses and
# resolves types, but it will not tell you that `function escape()` is an illegal
# method name, or that a wrapping Text bound to `height: implicitHeight` spins in a
# binding loop. Both of those shipped past qmllint and were caught here.
#
# It needs a live Wayland session and an Omarchy install, so CI cannot run it —
# run it on the box before releasing. Everything it touches is a temp directory;
# the running bar and the real credential store are never involved.
#
# Usage: tests/qml_smoke.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL_DIR="${OMARCHY_PATH:-/usr/share/omarchy}/shell"

fail() { printf '\033[31mFAIL\033[0m %s\n' "$1"; exit 1; }
info() { printf '\033[2m  %s\033[0m\n' "$1"; }

command -v quickshell >/dev/null || fail "quickshell is not installed"
[ -d "$SHELL_DIR/Ui" ] || fail "no Omarchy shell at $SHELL_DIR (set OMARCHY_PATH)"
[ -n "${WAYLAND_DISPLAY:-}" ] || fail "no Wayland session — this test needs a running compositor"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; [ -n "${FAKE_PID:-}" ] && kill "$FAKE_PID" 2>/dev/null' EXIT

# A shell root the engine can resolve `qs.Ui` / `qs.Commons` from, with the plugin
# mounted where its own `../bin/ticktick` lookup expects to find the helper.
ln -s "$SHELL_DIR/Ui" "$WORK/Ui"
ln -s "$SHELL_DIR/Commons" "$WORK/Commons"
ln -s "$ROOT/qml" "$WORK/plugin"
ln -s "$ROOT/bin" "$WORK/bin"

mkdir -p "$WORK/config/ticktick" "$WORK/state"

info "starting the fake TickTick API…"
python3 - "$WORK" "$ROOT" <<'PY' > "$WORK/fake.log" 2>&1 &
import json, pathlib, sys, time
sys.path.insert(0, sys.argv[2])  # the repo root, so `tests.fake_ticktick` imports
from tests.fake_ticktick import Server, TOKEN, _Handler
from datetime import datetime, timedelta

original_get = _Handler.do_GET

def focus_get(self):
    if self.path.split("?", 1)[0] == "/open/v1/focus":
        self._send(200, [])
    else:
        original_get(self)

_Handler.do_GET = focus_get

work = pathlib.Path(sys.argv[1])
s = Server(); s.__enter__()
f = s.fake

# Relative to the clock, never absolute: a fixture pinned to a literal date passes
# on the day it was written and silently changes bucket every day after.
def stamp(days=0, hour=9):
    when = datetime.now().astimezone().replace(
        hour=hour, minute=0, second=0, microsecond=0) + timedelta(days=days)
    return when.strftime("%Y-%m-%dT%H:%M:%S.000%z")

f.add_task(title="Renew domain", projectId="p-work", isAllDay=True,
           dueDate=stamp(-120, 0), priority=5,
           repeatFlag="RRULE:FREQ=YEARLY;INTERVAL=1")           # overdue
f.add_task(title="Submit report", projectId="p-work", priority=3,
           dueDate=stamp(0, 23), content="Include Q3 numbers.",
           reminders=["TRIGGER:-PT30M"],                        # today
           items=[{"id": "s1", "title": "gather figures", "status": 1},
                  {"id": "s2", "title": "write summary", "status": 0}])
f.add_task(title="Call the bank", projectId="p-home",
           dueDate=stamp(0, 23))                                # today
f.add_task(title="Pack for trip", projectId="p-home", isAllDay=True, tags=["errand"],
           dueDate=stamp(1, 0),                                 # tomorrow
           items=[{"id": "i1", "title": "passport", "status": 1},
                  {"id": "i2", "title": "charger", "status": 0}])
f.add_task(title="Someday idea", projectId=f.inbox_id)          # undated
# Due today, but a note: it renders and it must not reach the badge.
f.add_task(title="Meeting notes", projectId="p-work", kind="NOTE",
           content="What was said.", dueDate=stamp(0, 20))
(work / "base.txt").write_text(s.base)
(work / "config/ticktick/credentials.json").write_text(
    json.dumps({"access_token": TOKEN, "inbox_id": f.inbox_id}))
print("ready", s.base, flush=True)
time.sleep(180)
PY
FAKE_PID=$!

for _ in $(seq 1 50); do [ -s "$WORK/base.txt" ] && break; sleep 0.2; done
[ -s "$WORK/base.txt" ] || { cat "$WORK/fake.log"; fail "fake API never came up"; }
info "fake API at $(cat "$WORK/base.txt")"

cat > "$WORK/shell.qml" <<'QML'
import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "plugin" as Plugin

ShellRoot {
  // Everything Bar.qml exposes that a bar widget is documented to reach for.
  QtObject {
    id: fakeBar
    property string position: "top"
    property string fontFamily: Style.font.family
    property color foreground: Color.foreground
    property color barForeground: Color.foreground
    property color background: Color.background
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
    function moduleWidgets(id) { return [] }
  }

  Plugin.BarWidget {
    id: subject
    bar: fakeBar
    moduleName: "dddaniel1.dida365"
    // Strings on purpose: `omarchy bar plugin set` writes them that way unless the
    // caller remembers `--json`, and reading them as booleans is a real past bug.
    settings: ({ refreshIntervalSec: 86400, badgeMode: "Today", hideWhenEmpty: "false",
                 showProjectChips: "true", confirmDelete: "true", includeUndated: "true",
                 sortBy: "List" })
  }

  Timer {
    interval: 4000
    running: true
    onTriggered: {
      console.log("SMOKE geometry=" + subject.implicitWidth + "x" + subject.implicitHeight
                  + " visible=" + subject.visible + " badge=" + subject.badgeText)
      console.log("SMOKE settings hideWhenEmpty=" + subject.hideWhenEmpty
                  + " showProjectChips=" + subject.showProjectChips
                  + " confirmDelete=" + subject.confirmDelete)
      console.log("SMOKE rows=" + subject.rowCount)
      console.log("SMOKE sections=" + subject.sectionFor(0) + "|" + subject.sectionFor(1)
                  + "|" + subject.sectionFor(2))
      subject.open()
      Qt.callLater(function () {
        // Find the sidebar and verify it tracks the shortcut-driven view, and that
        // selecting a nav entry drives the service. (The old view-picker probe.)
        function findSidebar(item) {
          if (item.objectName === "sidebar") return item
          var children = item.children || []
          for (var c = 0; c < children.length; c++) {
            var found = findSidebar(children[c])
            if (found) return found
          }
          return null
        }
        var nav = findSidebar(subject.panel.contentItem[0])
        if (nav) {
          subject.setView("tomorrow")
          console.log("SMOKE navTracks=" + (nav.currentView === "tomorrow"))
          var orderMatches = true
          for (var mask = 0; mask < 4; mask++) {
            nav.showHabits = Boolean(mask & 1)
            nav.showStats = Boolean(mask & 2)
            var displayed = []
            for (var ni = 0; ni < nav.navItems.length; ni++) {
              var row=nav.navItems[ni]
              if (row.kind === "view" && row.shortcut) {
                displayed.push(row.value)
                orderMatches = orderMatches && subject.views[Number(row.shortcut)-1] === row.value
              }
            }
            orderMatches = orderMatches && displayed.slice(0,4).join(",") === "today,inbox,next,all"
          }
          nav.showHabits = Qt.binding(function() { return subject.service.showHabits })
          nav.showStats = Qt.binding(function() { return subject.service.showStats })
          console.log("SMOKE shortcutOrder=" + orderMatches)
          nav.viewSelected("inbox")
          console.log("SMOKE navSelect=" + subject.service.view)
          // The keyboard cursor walks the flat model and never lands on a header.
          subject.focusSidebar()
          nav.ensureCursor()
          console.log("SMOKE sidebarCursor=" + subject.focusPane + ":"
                      + (nav.selectable(nav.cursorIndex) ? "ok" : "bad"))
          // Moving previews: the highlight moves and the task pane follows it.
          var previewFrom = subject.service.view
          subject.sidebarStep(1)
          console.log("SMOKE preview=" + (subject.service.view !== previewFrom))
          nav.moveCursor(1); nav.moveCursor(1); nav.moveCursor(1)
          console.log("SMOKE sidebarStep=" + (nav.selectable(nav.cursorIndex) ? "ok" : "bad"))
          subject.focusList()
        }
        // Every view, in the order the number keys walk them.
        for (var i = 0; i < subject.views.length; i++) subject.setView(subject.views[i])
        subject.setView("habits")
        console.log("SMOKE habitTaskView=" + subject.service.readArgs()[2])
        subject.cycleView(1); subject.cycleView(-1)
        subject.moveCursor(1); subject.moveCursor(-1)
        subject.openSearch(); subject.closeSearch(true)
        subject.openAdd(); subject.closeAdd()
        subject.toggleFilters(); subject.toggleFilters()
        // The four sort modes, back round to where it started.
        for (var s = 0; s < 4; s++) subject.service.cycleSort()
        subject.service.cyclePriorityFilter(); subject.service.setPriorityFilter(-1)
        subject.service.sync()
        subject.setView("today")
        // Expanding a task that has a checklist must actually grow the panel. Rows
        // reach a delegate as a QVariant, and a nested array arrives array-LIKE but
        // fails Array.isArray — which silently blanked every checklist and reminder.
        var withItems = null
        for (var w = 0; w < subject.rows.length; w++) {
          if (subject.rows[w].itemsTotal > 0) withItems = subject.rows[w]
        }
        detailProbe.shut = subject.panel.contentHeight
        detailProbe.subjectRow = withItems
        if (withItems) subject.toggleExpanded(withItems.id)
        detailProbe.running = true   // the pane is built on the next tick, not this one

        if (subject.rowCount > 0) {
          subject.setCursor(0)
          subject.toggleExpanded(subject.rows[0].id)
          subject.cyclePriority(subject.rows[0])
          subject.requestDelete(subject.rows[0])
          console.log("SMOKE confirmOpen=" + subject.confirmOpen)
          subject.cancelDelete()
        }
        // A new task must be on screen on the keystroke, not two process launches
        // and a round trip later.
        var before = subject.rowCount
        subject.service.add("smoke draft task")
        console.log("SMOKE add before=" + before + " after=" + subject.rowCount)
        // …and it must join the group it belongs to. Appended to the end it would
        // open a second heading for a list already on screen further up.
        var seen = {}, dupes = 0
        for (var r = 0; r < subject.rowCount; r++) {
          var head = subject.sectionFor(r)
          if (head === "") continue
          if (seen[head]) dupes += 1
          seen[head] = true
        }
        console.log("SMOKE dupsections=" + dupes)
        // A note has no checkbox: completing one must be refused, not queued.
        var note = null
        for (var n = 0; n < subject.rows.length; n++) {
          if (subject.rows[n].isNote) note = subject.rows[n]
        }
        console.log("SMOKE note=" + (note ? note.title : "none"))
        if (note) subject.completeAt(note)
        // Restoration waits for server verification; do not optimistically drop it.
        var kept = subject.rowCount
        subject.service.complete({ id: "smoke-done", projectId: "p-work", title: "already finished", status: 2 })
        console.log("SMOKE donekept=" + (subject.rowCount === kept)
                    + " restoring=" + (subject.service.actionStatus === "Restoring already finished" || subject.service.actionStatus === "正在恢复：already finished"))
        subject.dismiss()
        console.log("SMOKE done rows=" + subject.rowCount + " sort=" + subject.service.sort)
        // The Stats view is a dashboard, not a list. Hold on it for a beat so its
        // Repeaters really lay out — an anchor or binding warning only a polish pass
        // would raise must not slip past the view-loop, which never gives it a frame.
        subject.setView("stats")
        statsProbe.running = true
      })
    }
  }
  Timer {
    id: statsProbe
    interval: 700
    onTriggered: {
      var s = subject.service.stats || {}
      var dist = s.distribution || {}
      console.log("SMOKE stats view=" + subject.service.view
                  + " days=" + s.days + " trend=" + ((s.trend || []).length)
                  + " lists=" + ((dist.byList || []).length))
      function findItem(item, name) {
        if (item.objectName === name) return item
        var children = item.children || []
        for (var i = 0; i < children.length; i++) {
          var found = findItem(children[i], name)
          if (found) return found
        }
        return null
      }
      var pane = findItem(subject.panel.contentItem[0], "statsPane")
      var settingsReturn=subject.service.view
      subject.showSettings()
      var settingsAccount=findItem(subject.panel.contentItem[0],"settingsAccount")
      var settingsLists=findItem(subject.panel.contentItem[0],"settingsLists")
      var settingsOk=subject.settingsHome && settingsAccount && settingsLists
      settingsAccount.clicked()
      settingsOk=settingsOk && subject.settingsSection && subject.contextTitle==="Account settings"
      subject.closeTools()
      settingsOk=settingsOk && subject.settingsHome
      settingsLists.clicked()
      settingsOk=settingsOk && subject.settingsSection && subject.contextResources.indexOf("folder")>=0
      subject.closeTools(); subject.closeTools()
      console.log("SMOKE settingsNavigation="+(settingsOk && subject.service.view===settingsReturn))
      var navLayout=findItem(subject.panel.contentItem[0],"sidebar")
      var settingsLayout=findItem(subject.panel.contentItem[0],"sidebarSettings")
      if (navLayout && settingsLayout) {
        var settingsPoint=settingsLayout.mapToItem(navLayout,0,0)
        var done=navLayout.navItems.filter(function(item){return item.value==="completed"})
        var wrappers=navLayout.navItems.filter(function(item){return item.section==="lists" || item.section==="more"})
        console.log("SMOKE sidebarLayout="+(done.length===1 && wrappers.length===0 && settingsPoint.y>=0 && settingsPoint.y+settingsLayout.height<=navLayout.height+1))
      }
      var flick = findItem(subject.panel.contentItem[0], "statsFlick")
      if (pane && flick) {
        subject.open()
        flick.scrollBy(100)
        var scrolled = flick.contentY > 0
        pane.inspectCalendar()
        var focused = pane.calendarFocus
        pane.releaseCalendar()
        var days = []
        for (var d = 0; d < 90; d++) days.push({date: "2026-10-01", count: 1})
        pane.stats = {summary: {open: 0}, days: 90, trend: days}
        console.log("SMOKE statsAccess=" + (scrolled && focused && !pane.calendarFocus)
                    + " grouped=" + pane.trend.length)
      }
      subject.setView("today")
      var management = findItem(subject.panel.contentItem[0], "managementPane")
      if (management) {
        var noManage=subject.views.indexOf("manage")<0
        subject.setView("habits")
        subject.openTools("New habit",["habit"],null)
        console.log("SMOKE contextualHabit="+(noManage && management.contextual && management.resource==="habit" && management.contextResources.length===1))
        subject.closeTools()
        console.log("SMOKE contextualReturn="+(subject.service.view==="habits"))
        subject.openTools("New habit",["habit"],null)
        subject.openTools("Account settings",["preference","revoke"],null)
        subject.closeTools()
        console.log("SMOKE contextualNested="+(subject.service.view==="habits"))
        subject.setView("today")
        subject.selectedTasks=["t-selected"]
        subject.openTools("Selected tasks",["batch"],{projectId:"p-work",id:"t-selected"})
        console.log("SMOKE contextualBulk="+(management.selectedIds.length===1 && management.selectedIds[0]==="t-selected"))
        subject.closeTools()
        subject.selecting=true;subject.selectedTasks=["old-selection"]
        subject.openProject("p-home")
        console.log("SMOKE contextualSelectionReset="+(!subject.selecting && subject.selectedTasks.length===0))
        subject.setView("manage")
        management.resource = "batch"
        subject.setView("countdown")
        console.log("SMOKE management=" + (management.resource === "countdown" && subject.rowCount === 0))
        subject.setView("today")
      }
      focusProbe.running = true
      quitTimer.running = true
    }
  }
  Timer {
    id: detailProbe
    property real shut: 0
    property var subjectRow: null
    interval: 500
    onTriggered: {
      console.log("SMOKE detail shut=" + Math.round(shut)
                  + " open=" + Math.round(subject.panel.contentHeight)
                  + " items=" + (subjectRow ? subjectRow.itemsTotal : 0))
      if (subjectRow) subject.toggleExpanded(subjectRow.id)
    }
  }

  Timer {
    id: focusProbe
    property int step: 0
    property real endsAt: 0
    interval: 200
    repeat: true
    onTriggered: {
      var s = subject.service
      if (s.focusBusy) return
      var task = { id: "focus-task", title: "写报告 <not markup>" }
      if (step === 0) {
        s.startFocus(task)
      } else if (step === 1) {
        console.log("SMOKE focusLinked=" + (s.focusState.taskId === task.id
          && s.focusState.taskTitle === task.title && s.focusRunning))
        endsAt = s.focusEndsAt
        s.startFocus({ id: "other", title: "Other task" })
        console.log("SMOKE focusKept=" + (s.focusEndsAt === endsAt && s.focusState.taskId === task.id))
        s.pauseFocus()
      } else if (step === 2) {
        s.startFocus({ id: "other", title: "Other task" })
        console.log("SMOKE focusPausedKept=" + (s.focusPaused && s.focusState.taskId === task.id
          && s.focusState.taskTitle === task.title))
        s.stopFocus()
      } else if (step === 3) {
        console.log("SMOKE focusStopped=" + (!s.focusActive && s.focusState.taskTitle === ""))
        s.startStopwatch(task)
      } else if (step === 4) {
        console.log("SMOKE stopwatchLinked=" + (s.focusTiming && s.focusActive && s.focusState.taskId === task.id && s.focusState.taskTitle === task.title))
        s.pauseFocus()
      } else if (step === 5) {
        s.startStopwatch({id:"other",title:"Other"})
        console.log("SMOKE stopwatchKept=" + (s.focusPaused && s.focusState.taskId === task.id))
        s.stopFocus()
      } else {
        Qt.quit()
      }
      step += 1
    }
  }
  Timer { id: quitTimer; interval: 15000; onTriggered: Qt.quit() }
}
QML

info "running the widget in quickshell…"
XDG_CONFIG_HOME="$WORK/config" \
XDG_STATE_HOME="$WORK/state" \
TICKTICK_API_BASE="$(cat "$WORK/base.txt")" \
  timeout 45 quickshell -n -p "$WORK/shell.qml" > "$WORK/out.log" 2>&1
status=$?

sed -e 's/\x1b\[[0-9;]*m//g' "$WORK/out.log" > "$WORK/clean.log"

grep -E "^\s*(SMOKE|.*qml:)" "$WORK/clean.log" | sed 's/^/  /'

[ $status -eq 0 ] || { cat "$WORK/clean.log"; fail "quickshell exited $status"; }

# The portal complaint is this harness running beside the real shell, not our code.
problems="$(grep -E "ERROR|WARN" "$WORK/clean.log" \
  | grep -v "Failed to register with host portal" || true)"
if [ -n "$problems" ]; then
  echo "$problems"
  fail "QML produced errors or warnings"
fi

# Today = overdue + today: "Renew domain", "Submit report", "Call the bank", plus the
# note that is also due today. Tomorrow's and the undated one are correctly excluded.
for marker in focusLinked focusKept focusPausedKept focusStopped stopwatchLinked stopwatchKept settingsNavigation; do
  grep -q "SMOKE $marker=true" "$WORK/clean.log" || fail "focus association check failed: $marker"
done
for marker in contextualHabit contextualReturn contextualBulk contextualNested contextualSelectionReset; do
  grep -q "SMOKE $marker=true" "$WORK/clean.log" || fail "contextual workflow failed: $marker"
done
grep -q "SMOKE navTracks=true" "$WORK/clean.log" || fail "the sidebar stopped tracking the view"
grep -q "SMOKE sidebarLayout=true" "$WORK/clean.log" || fail "sidebar settings overflow or Lists entry missing"
grep -q "SMOKE shortcutOrder=true" "$WORK/clean.log" || fail "number shortcuts differ from sidebar order"
grep -q "SMOKE navSelect=inbox" "$WORK/clean.log" || fail "selecting a sidebar item did not change the view"
grep -q "SMOKE sidebarCursor=sidebar:ok" "$WORK/clean.log" || fail "the sidebar keyboard cursor did not land on a row"
grep -q "SMOKE preview=true" "$WORK/clean.log" || fail "moving the sidebar cursor did not preview the list"
grep -q "SMOKE sidebarStep=ok" "$WORK/clean.log" || fail "the sidebar cursor stepped onto a header or off the end"
grep -q "SMOKE habitTaskView=all" "$WORK/clean.log" || fail "habit view reached the task CLI"
# The Stats view must actually render its dashboard — the trend over the completed
# window, and the open work grouped by list — not merely exist in the view list.
grep -q "SMOKE stats view=stats days=7 trend=7 lists=3" "$WORK/clean.log" \
  || { cat "$WORK/clean.log"; fail "the Stats view did not render its dashboard"; }
grep -q "SMOKE statsAccess=true grouped=13" "$WORK/clean.log" \
  || { cat "$WORK/clean.log"; fail "statistics scrolling, calendar focus or long-range aggregation failed"; }
grep -q "SMOKE rows=4" "$WORK/clean.log" \
  || { cat "$WORK/clean.log"; fail "expected 4 rows (1 overdue + 2 today + 1 note) in Today"; }
# …but the badge counts only the three real tasks. A note has no checkbox, so
# counting one reports work that does not exist.
grep -q "SMOKE .*badge=3" "$WORK/clean.log" \
  || { cat "$WORK/clean.log"; fail "the badge counted the note"; }
grep -q "SMOKE note=Meeting notes" "$WORK/clean.log" \
  || fail "the note never reached the list"
grep -q "SMOKE add before=4 after=5" "$WORK/clean.log" \
  || { cat "$WORK/clean.log"; fail "a new task did not appear synchronously"; }
grep -q "SMOKE dupsections=0" "$WORK/clean.log" \
  || { cat "$WORK/clean.log"; fail "a list was headed twice — the draft opened its own section"; }
# Sorting by list means the headings are list names, not Overdue/Today.
grep -qE "SMOKE sections=(WORK|HOME|INBOX)" "$WORK/clean.log" \
  || { cat "$WORK/clean.log"; fail "sections are not headed by list name under sort=list"; }
grep -q "SMOKE done .* sort=list" "$WORK/clean.log" \
  || fail "cycling the sort four times did not return to where it started"
grep -q "SMOKE confirmOpen=true" "$WORK/clean.log" \
  || fail "the delete confirmation never opened"
grep -q "SMOKE donekept=true restoring=true" "$WORK/clean.log" \
  || { cat "$WORK/clean.log"; fail "a finished task was completed again"; }
grep -q "SMOKE settings hideWhenEmpty=false showProjectChips=true confirmDelete=true" \
  "$WORK/clean.log" || fail "string settings were not coerced to booleans"

printf '\033[32mOK\033[0m   QML loads, renders and drives cleanly\n'
