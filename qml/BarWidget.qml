import QtQuick
import "I18n.js" as I18n
import QtQuick.Controls
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The plugin's entry point: bar button, badge, and the keyboard-driven popup.
//
// Everything here is presentation and input. State, process orchestration and the
// optimistic write queue live in Service.qml; anything worth a unit test lives in
// Python behind bin/ticktick. This file's whole job is to turn key presses and
// clicks into Service calls, and rows into pixels.
//
// The popup follows the Dida365 app's shape: a left sidebar (Sidebar.qml) holding
// the smart lists, the user's lists and the focus timer, and a right pane holding
// the tasks of whatever is selected, with quick-add along the bottom. The keyboard
// model is unchanged — the sidebar is click- and shortcut-driven, the cursor stays
// in the task list.
//
// Three host contracts this file is written against, all of which bite silently
// when broken:
//
//   1. The bar injects exactly `bar`, `moduleName` and `settings`, and it does so
//      AFTER construction — every read of `bar` is guarded.
//   2. `settings` is the shell.json entry minus its id. The manifest's `defaults`
//      block is inert at runtime, so every default lives in `setting(key, fallback)`
//      calls, and values arrive as STRINGS unless the user passed `--json`.
//   3. The bar is instantiated once per monitor, but an IPC target routes to only
//      one of those instances — so every IPC mutation fans out via `bar.moduleWidgets`.
Panel {
  id: widget

  moduleName: "dddaniel1.dida365"
  // The plugin id, not a friendly short name. An IPC target is single-occupancy —
  // the first handler to register wins and every later one is silently dead — so a
  // generic "ticktick" would break the moment any other TickTick plugin (or an older
  // copy of this one) is installed alongside it. That collision was observed live.
  ipcTarget: "dddaniel1.dida365"
  // Panel's built-in handler only offers open/close/show/hide/toggle, and a target
  // accepts exactly one handler. Ours adds refresh/add/count, so Panel's must stand down.
  manageIpc: false

  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // The data layer, reachable from outside. This file is presentation and input;
  // anything that is really a question about state — what the sort is, what is
  // queued — is answered here, and the QML smoke test drives it the same way.
  readonly property alias service: tt
  // The popup surface. Exposed for the same reason `service` is: so a harness can
  // ask where the card ended up rather than guessing at its geometry.
  readonly property alias panel: panel

  readonly property bool hideWhenEmpty: tt.boolSetting("hideWhenEmpty", false)
  readonly property bool showProjectChips: tt.boolSetting("showProjectChips", true)
  // …and whether the chip is telling the reader anything. Under the default sort the
  // section heading above the row IS the list name, and inside the Inbox or one list
  // every row shares it — so the chip printed "Inbox" under a heading reading INBOX.
  // TickTick does not repeat it there either.
  readonly property bool chipsUseful: showProjectChips
                                      && tt.effectiveSort !== "list"
                                      && tt.view !== "inbox"
                                      && !(tt.view === "project" && tt.projectFilter !== "")
  readonly property bool confirmDelete: tt.boolSetting("confirmDelete", true)

  // --- cursor / mode state ----------------------------------------------

  property bool cursorActive: false
  property int cursorIndex: 0
  property string expandedId: ""
  property bool adding: false
  property bool filtering: false
  // Which pane owns the keyboard: the task list (default) or the sidebar. Only the
  // focused pane shows a cursor, so a highlight never appears in both at once.
  property string focusPane: "list"
  // The token field is the fallback, revealed only when asked for, so the signed-out
  // panel leads with the one button most people want.
  property bool pastingToken: false
  property bool detailPickerOpen: false
  property bool confirmOpen: false
  property var confirmTask: null
  // Enter emits returnRequested and THEN activateRequested. Space emits only
  // activateRequested. This flag is how the two are told apart.
  property bool _returnConsumed: false

  // The rendered sidebar is also the keyboard order, including optional views.
  readonly property var viewOptions: {
    var out = []
    for (var i = 0; i < sidebar.viewOrder.length; i++) {
      var item = sidebar.viewOrder[i]
      out.push({ value: item.value, label: item.label })
    }
    return out
  }
  readonly property var views: {
    var out = []
    for (var i = 0; i < viewOptions.length; i++) out.push(viewOptions[i].value)
    return out
  }

  // The list a single project is scoped to, if any. The sidebar owns list picking now,
  // so a project is just the "project" view with a filter, never a picker screen.
  readonly property bool projectFilterActive: tt.view === "project" && tt.projectFilter !== ""
  readonly property bool showingHabits: tt.view === "habits"
  readonly property bool showingStats: tt.view === "stats"
  readonly property bool showingManagement: tt.view === "manage" || tt.view === "countdown"
  property string contextTitle: ""
  property bool settingsHome: false
  property bool settingsSection: false
  property var contextResources: []
  property string returnView: "today"
  property string returnProject: ""
  property bool selecting: false
  property var selectedTasks: []

  function openTools(title, resources, task) {
    settingsHome=false; settingsSection=false
    managementPane.contextProject="";managementPane.contextTask=""
    if (tt.view!=="manage") { returnView=tt.view; returnProject=tt.projectFilter }
    contextTitle=title; contextResources=resources
    expandedId=""; detailPickerOpen=false
    tt.setView("manage")
    managementPane.initialSelection=selectedTasks
    managementPane.openResource(resources[0],task || null)
  }
  function closeTools() {
    if (settingsSection) { showSettings(); return }
    settingsHome=false
    managementPane.formFocus=false; detailPickerOpen=false
    tt.setView(returnView); tt.setProjectFilter(returnProject)
    selectedTasks=[]; selecting=false
    keyCatcher.forceActiveFocus()
  }
  function showSettings() {
    if (tt.view !== "manage") { returnView=tt.view; returnProject=tt.projectFilter }
    settingsHome=true; settingsSection=false; contextTitle="Settings"
    managementPane.formFocus=false; detailPickerOpen=false
    tt.setView("manage")
  }
  function openSettingsSection(title, resources) {
    widget.openTools(title,resources,null)
    settingsSection=true
  }
  function toggleSelection(task) {
    var ids=selectedTasks.slice(), at=ids.indexOf(task.id)
    if (at>=0) ids.splice(at,1)
    else if (ids.length<50) {
      for (var i=0;i<tt.tasks.length;i++) if (ids.indexOf(tt.tasks[i].id)>=0 && tt.tasks[i].projectId!==task.projectId) {
        tt.toast("Select tasks from one list at a time"); return
      }
      ids.push(task.id)
    }
    selectedTasks=ids
  }

  // Habits join the same cursor, section and delegate machinery the tasks use, rather
  // than getting a list of their own: one cursor, one set of keys, one way to draw a row.
  // Stats have no rows at all: the dashboard owns the whole pane.
  readonly property var rows: widget.showingStats || widget.showingManagement ? []
    : widget.showingHabits ? (tt.habits || []) : (tt.tasks || [])
  readonly property int rowCount: rows.length

  // The header's own count. Notes are excluded the same way the sidebar and the bar
  // badge exclude them, so the two numbers can never look like different accounts.
  readonly property int paneCount: {
    var n = 0
    for (var i = 0; i < rowCount; i++) {
      if (widget.showingHabits || !Model.isNote(rows[i])) n += 1
    }
    return n
  }

  // What the task pane's heading says: the list's own name when scoped to one, otherwise
  // the smart list's label.
  function viewLabel() {
    if (tt.view === "tomorrow") return I18n.tr("Tomorrow")
    if (tt.view === "stats") return I18n.tr("Statistics")
    if (tt.view === "manage") return I18n.tr(contextTitle || "Settings")
    if (widget.projectFilterActive) {
      var list = tt.projects || []
      for (var i = 0; i < list.length; i++) {
        if (String(list[i].id || "") === String(tt.projectFilter)) return Model.squish(list[i].name) || "List"
      }
      return "List"
    }
    for (var j = 0; j < viewOptions.length; j++) {
      if (viewOptions[j].value === tt.view) return viewOptions[j].label
    }
    return I18n.tr("Tasks")
  }

  readonly property string summary: {
    if (!tt.authed) return I18n.tr("Not signed in")
    if (!tt.loaded) return I18n.tr("Loading…")
    var c = tt.counts || {}
    var over = Number(c.overdue || 0)
    var today = Number(c.today || 0)
    if (I18n.isChinese(Qt.locale().name)) return over > 0 || today > 0 ? "逾期 " + over + " · 今天 " + today : "暂无到期任务"
    if (over > 0 && today > 0) return over + " overdue · " + today + " today"
    if (over > 0) return over + (over === 1 ? " task overdue" : " tasks overdue")
    if (today > 0) return today + (today === 1 ? " task today" : " tasks today")
    return I18n.tr("Nothing due")
  }

  // The bar shows one number: the task badge. The habit count used to ride along
  // as a second "2♦" beside it, which read as a separate widget rather than one count.
  readonly property string badgeText: !tt.authed ? "!"
    : (tt.badgeCount > 0 ? String(tt.badgeCount) : "")

  // --- helpers ----------------------------------------------------------

  readonly property var tagOptions: {
    var out = [{ value: "", label: I18n.tr("Any tag") }]
    var list = tt.tags || []
    for (var i = 0; i < list.length; i++) {
      var tag = list[i] || {}
      var name = Model.squish(tag.name)
      if (name !== "") out.push({ value: name, label: "#" + (Model.squish(tag.label) || name) })
    }
    return out
  }

  function selectedTask() {
    if (widget.showingHabits || widget.showingStats) return null
    return (cursorIndex >= 0 && cursorIndex < rowCount) ? rows[cursorIndex] : null
  }

  function selectedHabit() {
    if (!widget.showingHabits) return null
    return (cursorIndex >= 0 && cursorIndex < rowCount) ? rows[cursorIndex] : null
  }

  function clampCursor() {
    if (cursorIndex >= rowCount) cursorIndex = Math.max(0, rowCount - 1)
    if (cursorIndex < 0) cursorIndex = 0
  }

  // A keyboard move must scroll the cursor into view; a mouse hover must not. The
  // hovered row is by definition already under the pointer, and scrolling slides the
  // list out from under it — a different clipped row lands under the mouse, hovers,
  // scrolls again, and the list runs itself to the bottom on a mouse-over nobody
  // meant as a scroll. `scroll !== false` so existing one-argument callers are unaffected.
  function setCursor(index, scroll) {
    cursorActive = true
    cursorIndex = Math.max(0, Math.min(rowCount - 1, index))
    if (scroll !== false) scrollIntoView()
  }

  function moveCursor(delta) {
    cursorActive = true
    if (rowCount === 0) return
    cursorIndex = Math.max(0, Math.min(rowCount - 1, cursorIndex + delta))
    scrollIntoView()
  }

  function cycleView(step) {
    var at = views.indexOf(tt.view)
    if (at < 0) at = 0
    setView(views[(at + step + views.length) % views.length])
  }

  function setView(name) {
    selecting=false; selectedTasks=[]; managementPane.formFocus=false; detailPickerOpen=false
    tt.setProjectFilter("")
    tt.setView(name)
    cursorIndex = 0
    expandedId = ""
    if (listFlick) listFlick.contentY = 0
    // Habits are not on the task poll, so entering their view is what asks for them.
    if (name === "habits") tt.loadHabits()
    if (name === "stats") tt.loadStats()
  }

  // Scope the task pane to one list. The view goes to "project" first (which clears any
  // previous filter) and the filter lands second, so the two never fight.
  function openProject(projectId) {
    selecting=false;selectedTasks=[]
    var id = String(projectId || "")
    if (id === "") return
    tt.setView("project")
    tt.setProjectFilter(id)
    cursorIndex = 0
    expandedId = ""
    if (listFlick) listFlick.contentY = 0
  }

  // Move the keyboard into the sidebar: the task cursor steps back so only one row in
  // the whole card is lit, and the sidebar cursor lands on the current view or list.
  function focusSidebar() {
    cursorActive = false
    focusPane = "sidebar"
    sidebar.ensureCursor()
  }

  // …and back into the task list, which resumes showing its cursor where it was.
  function focusList() {
    focusPane = "list"
    cursorActive = true
  }

  // Move the sidebar cursor AND show what it lands on, so browsing lists reads like the
  // app: arrowing previews each list in the task pane. The helper is cache-first, so
  // this is a local re-derive unless the cache is genuinely stale, and Service coalesces
  // its refreshes — holding a key does not spray requests.
  function sidebarStep(delta) {
    sidebar.moveCursor(delta)
    var item = sidebar.navItems[sidebar.cursorIndex]
    if (item && (item.kind === "view" || item.kind === "project")) sidebar.activateCurrent()
  }

  // The section a row opens, or "" when the row above already opened it. What the
  // sections mean follows the sort: by list they are list names (TickTick's own
  // default), by date they are Overdue / Today / Tomorrow. Sorting by priority or
  // title has no sections at all — a heading would cut across the order asked for.
  function sectionFor(index) {
    var list = rows
    if (index < 0 || index >= list.length) return ""
    if (widget.showingHabits) {
      // Habits are grouped by the section the account files them under, which is the
      // same thing TickTick's own habit list shows. An unfiled habit gets no heading
      // rather than an empty one.
      var name = Model.squish(list[index].section)
      if (name === "") return ""
      if (index > 0 && Model.squish(list[index - 1].section) === name) return ""
      return name.toUpperCase()
    }
    var sort = tt.effectiveSort
    // Under the list sort the heading is the list's own name; when the pane is already
    // scoped to a single list, that heading is the title right above it and only repeats it.
    if (sort === "list" && (tt.view === "inbox" || widget.projectFilterActive)) return ""
    var key = Model.sectionKey(list[index], sort)
    if (key === "") return ""
    if (index > 0 && Model.sectionKey(list[index - 1], sort) === key) return ""
    return Model.sectionLabel(list[index], sort).toUpperCase()
  }

  function toggleExpanded(taskId) {
    var id = String(taskId || "")
    expandedId = (expandedId === id) ? "" : id
  }

  function completeAt(task) {
    if (!task) return
    tt.complete(task)
    if (expandedId === String(task.id || "")) expandedId = ""
    Qt.callLater(widget.clampCursor)
  }

  function requestDelete(task) {
    if (!task) return
    if (!confirmDelete) {
      tt.remove(task)
      Qt.callLater(widget.clampCursor)
      return
    }
    confirmTask = task
    confirmOpen = true
  }

  function confirmDeleteNow() {
    var task = confirmTask
    confirmOpen = false
    confirmTask = null
    if (task) {
      tt.remove(task)
      if (expandedId === String(task.id || "")) expandedId = ""
      Qt.callLater(widget.clampCursor)
    }
  }

  function cancelDelete() {
    confirmOpen = false
    confirmTask = null
  }

  function cyclePriority(task) {
    if (!task) return
    // TickTick has exactly four levels; walking up and wrapping is the whole story.
    var ladder = [0, 1, 3, 5]
    var at = ladder.indexOf(Model.toInt(task.priority))
    tt.setPriority(task, ladder[(at < 0 ? 0 : at + 1) % ladder.length])
  }

  function openSearch() {
    Qt.callLater(function () { sidebar.focusSearch() })
  }

  function closeSearch(clearText) {
    if (clearText) {
      // The field's `text` binding is broken the moment the user types into it,
      // so clearing the service alone would leave the old query on screen.
      sidebar.clearSearch()
      tt.setSearch("")
    }
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  function openAdd() {
    adding = true
    Qt.callLater(function () { quickAdd.focusField() })
  }

  // Hand the keyboard back to the row cursor. Focus does not return on its own: a
  // TextField that gives up focus leaves the window with no active focus item at all,
  // and PanelKeyCatcher only sees keys while it holds it — so without this, one edit
  // in the detail pane left the popup deaf until it was closed and reopened.
  function reclaimKeys() {
    Qt.callLater(function () {
      if (widget.opened && !widget.detailPickerOpen && !sortPicker.popupOpen
          && !priorityPicker.popupOpen && !tagPicker.popupOpen && !widget.adding
          && !sidebar.searchFocused && !widget.pastingToken) {
        keyCatcher.forceActiveFocus()
      }
    })
  }

  function toggleFilters() {
    filtering = !filtering
    // Leaving a filter on behind a hidden control is how a list ends up looking
    // empty for no visible reason.
    if (!filtering) tt.clearFilters()
  }

  function closeAdd() {
    adding = false
    quickAdd.clear()
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  // Esc unwinds one layer at a time rather than slamming the popup shut, so a
  // stray Esc while searching never loses the reader their place.
  function dismiss() {
    if (tt.view === "manage") { closeTools(); return }
    if (confirmOpen) { cancelDelete(); return }
    if (adding) { closeAdd(); return }
    if (sidebar.searchFocused || tt.search !== "") { closeSearch(true); return }
    // Esc out of the sidebar hands the keyboard back to the list rather than closing.
    if (focusPane === "sidebar") { focusList(); return }
    if (filtering) { toggleFilters(); return }
    if (expandedId !== "") { expandedId = ""; return }
    if (tt.view === "project" && tt.projectFilter !== "") { tt.setProjectFilter(""); return }
    widget.close()
  }

  // The delegate at `index`. NOT `children[index]`: a Repeater is itself a child of
  // the Column it fills, so positional lookup is off by one and silently scrolls to
  // the wrong row. Matching on the delegate's own `index` cannot drift.
  function itemForIndex(index) {
    for (var i = 0; i < listColumn.children.length; i++) {
      var child = listColumn.children[i]
      if (child && child.index === index) return child
    }
    return null
  }

  function scrollIntoView() {
    if (!listFlick) return
    Qt.callLater(function () {
      var item = widget.itemForIndex(widget.cursorIndex)
      if (!item || !item.height) return
      var margin = Style.space(8)
      var top = item.mapToItem(listFlick.contentItem, 0, 0).y
      var bottom = top + item.height
      var maxY = Math.max(0, listFlick.contentHeight - listFlick.height)
      if (top < listFlick.contentY + margin) {
        listFlick.contentY = Math.max(0, top - margin)
      } else if (bottom > listFlick.contentY + listFlick.height - margin) {
        listFlick.contentY = Math.min(maxY, bottom + margin - listFlick.height)
      }
    })
  }

  // Run `method` on this widget on every monitor. An IPC target routes to exactly
  // one handler, but the bar — and therefore this widget — exists once per screen,
  // so without this a two-monitor user gets a stale badge on one of them.
  function broadcast(method) {
    var peers = (bar && typeof bar.moduleWidgets === "function")
      ? bar.moduleWidgets(moduleName) : [widget]
    for (var i = 0; i < peers.length; i++) {
      if (peers[i] && typeof peers[i][method] === "function") peers[i][method]()
    }
  }

  function refresh() { tt.refresh() }

  // --- bar slot ---------------------------------------------------------

  visible: !hideWhenEmpty || !tt.loaded || !tt.authed || tt.badgeCount > 0
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (!opened) {
      cancelDelete()
      return
    }
    cursorActive = false
    cursorIndex = 0
    expandedId = ""
    adding = false
    focusPane = "list"
    if (listFlick) listFlick.contentY = 0
    // Opening is when the two things the task poll does not carry are worth asking
    // for: the habit list, and today's focus tally.
    if (tt.view === "habits") tt.loadHabits()
    if (tt.view === "stats") tt.loadStats()
    tt.loadFocus()
    tt.refresh()
    tt.loadTags()  // cheap, and a tag created elsewhere should be filterable here
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: tt
    settings: widget.settings
    // A refresh replaces `tasks`, which rebuilds every row — including the detail
    // pane the user is typing into. Hold reads while that pane owns the keyboard.
    paused: widget.detailPickerOpen
    onLoadFailed: function (message) {
      // Truth arriving late must not strand the cursor past the end of a list
      // that shrank while the request was in flight.
      Qt.callLater(widget.clampCursor)
    }
  }

  Connections {
    target: tt
    function onTasksChanged() { Qt.callLater(widget.clampCursor) }
    function onProjectsChanged() { Qt.callLater(widget.clampCursor) }
    // Changing project scope swaps the list under the cursor, so the cursor goes
    // home. Stated once here rather than beside each of the four call sites — the
    // one that forgot it (Esc out of a project) left the cursor past the end of the
    // shorter project list, where Enter and x silently did nothing.
    function onProjectFilterChanged() { widget.cursorIndex = 0 }
    // A write has finished and the cache now holds it. The bar exists once per
    // monitor, each with its own Service and poll timer, so refreshing only this
    // instance leaves every other screen counting a task the user just completed
    // until its own timer fires — up to refreshIntervalSec later.
    function onSettled() { widget.broadcast("refresh") }
  }

  IpcHandler {
    target: widget.ipcTarget

    function open(): void { widget.open() }
    function close(): void { widget.close() }
    function show(): void { widget.open() }
    function hide(): void { widget.close() }
    function toggle(): void { widget.toggle() }
    function refresh(): string { widget.broadcast("refresh"); return "ok" }
    // No broadcast here: the add is queued, not done. Fanning out now would have every
    // peer read the list from before it. `Service.settled` fans out once it has landed.
    function add(title: string): string { tt.add(title); return "ok" }
    function count(): string { return String(tt.badgeCount) }
    function view(name: string): string { widget.setView(tt.normalizeView(name)); return tt.view }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: widget.bar
    // A vertical bar has no room for a number beside the glyph. A running focus block
    // outranks the task count: it is the thing with seconds on it.
    readonly property bool showingClock: tt.showFocus && tt.focusClockText !== ""
    // The TickTick/Dida mark: an open ring with a check — the app's own logo —
    // rather than the generic checkbox glyph the box used to be.
    readonly property string mark: "󰄴"
    readonly property string barValue: showingClock ? tt.focusClockText : widget.badgeText
    text: (bar && bar.vertical) ? mark : mark + (barValue === "" ? "" : " " + barValue)
    fontSize: Style.font.caption
    horizontalMargin: 6
    active: tt.authed && (showingClock || Number((tt.counts || {}).overdue || 0) > 0)
    activeColor: widget.urgent
    tooltipText: "Dida 365 — " + widget.summary
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) tt.refresh()
      else if (buttonCode === Qt.MiddleButton) { widget.open(); Qt.callLater(widget.openAdd) }
      else widget.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    bar: widget.bar
    owner: widget
    open: widget.opened
    focusTarget: keyCatcher
    // Wider than a single-column tray: the sidebar needs room for list names and the
    // task pane for a title plus its metadata. Signed out there is no sidebar, so the
    // card shrinks to the sign-in form.
    contentWidth: panel.fittedContentWidth(tt.authed ? Style.space(680) : Style.space(420))
    // A floor, so the sidebar's own content (smart lists, lists, focus) always has room
    // even when the selected view holds only a task or two.
    contentHeight: panel.fittedContentHeight(
      Math.max(mainColumn.naturalHeight, Style.space(380)), Style.space(640))

    // A plain Item wrapping the catcher: when the confirm dialog is up the catcher
    // is `blocked`, which makes it a transparent pass-through, and the unaccepted
    // key then bubbles up to here. That is the only way to give a modal first
    // refusal, because ConfirmDialog has no focus handling of its own — it exposes
    // handleKey(event) and expects to be driven.
    Item {
      id: keyRoot
      anchors.fill: parent

      Keys.onPressed: function (event) {
        if (widget.confirmOpen && confirmDialog.handleKey(event)) event.accepted = true
      }

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        Keys.onReleased: function(event) {
          if (!widget.showingStats || blocked || widget.focusPane !== "list") return
          if (event.key === Qt.Key_PageDown || event.key === Qt.Key_PageUp) {
            statsFlick.scrollBy((event.key === Qt.Key_PageDown ? 1 : -1) * statsFlick.height * 0.8)
            event.accepted = true
          } else if (event.key === Qt.Key_Home || event.key === Qt.Key_End) {
            statsFlick.contentY = event.key === Qt.Key_Home ? 0 : Math.max(0, statsFlick.contentHeight - statsFlick.height)
            event.accepted = true
          }
        }
        // Any focused text field, an open dropdown, or the modal owns the keyboard.
        blocked: widget.confirmOpen || widget.detailPickerOpen || sortPicker.popupOpen
                 || priorityPicker.popupOpen || tagPicker.popupOpen
                 || sidebar.searchFocused || tokenField.activeFocus || quickAdd.editing
                 || (widget.showingStats && statsPane.calendarFocus)

        onMoveRequested: function (dx, dy) {
          // The sidebar owns the arrows while it has the keyboard: up/down walk the
          // nav, and a push to the right hands the keys back to the list.
          if (widget.focusPane === "sidebar") {
            if (dy !== 0) widget.sidebarStep(dy)
            else if (dx > 0) widget.focusList()
            return
          }
          if (dx !== 0) { widget.cycleView(dx > 0 ? 1 : -1); return }
          if (dy === 0) return
          if (widget.showingStats) { statsFlick.scrollBy(dy * Style.space(48)); return }
          if (!widget.cursorActive) { widget.cursorActive = true; return }
          widget.moveCursor(dy)
        }

        // Fires only for Enter — Space never emits it. Complete lives here.
        onReturnRequested: {
          widget._returnConsumed = true
          if (!tt.authed) return
          // In the sidebar, Enter commits the highlighted view or list and drops the
          // keyboard back into the task pane, so the next key is a task key.
          if (widget.focusPane === "sidebar") {
            sidebar.activateCurrent()
            widget.focusList()
            return
          }
          if (widget.showingHabits) {
            tt.checkInHabit(widget.selectedHabit())
            return
          }
          if (widget.selecting) { var selected=widget.selectedTask(); if(selected) widget.toggleSelection(selected); return }
          widget.completeAt(widget.selectedTask())
        }

        // Fires for BOTH Enter and Space, and always after returnRequested, so the
        // flag is how Space keeps "expand" to itself.
        onActivateRequested: {
          if (widget._returnConsumed) { widget._returnConsumed = false; return }
          // A habit has nothing to expand: its whole state is already on the row. A
          // statistic is not a thing to open at all.
          if (!tt.authed || widget.showingHabits || widget.showingStats
              || widget.focusPane === "sidebar") return
          var task = widget.selectedTask()
          if (widget.selecting) { if(task) widget.toggleSelection(task); return }
          if (task) widget.toggleExpanded(task.id)
        }

        onCloseRequested: widget.dismiss()
        onDeleteRequested: if (tt.authed && widget.focusPane === "list"
                               && !widget.showingHabits && !widget.showingStats)
                             widget.requestDelete(widget.selectedTask())
        onTabRequested: function (direction) {
          if (widget.showingManagement && widget.focusPane === "list") { managementPane.focusForm(); return }
          if (widget.showingStats && widget.focusPane === "list" && direction > 0 && statsPane.calendarDays.length) {
            statsPane.inspectCalendar()
            statsFlick.contentY = Math.max(0, Math.min(statsFlick.contentHeight - statsFlick.height, Style.space(200)))
            return
          }
          if (widget.focusPane === "sidebar") widget.focusList()
          else widget.focusSidebar()
        }

        // h/j/k/l and x/X are consumed as navigation and delete before they reach
        // here, so nothing below may claim them.
        onTextKey: function (text) {
          if (!tt.authed) return
          // The number keys walk `viewOptions` in order, so the sidebar and the
          // shortcuts cannot drift apart when a view is added or reordered.
          var digit = "1234567890".indexOf(text)
          if (digit >= 0 && digit < widget.views.length) {
            widget.setView(widget.views[digit])
            return
          }
          switch (text) {
          case "r": case "R": if (widget.showingManagement) managementPane.load(); else if (widget.showingStats) tt.loadStats(true); else tt.refresh(); break
          // Refresh is cache-first by design; this is how you say "go and look now",
          // and it drains anything queued offline on the way.
          case "s": case "S": if (widget.showingManagement) managementPane.load(); else if (widget.showingStats) tt.loadStats(true); else tt.sync(); break
          // The list-only verbs stand down in a view with no rows: adding, sorting and
          // filtering a dashboard would do nothing the user could see.
          case "a": case "A": if (!widget.showingStats && !widget.showingManagement) widget.openAdd(); break
          case "/": widget.openSearch(); break
          case "o": case "O": if (!widget.showingStats && !widget.showingManagement) tt.cycleSort(); break
          case "f": case "F": if (!widget.showingStats && !widget.showingManagement) widget.toggleFilters(); break
          case "d": case "D":
            if (widget.focusPane === "list" && !widget.showingHabits && !widget.showingStats) {
              widget.requestDelete(widget.selectedTask())
            }
            break
          case "p":
            // Plain `p` stays with task priority: these views had it before there was
            // a timer to start, and taking a working key away is worse than adding one.
            if (widget.focusPane === "list" && !widget.showingHabits && !widget.showingStats) {
              widget.cyclePriority(widget.selectedTask())
            }
            break
          // Shift-P drives the focus timer — start, pause, resume.
          case "P":
            if (tt.showFocus) tt.toggleFocus()
            break
          }
        }

        // ================================================== signed in
        //
        // Two panes straight from the app: a navigation rail and the task list, with
        // quick-add along the bottom of the list.
        Row {
          id: body
          anchors.fill: parent
          visible: tt.authed
          spacing: Style.spacing.lg

          Sidebar {
            id: sidebar
            objectName: "sidebar"
            service: tt
            cursorActive: widget.focusPane === "sidebar"
            width: Style.space(188)
            height: parent.height
            foreground: widget.foreground
            accent: Color.accent
            fontFamily: widget.fontFamily
            showHabits: tt.showHabits
            showStats: tt.showStats
            onOrganizeRequested: widget.openTools("Lists and folders",["project","folder","tag"],null)
            onFocusHistoryRequested: widget.openTools("Focus history",["focus-record"],null)
            onSettingsRequested: widget.showSettings()
            onViewSelected: function (value) { widget.setView(value) }
            onProjectSelected: function (projectId) { widget.openProject(projectId) }
            onSearchEdited: function (text) { tt.setSearch(text) }
            onSearchCancelled: widget.closeSearch(true)
          }

          // The task pane. A hairline between the two panes is the app's own divider,
          // drawn here rather than as row spacing so it reaches the card's full height.
          Item {
            id: mainPane
            width: Math.max(0, parent.width - sidebar.width - body.spacing)
            height: parent.height

            Rectangle {
              id: paneDivider
              width: 1
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              anchors.left: parent.left
              color: Qt.rgba(widget.foreground.r, widget.foreground.g, widget.foreground.b, 0.12)
            }

            Column {
              id: mainColumn
              anchors.left: paneDivider.right
              anchors.leftMargin: Style.spacing.lg
              anchors.right: parent.right
              anchors.top: parent.top
              height: parent.height
              spacing: Style.spacing.md

              // Intrinsic height for the panel to fit to; it never lets the list drive
              // the card past its cap, which is why the list is clamped here too.
              readonly property real naturalHeight:
                  paneHeader.implicitHeight + Style.spacing.md
                + paneRule.height
                + (filterBar.visible ? filterBar.implicitHeight + spacing : 0)
                + (listFlick.visible ? Math.min(listColumn.implicitHeight, Style.space(430)) + spacing : 0)
                + (statsFlick.visible ? Math.min(statsPane.implicitHeight, Style.space(430)) + spacing : 0)
                + (emptyState.visible ? emptyState.implicitHeight + spacing : 0)
                + (statusLine.visible ? statusLine.implicitHeight + spacing : 0)
                + (quickAddBar.visible ? quickAddBar.implicitHeight + spacing : 0)
                + spacing

              // ---- header: what list you are looking at, and the tools
              Item {
                id: paneHeader
                width: parent.width
                implicitHeight: Math.max(paneTitle.implicitHeight, paneCount.implicitHeight, paneTools.implicitHeight)

                Text {
                  id: paneTitle
                  anchors.left: parent.left
                  anchors.right: paneCount.visible ? paneCount.left : paneTools.left
                  anchors.rightMargin: Style.spacing.sm
                  anchors.verticalCenter: parent.verticalCenter
                  text: widget.viewLabel()
                  textFormat: Text.PlainText
                  color: widget.foreground
                  font.family: widget.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  id: paneCount
                  visible: text !== ""
                  anchors.right: paneTools.left
                  anchors.rightMargin: Style.spacing.md
                  anchors.verticalCenter: parent.verticalCenter
                  text: widget.paneCount > 0 ? String(widget.paneCount) : ""
                  color: widget.dim
                  font.family: widget.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Row {
                  id: paneTools
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.spacing.xs

                  Button {
                    visible: tt.view === "manage"
                    text:I18n.tr("Back")
                    foreground:widget.foreground
                    fontFamily:widget.fontFamily
                    focusable:true
                    onClicked:widget.closeTools()
                  }
                  Button {
                    visible:tt.view === "manage" && widget.contextTitle === "Account settings"
                    text:I18n.tr("Sign out")
                    foreground:widget.foreground
                    onClicked:{tt.signOut();widget.closeTools()}
                  }
                  Button {
                    visible: !widget.showingHabits && !widget.showingStats && !widget.showingManagement
                    text:widget.selecting ? I18n.tr("Cancel selection") : I18n.tr("Select")
                    foreground:widget.foreground
                    fontFamily:widget.fontFamily
                    onClicked:{widget.selecting=!widget.selecting;widget.selectedTasks=[]}
                  }
                  Button {
                    visible:!widget.showingManagement && widget.selecting && widget.selectedTasks.length>0
                    text:I18n.tr("Actions (")+widget.selectedTasks.length+")"
                    foreground:widget.foreground
                    onClicked:{
                      var task=tt.taskRow(widget.selectedTasks[0])
                      widget.openTools("Selected tasks",["batch"],task)
                    }
                  }

                  Button {
                    visible: tt.view === "next" || tt.view === "tomorrow"
                    text: tt.view === "tomorrow" ? I18n.tr("Next 7 days") : I18n.tr("Tomorrow")
                    foreground: widget.foreground
                    fontFamily: widget.fontFamily
                    focusable: true
                    onClicked: widget.setView(tt.view === "tomorrow" ? "next" : "tomorrow")
                  }

                  Button {
                    visible: widget.showingHabits
                    text: I18n.tr("Add habit")
                    foreground: widget.foreground
                    fontFamily: widget.fontFamily
                    onClicked: widget.openTools("New habit",["habit"],null)
                  }

                  Dropdown {
                    id: sortPicker
                    // Habits are not sorted and a dashboard is not a list, so the
                    // control is not offered in either.
                    visible: !widget.showingHabits && !widget.showingStats && !widget.showingManagement && !widget.selecting
                    width: Math.min(Style.space(150), mainColumn.width * 0.42)
                    label: I18n.tr("Sort")
                    showLabel: false
                    options: [
                      { value: "list", label: I18n.tr("Sort: List") },
                      { value: "time", label: I18n.tr("Sort: Date") },
                      { value: "priority", label: I18n.tr("Sort: Priority") },
                      { value: "title", label: I18n.tr("Sort: Title") }
                    ]
                    foreground: widget.foreground
                    fontFamily: widget.fontFamily
                    onChanged: function (value) { tt.setSort(value) }
                    onPopupOpenChanged: if (!popupOpen) widget.reclaimKeys()
                  }

                  // A Dropdown assigns `value` on selection, which would strand the control
                  // whenever the `o` shortcut changes the sort behind it; the Binding keeps
                  // it following the service either way.
                  Binding {
                    target: sortPicker
                    property: "value"
                    value: tt.sort
                  }

                  Button {
                    // A task filter has nothing to say about habits, so the funnel
                    // stays out of the way there rather than filtering a list it cannot match.
                    visible: !widget.showingHabits && !widget.showingStats && !widget.showingManagement && !widget.selecting
                    text: I18n.tr("Filter")
                    bordered: true
                    selected: widget.filtering
                    foreground: widget.dim
                    fontFamily: widget.fontFamily
                    fontSize: Style.font.caption
                    verticalPadding: Style.spacing.xs
                    tooltipText: I18n.tr("Priority and tag filters")
                    onClicked: widget.toggleFilters()
                  }
                }
              }

              PanelSeparator {
                id: paneRule
                foreground: widget.foreground
              }

              Flow {
                id: filterBar
                visible: tt.authed && widget.filtering && !widget.showingHabits
                         && !widget.showingStats && !widget.showingManagement
                width: parent.width
                spacing: Style.spacing.md

                Text {
                  text: I18n.tr("Filter")
                  color: widget.dim
                  font.family: widget.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Dropdown {
                  id: priorityPicker
                  width: Style.space(150)
                  label: I18n.tr("Priority")
                  showLabel: false
                  options: [
                    { value: "-1", label: I18n.tr("Any priority") },
                    { value: "5", label: I18n.tr("High priority") },
                    { value: "3", label: I18n.tr("Medium priority") },
                    { value: "1", label: I18n.tr("Low priority") },
                    { value: "0", label: I18n.tr("No priority") }
                  ]
                  foreground: widget.foreground
                  fontFamily: widget.fontFamily
                  onChanged: function (value) { tt.setPriorityFilter(Model.toInt(value)) }
                  onPopupOpenChanged: if (!popupOpen) widget.reclaimKeys()
                }

                Binding {
                  target: priorityPicker
                  property: "value"
                  value: String(tt.priorityFilter)
                }

                Dropdown {
                  id: tagPicker
                  width: Math.min(filterBar.width, Style.space(150))
                  label: I18n.tr("Tag")
                  showLabel: false
                  options: widget.tagOptions
                  foreground: widget.foreground
                  fontFamily: widget.fontFamily
                  onChanged: function (value) { tt.setTagFilter(value) }
                  onPopupOpenChanged: if (!popupOpen) widget.reclaimKeys()
                }

                Binding {
                  target: tagPicker
                  property: "value"
                  value: tt.tagFilter
                }
              }

              Flickable {
                id: listFlick
                visible: tt.authed && widget.rowCount > 0
                width: parent.width
                // Reserve the chrome first so expanded tasks stay inside the card.
                height: visible ? Math.max(0, mainColumn.height - paneHeader.implicitHeight
                  - paneRule.height - quickAddBar.implicitHeight
                  - (filterBar.visible ? filterBar.implicitHeight + mainColumn.spacing : 0)
                  - (statusLine.visible ? statusLine.implicitHeight + mainColumn.spacing : 0)
                  - mainColumn.spacing * 3) : 0
                contentWidth: width
                contentHeight: listColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick
                interactive: contentHeight > height
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                Column {
                  id: listColumn
                  width: listFlick.width
                  spacing: Style.spacing.xs

                  Repeater {
                    model: widget.rows

                    delegate: Column {
                      id: entry
                      required property int index
                      required property var modelData

                      readonly property string rowId: String(modelData && modelData.id ? modelData.id : "")
                      readonly property bool onCursor: widget.cursorActive && widget.cursorIndex === entry.index

                      width: listColumn.width
                      spacing: Style.spacing.xs

                      PanelSectionHeader {
                        visible: text !== ""
                        width: parent.width
                        topPadding: (entry.index > 0 ? Style.spacing.lg : Style.spacing.xs)
                          + Math.ceil(fontSize * 0.15)
                        leftPadding: Style.spacing.rowPaddingX
                        elide: Text.ElideRight
                        text: widget.sectionFor(entry.index)
                        foreground: widget.foreground
                        fontFamily: widget.fontFamily
                      }

                      // ---- a habit row
                      HabitRow {
                        visible: widget.showingHabits
                        width: parent.width
                        habit: entry.modelData
                        hasCursor: entry.onCursor
                        foreground: widget.foreground
                        fontFamily: widget.fontFamily
                        onHovered: function (isHovered) { if (isHovered) widget.setCursor(entry.index, false) }
                        onCheckinRequested: tt.checkInHabit(entry.modelData)
                        onEditRequested: {
                          widget.openTools("Edit habit",["habit"],null)
                          managementPane.choose(entry.modelData)
                        }
                      }

                      // ---- a task row
                      TaskRow {
                        id: taskRow
                        visible: !widget.showingHabits
                        width: parent.width
                        task: entry.modelData
                        selectionMode:widget.selecting
                        selected:widget.selectedTasks.indexOf(entry.rowId)>=0
                        onSelectionRequested:widget.toggleSelection(entry.modelData)
                        expanded: widget.expandedId === entry.rowId
                        showProjectChip: widget.chipsUseful
                        showFocusAction: tt.showFocus
                        focusAvailable: !tt.focusActive && !tt.focusBusy
                        hasCursor: entry.onCursor
                        foreground: widget.foreground
                        fontFamily: widget.fontFamily
                        urgent: widget.urgent
                        onHovered: function (isHovered) { if (isHovered) widget.setCursor(entry.index, false) }
                        onFocusRequested: tt.startFocus(entry.modelData)
                        onStopwatchRequested: tt.startStopwatch(entry.modelData)
                        onCompleteRequested: widget.completeAt(entry.modelData)
                        onDeleteRequested: widget.requestDelete(entry.modelData)
                        onExpandRequested: { widget.setCursor(entry.index); widget.toggleExpanded(entry.rowId) }
                        onPriorityCycleRequested: widget.cyclePriority(entry.modelData)
                      }

                      // Built only while it is open. The pane is a whole task editor —
                      // four fields and three dropdowns — and exactly one row can be
                      // expanded at a time, so instantiating one per row would build
                      // hundreds of controls nobody is looking at.
                      Loader {
                        id: detailLoader
                        width: parent.width
                        active: !widget.showingHabits && widget.expandedId === entry.rowId
                        visible: active  // a Column lays out zero-height children otherwise

                        sourceComponent: TaskDetail {
                          width: detailLoader.width
                          task: entry.modelData
                          projects: tt.projects
                          expanded: true
                          foreground: widget.foreground
                          fontFamily: widget.fontFamily
                          onItemToggled: function (itemId, done) { tt.toggleItem(entry.modelData, itemId, done) }
                          onItemAdded: function (title) { tt.addItem(entry.modelData, title) }
                          onItemRemoved: function (itemId) { tt.removeItem(entry.modelData, itemId) }
                          onMoveRequested: function (projectId) { tt.moveToProject(entry.modelData, projectId) }
                          onDueRequested: function (when) { tt.setDue(entry.modelData, when) }
                          onStartRequested: function (when) { tt.setStart(entry.modelData, when) }
                          onTagsRequested: function (tags) { tt.setTags(entry.modelData, tags) }
                          onRepeatRequested: function (rule) { tt.setRepeat(entry.modelData, rule) }
                          onReminderRequested: function (spec) { tt.setReminder(entry.modelData, spec) }
                          onCommentsRequested: {
                            var task = entry.modelData
                            widget.openTools("Task comments",["comment"],task)
                          }
                          onAssignmentRequested:widget.openTools("Task assignee",["assignment"],entry.modelData)
                          // An open dropdown or a focused field owns j/k/Enter; tell the key
                          // catcher to stand down for as long as that is true.
                          onEditingChanged: {
                            widget.detailPickerOpen = editing
                            if (!editing) widget.reclaimKeys()
                          }
                          // Committing a change writes through Service *before* the control
                          // finishes closing, and that write replaces `tasks`, which rebuilds
                          // every delegate — so this handler is destroyed before it can report
                          // the close, and the catcher would stay deaf forever. The destructor
                          // still runs in a live context, so it is the falling edge.
                          Component.onDestruction: {
                            if (editing) {
                              widget.detailPickerOpen = false
                              widget.reclaimKeys()
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }

              // ---- the statistics dashboard
              //
              // Its own pane rather than a row list: a statistic is not something to act
              // on, so it gets no cursor, no checkbox and no detail pane. The numbers are
              // Service.stats, fetched on entering the view.
              Flickable {
                id: statsFlick
                objectName: "statsFlick"
                visible: tt.authed && widget.showingStats
                width: parent.width
                height: visible ? Math.max(0, mainColumn.height - paneHeader.implicitHeight
                  - paneRule.height
                  - (statusLine.visible ? statusLine.implicitHeight + mainColumn.spacing : 0)
                  - mainColumn.spacing * 3) : 0
                contentWidth: width
                contentHeight: statsPane.implicitHeight
                function scrollBy(amount) {
                  contentY = Math.max(0, Math.min(Math.max(0, contentHeight - height), contentY + amount))
                }
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick
                interactive: contentHeight > height
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                StatsPane {
                  id: statsPane
                  width: statsFlick.width
                  stats: tt.stats
                  loading: tt.statsLoading
                  error: tt.statsError
                  onRefreshRequested: tt.loadStats(true)
                  onReturnToPanel: keyCatcher.forceActiveFocus()
                  foreground: widget.foreground
                  fontFamily: widget.fontFamily
                }
              }

              Flickable {
                id: managementFlick
                visible: tt.authed && widget.showingManagement && !widget.settingsHome
                onVisibleChanged: if (visible) contentY=0
                width: parent.width
                height: visible ? Math.max(0, mainColumn.height - paneHeader.implicitHeight - paneRule.height
                  - (statusLine.visible ? statusLine.implicitHeight + mainColumn.spacing : 0) - mainColumn.spacing * 3) : 0
                contentWidth: width
                contentHeight: managementPane.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                ManagePane {
                  id: managementPane
                  width: parent.width
                  service: tt
                  contextual:true
                  contextResources:widget.contextResources
                  datesOnly: tt.view === "countdown"
                  foreground: widget.foreground
                  fontFamily: widget.fontFamily
                  onDatesOnlyChanged: if (datesOnly) load()
                  onEditingChanged: widget.detailPickerOpen = editing
                  onReturnToPanel: { if (tt.view === "manage") widget.closeTools(); else keyCatcher.forceActiveFocus() }
                }
              }

              Column {
                visible: tt.authed && tt.view === "manage" && widget.settingsHome
                width: parent.width
                spacing: Style.spacing.sm
                Button {
                  objectName: "settingsAccount"
                  text: I18n.tr("Account settings")
                  width: parent.width
                  leftAlign: true
                  foreground: widget.foreground
                  focusable: true
                  onClicked: widget.openSettingsSection("Account settings",["preference","revoke"])
                }
                Button {
                  objectName: "settingsLists"
                  text: I18n.tr("List settings")
                  width: parent.width
                  leftAlign: true
                  foreground: widget.foreground
                  focusable: true
                  onClicked: widget.openSettingsSection("List settings",["project","folder","tag","column"])
                }
              }

              Text {
                id: emptyState
                visible: tt.authed && tt.loaded && widget.rowCount === 0 && !widget.showingStats && !widget.showingManagement
                width: parent.width
                text: widget.showingHabits ? I18n.tr("No habits yet. Choose Add habit to get started.")
                    : tt.search !== "" ? I18n.tr("Nothing matches “") + Model.elide(tt.search, 30) + "”"
                    : (tt.priorityFilter >= 0 || tt.tagFilter !== "") ? I18n.tr("Nothing matches that filter")
                    : tt.view === "completed" ? I18n.tr("Nothing finished recently")
                    : "Nothing due. Enjoy it."
                color: widget.dim
                font.family: widget.fontFamily
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                topPadding: Style.spacing.lg
                bottomPadding: Style.spacing.lg
              }

              Text {
                id: statusLine
                visible: tt.authed && (tt.actionStatus !== "" || tt.errorText !== "")
                width: parent.width
                text: tt.actionStatus !== "" ? tt.actionStatus : tt.errorText
                color: tt.actionStatus !== "" ? widget.dim : widget.urgent
                font.family: widget.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              // ---- quick add, along the bottom of the list the way the app has it
              Item {
                id: quickAddBar
                // There is nothing to add to a dashboard, so the prompt goes with the
                // list verbs: out of the way until you are back on a task view.
                visible: !widget.showingStats && !widget.showingManagement
                width: parent.width
                implicitHeight: widget.adding ? quickAdd.implicitHeight : addPrompt.implicitHeight
                height: visible ? implicitHeight : 0

                Button {
                  id: addPrompt
                  visible: !widget.adding
                  leftAlign: true
                  width: parent.width
                  text: I18n.tr("＋  Add a task…")
                  bordered: false
                  foreground: widget.dim
                  fontFamily: widget.fontFamily
                  fontSize: Style.font.body
                  onClicked: widget.openAdd()
                }

                QuickAdd {
                  id: quickAdd
                  visible: widget.adding
                  anchors.top: parent.top
                  width: parent.width
                  service: tt
                  foreground: widget.foreground
                  fontFamily: widget.fontFamily
                  onSubmitted: function (text) {
                    tt.add(text)
                    widget.closeAdd()
                  }
                  onDismissed: widget.closeAdd()
                }
              }
            }
          }
        }

        // ================================================== signed out
        Column {
          id: signIn
          visible: !tt.authed
          anchors.fill: parent
          spacing: Style.spacing.rowGap

          PanelHero {
            width: parent.width
            title: "Dida 365"
            meta: widget.summary
            foreground: widget.foreground
            fontFamily: widget.fontFamily
            iconComponent: Component {
              Text {
                text: "󰄲"
                color: widget.foreground
                font.family: widget.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Item { width: 1; height: Style.spacing.sm }

          Text {
            width: parent.width
            text: I18n.tr("Connect your TickTick account to see your tasks here.")
            color: widget.dim
            font.family: widget.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // The browser flow leads: it is the one people expect from a "sign in"
          // button, and it needs nothing pasted. It opens a terminal of its own
          // because it is interactive — it may ask for a client id the first time,
          // and it waits on a redirect back to localhost.
          Button {
            width: parent.width
            text: I18n.tr("Sign in with browser")
            bordered: true
            foreground: widget.foreground
            fontFamily: widget.fontFamily
            onClicked: tt.signIn()
          }

          Text {
            visible: tt.authMessage !== ""
            width: parent.width
            text: tt.authMessage
            color: widget.urgent
            font.family: widget.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // The fallback, and the faster path for anyone who already has a token:
          // folded away until asked for, so the panel leads with one button.
          Button {
            visible: !widget.pastingToken
            width: parent.width
            text: I18n.tr("Paste an API token instead")
            bordered: false
            foreground: widget.dim
            fontFamily: widget.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: {
              widget.pastingToken = true
              Qt.callLater(function () { tokenField.forceActiveFocus() })
            }
          }

          Text {
            visible: widget.pastingToken
            width: parent.width
            text: I18n.tr("In the TickTick web app: avatar → Settings → Account → API Token.")
            color: widget.dim
            font.family: widget.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          TextField {
            id: tokenField
            visible: widget.pastingToken
            width: parent.width
            enabled: !tt.authBusy
            password: true
            placeholderText: tt.authBusy ? I18n.tr("Checking…") : I18n.tr("API token")
            foreground: widget.foreground
            font.family: widget.fontFamily
            onAccepted: {
              tt.signInWithToken(text)
              text = ""
            }
          }

          Button {
            visible: widget.pastingToken
            width: parent.width
            text: tt.authBusy ? I18n.tr("Connecting…") : I18n.tr("Connect")
            bordered: true
            foreground: widget.foreground
            fontFamily: widget.fontFamily
            onClicked: {
              tt.signInWithToken(tokenField.text)
              tokenField.text = ""
            }
          }
        }
      }

      ConfirmDialog {
        id: confirmDialog
        anchors.fill: parent
        z: 10
        opened: widget.confirmOpen
        message: widget.confirmTask
          ? I18n.tr("Delete “") + Model.elide(widget.confirmTask.title, 42) + I18n.tr("”?\nThis cannot be undone.")
          : ""
        confirmText: "Delete"
        cancelText: "Keep"
        foreground: widget.foreground
        fontFamily: widget.fontFamily
        onCanceled: widget.cancelDelete()
        onConfirmed: widget.confirmDeleteNow()
      }
    }
  }
}
