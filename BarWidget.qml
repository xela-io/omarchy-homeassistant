import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "xela.home-assistant"
  ipcTarget: "xela.home-assistant"
  // Reported by ha.py, which reads it from ~/.config/omarchy/home-assistant.json.
  property string haUrl: "http://homeassistant.local:8123"
  readonly property string helperPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/xela.home-assistant/ha.py"

  property var sections: []
  property var states: ({})
  // states is mutated in place; bindings read `rev` to notice.
  property int rev: 0
  property bool connected: false
  property bool started: false
  property bool authError: false
  property string error: ""
  property string actionError: ""
  property var palette: ({})

  readonly property int lightsOn: {
    rev
    var n = 0
    for (var id in states)
      if (id.indexOf("light.") === 0 && states[id].state === "on") n++
    return n
  }
  readonly property string iconState: !started ? "loading" : (!connected ? "error" : (lightsOn > 0 ? "on" : "idle"))
  readonly property color iconColor: {
    if (iconState === "on") return themeColor("yellow", "#e5c07b")
    if (iconState === "error") return themeColor("red", Color.urgent)
    return bar ? bar.barForeground : Color.foreground
  }
  readonly property string headline: {
    if (!started) return "Verbinde …"
    if (!connected) return error || "Nicht verbunden"
    if (lightsOn === 1) return "1 Licht an"
    if (lightsOn > 1) return lightsOn + " Lichter an"
    return "Alle Lichter aus"
  }
  function themeColor(name, fallback) { return palette[name] || fallback }

  // Sections the user folded or unfolded this session; "Sonstige" (entities
  // without an area) starts folded because it is mostly diagnostics.
  property var folds: ({})
  function isFolded(title) { return folds[title] !== undefined ? folds[title] : title === "Sonstige" }
  function setFolded(title, folded) {
    var next = Object.assign({}, folds)
    next[title] = folded
    folds = next
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function glyph(cp) { return String.fromCodePoint(cp) }

  function handle(line) {
    var m
    try { m = JSON.parse(line) } catch (e) { return }
    if (m.type === "status") {
      started = true
      if (m.url) haUrl = m.url
      connected = !!m.connected
      authError = !!m.auth
      error = m.error || ""
    } else if (m.type === "layout") {
      sections = m.sections
    } else if (m.type === "states") {
      states = m.states
      rev++
    } else if (m.type === "state") {
      states[m.entity_id] = { state: m.state, attributes: m.attributes }
      rev++
    } else if (m.type === "error") {
      actionError = m.message
      actionErrorTimer.restart()
    }
  }

  function call(domain, service, entityId, data) {
    if (!helper.running) return
    helper.write(JSON.stringify({ domain: domain, service: service, entity_id: entityId, data: data || {} }) + "\n")
  }

  // Flip the local state right away; the state_changed event confirms or reverts it.
  function setOn(entityId, on) {
    var domain = entityId.split(".")[0]
    var s = states[entityId]
    if (s) { s.state = on ? "on" : "off"; rev++ }
    call(domain, on ? "turn_on" : "turn_off", entityId)
  }

  function reconnect() {
    connected = false
    started = false
    helper.running = false
    restartTimer.restart()
  }

  function openWebUi() {
    if (bar) bar.run("xdg-open " + haUrl)
    close()
  }

  // ---- presentation helpers -------------------------------------------------

  readonly property var toggleDomains: ["light", "switch", "fan", "input_boolean", "siren", "humidifier"]
  readonly property var pressDomains: ({ scene: "turn_on", script: "turn_on", button: "press", input_button: "press" })

  function entityIcon(domain, attrs, on) {
    var dc = attrs.device_class || ""
    if (domain === "light") return glyph(on ? 0xF06E8 : 0xF0335)
    if (domain === "switch" || domain === "input_boolean") return glyph(on ? 0xF0521 : 0xF0A19)
    if (domain === "fan") return glyph(0xF0210)
    if (domain === "cover") return glyph(0xF111B)
    if (domain === "climate") return glyph(0xF0393)
    if (domain === "scene") return glyph(0xF03D8)
    if (domain === "script") return glyph(0xF0BC1)
    if (domain === "button" || domain === "input_button") return glyph(0xF12A8)
    if (domain === "lock") return glyph(0xF033E)
    if (domain === "media_player") return glyph(0xF04C3)
    if (domain === "binary_sensor") {
      if (dc === "door" || dc === "garage_door") return glyph(0xF081A)
      if (dc === "window" || dc === "opening") return glyph(0xF05B1)
      if (dc === "motion" || dc === "occupancy" || dc === "presence") return glyph(0xF0D91)
      return glyph(0xF09DE)
    }
    if (dc === "temperature") return glyph(0xF050F)
    if (dc === "humidity" || dc === "moisture") return glyph(0xF058E)
    if (dc === "power" || dc === "energy" || dc === "voltage" || dc === "current") return glyph(0xF0241)
    if (dc === "battery") return glyph(0xF0079)
    return glyph(0xF029A)
  }

  function number(v, digits) {
    return Number(v).toLocaleString(Qt.locale("de_DE"), "f", digits)
  }

  function stateLabel(domain, s, attrs) {
    var v = s.state
    if (v === "unavailable") return "nicht verfügbar"
    if (v === "unknown") return "unbekannt"
    var dc = attrs.device_class || ""
    if (domain === "binary_sensor") {
      var on = v === "on"
      var pairs = {
        door: ["offen", "zu"], garage_door: ["offen", "zu"], window: ["offen", "zu"], opening: ["offen", "zu"],
        motion: ["Bewegung", "ruhig"], occupancy: ["belegt", "frei"], presence: ["anwesend", "abwesend"],
        moisture: ["nass", "trocken"], connectivity: ["verbunden", "getrennt"], battery: ["schwach", "OK"],
        lock: ["offen", "verriegelt"], problem: ["Problem", "OK"], smoke: ["Rauch!", "OK"], plug: ["eingesteckt", "aus"]
      }
      var p = pairs[dc] || ["an", "aus"]
      return on ? p[0] : p[1]
    }
    if (domain === "media_player" && v === "playing" && attrs.media_title)
      return (attrs.media_artist ? attrs.media_artist + " – " : "") + attrs.media_title
    if (domain === "cover" && attrs.current_position !== undefined)
      return attrs.current_position + " %"
    if (dc === "timestamp" && !isNaN(Date.parse(v)))
      return Qt.formatDateTime(new Date(v), "dd.MM. HH:mm")
    var labels = {
      on: "an", off: "aus", open: "offen", closed: "zu", opening: "öffnet", closing: "schließt",
      locked: "verriegelt", unlocked: "entriegelt", home: "zu Hause", not_home: "abwesend",
      playing: "spielt", paused: "pausiert", idle: "bereit", standby: "Standby"
    }
    if (labels[v]) return labels[v]
    if (/^-?\d+(\.\d+)?$/.test(v)) {
      var digits = v.indexOf(".") < 0 ? 0 : Math.min(1, v.split(".")[1].length)
      v = number(parseFloat(v), digits)
    }
    return attrs.unit_of_measurement ? v + " " + attrs.unit_of_measurement : v
  }

  function isActive(domain, state) {
    if (domain === "climate") return state !== "off" && state !== "unavailable"
    return ["on", "open", "opening", "playing", "unlocked", "home"].indexOf(state) >= 0
  }

  function dimmable(attrs) {
    var modes = attrs.supported_color_modes || []
    for (var i = 0; i < modes.length; i++) if (modes[i] !== "onoff") return true
    return false
  }

  // ---- plumbing ---------------------------------------------------------------

  Process {
    id: helper
    command: ["python3", "-u", root.helperPath]
    running: true
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.handle(line) } }
    onExited: {
      root.connected = false
      restartTimer.restart()
    }
  }
  Timer { id: restartTimer; interval: 1500; onTriggered: helper.running = true }
  Timer { id: actionErrorTimer; interval: 6000; onTriggered: root.actionError = "" }

  FileView {
    path: Color.currentThemePath + "/colors.toml"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      var next = {}
      var re = /^\s*(\w+)\s*=\s*"(#[0-9a-fA-F]{6,8})"/gm, m
      var t = text()
      while ((m = re.exec(t)) !== null) next[m[1]] = m[2]
      root.palette = next
    }
  }

  // ---- bar ---------------------------------------------------------------------

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph(0xF07D0)
    labelVisible: false
    dimmed: root.iconState === "loading"
    horizontalMargin: 7.5
    tooltipText: "Home Assistant · " + root.headline
    onPressed: function(b) { if (b === Qt.RightButton) root.reconnect(); else root.toggle() }

    Text {
      id: icon
      anchors.centerIn: parent
      text: root.glyph(0xF07D0)
      textFormat: Text.PlainText
      color: root.iconColor
      opacity: root.iconState === "error" ? 0.6 : 1
      font.family: button.fontFamily
      font.pixelSize: button.fontSize
      renderType: Text.NativeRendering
      Behavior on color { ColorAnimation { duration: 300 } }
    }
  }

  // ---- popup -------------------------------------------------------------------

  KeyboardPanel {
    id: details
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: details.fittedContentWidth(Style.space(420))
    contentHeight: details.fittedContentHeight(content.implicitHeight, Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") root.reconnect() }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: content
          width: flick.width - (flick.interactive ? Style.space(10) : 0)
          spacing: Style.space(10)
          bottomPadding: Style.space(8)

          Text { text: "Home Assistant"; color: Color.popups.text; font.family: Style.font.family; font.pixelSize: Style.font.title; font.bold: true }
          Text {
            width: parent.width; wrapMode: Text.WordWrap
            text: root.headline
            color: root.started && !root.connected ? Color.urgent : Color.popups.text
            font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true
          }
          Text {
            visible: root.authError
            width: parent.width; wrapMode: Text.WordWrap; textFormat: Text.PlainText
            text: "In Home Assistant unter Profil → Sicherheit einen langlebigen Zugriffstoken erstellen und im Terminal speichern:\n\nsecret-tool store --label=\"Home Assistant\" service home-assistant url " + root.haUrl + "\n\nDanach mit Rechtsklick aufs Icon neu verbinden."
            color: Color.popups.text; font.family: Style.font.family; font.pixelSize: Style.font.caption
          }
          Text {
            visible: root.actionError !== ""
            width: parent.width; wrapMode: Text.WordWrap; textFormat: Text.PlainText
            text: root.actionError
            color: Color.urgent; font.family: Style.font.family; font.pixelSize: Style.font.caption
          }

          Repeater {
            model: root.connected ? root.sections : []

            Column {
              id: section
              required property var modelData
              width: content.width
              spacing: Style.space(6)

              readonly property string title: String(modelData.title || "")
              readonly property bool folded: root.isFolded(title)

              PanelSeparator {}
              PanelSectionHeader {
                width: parent.width
                text: root.glyph(section.folded ? 0xF0142 : 0xF0140) + "  " + section.title.toUpperCase()
                      + (section.folded ? "  ·  " + section.modelData.entities.length : "")
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setFolded(section.title, !section.folded)
                }
              }

              Repeater {
                model: section.folded ? [] : section.modelData.entities

                Column {
                  id: row
                  required property var modelData
                  readonly property string eid: modelData.id
                  readonly property string domain: eid.split(".")[0]
                  readonly property var st: { root.rev; return root.states[eid] || { state: "unavailable", attributes: {} } }
                  readonly property var attrs: st.attributes || {}
                  readonly property string name: modelData.name || attrs.friendly_name || eid
                  readonly property bool active: root.isActive(domain, st.state)
                  readonly property bool unavailable: st.state === "unavailable" || st.state === "unknown"
                  readonly property bool toggleable: root.toggleDomains.indexOf(domain) >= 0
                  readonly property bool pressable: root.pressDomains[domain] !== undefined
                  readonly property bool showValue: !toggleable && !pressable && domain !== "climate"
                  width: section.width
                  spacing: Style.space(4)
                  opacity: unavailable && !showValue ? 0.5 : 1

                  Item {
                    width: parent.width
                    implicitHeight: Math.max(controls.implicitHeight, label.implicitHeight, Style.space(26))

                    Text {
                      id: glyphText
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(24)
                      text: root.entityIcon(row.domain, row.attrs, row.active)
                      color: row.active ? (row.domain === "light" ? root.themeColor("yellow", Color.accent) : Color.accent) : Qt.darker(Color.popups.text, 1.3)
                      font.family: button.fontFamily; font.pixelSize: Style.font.icon
                      Behavior on color { ColorAnimation { duration: 200 } }
                    }
                    Text {
                      id: label
                      anchors.left: glyphText.right
                      anchors.leftMargin: Style.space(6)
                      anchors.right: controls.left
                      anchors.rightMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                      text: row.name
                      elide: Text.ElideRight
                      textFormat: Text.PlainText
                      color: Color.popups.text; font.family: Style.font.family; font.pixelSize: Style.font.body
                    }

                    Row {
                      id: controls
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(6)

                      Text {
                        visible: row.showValue
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(implicitWidth, Style.space(200))
                        elide: Text.ElideRight
                        text: root.stateLabel(row.domain, row.st, row.attrs)
                        textFormat: Text.PlainText
                        color: Color.popups.text; font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true
                      }

                      // Cover: open / stop / close.
                      Repeater {
                        model: row.domain === "cover" && !row.unavailable ? [[0xF0143, "open_cover"], [0xF04DB, "stop_cover"], [0xF0140, "close_cover"]] : []
                        Button {
                          required property var modelData
                          iconText: root.glyph(modelData[0])
                          bordered: true
                          onClicked: root.call("cover", modelData[1], row.eid)
                        }
                      }

                      // Media player: play / pause.
                      Button {
                        visible: row.domain === "media_player" && !row.unavailable && row.st.state !== "off"
                        iconText: root.glyph(row.st.state === "playing" ? 0xF03E4 : 0xF040A)
                        bordered: true
                        onClicked: root.call("media_player", "media_play_pause", row.eid)
                      }

                      // Climate: current → target, with ± steps.
                      Text {
                        visible: row.domain === "climate"
                        anchors.verticalCenter: parent.verticalCenter
                        text: (row.attrs.current_temperature !== undefined ? root.number(row.attrs.current_temperature, 1) + "°" : "–")
                              + (row.attrs.temperature !== undefined && row.attrs.temperature !== null ? "  →  " + root.number(row.attrs.temperature, 1) + "°" : "")
                        color: Color.popups.text; font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true
                      }
                      Repeater {
                        model: row.domain === "climate" && typeof row.attrs.temperature === "number" ? [-1, 1] : []
                        Button {
                          required property var modelData
                          iconText: root.glyph(modelData < 0 ? 0xF0374 : 0xF0415)
                          bordered: true
                          onClicked: {
                            var step = row.attrs.target_temp_step || 0.5
                            var t = row.attrs.temperature + modelData * step
                            t = Math.max(row.attrs.min_temp || 5, Math.min(row.attrs.max_temp || 35, t))
                            root.call("climate", "set_temperature", row.eid, { temperature: t })
                          }
                        }
                      }

                      Button {
                        visible: row.pressable
                        text: "Ausführen"
                        bordered: true
                        enabled: !row.unavailable
                        onClicked: root.call(row.domain, root.pressDomains[row.domain], row.eid)
                      }

                      ToggleSwitch {
                        visible: row.toggleable
                        anchors.verticalCenter: parent.verticalCenter
                        checked: row.st.state === "on"
                        busy: row.unavailable
                        foreground: root.bar ? root.bar.foreground : Color.foreground
                        onToggled: root.setOn(row.eid, !checked)
                      }
                    }
                  }

                  PanelSlider {
                    visible: row.domain === "light" && row.active && root.dimmable(row.attrs)
                    bar: root.bar
                    x: Style.space(30)
                    width: parent.width - x
                    height: Style.space(22)
                    minimum: 1
                    maximum: 100
                    step: 1
                    integer: true
                    value: Math.max(1, Math.round((row.attrs.brightness || 0) / 2.55))
                    onReleased: function(v) { root.call("light", "turn_on", row.eid, { brightness_pct: Math.round(v) }) }
                  }
                }
              }
            }
          }

          PanelSeparator {}
          Row {
            spacing: Style.space(8)
            Button { text: "Home Assistant öffnen"; bordered: true; onClicked: root.openWebUi() }
            Button { text: "Neu verbinden"; bordered: true; onClicked: root.reconnect() }
          }
        }
      }
    }
  }
}
