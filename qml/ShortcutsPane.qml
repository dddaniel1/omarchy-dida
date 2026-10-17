import QtQuick
import "I18n.js" as I18n
import qs.Commons

Column {
  id: root
  objectName: "shortcutsPane"
  property var viewOptions: []
  property bool showFocus: true
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.family
  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.82)
  spacing: Style.spacing.lg

  component Copy: Text {
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    Accessible.role: Accessible.StaticText
    Accessible.name: text
  }
  component Section: Column {
    property string title: ""
    property var entries: []
    width: root.width
    spacing: Style.spacing.sm
    Copy { width: parent.width; text: parent.title; font.bold: true; font.pixelSize: Style.font.subtitle }
    Repeater {
      model: parent.entries
      delegate: Row {
        id: shortcutRow
        required property var modelData
        width: root.width
        spacing: Style.spacing.md
        Copy {
          id: keyLabel
          width: Math.min(Style.space(160), (parent.width - parent.spacing) * 0.48)
          text: modelData[0]
          font.bold: true
        }
        Copy {
          width: Math.max(0, parent.width - keyLabel.width - parent.spacing)
          text: I18n.tr(modelData[1])
          color: root.dim
        }
      }
    }
  }
  Copy {
    width: parent.width
    text: I18n.tr("Shortcuts work while the panel is focused. Text fields and open menus use their own keys.")
    color: root.dim
  }
  Section {
    title: I18n.tr("Navigation")
    entries: [
      ["↑ / ↓ · k / j", "Move the cursor; scroll this page"],
      ["← / → · h / l", "Switch views; leave the sidebar with →"],
      ["Tab / Shift+Tab", "Switch between list and sidebar; enter forms or the statistics calendar"],
      ["Enter", "Open the highlighted sidebar item"],
      ["Esc", "Go back one layer, then close the panel"],
      ["?", "Open keyboard shortcuts"],
      ["PgUp / PgDn", "Scroll shortcuts or statistics by a page"],
      ["Home / End", "Go to the top or bottom of shortcuts or statistics"]
    ]
  }
  Section {
    title: I18n.tr("View shortcuts")
    entries: {
      var out = []
      for (var i = 0; i < root.viewOptions.length && i < 10; i++)
        out.push(["1234567890".charAt(i), root.viewOptions[i].label])
      return out
    }
  }
  Section {
    title: I18n.tr("Tasks and habits")
    entries: [
      ["Enter", "Complete the selected task; check in a habit; toggle task selection"],
      ["Space", "Expand or collapse task details; toggle task selection"],
      ["a", "Quick-add a task in a list view"],
      ["/", "Search tasks"],
      ["o", "Cycle sort: list, date, priority, title"],
      ["f", "Show or hide priority and tag filters"],
      ["p", "Cycle the selected task's priority"],
      ["x / d", "Delete the selected task (confirmation required)"],
      ["r", "Refresh the current view"],
      ["s", "Sync queued tasks; refresh habits, statistics or important dates"]
    ]
  }
  Section {
    visible: root.showFocus
    title: I18n.tr("Focus")
    entries: [["Shift+P", "Start, pause or resume the focus timer"]]
  }
}
