import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One habit line: mark · name · streak · tally.
//
// Divided the same way a task row is: the mark states what the habit IS — filled for
// a finished day, empty for an open one — and never previews what a click would do,
// which is the failure mode TaskRow documents at length. The row's own fields are read
// through Model's total helpers, and everything about *today* (whether it is due,
// whether it is done, how long the streak is) arrives already resolved in the row, so
// this file never has to know how a streak is counted.
CursorSurface {
  id: root

  property var habit: null
  property string fontFamily: Style.font.family

  signal checkinRequested()
  signal hovered(bool isHovered)

  readonly property var row: habit || ({})
  readonly property string nameText: Model.squish(row.name) || "Untitled habit"
  readonly property string tallyText: Model.habitTally(row)
  readonly property string streakText: Model.habitStreakLabel(row)
  readonly property bool done: row.done === true
  // A habit outside today's repeat rule. Still shown — it is a real habit, and hiding
  // it would make a weekly one look deleted — but dimmed rather than claiming to be due.
  readonly property bool dueToday: row.due !== false
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color markColor: done ? Color.accent : (hasCursor ? foreground : dim)

  implicitHeight: Math.max(mark.implicitHeight, labels.implicitHeight) + Style.spacing.lg

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onContainsMouseChanged: root.hovered(containsMouse)
    // The whole row is the target here, unlike the reference implementation this came
    // from. A habit has no detail pane to expand, so the only thing a click could mean
    // is the check-in; requiring the cursor to find a circle to do the one thing the
    // row is for would be a smaller target for no benefit.
    onClicked: root.checkinRequested()
  }

  Text {
    id: mark
    anchors.left: parent.left
    anchors.leftMargin: Style.spacing.rowPaddingX
    anchors.verticalCenter: parent.verticalCenter
    text: root.done ? "󰄲" : "󰄱"
    color: root.markColor
    font.family: root.fontFamily
    font.pixelSize: Style.font.subtitle
  }

  Column {
    id: labels
    anchors.left: mark.right
    anchors.leftMargin: Style.spacing.controlGap
    anchors.right: parent.right
    anchors.rightMargin: Style.spacing.rowPaddingX
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.spacing.xs

    Text {
      id: name
      width: parent.width
      text: root.nameText
      textFormat: Text.PlainText
      // A finished day steps back the way a finished task does; so does one that is not
      // due at all, because neither is asking for anything right now.
      color: (root.done || !root.dueToday) ? root.dim : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    Flow {
      id: trailing
      width: parent.width
      spacing: Style.spacing.md

      Text {
        // A streak is worth protecting, so it keeps the accent even on a day that is
        // not done yet — that is exactly when it is at risk.
        visible: root.streakText !== ""
        text: root.streakText
        color: Color.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        visible: root.tallyText !== ""
        width: Math.min(implicitWidth, trailing.width)
        elide: Text.ElideRight
        text: root.tallyText
        color: root.done ? Color.accent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        visible: !root.dueToday
        text: "not today"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
