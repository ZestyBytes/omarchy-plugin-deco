import QtQuick
import Quickshell
import "." as Deco

ShellRoot {
  id: testRoot

  FloatingWindow {
    id: hostWindow
    visible: true
    implicitWidth: 800
    implicitHeight: 800
    color: "transparent"

    Deco.Panel {
      id: panelUnderTest
      anchors.fill: parent
      bar: null
    }
  }

  function findNamedObject(object, name) {
    if (!object) return null
    if (object.objectName === name) return object

    var descendants = object.data || object.children || []
    for (var i = 0; i < descendants.length; i++) {
      var match = findNamedObject(descendants[i], name)
      if (match) return match
    }
    return null
  }

  function fail(message) {
    console.error("DECO_PANEL_TEST_FAIL: " + message)
    Qt.quit()
  }

  function runTest() {
    var popup = findNamedObject(panelUnderTest, "decoPopup")
    var scrollArea = findNamedObject(panelUnderTest, "deviceScrollArea")
    var scrollBar = findNamedObject(panelUnderTest, "deviceScrollBar")
    if (!popup) return fail("the popup does not expose a capped panel surface")
    if (!scrollArea) return fail("the device list is not inside a scroll area")
    if (!scrollBar || !scrollBar.visible)
      return fail("an overflowing device list does not show a vertical scrollbar")
    if (popup.contentHeight > panelUnderTest.maximumPopupHeight)
      return fail("the popup exceeds its maximum height")
    if (scrollArea.contentItem.contentHeight <= scrollArea.height)
      return fail("a 235-device list does not overflow the viewport")
    if (!scrollArea.contentItem.interactive)
      return fail("the overflowing list is not interactive")

    var initialY = scrollArea.contentItem.contentY
    scrollArea.contentItem.contentY = Math.min(
      120,
      scrollArea.contentItem.contentHeight - scrollArea.height
    )
    if (scrollArea.contentItem.contentY <= initialY)
      return fail("the overflowing list cannot change its scroll position")

    console.log("DECO_PANEL_TEST_PASS")
    Qt.quit()
  }

  Component.onCompleted: {
    var clients = []
    for (var i = 0; i < 235; i++) {
      clients.push({
        name: "device-" + i,
        ip: "192.168.68." + ((i % 253) + 2),
        mac: "client-" + i,
        online: true,
        down_kbps: 0,
        up_kbps: 0
      })
    }
    panelUnderTest.nodes = [{
      name: "Office",
      mac: "main",
      role: "master",
      via: "",
      via_dbm: null,
      clients: clients
    }]
    testTimer.start()
  }

  Timer {
    id: testTimer
    interval: 250
    onTriggered: testRoot.runTest()
  }
}
