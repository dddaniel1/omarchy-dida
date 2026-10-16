import QtQuick
import "I18n.js" as I18n
import QtQuick.Controls
import QtCore
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Task views, collapsible user lists and tools, with focus and settings pinned below.
//
// It owns no task state — everything is read from `service` and every choice is a
// signal. It does own its own *cursor*, though: the row the keyboard is on while the
// panel's focus is in the sidebar. The panel moves it with `moveCursor(±1)` and
// commits it with `activateCurrent()`; the task pane keeps its own cursor, and only
// one of the two is ever shown because the panel clears the other's when focus flips.
Item {
  id: root

  property var service: null
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property bool showHabits: true
  property bool showStats: true
  Settings {
    id: navigationPrefs
    location: "file://" + StandardPaths.writableLocation(StandardPaths.GenericConfigLocation) + "/dida-sidebar.ini"
    property bool toolsExpanded: false
    property bool focusExpanded: false
    property string collapsedFolders: "[]"
  }

  function folderCollapsed(id) {
    try { return JSON.parse(navigationPrefs.collapsedFolders).indexOf(id) >= 0 }
    catch (error) { return false }
  }

  function revealCurrent() {
    if (root.currentView === "habits" || root.currentView === "countdown") navigationPrefs.toolsExpanded = true
    if (root.currentView === "stats") {
      navigationPrefs.focusExpanded = true
      if (!(root.service && root.service.showFocus)) navigationPrefs.toolsExpanded = true
    }
    if (root.currentView === "project") {
      var projects = root.service ? root.service.projects || [] : []
      for (var i = 0; i < projects.length; i++) {
        if (String(projects[i].id) === root.projectFilter && root.folderCollapsed(String(projects[i].groupId || "")))
          root.toggleSection(String(projects[i].groupId))
      }
    }
  }
  onCurrentViewChanged: revealCurrent()
  onProjectFilterChanged: revealCurrent()
  Component.onCompleted: revealCurrent()

  function toggleSection(section) {
    if (section === "tools") navigationPrefs.toolsExpanded = !navigationPrefs.toolsExpanded
    else {
      var folders = []
      try { folders = JSON.parse(navigationPrefs.collapsedFolders) } catch (error) {}
      var at = folders.indexOf(section)
      if (at < 0) folders.push(section)
      else folders.splice(at, 1)
      navigationPrefs.collapsedFolders = JSON.stringify(folders)
    }
    root.cursorIndex = root.navItems.findIndex(function(item) { return item.section === section })
  }
  readonly property var viewOrder: {
    var out = [
      { value: "today", label: I18n.tr("Today"), glyph: "󰃭" },
      { value: "inbox", label: I18n.tr("Inbox"), glyph: "󰆳" },
      { value: "next", label: I18n.tr("Next 7 days"), glyph: "󰃶" },
      { value: "all", label: I18n.tr("All tasks"), glyph: "󰉸" },
      { value: "completed", label: I18n.tr("Done"), glyph: "󰄲" }
    ]
    if (showHabits) out.push({ value: "habits", label: I18n.tr("Habits"), glyph: "󰑓" })
    out.push({ value: "countdown", label: I18n.tr("Dates"), glyph: "󰃭" })
    return out
  }
  property int sidebarWidth: Style.space(188)

  // Index into `navItems` that the keyboard is on. Headers are never selectable, so
  // this only ever points at a view or a list; `cursorActive` is whether to paint it.
  property int cursorIndex: -1
  property bool cursorActive: false

  signal viewSelected(string value)
  signal projectSelected(string projectId)
  signal searchEdited(string text)
  signal searchCancelled()
  signal organizeRequested()
  signal focusHistoryRequested()
  signal settingsRequested()

  readonly property string currentView: root.service ? root.service.view : "today"
  readonly property string projectFilter: root.service ? root.service.projectFilter : ""
  readonly property color dim: Qt.darker(foreground, 1.6)
  readonly property string searchGlyph: "󰍉"
  // The resolved focus durations. They belong to the start button's tooltip: the card
  // itself prints them only while a block is running, so idle it is a control and a
  // label rather than a settings readout.
  readonly property string focusPrefsText: Model.focusPrefsLabel(
    (root.service && root.service.focusState) ? root.service.focusState.prefs : null)

  width: sidebarWidth
  implicitWidth: sidebarWidth

  function focusSearch() {
    searchField.forceActiveFocus()
    searchField.selectAll()
  }

  function clearSearch() {
    searchField.text = ""
    root.searchEdited("")
  }

  readonly property bool searchFocused: searchField.activeFocus

  function isProjectView() {
    return root.currentView === "project"
  }

  // ---- the list of lists --------------------------------------------------
  //
  // Folders are shown the way TickTick files them: loose lists first (the Inbox is
  // one), then each folder with its lists together. A folder the catalogue does not
  // name sorts last rather than first, which an unranked 0 would have done.

  function groupRankOf(project) {
    var gid = String((project || {}).groupId || "")
    if (gid === "") return -1
    var list = (root.service && root.service.groups) || []
    for (var i = 0; i < list.length; i++) {
      if (String(list[i].id || "") === gid) return i
    }
    return 1e6
  }

  function groupNameOf(project) {
    var gid = String((project || {}).groupId || "")
    if (gid === "") return "Lists"
    var list = (root.service && root.service.groups) || []
    for (var i = 0; i < list.length; i++) {
      if (String(list[i].id || "") === gid) return Model.squish(list[i].name) || "Folder"
    }
    return "Folder"
  }

  readonly property var sortedProjects: {
    var list = (root.service && root.service.projects) || []
    // Decorated with the original index so lists inside one folder keep the order
    // TickTick gave them — the Inbox leading the list is not negotiable.
    var decorated = []
    for (var i = 0; i < list.length; i++) decorated.push({ project: list[i], at: i })
    decorated.sort(function (a, b) {
      var ra = root.groupRankOf(a.project)
      var rb = root.groupRankOf(b.project)
      return ra !== rb ? ra - rb : a.at - b.at
    })
    var out = []
    for (var j = 0; j < decorated.length; j++) out.push(decorated[j].project)
    return out
  }

  // A flat model of headers and list rows, so one Repeater can paint the tree.
  readonly property var projectRows: {
    var out = []
    var list = root.sortedProjects
    var lastGroup = null
    for (var i = 0; i < list.length; i++) {
      var project = list[i]
      // The Inbox is drawn once, up with the smart lists. The catalogue synthesises
      // it as a project as well, so painting every project printed "Inbox" twice
      // with the same count. Real project ids are hex and `inbox<userId>` is
      // TickTick's only prefixed id, the same test `inboxCount` already makes.
      if (String(project.id || "").indexOf("inbox") === 0) continue
      var gid = String(project.groupId || "")
      if (gid !== "" && gid !== lastGroup) {
        out.push({ kind: "section", key: "h:" + gid, section: gid, expanded: !root.folderCollapsed(gid), label: root.groupNameOf(project) })
      }
      lastGroup = gid
      if (gid !== "" && root.folderCollapsed(gid)) continue
      out.push({
        kind: "project",
        key: "p:" + String(project.id || ""),
        id: String(project.id || ""),
        nested: gid !== "",
        name: Model.squish(project.name) || "Untitled",
        count: Model.toInt(project.count)
      })
    }
    return out
  }

  // Rendering and keyboard traversal share the visible rows; only static headings
  // are skipped, while disclosures can be activated with Enter.
  readonly property var navItems: {
    var c = (root.service && root.service.counts) || {}
    var counts = { today: Model.toInt(c.overdue) + Model.toInt(c.today),
      tomorrow: Model.toInt(c.tomorrow), next: Model.toInt(c.upcoming),
      inbox: root.inboxCount(), all: Model.toInt(c.total),
      habits: root.service ? Model.toInt(root.service.habitBadge) : 0,
      countdown: root.service ? Model.toInt(root.service.countdownCount) : 0 }
    var out = [{ kind: "header", key: "tasks", label: I18n.tr("TASKS") }]
    for (var v = 0; v < root.viewOrder.length; v++) {
      var view = root.viewOrder[v]
      if (view.value === "habits" || view.value === "countdown") continue
      out.push({ kind: "view", key: "v:" + view.value, value: view.value,
        label: view.label, glyph: view.glyph, shortcut: "1234567890".charAt(v), count: counts[view.value] || 0 })
    }
    out.push({kind:"header",key:"lists-gap",label:""})
    var rows = root.projectRows
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      if (row.kind === "section") out.push(row)
      else out.push({ kind: "project", key: row.key, id: row.id, label: row.name, count: row.count, nested: row.nested })
    }
    out.push({kind:"section",key:"tools",section:"tools",label:I18n.tr("Tools"),expanded:navigationPrefs.toolsExpanded})
    if (navigationPrefs.toolsExpanded) {
      for (var t = 0; t < root.viewOrder.length; t++) {
        var tool = root.viewOrder[t]
        if (tool.value === "habits" || tool.value === "countdown")
          out.push({kind:"view",key:"v:"+tool.value,value:tool.value,label:tool.label,glyph:tool.glyph,count:counts[tool.value] || 0,shortcut:"1234567890".charAt(t)})
      }
      if (root.showStats && !(root.service && root.service.showFocus))
        out.push({kind:"view",key:"v:stats",value:"stats",label:I18n.tr("Statistics"),glyph:"󰄨"})
    }
    return out
  }

  function projectIsCurrent(id) {
    return root.currentView === "project" && String(root.projectFilter) === String(id)
  }

  function isCurrent(item) {
    if (!item || item.kind === "header") return false
    if (item.kind === "action") return false
    if (item.kind === "project") return root.projectIsCurrent(item.id)
    return root.currentView === item.value && !root.isProjectView()
  }

  function selectable(i) {
    return i >= 0 && i < root.navItems.length && root.navItems[i].kind !== "header"
  }

  // Where the cursor wants to be when the keyboard enters the sidebar: the current
  // view or list, or the first row if neither is on screen.
  function indexOfCurrent() {
    var items = root.navItems
    for (var i = 0; i < items.length; i++) {
      if (root.isCurrent(items[i])) return i
    }
    for (var j = 0; j < items.length; j++) {
      if (root.selectable(j)) return j
    }
    return -1
  }

  function ensureCursor() {
    if (!root.selectable(root.cursorIndex)) root.cursorIndex = root.indexOfCurrent()
  }

  // Step over headers; clamp at the ends rather than wrapping, so holding a key does
  // not silently loop the highlight.
  function moveCursor(delta) {
    var items = root.navItems
    if (items.length === 0) { root.cursorIndex = -1; return }
    var step = delta > 0 ? 1 : -1
    var i = root.selectable(root.cursorIndex) ? root.cursorIndex : (step > 0 ? -1 : items.length)
    for (var k = 0; k < items.length; k++) {
      i += step
      if (i < 0 || i >= items.length) return
      if (items[i].kind !== "header") { root.cursorIndex = i; return }
    }
  }

  function activateAt(index) {
    var item = root.navItems[index]
    if (!item || item.kind === "header") return
    if (item.kind === "section") { root.toggleSection(item.section); return }
    if (item.kind === "action") {
      if (item.action === "history") root.focusHistoryRequested()
      else root.organizeRequested()
      return
    }
    if (item.kind === "project") root.projectSelected(item.id)
    else root.viewSelected(item.value)
  }

  function activateCurrent() {
    root.activateAt(root.cursorIndex)
  }

  // The Inbox count is not in the bucket counts: `/task/filter` counts by date, so
  // the number comes from the Inbox entry the catalogue synthesises.
  function inboxCount() {
    var list = (root.service && root.service.projects) || []
    for (var i = 0; i < list.length; i++) {
      if (String(list[i].id || "").indexOf("inbox") === 0) return Model.toInt(list[i].count)
    }
    return 0
  }

  // ---- the nav row --------------------------------------------------------
  //
  // Selected rows paint the kit's `selected` fill (CursorSurface `current`); the
  // keyboard cursor and mouse hover both paint the shared hover fill, so the sidebar
  // shows exactly one highlight whether it was reached by key or pointer.

  component NavItem: CursorSurface {
    id: navItem

    property string glyph: ""
    property string label: ""
    property string trailing: ""
    property string shortcut: ""
    property bool active: false
    property bool keyboardCursor: false
    property color navForeground: Color.foreground
    property color navDim: Qt.darker(navForeground, 1.6)
    property string navFontFamily: Style.font.family

    signal chosen()

    width: parent ? parent.width : implicitWidth
    implicitHeight: Style.spacing.popupRowHeight
    height: implicitHeight
    radius: Style.cornerRadius
    foreground: navItem.navForeground
    hasCursor: navMouse.containsMouse || navItem.keyboardCursor
    current: navItem.active

    MouseArea {
      id: navMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: navItem.chosen()
    }

    Text {
      id: navGlyph
      visible: navItem.glyph !== ""
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.controlGap
      anchors.verticalCenter: parent.verticalCenter
      text: navItem.glyph
      color: navItem.active ? navItem.navForeground : navItem.navDim
      font.family: navItem.navFontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      id: navTrailing
      visible: navItem.trailing !== ""
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.controlPaddingX
      anchors.verticalCenter: parent.verticalCenter
      text: navItem.trailing
      color: navItem.navDim
      font.family: navItem.navFontFamily
      font.pixelSize: Style.font.caption
    }

    PanelToolTip {
      visible: navMouse.containsMouse && navItem.shortcut !== ""
      text: navItem.label + I18n.tr(" · Press ") + navItem.shortcut
    }

    Text {
      anchors.left: navGlyph.visible ? navGlyph.right : parent.left
      anchors.leftMargin: Style.spacing.controlGap
      anchors.right: navTrailing.left
      anchors.rightMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      text: navItem.label
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: navItem.active ? navItem.navForeground : Qt.darker(navItem.navForeground, 1.2)
      font.family: navItem.navFontFamily
      font.pixelSize: Style.font.body
      font.bold: navItem.active
    }
  }

  Column {
    id: column
    anchors.fill: parent
    spacing: Style.spacing.md

    Item {
      id: searchRow
      width: parent.width
      height: searchField.implicitHeight

      TextField {
        id: searchField
        width: parent.width
        objectName: "sidebarSearch"
        leftPadding: searchIcon.x + searchIcon.width + Style.spacing.sm
        placeholderText: I18n.tr("Search")
        foreground: root.foreground
        accent: root.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        verticalPadding: Style.spacing.sm
        text: root.service ? root.service.search : ""
        onTextEdited: root.searchEdited(text)
        onAccepted: root.searchCancelled()
        Keys.onEscapePressed: root.searchCancelled()
        Text {
          id: searchIcon
          objectName: "sidebarSearchIcon"
          x: searchField.horizontalPadding
          anchors.verticalCenter: parent.verticalCenter
          text: root.searchGlyph
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }

    Item {
      id: navArea
      width: parent.width
      height: Math.max(0, column.height - searchRow.height - settingsRow.height
        - (focusCard.visible ? focusCard.height : 0)
        - column.spacing * (focusCard.visible ? 3 : 2))

      Flickable {
        id: navFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: navColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        // Kept because it is the shell's own convention, but a `ScrollBar` draws
        // nothing in Quickshell — verified with the policy forced to AlwaysOn — which
        // is why the nav has an indicator of its own below.
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: navColumn
          width: navFlick.width
          spacing: Style.spacing.xxs

          Repeater {
            model: root.navItems

            delegate: Item {
              id: navEntry
              required property int index
              required property var modelData

              readonly property bool isHeader: modelData.kind === "header"

              width: navColumn.width
                implicitHeight: isHeader ? (modelData.label === "" ? Style.spacing.md : navHeader.implicitHeight + Style.spacing.md)
                                       : navRow.implicitHeight
              height: implicitHeight

              Text {
                id: navHeader
                visible: navEntry.isHeader
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.controlGap
                anchors.bottom: parent.bottom
                text: navEntry.isHeader ? String(modelData.label || "") : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              NavItem {
                id: navRow
                visible: !navEntry.isHeader
                x: modelData.nested ? Style.space(14) : 0
                width: parent.width - x
                objectName: "sidebar-" + modelData.key
                glyph: navEntry.isHeader ? ""
                  : modelData.kind === "section" ? (modelData.expanded ? "󰅀" : "󰅂")
                  : String(modelData.glyph || (modelData.kind === "project" ? "󰉋" : ""))
                label: navEntry.isHeader ? "" : String(modelData.label || modelData.name || "")
                shortcut: String(modelData.shortcut || "")
                trailing: (!navEntry.isHeader && Model.toInt(modelData.count) > 0)
                  ? String(Model.toInt(modelData.count)) : ""
                active: !navEntry.isHeader && root.isCurrent(modelData)
                keyboardCursor: root.cursorActive && root.cursorIndex === navEntry.index
                navForeground: root.foreground
                navFontFamily: root.fontFamily
                onChosen: root.activateAt(navEntry.index)
              }
            }
          }
        }
      }

      // The nav list used to clip silently: the row at the fold was simply cut in
      // half with nothing to say the list kept going. This is the smallest thing that
      // says it — a thumb on the right edge, drawn only while the list overflows, in
      // the padding the row counts already leave empty. It takes no height, so it
      // clips nothing that was not clipped before.
      Item {
        id: navScrollbar

        visible: navFlick.contentHeight > navFlick.height

        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: Style.space(3)

        Rectangle {
          width: parent.width
          radius: width / 2
          color: root.dim
          // Thumb size is the fraction of the list on screen; its travel is the rest.
          height: Math.max(Style.space(14),
                           navFlick.height * navFlick.height / Math.max(1, navFlick.contentHeight))
          y: {
            var travel = navFlick.contentHeight - navFlick.height
            var room = navFlick.height - height
            return travel > 0 ? Math.max(0, room * (navFlick.contentY / travel)) : 0
          }
        }
      }
    }

    // ---- focus timer ------------------------------------------------------
    //
    // A pomodoro is not a list: it is a clock that keeps running while you look at
    // something else, so it lives outside the scroll and outside the task pane.
    Column {
      id: focusCard
      visible: root.service && root.service.showFocus && root.service.authed
      width: parent.width
      spacing: Style.spacing.xs

      PanelSeparator { foreground: root.foreground }

      Item {
        width: parent.width
        implicitHeight: Math.max(focusClockText.implicitHeight, focusButtons.implicitHeight)

        Text {
          id: focusClockText
          anchors.left: parent.left
          anchors.right: focusButtons.left
          anchors.rightMargin: Style.spacing.sm
          anchors.verticalCenter: parent.verticalCenter
          elide: Text.ElideRight
          text: root.service && root.service.focusActive
            ? root.service.focusClockText
            : Model.focusPhaseLabel("focus")
          color: root.service && root.service.focusActive ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
        }

        Row {
          id: focusButtons
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.xxs

          Button {
            objectName: "sidebarFocusMore"
            text: "⋯"
            tooltipText: I18n.tr("Focus history and statistics")
            width: Style.space(26)
            horizontalPadding: 0
            foreground: root.foreground
            focusable: true
            onClicked: navigationPrefs.focusExpanded = !navigationPrefs.focusExpanded
          }

          Button {
            visible:root.service && !root.service.focusActive
            iconText:"󱎫"
            tooltipText:I18n.tr("Start stopwatch")
            width:Style.space(26)
            height:Style.space(26)
            horizontalPadding:0
            verticalPadding:0
            foreground:root.foreground
            fontFamily:root.fontFamily
            focusable:true
            onClicked:root.service.startStopwatch()
          }

          Button {
            visible: root.service && !root.service.focusActive
            iconText: "󰐊"
            tooltipText: I18n.tr("Start focus — ") + root.focusPrefsText
            width: Style.space(26)
            height: Style.space(26)
            horizontalPadding: 0
            verticalPadding: 0
            iconSize: Style.font.body
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.service.startFocus()
          }

          Button {
            visible: root.service && root.service.focusRunning
            iconText: "󰏤"
            tooltipText: I18n.tr("Pause")
            width: Style.space(26)
            height: Style.space(26)
            horizontalPadding: 0
            verticalPadding: 0
            iconSize: Style.font.body
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.service.pauseFocus()
          }

          Button {
            visible: root.service && root.service.focusPaused
            iconText: "󰐊"
            tooltipText: I18n.tr("Resume")
            width: Style.space(26)
            height: Style.space(26)
            horizontalPadding: 0
            verticalPadding: 0
            iconSize: Style.font.body
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.service.resumeFocus()
          }

          Button {
            visible: root.service && root.service.focusTiming && root.service.focusActive
            text: I18n.tr("Save")
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.service.completeFocus()
          }

          Button {
            visible: root.service && root.service.focusActive
            iconText: "󰓛"
            tooltipText: I18n.tr("Discard this block without recording it")
            width: Style.space(26)
            height: Style.space(26)
            horizontalPadding: 0
            verticalPadding: 0
            iconSize: Style.font.body
            foreground: root.dim
            fontFamily: root.fontFamily
            onClicked: root.service.stopFocus()
          }
        }
      }

      Text {
        // Status, not configuration: phase, whether it is paused, and how many blocks
        // this session has finished. Idle the card prints none of it, which is what
        // used to leave the durations sitting there as a permanent settings readout.
        visible: root.service && root.service.focusActive
        width: parent.width
        wrapMode: Text.WordWrap
        text: Model.focusPhaseLabel((root.service.focusState || {}).phase)
          + (root.service.focusPaused ? I18n.tr(" · paused") : "")
          + (root.service.focusBlocksDone > 0 ? " · " + root.service.focusBlocksDone + I18n.tr(" done") : "")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      NavItem {
        visible: navigationPrefs.focusExpanded
        objectName: "sidebarFocusHistory"
        label: I18n.tr("Focus history")
        glyph: "󰥔"
        navForeground: root.foreground
        navFontFamily: root.fontFamily
        activeFocusOnTab: true
        keyboardCursor: activeFocus
        Keys.onReturnPressed: root.focusHistoryRequested()
        Keys.onSpacePressed: root.focusHistoryRequested()
        onChosen: root.focusHistoryRequested()
      }
      NavItem {
        visible: navigationPrefs.focusExpanded && root.showStats
        objectName: "sidebarStats"
        label: I18n.tr("Statistics")
        glyph: "󰄨"
        navForeground: root.foreground
        navFontFamily: root.fontFamily
        active: root.currentView === "stats"
        activeFocusOnTab: true
        keyboardCursor: activeFocus
        Keys.onReturnPressed: root.viewSelected("stats")
        Keys.onSpacePressed: root.viewSelected("stats")
        onChosen: root.viewSelected("stats")
      }

      Text {
        visible: root.service && String((root.service.focusState || {}).taskId || "") !== ""
        width: parent.width
        text: visible ? (Model.squish((root.service.focusState || {}).taskTitle) || I18n.tr("Linked task")) : ""
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        // Today's totals, alongside the block that produced them. Idle, a day's focus
        // minutes are the Stats view's business, and "0 blocks" was just noise.
        visible: root.service && root.service.focusActive
        width: parent.width
        text: root.service ? Model.focusTallyLabel(root.service.focusTally) : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    NavItem {
      id:settingsRow
      objectName:"sidebarSettings"
      width:parent.width
      label:I18n.tr("Settings")
      glyph:"󰒓"
      navForeground:root.foreground
      navFontFamily:root.fontFamily
      activeFocusOnTab:true
      keyboardCursor:activeFocus
      Keys.onReturnPressed:root.settingsRequested()
      Keys.onSpacePressed:root.settingsRequested()
      onChosen:root.settingsRequested()
    }
  }
}
