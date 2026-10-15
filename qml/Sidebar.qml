import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The left navigation pane, modelled on the Dida365 sidebar: the smart lists with
// their live counts, then the user's own lists grouped under their folders, then
// Habits and Done, with the focus timer pinned to the bottom.
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
  property int sidebarWidth: Style.space(188)

  // Index into `navItems` that the keyboard is on. Headers are never selectable, so
  // this only ever points at a view or a list; `cursorActive` is whether to paint it.
  property int cursorIndex: -1
  property bool cursorActive: false

  signal viewSelected(string value)
  signal projectSelected(string projectId)
  signal searchEdited(string text)
  signal searchCancelled()

  readonly property string currentView: root.service ? root.service.view : "today"
  readonly property string projectFilter: root.service ? root.service.projectFilter : ""
  readonly property color dim: Qt.darker(foreground, 1.6)
  readonly property string searchGlyph: "󰍉"

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
      var gid = String(project.groupId || "")
      if (gid !== "" && gid !== lastGroup) {
        out.push({ kind: "header", key: "h:" + gid, label: root.groupNameOf(project).toUpperCase() })
      }
      lastGroup = gid
      out.push({
        kind: "project",
        key: "p:" + String(project.id || ""),
        id: String(project.id || ""),
        name: Model.squish(project.name) || "Untitled",
        count: Model.toInt(project.count)
      })
    }
    return out
  }

  // The single ordered list the Repeater paints and the cursor walks: the five smart
  // lists, then the user's lists under their folders, then Habits and Done. Headers
  // are entries too — they take a slot in the layout — but the cursor steps over them.
  readonly property var navItems: {
    var c = (root.service && root.service.counts) || {}
    var out = [
      { kind: "view", key: "v:today", value: "today", label: "Today", glyph: "󰃭",
        count: Model.toInt(c.overdue) + Model.toInt(c.today) },
      { kind: "view", key: "v:tomorrow", value: "tomorrow", label: "Tomorrow", glyph: "󰃮",
        count: Model.toInt(c.tomorrow) },
      { kind: "view", key: "v:next", value: "next", label: "Next 7", glyph: "󰃶",
        count: Model.toInt(c.upcoming) },
      { kind: "view", key: "v:inbox", value: "inbox", label: "Inbox", glyph: "󰆳",
        count: root.inboxCount() },
      { kind: "view", key: "v:all", value: "all", label: "All", glyph: "󰉸",
        count: Model.toInt(c.total) },
      { kind: "header", key: "h:lists", label: "LISTS" }
    ]
    var rows = root.projectRows
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      if (row.kind === "header") out.push({ kind: "header", key: row.key, label: row.label })
      else out.push({ kind: "project", key: row.key, id: row.id, label: row.name, count: row.count })
    }
    out.push({ kind: "header", key: "h:other", label: "OTHER" })
    if (root.showHabits) {
      out.push({ kind: "view", key: "v:habits", value: "habits", label: "Habits", glyph: "󰑓",
        count: root.service ? Model.toInt(root.service.habitBadge) : 0 })
    }
    if (root.showStats) {
      out.push({ kind: "view", key: "v:stats", value: "stats", label: "Stats", glyph: "󰄨",
        count: 0 })
    }
    out.push({ kind: "view", key: "v:completed", value: "completed", label: "Done", glyph: "󰄲",
      count: 0 })
    return out
  }

  function projectIsCurrent(id) {
    return root.currentView === "project" && String(root.projectFilter) === String(id)
  }

  function isCurrent(item) {
    if (!item || item.kind === "header") return false
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

    Row {
      id: searchRow
      width: parent.width
      spacing: Style.spacing.sm

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.searchGlyph
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      TextField {
        id: searchField
        width: Math.max(0, parent.width - root.searchGlyph.length * Style.font.bodySmall * 0.7)
        placeholderText: "Search"
        foreground: root.foreground
        accent: root.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        verticalPadding: Style.spacing.sm
        text: root.service ? root.service.search : ""
        onTextEdited: root.searchEdited(text)
        onAccepted: root.searchCancelled()
        Keys.onEscapePressed: root.searchCancelled()
      }
    }

    Flickable {
      id: navFlick
      width: parent.width
      height: Math.max(0, column.height - searchRow.height - focusCard.height
        - column.spacing * (focusCard.visible ? 2 : 1))
      contentWidth: width
      contentHeight: navColumn.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height
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
            implicitHeight: isHeader ? (navHeader.implicitHeight + Style.spacing.md)
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
              width: parent.width
              glyph: navEntry.isHeader ? ""
                : String(modelData.glyph || (modelData.kind === "project" ? "󰉋" : ""))
              label: navEntry.isHeader ? "" : String(modelData.label || modelData.name || "")
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
            visible: root.service && !root.service.focusActive
            iconText: "󰐊"
            tooltipText: "Start focus"
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
            tooltipText: "Pause"
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
            tooltipText: "Resume"
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
            visible: root.service && root.service.focusActive
            iconText: "󰓛"
            tooltipText: "Discard this block without recording it"
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
        width: parent.width
        wrapMode: Text.WordWrap
        text: root.service && root.service.focusActive
          ? (Model.focusPhaseLabel((root.service.focusState || {}).phase)
             + (root.service.focusPaused ? " · paused" : "")
             + (root.service.focusBlocksDone > 0 ? " · " + root.service.focusBlocksDone + " done" : ""))
          : Model.focusPrefsLabel((root.service.focusState || {}).prefs)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        visible: root.service && String((root.service.focusState || {}).taskId || "") !== ""
        width: parent.width
        text: visible ? (Model.squish((root.service.focusState || {}).taskTitle) || "Linked task") : ""
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        width: parent.width
        text: root.service ? Model.focusTallyLabel(root.service.focusTally) : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }
}
