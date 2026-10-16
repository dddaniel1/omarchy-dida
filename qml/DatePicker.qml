import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui
import "I18n.js" as I18n

QQC.Popup {
  id: root
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property string seed: ""
  property date selectedDate: new Date()
  property date displayedMonth: new Date()
  signal dateSelected(string value)
  width: Math.min(Style.space(270), parent ? parent.width : Style.space(270))
  padding: Style.spacing.md
  closePolicy: QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutside
  focus: true

  function choose(date) {
    var time = /^\d{4}-\d{2}-\d{2}(\s+\d{2}:\d{2})$/.exec(seed)
    dateSelected(Qt.formatDate(date, "yyyy-MM-dd") + (time ? time[1] : ""))
    close()
  }
  function moveMonth(delta) {
    displayedMonth = new Date(displayedMonth.getFullYear(), displayedMonth.getMonth() + delta, 1)
  }
  onOpened: {
    var match = /^(\d{4})-(\d{2})-(\d{2})/.exec(seed)
    selectedDate = match ? new Date(Number(match[1]), Number(match[2])-1, Number(match[3])) : new Date()
    displayedMonth = new Date(selectedDate.getFullYear(), selectedDate.getMonth(), 1)
    monthGrid.forceActiveFocus()
  }
  background: Rectangle {
    color: Color.background
    radius: Style.cornerRadius
    border.width: 1
    border.color: root.foreground
  }
  contentItem: Column {
    spacing: Style.spacing.sm
    Row {
      width: parent.width
      Button {
        text: "‹"
        width: Style.space(30)
        foreground: root.foreground
        focusable: true
        tooltipText: I18n.tr("Previous month")
        onClicked: root.moveMonth(-1)
      }
      Text {
        width: parent.width - Style.space(60)
        anchors.verticalCenter: parent.verticalCenter
        text: Qt.formatDate(root.displayedMonth, I18n.isChinese(Qt.locale().name) ? "yyyy年 M月" : "MMMM yyyy")
        horizontalAlignment: Text.AlignHCenter
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
      Button {
        text: "›"
        width: Style.space(30)
        foreground: root.foreground
        focusable: true
        tooltipText: I18n.tr("Next month")
        onClicked: root.moveMonth(1)
      }
    }
    QQC.DayOfWeekRow {
      width: parent.width
      locale: Qt.locale()
      delegate: Text {
        required property string shortName
        text: shortName
        horizontalAlignment: Text.AlignHCenter
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
    QQC.MonthGrid {
      id: monthGrid
      objectName: "datePickerMonth"
      width: parent.width
      height: Style.space(180)
      month: root.displayedMonth.getMonth()
      year: root.displayedMonth.getFullYear()
      locale: Qt.locale()
      onClicked: function(date) { root.choose(date) }
      Keys.onLeftPressed: root.selectedDate = new Date(root.selectedDate.getFullYear(), root.selectedDate.getMonth(), root.selectedDate.getDate()-1)
      Keys.onRightPressed: root.selectedDate = new Date(root.selectedDate.getFullYear(), root.selectedDate.getMonth(), root.selectedDate.getDate()+1)
      Keys.onUpPressed: root.selectedDate = new Date(root.selectedDate.getFullYear(), root.selectedDate.getMonth(), root.selectedDate.getDate()-7)
      Keys.onDownPressed: root.selectedDate = new Date(root.selectedDate.getFullYear(), root.selectedDate.getMonth(), root.selectedDate.getDate()+7)
      Keys.onReturnPressed: root.choose(root.selectedDate)
      Keys.onSpacePressed: root.choose(root.selectedDate)
      delegate: Rectangle {
        required property var model
        color: model.date.toDateString() === root.selectedDate.toDateString() ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.25) : "transparent"
        radius: Style.cornerRadius
        Text {
          anchors.centerIn: parent
          text: model.day
          color: root.foreground
          opacity: model.month === monthGrid.month ? 1 : 0.5
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: model.today
        }
        Accessible.name: Qt.formatDate(model.date, "yyyy-MM-dd")
      }
    }
    Button {
      text: I18n.tr("Today")
      foreground: root.foreground
      focusable: true
      onClicked: root.choose(new Date())
    }
  }
  onSelectedDateChanged: displayedMonth = new Date(selectedDate.getFullYear(), selectedDate.getMonth(), 1)
}
