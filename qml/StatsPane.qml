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
  readonly property var heatmap: root.stats ? (root.stats.heatmap || {}) : ({})
  readonly property var heatmapWeeks: Model.asList(root.heatmap.weeks)
  readonly property var listSlices: Model.pieSlices(root.lists, root.summary.open)
  property string heatmapHoverText: ""

  // A payload with no `summary` is one that has not arrived; the zeros of an empty
  // account are indistinguishable from a failed read without this flag.
  readonly property bool loaded: root.stats !== undefined && root.stats.summary !== undefined

  implicitHeight: body.implicitHeight

  function peakOf(items, key) {
    var peak = 0
    for (var i = 0; i < items.length; i++) peak = Math.max(peak, Model.toInt(items[i][key]))
    return Math.max(1, peak)
  }

  function priorityCount(level) {
    for (var i = 0; i < root.priorities.length; i++) {
      if (Model.toInt(root.priorities[i].priority) === level) {
        return Model.toInt(root.priorities[i].count)
      }
    }
    return 0
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
    property var dayData: null
    property int peak: 1

    readonly property int count: dayData ? Model.toInt(dayData.count) : 0

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
      text: String(trendDay.dayData ? (trendDay.dayData.weekday || "") : "")
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // A single day cell in the 5-week calendar activity heatmap
  component HeatmapCell: Rectangle {
    id: cellItem
    property var dayData: null
    readonly property int level: dayData ? Model.toInt(dayData.level) : 0
    readonly property bool isToday: dayData ? Boolean(dayData.isToday) : false
    readonly property bool isFuture: dayData ? Boolean(dayData.isFuture) : false
    readonly property int count: dayData ? Model.toInt(dayData.count) : 0

    width: Style.space(16)
    height: Style.space(16)
    radius: Style.cornerRadius

    color: {
      if (cellItem.isFuture) return "transparent"
      if (cellItem.level <= 0) return root.track
      if (cellItem.level === 1) return Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.4)
      if (cellItem.level === 2) return Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.7)
      return root.accent
    }

    border.width: cellItem.isToday ? 1 : (cellItem.isFuture ? 1 : 0)
    border.color: cellItem.isToday ? root.foreground : (cellItem.isFuture ? root.track : "transparent")

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onEntered: {
        if (!cellItem.dayData) return
        if (cellItem.isFuture) {
          root.heatmapHoverText = cellItem.dayData.date + " (future)"
        } else {
          root.heatmapHoverText = cellItem.dayData.date + ": " + cellItem.count + (cellItem.count === 1 ? " task" : " tasks") + " completed"
        }
      }
      onExited: {
        root.heatmapHoverText = ""
      }
    }
  }

  // A labelled horizontal bar: name on the left, filled track, count on the right.
  component Bar: Item {
    id: barRow
    property string label: ""
    property string value: ""
    property real ratio: 0
    property color barColor: root.accent
    property bool showDot: false

    width: parent ? parent.width : 0
    implicitHeight: Math.max(labelBox.implicitHeight, valueText.implicitHeight, track.height)
    height: implicitHeight

    Row {
      id: labelBox
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(Style.space(90), parent.width * 0.35)
      spacing: Style.spacing.xs

      Rectangle {
        visible: barRow.showDot
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(8)
        height: Style.space(8)
        radius: Style.cornerRadius
        color: barRow.barColor
      }

      Text {
        id: labelText
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - (barRow.showDot ? (Style.space(8) + Style.spacing.xs) : 0)
        text: barRow.label
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }

    Rectangle {
      id: track
      anchors.left: labelBox.right
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
        color: barRow.barColor
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
    property color chipColor: root.track
    property color textColor: root.foreground
    radius: Style.cornerRadius
    color: chipColor
    implicitWidth: chipText.implicitWidth + Style.spacing.md
    implicitHeight: chipText.implicitHeight + Style.spacing.xs
    Text {
      id: chipText
      anchors.centerIn: parent
      text: parent.label + (parent.value === "" ? "" : "  " + parent.value)
      color: parent.textColor
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

    // ---- completion trend (last 7 days)
    Column {
      visible: root.loaded && root.trend.length > 0
      width: parent.width
      spacing: Style.spacing.sm

      Text {
        text: "Completed (last 7 days)"
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
            dayData: modelData
            width: trendRow.width / Math.max(1, root.trend.length)
            peak: root.peakOf(root.trend, "count")
          }
        }
      }
    }

    // ---- activity heatmap (5 calendar weeks grid)
    Column {
      visible: root.loaded && root.heatmapWeeks.length > 0
      width: parent.width
      spacing: Style.spacing.sm

      Item {
        width: parent.width
        height: Math.max(titleText.implicitHeight, summaryCountText.implicitHeight)

        Text {
          id: titleText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "Activity heatmap"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Text {
          id: summaryCountText
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: Model.toInt(root.heatmap.total) + " completions · " + Model.toInt(root.heatmap.weekCount || root.heatmapWeeks.length) + " weeks"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Row {
        spacing: Style.spacing.sm

        // Weekday labels column: Mon, Wed, Fri
        Column {
          spacing: Style.space(3)
          Repeater {
            model: ["Mon", "", "Wed", "", "Fri", "", ""]
            delegate: Item {
              required property var modelData
              width: Style.space(26)
              height: Style.space(16)
              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: String(modelData)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        // The weeks columns
        Row {
          spacing: Style.space(3)
          Repeater {
            model: root.heatmapWeeks
            delegate: Column {
              id: weekCol
              property var weekData: modelData
              spacing: Style.space(3)
              Repeater {
                model: Model.asList(weekCol.weekData)
                delegate: HeatmapCell {
                  dayData: modelData
                }
              }
            }
          }
        }
      }

      // Heatmap footer: hover info on left, legend on right
      Item {
        width: parent.width
        height: Math.max(hoverText.implicitHeight, legendRow.implicitHeight)

        Text {
          id: hoverText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: root.heatmapHoverText || (Model.toInt(root.heatmap.maxCount) > 0 ? ("Peak: " + Model.toInt(root.heatmap.maxCount) + " / day") : "")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Row {
          id: legendRow
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.xxs

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Less"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Rectangle {
            width: Style.space(10)
            height: Style.space(10)
            radius: Style.cornerRadius
            color: root.track
          }
          Rectangle {
            width: Style.space(10)
            height: Style.space(10)
            radius: Style.cornerRadius
            color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.4)
          }
          Rectangle {
            width: Style.space(10)
            height: Style.space(10)
            radius: Style.cornerRadius
            color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.7)
          }
          Rectangle {
            width: Style.space(10)
            height: Style.space(10)
            radius: Style.cornerRadius
            color: root.accent
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "More"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }

    // ---- open work by list (with Pie/Donut Chart)
    Column {
      visible: root.loaded && root.lists.length > 0
      width: parent.width
      spacing: Style.spacing.sm

      Item {
        width: parent.width
        height: Math.max(listTitleText.implicitHeight, listSummaryText.implicitHeight)

        Text {
          id: listTitleText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "By list"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Text {
          id: listSummaryText
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: Model.toInt(root.summary.open) + " open"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // Pie/Donut Chart & List Breakdown side-by-side
      Row {
        width: parent.width
        spacing: Style.spacing.md

        // Donut Pie Chart
        Item {
          id: pieContainer
          width: Style.space(96)
          height: Style.space(96)
          anchors.verticalCenter: parent.verticalCenter

          Canvas {
            id: pieCanvas
            anchors.fill: parent
            onPaint: {
              var ctx = getContext("2d")
              ctx.clearRect(0, 0, width, height)
              var slices = root.listSlices
              if (!slices || slices.length === 0) return

              var cx = width / 2
              var cy = height / 2
              var outerR = Math.min(cx, cy) - 2
              var innerR = outerR * 0.58

              for (var i = 0; i < slices.length; i++) {
                var s = slices[i]
                ctx.beginPath()
                ctx.arc(cx, cy, outerR, s.startAngle, s.endAngle, false)
                ctx.arc(cx, cy, innerR, s.endAngle, s.startAngle, true)
                ctx.closePath()
                ctx.fillStyle = s.color
                ctx.fill()
              }
            }

            Component.onCompleted: requestPaint()

            Connections {
              target: root
              function onListSlicesChanged() { pieCanvas.requestPaint() }
            }
          }

          Column {
            anchors.centerIn: parent
            spacing: 0
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: String(Model.toInt(root.summary.open))
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "tasks"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        // List bars on the right
        Column {
          width: parent.width - pieContainer.width - Style.spacing.md
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.xs

          Repeater {
            model: root.lists
            delegate: Bar {
              property var itemData: modelData
              width: parent.width
              label: itemData ? (Model.squish(itemData.name) || "No list") : "No list"
              value: itemData ? (Model.toInt(itemData.count) + " (" + Math.round((Model.toInt(itemData.count) / Math.max(1, Model.toInt(root.summary.open))) * 100) + "%)") : "0"
              ratio: itemData ? (Model.toInt(itemData.count) / root.peakOf(root.lists, "count")) : 0
              barColor: itemData ? Model.listColor(itemData.color, index) : root.accent
              showDot: true
            }
          }
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
            property var prioData: modelData
            visible: prioData ? (Model.toInt(prioData.count) > 0) : false
            label: prioData ? String(prioData.label || "None") : "None"
            value: prioData ? String(Model.toInt(prioData.count)) : "0"
            textColor: prioData ? Model.priorityColor(prioData.priority, root.foreground, Color.urgent) : root.foreground
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
          property var tagData: modelData
          label: tagData ? ("#" + String(tagData.tag || "")) : "#"
          value: tagData ? String(Model.toInt(tagData.count)) : "0"
          ratio: tagData ? (Model.toInt(tagData.count) / root.peakOf(root.tags, "count")) : 0
          barColor: Model.listColor("", index + 4)
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
