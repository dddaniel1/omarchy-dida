import QtQuick
import qs.Commons
import "Model.js" as Model

// The Stats view: a dashboard, not a list.
//
// Everything it draws is presentation — the numbers arrive already computed by
// `ticktick/stats.py` through Service.stats, exactly like every other read. It owns no
// cursor and no actions: a statistic is something to look at, not something to tick
// off, so it deliberately does not join the row/cursor machinery the task pane uses.
Item {
  id: root

  property var stats: ({})
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  readonly property color dim: Qt.darker(foreground, 1.6)
  readonly property color accent: Color.accent
  readonly property color track: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)

  readonly property var summary: root.stats ? (root.stats.summary || {}) : ({})
  readonly property var dist: root.stats ? (root.stats.distribution || {}) : ({})
  readonly property var trend: root.stats ? Model.asList(root.stats.trend) : []
  readonly property var lists: Model.asList(dist.byList)
  readonly property var tags: Model.asList(dist.byTag)
  readonly property var priorities: Model.asList(dist.byPriority)
  // A payload with no `summary` is one that has not arrived; the zeros of an empty
  // account are indistinguishable from a failed read without this flag.
  readonly property bool loaded: root.stats !== undefined && root.stats.summary !== undefined

  implicitHeight: body.implicitHeight

  function peakOf(items, key) {
    var peak = 0
    for (var i = 0; i < items.length; i++) peak = Math.max(peak, Model.toInt(items[i][key]))
    return Math.max(1, peak)
  }

  // ---- small pieces ----------------------------------------------------

  component Tile: Column {
    property string value: "0"
    property string label: ""
    property color valueColor: root.foreground
    spacing: Style.spacing.xxs
    Text {
      text: parent.value
      color: parent.valueColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
      font.bold: true
    }
    Text {
      text: parent.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // One day of the completion chart: the count above a bar, the weekday beneath it.
  // Bars share a baseline and a peak, so the tallest is always the same height.
  component TrendDay: Item {
    id: trendDay
    required property var modelData
    property int peak: 1

    readonly property int count: Model.toInt(modelData.count)

    height: Style.space(104)

    Text {
      anchors.top: parent.top
      anchors.horizontalCenter: parent.horizontalCenter
      text: trendDay.count > 0 ? String(trendDay.count) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Rectangle {
      id: trendBar
      anchors.bottom: weekdayText.top
      anchors.bottomMargin: Style.spacing.xxs
      anchors.horizontalCenter: parent.horizontalCenter
      width: Math.max(Style.space(6), parent.width * 0.5)
      height: Math.max(Style.space(2),
                       Math.round(Style.space(60) * (trendDay.count / Math.max(1, trendDay.peak))))
      radius: Style.cornerRadius
      color: root.accent
      opacity: trendDay.count > 0 ? 1.0 : 0.2
    }

    Text {
      id: weekdayText
      anchors.bottom: parent.bottom
      anchors.horizontalCenter: parent.horizontalCenter
      text: String(modelData.weekday || "")
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // A labelled horizontal bar: name on the left, filled track, count on the right.
  component Bar: Item {
    id: barRow
    property string label: ""
    property string value: ""
    property real ratio: 0

    width: parent ? parent.width : 0
    implicitHeight: Math.max(labelText.implicitHeight, valueText.implicitHeight, track.height)
    height: implicitHeight

    Text {
      id: labelText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(Style.space(120), parent.width * 0.35)
      text: barRow.label
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Rectangle {
      id: track
      anchors.left: labelText.right
      anchors.leftMargin: Style.spacing.sm
      anchors.right: valueText.left
      anchors.rightMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      height: Style.space(8)
      radius: Style.cornerRadius
      color: root.track

      Rectangle {
        width: parent.width * Math.max(0, Math.min(1, barRow.ratio))
        height: parent.height
        radius: parent.radius
        color: root.accent
      }
    }

    Text {
      id: valueText
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: barRow.value
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  component Chip: Rectangle {
    property string label: ""
    property string value: ""
    radius: Style.cornerRadius
    color: root.track
    implicitWidth: chipText.implicitWidth + Style.spacing.md
    implicitHeight: chipText.implicitHeight + Style.spacing.xs
    Text {
      id: chipText
      anchors.centerIn: parent
      text: parent.label + (parent.value === "" ? "" : "  " + parent.value)
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  function sectionTitle(text) {
    return String(text || "")
  }

  // ---- the dashboard ---------------------------------------------------

  Column {
    id: body
    width: parent.width
    spacing: Style.spacing.lg

    Text {
      visible: !root.loaded
      width: parent.width
      text: "Gathering your statistics…"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    // ---- headline tiles
    Row {
      visible: root.loaded
      width: parent.width
      spacing: Style.spacing.xl

      Tile {
        value: String(Model.toInt(root.summary.completed))
        label: "completed in " + Model.toInt(root.stats.days) + "d"
        valueColor: root.accent
      }
      Tile {
        value: String(Model.toInt(root.summary.open))
        label: "open"
      }
      Tile {
        value: String(Model.toInt(root.summary.overdue))
        label: "overdue"
        valueColor: Model.toInt(root.summary.overdue) > 0 ? Color.urgent : root.foreground
      }
      Tile {
        value: String(Model.toInt(root.summary.today))
        label: "due today"
      }
    }

    // ---- habits and focus, as a line each
    Column {
      visible: root.loaded
      width: parent.width
      spacing: Style.spacing.xxs

      Text {
        visible: root.focusLine() !== ""
        width: parent.width
        text: root.focusLine()
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        visible: root.habitLine() !== ""
        width: parent.width
        text: root.habitLine()
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }

    // ---- completion trend
    Column {
      visible: root.loaded && root.trend.length > 0
      width: parent.width
      spacing: Style.spacing.sm

      Text {
        text: "Completed"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      Row {
        id: trendRow
        width: parent.width
        Repeater {
          model: root.trend
          delegate: TrendDay {
            width: trendRow.width / Math.max(1, root.trend.length)
            peak: root.peakOf(root.trend, "count")
          }
        }
      }
    }

    // ---- open work by list
    Column {
      visible: root.loaded && root.lists.length > 0
      width: parent.width
      spacing: Style.spacing.sm

      Text {
        text: "By list"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      Repeater {
        model: root.lists
        delegate: Bar {
          required property var modelData
          label: Model.squish(modelData.name) || "No list"
          value: String(Model.toInt(modelData.count))
          ratio: Model.toInt(modelData.count) / root.peakOf(root.lists, "count")
        }
      }
    }

    // ---- priority and tags
    Column {
      visible: root.loaded && (root.priorities.length > 0 || root.tags.length > 0)
      width: parent.width
      spacing: Style.spacing.sm

      Text {
        text: "Priority"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      Flow {
        width: parent.width
        spacing: Style.spacing.sm

        Repeater {
          model: root.priorities
          delegate: Chip {
            required property var modelData
            visible: Model.toInt(modelData.count) > 0
            label: String(modelData.label || "None")
            value: String(Model.toInt(modelData.count))
          }
        }
      }

      Text {
        visible: root.tags.length > 0
        topPadding: Style.spacing.sm
        text: "Tags"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      Repeater {
        model: root.tags
        delegate: Bar {
          required property var modelData
          label: "#" + String(modelData.tag || "")
          value: String(Model.toInt(modelData.count))
          ratio: Model.toInt(modelData.count) / root.peakOf(root.tags, "count")
        }
      }
    }
  }

  // ---- the two assembled lines ----------------------------------------

  function focusLine() {
    if (!root.stats || !root.stats.focus) return ""
    var focus = root.stats.focus
    var blocks = Model.toInt(focus.count)
    var minutes = Model.toInt(focus.minutes)
    if (blocks === 0 && minutes === 0) return ""
    return "Focus today: " + blocks + (blocks === 1 ? " block · " : " blocks · ") + minutes + "m"
      + (String(focus.source || "") === "network" ? "" : " (cached)")
  }

  function habitLine() {
    if (!root.stats || !root.stats.habits) return ""
    var habits = root.stats.habits
    var due = Model.toInt(habits.due)
    if (due === 0 && Model.toInt(habits.total) === 0) return ""
    var line = "Habits: " + Model.toInt(habits.done) + "/" + due + " done"
    var best = Model.toInt(habits.streakBest)
    if (best > 1) line += " · best streak " + best + "d"
    return line
  }
}
