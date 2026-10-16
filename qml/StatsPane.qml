import QtQuick
import "I18n.js" as I18n
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Account arithmetic lives in Python; this pane only arranges its results.
Item {
  id: root
  objectName: "statsPane"
  property var stats: ({})
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property bool loading: false
  property string error: ""
  signal refreshRequested()
  signal returnToPanel()
  property bool calendarFocus: false

  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.82)
  readonly property color track: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)
  readonly property bool loaded: Boolean(stats && stats.summary)
  readonly property bool historyAvailable: loaded && stats.historyAvailable !== false
  readonly property var summary: loaded ? stats.summary : ({})
  readonly property var dist: stats.distribution || ({})
  readonly property var lists: Model.asList(dist.byList)
  readonly property var tags: Model.asList(dist.byTag)
  readonly property var priorities: Model.asList(dist.byPriority)
  readonly property var heatmap: stats.heatmap || ({})
  readonly property var weeks: Model.asList(heatmap.weeks)
  readonly property var trend: groupedTrend()
  readonly property bool compact: width < Style.space(370)
  property int selectedDay: 0
  property string hoverDay: ""
  readonly property var calendarDays: Model.asList(heatmap.days)
  readonly property string dayDetail: hoverDay || describeDay(calendarDays[selectedDay])
  implicitHeight: body.implicitHeight
  function inspectCalendar() {
    if (calendarDays.length) dayCells.itemAt(selectedDay).forceActiveFocus()
  }
  function releaseCalendar() {
    calendarFocus = false
    returnToPanel()
  }

  function describeDay(day) {
    if (!day) return I18n.tr("Select a date to inspect activity.")
    return day.date + (day.isFuture ? I18n.tr(" · future") : " · " + day.count + I18n.tr(" completed"))
  }
  function groupedTrend() {
    var days = Model.asList(stats.trend)
    if (days.length <= 14) return days
    var out = []
    for (var i = 0; i < days.length; i += 7) {
      var end = Math.min(i + 6, days.length - 1), count = 0
      for (var j = i; j <= end; j++) count += Model.toInt(days[j].count)
      out.push({ date: days[i].date, endDate: days[end].date, count: count })
    }
    return out
  }
  function peak() {
    var result = 1
    for (var i = 0; i < trend.length; i++) result = Math.max(result, Model.toInt(trend[i].count))
    return result
  }
  function rangeLabel() {
    var days = Model.asList(stats.trend)
    return days.length && days[0].date ? days[0].date + " – " + days[days.length - 1].date : ""
  }

  component Copy: Text {
    width: parent.width
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    Accessible.role: Accessible.StaticText
    Accessible.name: text
  }
  component Heading: Copy {
    color: root.foreground
    font.pixelSize: Style.font.subtitle
    font.bold: true
  }
  component Metric: Column {
    property string label: ""
    property string value: "0"
    property color valueColor: root.foreground
    spacing: Style.spacing.xxs
    Copy { text: parent.label }
    Copy { text: parent.value; color: parent.valueColor; font.pixelSize: Style.font.title; font.bold: true }
  }
  component DistributionRow: Column {
    id: entry
    property string label: ""
    property string value: ""
    property real ratio: 0
    property color fill: Color.accent
    width: parent.width
    spacing: Style.spacing.xxs
    Row {
      width: parent.width
      spacing: Style.spacing.sm
      Copy { width: Math.max(0, parent.width - amount.width - parent.spacing); text: entry.label; color: root.foreground }
      Copy { id: amount; width: implicitWidth; text: entry.value }
    }
    Rectangle {
      width: parent.width; height: Style.space(5); color: root.track
      Rectangle { width: parent.width * Math.max(0, Math.min(1, entry.ratio)); height: parent.height; color: entry.fill }
    }
    Accessible.role: Accessible.StaticText
    Accessible.name: label + ": " + value
  }

  Column {
    id: body
    width: parent.width
    spacing: Style.spacing.lg

    Column {
      width: parent.width
      spacing: Style.spacing.xs
      Row {
        width: parent.width
        spacing: Style.spacing.sm
        Copy {
          width: Math.max(0, parent.width - refreshButton.width - parent.spacing)
          text: root.loading ? I18n.tr("Updating statistics…") : root.loaded
            ? I18n.tr("Updated ") + Qt.formatDateTime(new Date(root.stats.generated), "MMM d, hh:mm")
              + (root.stats.source === "cache" ? I18n.tr(" · cached tasks") : "")
            : root.error ? I18n.tr("Statistics unavailable") : I18n.tr("Gathering your statistics…")
        }
        Button {
          id: refreshButton
          text: root.loading ? I18n.tr("Updating…") : root.error ? I18n.tr("Retry") : I18n.tr("Refresh")
          enabled: !root.loading
          onClicked: root.refreshRequested()
          Accessible.name: text + " statistics"
        }
      }
      Copy { visible: root.error !== ""; text: root.error + (root.loaded ? I18n.tr(" Available figures are shown below.") : I18n.tr(" Select Retry to try again.")); color: root.foreground }
    }

    Grid {
      visible: root.loaded
      width: parent.width
      columns: root.compact ? 2 : 4
      columnSpacing: Style.spacing.md
      rowSpacing: Style.spacing.md
      Metric { width: (parent.width - (parent.columns - 1) * parent.columnSpacing) / parent.columns; label: I18n.tr("Completed · ") + Model.toInt(root.stats.days) + I18n.tr(" days"); value: root.historyAvailable ? String(Model.toInt(root.summary.completed)) : "—"; valueColor: Color.accent }
      Metric { width: (parent.width - (parent.columns - 1) * parent.columnSpacing) / parent.columns; label: I18n.tr("Open tasks"); value: String(Model.toInt(root.summary.open)) }
      Metric { width: (parent.width - (parent.columns - 1) * parent.columnSpacing) / parent.columns; label: I18n.tr("Overdue"); value: String(Model.toInt(root.summary.overdue)); valueColor: Model.toInt(root.summary.overdue) > 0 ? Color.urgent : root.foreground }
      Metric { width: (parent.width - (parent.columns - 1) * parent.columnSpacing) / parent.columns; label: I18n.tr("Due today"); value: String(Model.toInt(root.summary.today)) }
    }

    Copy {
      visible: root.loaded && root.historyAvailable && Model.toInt(root.summary.open) === 0 && Model.toInt(root.heatmap.total) === 0
      text: I18n.tr("No task activity yet. Add a task from a task view; completed tasks will appear here.")
    }
    Copy { visible: root.loaded && !root.historyAvailable; text: I18n.tr("Completion history is unavailable. Refresh when connected to load the trend and calendar.") }

    Column {
      visible: root.loaded && root.historyAvailable && root.trend.length > 0
      width: parent.width
      spacing: Style.spacing.sm
      Heading { text: I18n.tr("Completed · last ") + Model.toInt(root.stats.days) + I18n.tr(" days") }
      Copy { text: root.rangeLabel() + (Model.toInt(root.stats.days) > 14 ? I18n.tr(" · grouped by week") : "") }
      Row {
        id: trendRow
        width: parent.width
        Repeater {
          model: root.trend
          delegate: Item {
            required property var modelData
            required property int index
            width: trendRow.width / Math.max(1, root.trend.length)
            height: Style.space(110)
            readonly property int count: Model.toInt(modelData.count)
            Rectangle {
              id: bar
              anchors.bottom: dateLabel.top
              anchors.bottomMargin: Style.spacing.xs
              anchors.horizontalCenter: parent.horizontalCenter
              width: Math.max(1, Math.min(Style.space(22), parent.width * 0.55))
              height: Math.max(1, Style.space(64) * parent.count / root.peak())
              color: Color.accent
              opacity: parent.count ? 1 : 0.2
            }
            Text {
              anchors.bottom: bar.top; anchors.bottomMargin: Style.spacing.xxs
              anchors.horizontalCenter: parent.horizontalCenter
              text: parent.count; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
            }
            Text {
              id: dateLabel
              anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter
              text: root.trend.length <= 7 ? I18n.dateLabel(modelData.weekday || String(modelData.date).slice(5))
                : index % 2 === 0 || index === root.trend.length - 1 ? String(modelData.date).slice(5) : ""
              color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
            }
            Accessible.role: Accessible.StaticText
            Accessible.name: modelData.date + (modelData.endDate ? " through " + modelData.endDate : "") + ": " + count + " completed"
          }
        }
      }
    }

    Column {
      visible: root.loaded && root.historyAvailable && root.weeks.length > 0
      width: parent.width
      spacing: Style.spacing.sm
      Heading { text: I18n.tr("Activity heatmap") }
      Copy { text: I18n.tr("5 weeks · ") + (root.calendarDays.length ? root.calendarDays[0].date + " – " + root.calendarDays[root.calendarDays.length - 1].date : "") }
      // Contribution heatmap: weeks run left to right, weekdays top to bottom.
      Row {
        width: parent.width
        spacing: Style.spacing.sm
        Column {
          spacing: Style.space(3)
          Repeater {
            model: ["Mon", "", "Wed", "", "Fri", "", ""]
            delegate: Copy {
              required property string modelData
              width: Style.space(30); height: Style.space(15)
              font.pixelSize: Style.font.caption
              text: modelData
            }
          }
        }
      Grid {
        id: calendar
        rows: 7; columns: root.weeks.length
        flow: Grid.TopToBottom
        spacing: Style.space(3)
        Repeater {
          id: dayCells
          model: root.calendarDays
          delegate: Rectangle {
            id: day
            required property var modelData
            required property int index
            width: Style.space(15)
            height: width
            readonly property int level: Model.toInt(modelData.level)
            color: modelData.isFuture ? "transparent" : level <= 0 ? root.track : Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, level === 1 ? 0.4 : level === 2 ? 0.7 : 1)
            border.width: modelData.isToday || activeFocus ? 1 : 0
            border.color: root.foreground
            activeFocusOnTab: true
            Accessible.role: Accessible.Button
            Accessible.name: root.describeDay(modelData)
            Accessible.onPressAction: { root.selectedDay = index; forceActiveFocus() }
            onActiveFocusChanged: {
              root.calendarFocus = activeFocus
              if (activeFocus) root.selectedDay = index
            }
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape || event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                root.releaseCalendar()
                event.accepted = true
                return
              }
              var next = index
              if (event.key === Qt.Key_Left) next -= 7
              else if (event.key === Qt.Key_Right) next += 7
              else if (event.key === Qt.Key_Up) next--
              else if (event.key === Qt.Key_Down) next++
              else return
              next = Math.max(0, Math.min(root.calendarDays.length - 1, next))
              dayCells.itemAt(next).forceActiveFocus()
              event.accepted = true
            }
            MouseArea {
              anchors.fill: parent; hoverEnabled: true
              onEntered: root.hoverDay = root.describeDay(day.modelData)
              onExited: root.hoverDay = ""
              onClicked: { root.selectedDay = day.index; day.forceActiveFocus() }
            }
          }
        }
      }
        Column {
          width: Math.max(0, parent.width - Style.space(30) - calendar.width - parent.spacing * 2)
          spacing: Style.spacing.sm
          Copy { text: Model.toInt(root.heatmap.total) + I18n.tr(" completed"); color: root.foreground; font.bold: true }
          Copy { text: I18n.tr("Peak: ") + Model.toInt(root.heatmap.maxCount) + I18n.tr(" in one day") }
          Row {
            spacing: Style.space(3)
            Repeater {
              model: [0, 0.4, 0.7, 1]
              delegate: Rectangle {
                required property real modelData
                width: Style.space(12); height: width
                color: modelData === 0 ? root.track : Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, modelData)
              }
            }
          }
          Copy { text: "0 · 1 · 2–3 · 4+"; font.pixelSize: Style.font.caption }
        }
      }
      Copy { text: root.dayDetail; Accessible.name: text }
      Copy { text: I18n.tr("Outline: today. Tab to inspect; arrows to move; Esc to return.") }
    }

    Column {
      visible: root.loaded && root.lists.length > 0
      width: parent.width; spacing: Style.spacing.md
      Heading { text: I18n.tr("Open tasks by list") }
      Repeater {
        model: root.lists
        delegate: DistributionRow {
          required property var modelData
          required property int index
          label: Model.squish(modelData.name) || I18n.tr("No list")
          ratio: Model.toInt(modelData.count) / Math.max(1, Model.toInt(root.summary.open))
          value: modelData.count + " · " + Math.round(ratio * 100) + "%"
          fill: Model.listColor(modelData.color, index)
        }
      }
    }

    Column {
      visible: root.loaded && Model.toInt(root.summary.open) > 0
      width: parent.width; spacing: Style.spacing.sm
      Heading { text: I18n.tr("Priority · open tasks") }
      Repeater {
        model: root.priorities
        delegate: DistributionRow {
          required property var modelData
          visible: Model.toInt(modelData.count) > 0
          label: I18n.tr(String(modelData.label || "None")); value: String(modelData.count)
          ratio: Model.toInt(modelData.count) / Math.max(1, Model.toInt(root.summary.open))
          fill: Model.priorityColor(modelData.priority, root.foreground, Color.urgent)
        }
      }
    }
    Column {
      visible: root.loaded && root.tags.length > 0
      width: parent.width; spacing: Style.spacing.md
      Heading { text: I18n.tr("Tags · open tasks") }
      Copy { text: I18n.tr("Tasks with several tags appear in each tag's count.") }
      Repeater {
        model: root.tags
        delegate: DistributionRow {
          required property var modelData
          label: "#" + modelData.tag; value: String(modelData.count)
          ratio: Model.toInt(modelData.count) / Math.max(1, Model.toInt(root.summary.open))
        }
      }
    }
    Column {
      visible: root.loaded && Boolean(root.stats.focus || root.stats.habits)
      width: parent.width; spacing: Style.spacing.xs
      Heading { text: I18n.tr("Daily rhythm") }
      Copy {
        visible: Boolean(root.stats.focus)
        text: I18n.tr("Focus today: ") + Model.toInt((root.stats.focus || {}).minutes) + I18n.tr(" min · ") + Model.toInt((root.stats.focus || {}).count) + I18n.tr(" blocks")
          + ((root.stats.focus || {}).source === "network" ? "" : I18n.tr(" · cached"))
      }
      Copy {
        visible: Boolean(root.stats.habits)
        text: I18n.tr("Habits today: ") + Model.toInt((root.stats.habits || {}).done) + "/" + Model.toInt((root.stats.habits || {}).due)
          + I18n.tr(" done · best streak ") + Model.toInt((root.stats.habits || {}).streakBest) + I18n.tr(" days")
      }
    }
  }
}
