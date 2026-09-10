import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Ui
import qs.Commons

BarWidget {
  id: root
  // The bar host overwrites this with the layout entry id, so the literal only
  // matters before the widget is slotted. Kept in sync with manifest.id anyway.
  moduleName: "mechurisr.media-search"

  // This plugin ships its own service, so resolve it under our own id first.
  // Looking up "omarchy.media" alone returns null once we are enabled: the
  // manifest's omarchy.clonedFrom disables the built-in plugin, so no service
  // is registered under that id anymore. The fallback only covers the window
  // before the host has injected moduleName.
  readonly property var mediaService: bar?.shell
    ? (bar.shell.serviceFor(root.moduleName) || bar.shell.serviceFor("omarchy.media"))
    : null
  readonly property var activePlayer: mediaService ? mediaService.activePlayer : null
  readonly property var sourcePlayers: mediaService ? mediaService.sourcePlayers : []

  // Since Omarchy 4.0.3 a widget hosted by a third-party replacement bar gets
  // a service-less shell facade — the host will not hand an untrusted bar a
  // lookup that could retrieve any plugin's live service object — so
  // serviceFor() comes back null there. Nothing the plugin can do about it,
  // but the panel should say so instead of offering a search box that
  // silently does nothing.
  readonly property bool serviceAvailable: mediaService !== null

  readonly property bool hasMedia: activePlayer !== null && (activePlayer.trackTitle || activePlayer.trackArtist)
  // No MPRIS player at all: stay on the bar as a launcher instead of vanishing.
  readonly property bool idle: !hasMedia
  readonly property string playIcon: idle ? "󰝚" : (activePlayer.isPlaying ? "󰏤" : "󰐊")
  readonly property string title: activePlayer ? (activePlayer.trackTitle || "") : ""
  readonly property string artist: activePlayer ? (activePlayer.trackArtist || "") : ""
  readonly property string identity: activePlayer ? (activePlayer.identity || "") : ""

  property bool popupOpen: false

  function close() {
    selectedIndex = -1
    popupOpen = false
  }
  property real maxLabelWidth: 180

  // Search state lives on the service so it survives panel close/reopen and is
  // shared by every bar instance (one per monitor).
  readonly property var searchResults: mediaService ? mediaService.searchResults : []
  readonly property bool searching: mediaService ? mediaService.searching : false
  readonly property string searchError: mediaService ? mediaService.searchError : ""

  // Overridable from this widget's entry in shell.json, so pointing the button
  // at a different service does not mean editing the plugin.
  readonly property string launchCommand: setting("launchCommand",
    "omarchy-launch-webapp https://music.youtube.com/")

  // -1 means the search field owns the keyboard; >= 0 selects a result row.
  // Cursor moves are only handled while the field is unfocused, so typing a
  // query is never mistaken for vim-style navigation.
  property int selectedIndex: -1

  function runSearch() {
    if (!mediaService) return
    var q = searchField.text.trim()
    if (!q) return
    selectedIndex = -1
    mediaService.search(q)
  }

  function focusSearch() {
    selectedIndex = -1
    searchField.forceActiveFocus()
  }

  function enterList() {
    if (searchResults.length === 0) return
    selectedIndex = 0
    // Dropping focus from the field un-blocks the key catcher, which then
    // drives the cursor.
    keyCatcher.forceActiveFocus()
  }

  function moveCursor(delta) {
    if (searchResults.length === 0) return
    var next = selectedIndex + delta
    if (next < 0) {
      focusSearch()
      return
    }
    if (next >= searchResults.length) next = searchResults.length - 1
    selectedIndex = next
  }

  function activateCursor() {
    if (selectedIndex < 0 || selectedIndex >= searchResults.length) return
    playResult(searchResults[selectedIndex].videoId)
  }

  function playResult(videoId) {
    if (!mediaService || !videoId) return
    mediaService.playResult(videoId)
    popupOpen = false
  }

  function openPanel() { popupOpen = true }
  function togglePanel() { popupOpen = !popupOpen }

  // Repeat rides the player's own MPRIS LoopStatus rather than anything we
  // track ourselves, so it keeps working (and stays in sync) no matter which
  // source is active, as long as that player supports it.
  // Mutually exclusive with autoplay-related: a looping track never reaches
  // EOF, so autoplay would never get a chance to fire while repeat is on.
  function toggleRepeat() {
    if (!activePlayer || !activePlayer.loopSupported) return
    var on = activePlayer.loopState === MprisLoopState.Track
    activePlayer.loopState = on ? MprisLoopState.None : MprisLoopState.Track
    if (!on && mediaService) mediaService.autoplayRelated = false
  }

  // A bar surface exists per monitor, so the single instance that wins the IPC
  // target relays to its peers via broadcast(). The target is deliberately short
  // rather than the plugin id, because it is what a keybinding has to type:
  //   omarchy-shell media-search toggle
  IpcHandler {
    target: "media-search"

    function toggle(): string {
      root.broadcast("togglePanel")
      return "ok"
    }

    function open(): string {
      root.broadcast("openPanel")
      return "ok"
    }

    function close(): string {
      root.broadcast("close")
      return "ok"
    }
  }

  function closeFromPanel() {
    // Clear the query along with the panel so reopening starts fresh rather
    // than showing results for whatever was typed last time.
    if (mediaService) mediaService.clearSearch()
    searchField.text = ""
    popupOpen = false
  }

  visible: true
  implicitWidth: row.implicitWidth + Style.space(14)
  implicitHeight: barSize

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(6)

    Text {
      id: glyph
      anchors.verticalCenter: parent.verticalCenter
      text: root.playIcon
      color: activePlayer && activePlayer.isPlaying ? root.bar.barForeground : Qt.darker(root.bar.barForeground, 1.5)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      Behavior on color {
        enabled: !root.bar || root.bar.foregroundAnimationEnabled
        ColorAnimation { duration: 160 }
      }
    }

    Item {
      id: scrollClip
      width: Math.min(root.maxLabelWidth, labelText.implicitWidth)
      height: glyph.height
      clip: true
      anchors.verticalCenter: parent.verticalCenter
      visible: !root.bar.vertical && root.title !== ""

      Text {
        id: labelText
        text: root.title + (root.artist ? "  ·  " + root.artist : "")
        color: root.bar.barForeground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter

        property bool needsScroll: implicitWidth > scrollClip.width

        NumberAnimation on x {
          id: scrollAnim
          running: labelText.needsScroll && !root.popupOpen && !root.bar.vertical
          loops: Animation.Infinite
          duration: Math.max(6000, labelText.implicitWidth * 25)
          from: scrollClip.width
          to: -labelText.implicitWidth
          easing.type: Easing.Linear
        }
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

    onClicked: function(mouse) {
      // Left click always opens the panel, even with nothing playing — that is
      // where search lives, so it doubles as the way to start music.
      if (mouse.button === Qt.LeftButton) {
        root.popupOpen = !root.popupOpen
        return
      }
      if (!root.activePlayer) return
      if (mouse.button === Qt.MiddleButton) {
        if (root.mediaService) root.mediaService.runAction("playPause", false)
      } else if (mouse.button === Qt.RightButton) {
        if (root.mediaService) root.mediaService.runAction("next", false)
      }
    }
    onWheel: function(wheel) {
      if (!root.activePlayer) return
      if (wheel.angleDelta.y > 0 && root.mediaService) root.mediaService.runAction("previous", false)
      else if (wheel.angleDelta.y < 0 && root.mediaService) root.mediaService.runAction("next", false)
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, root.hasMedia ? (root.title + (root.artist ? " — " + root.artist : "")) : "Search music")
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  // KeyboardPanel rather than PopupCard: the search field needs real keyboard
  // input, and only KeyboardPanel's layer-shell window takes keyboard focus.
  // A PopupCard is an xdg-popup of the bar, which never gets focus.
  KeyboardPanel {
    id: panel
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    focusTarget: searchField
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    // Blocked while the query field is focused so letters reach the editor;
    // once focus leaves the field it drives the result cursor.
    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus

      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.selectedIndex >= 0 ? root.focusSearch() : root.closeFromPanel()

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(10)

      Row {
        width: parent.width
        spacing: Style.space(6)

        TextField {
          id: searchField
          width: parent.width - searchBtn.width - Style.space(6)
          placeholderText: "Search music…"
          foreground: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
          enabled: root.serviceAvailable
          opacity: enabled ? 1.0 : 0.4

          onAccepted: root.runSearch()
          Keys.onEscapePressed: root.closeFromPanel()
          // Down hands the keyboard to the result list; the field keeps Left
          // and Right for ordinary cursor movement within the query.
          Keys.onDownPressed: root.enterList()

          // Layer-shell hands the surface focus on open, but Qt still needs an
          // item to hold active focus, so claim it once the panel maps.
          onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)
          Component.onCompleted: if (visible) Qt.callLater(forceActiveFocus)
        }

        Button {
          id: searchBtn
          iconText: root.searching ? "󰑖" : "󰍉"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: root.serviceAvailable && !root.searching && searchField.text.trim() !== ""
          opacity: enabled ? 1.0 : 0.4
          onClicked: root.runSearch()
        }
      }

      Text {
        width: parent.width
        text: !root.serviceAvailable
          ? "Search needs the built-in bar: a replacement bar cannot reach this plugin's service."
          : (root.searching ? "Searching…" : root.searchError)
        color: Qt.darker(root.bar.foreground, 1.4)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        elide: Text.ElideRight
        visible: text !== ""
      }

      Column {
        id: resultList
        width: parent.width
        spacing: Style.space(2)
        visible: root.searchResults.length > 0

        Repeater {
          model: root.searchResults

          BorderSurface {
            id: resultRow
            required property var modelData
            required property int index

            readonly property bool cursorOn: root.selectedIndex === index

            width: resultList.width
            height: resultInner.implicitHeight + Style.space(8)
            radius: Style.spacing.labelGap
            color: cursorOn || resultHover.hovered
              ? Style.selectedFillFor(root.bar.foreground, Color.accent)
              : "transparent"
            borderSpec: cursorOn
              ? Border.controlSpec("normal", root.bar.foreground, Color.accent)
              : Border.none()

            Row {
              id: resultInner
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(8)

              Text {
                text: "󰐊"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                width: Style.space(16)
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                width: parent.width - Style.space(24) - durationLabel.width
                spacing: Style.space(1)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  text: resultRow.modelData.title
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                  width: parent.width
                }

                Text {
                  text: resultRow.modelData.uploader
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  width: parent.width
                  visible: text !== ""
                }
              }

              Text {
                id: durationLabel
                text: resultRow.modelData.duration
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            HoverHandler { id: resultHover }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.playResult(resultRow.modelData.videoId)
            }
          }
        }
      }

      PanelSeparator {
        visible: resultList.visible
        foreground: root.bar.foreground
      }

      Row {
        spacing: Style.space(10)
        width: parent.width

        BorderSurface {
          width: Style.space(64)
          height: Style.space(64)
          radius: Style.spacing.labelGap
          color: Style.normalFillFor(root.bar.foreground, Color.accent)
          borderSpec: Border.controlSpec("normal", root.bar.foreground, Color.accent)

          Image {
            anchors.fill: parent
            anchors.margins: Style.space(2)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            source: root.activePlayer && root.activePlayer.trackArtUrl ? root.activePlayer.trackArtUrl : ""
            visible: source !== ""
          }

          Text {
            anchors.centerIn: parent
            visible: !root.activePlayer || !root.activePlayer.trackArtUrl
            text: "󰝚"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
          }
        }

        Column {
          spacing: Style.space(4)
          width: parent.width - Style.space(74)

          Text {
            text: root.title || "Nothing playing"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            text: root.artist
            color: Qt.darker(root.bar.foreground, 1.3)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
            width: parent.width
            visible: text !== ""
          }

          Text {
            text: root.activePlayer && root.activePlayer.trackAlbum ? root.activePlayer.trackAlbum : ""
            color: Qt.darker(root.bar.foreground, 1.6)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width
            visible: text !== ""
          }
        }
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(6)

        Button {
          iconText: "󰒮"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: root.activePlayer && root.activePlayer.canGoPrevious
          opacity: enabled ? 1.0 : 0.4
          onClicked: if (root.mediaService) root.mediaService.runAction("previous", false, root.mediaService.playerKey(root.activePlayer))
        }

        Button {
          iconText: root.activePlayer && root.activePlayer.isPlaying ? "󰏤" : "󰐊"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.panelGap
          verticalPadding: Style.spacing.controlPaddingY
          iconSize: Style.font.iconLarge
          enabled: root.activePlayer && (root.activePlayer.canTogglePlaying || root.activePlayer.canPlay || root.activePlayer.canPause)
          opacity: enabled ? 1.0 : 0.4
          onClicked: if (root.mediaService) root.mediaService.runAction("playPause", false, root.mediaService.playerKey(root.activePlayer))
        }

        Button {
          iconText: "󰒭"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: root.activePlayer && root.activePlayer.canGoNext
          opacity: enabled ? 1.0 : 0.4
          onClicked: if (root.mediaService) root.mediaService.runAction("next", false, root.mediaService.playerKey(root.activePlayer))
        }

        // Stop the locally streamed track. Only meaningful for playback this
        // widget started, so it hides when mpv is not the active source.
        Button {
          iconText: "󰓛"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          visible: root.identity === "mpv"
          onClicked: if (root.mediaService) root.mediaService.stopPlayback()
        }
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(6)

        // Toggles the active player's own MPRIS LoopStatus, so it works for
        // any source that supports it (mpv included), not just ours.
        Button {
          text: "Repeat"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          selected: root.activePlayer && root.activePlayer.loopState === MprisLoopState.Track
          enabled: root.activePlayer && root.activePlayer.loopSupported
          opacity: enabled ? 1.0 : 0.4
          tooltipText: enabled ? "" : "This source doesn't support repeat"
          onClicked: root.toggleRepeat()
        }

        // Only applies to tracks this widget streamed via yt-dlp/mpv: on
        // natural end, queues the next entry from YouTube's auto-generated
        // radio playlist for that video.
        Button {
          text: "Autoplay related"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          selected: root.mediaService && root.mediaService.autoplayRelated
          onClicked: if (root.mediaService) root.mediaService.toggleAutoplayRelated()
        }
      }

      Button {
        anchors.horizontalCenter: parent.horizontalCenter
        text: "Open YouTube Music"
        foreground: root.bar.foreground
        horizontalPadding: Style.spacing.controlPaddingX
        verticalPadding: Style.spacing.controlPaddingY
        onClicked: {
          if (root.bar) root.bar.run(root.launchCommand)
          root.popupOpen = false
        }
      }

      PanelSeparator {
        visible: root.sourcePlayers.length > 1
        foreground: root.bar.foreground
      }

      Column {
        id: sourceList
        visible: root.sourcePlayers.length > 1
        width: parent.width
        spacing: Style.space(4)

        Repeater {
          model: root.sourcePlayers

          BorderSurface {
            id: sourceRow
            required property var modelData

            readonly property var player: modelData
            readonly property bool selected: root.activePlayer && player
              && root.mediaService.playerKey(root.activePlayer) === root.mediaService.playerKey(player)
            readonly property string sourceTitle: player ? (player.trackTitle || player.identity || player.desktopEntry || "Media source") : "Media source"
            readonly property string sourceDetail: player && player.trackArtist ? player.trackArtist : (player && player.identity ? player.identity : "")

            width: sourceList.width
            height: sourceInner.implicitHeight + Style.space(10)
            radius: Style.spacing.labelGap
            color: selected ? Style.selectedFillFor(root.bar.foreground, Color.accent) : "transparent"
            borderSpec: selected ? Border.controlSpec("normal", root.bar.foreground, Color.accent) : Border.none()

            Row {
              id: sourceInner
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: sourceRow.borderLeft + Style.space(8)
              anchors.rightMargin: sourceRow.borderRight + Style.space(8)
              spacing: Style.space(8)

              Text {
                text: sourceRow.player && sourceRow.player.isPlaying ? "󰏤" : "󰐊"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                width: Style.space(18)
                horizontalAlignment: Text.AlignHCenter
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                width: parent.width - Style.space(26)
                spacing: Style.space(1)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  text: sourceRow.sourceTitle
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: sourceRow.selected
                  elide: Text.ElideRight
                  width: parent.width
                }

                Text {
                  text: sourceRow.sourceDetail
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  width: parent.width
                  visible: text !== ""
                }
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: if (root.mediaService) root.mediaService.selectPlayer(root.mediaService.playerKey(sourceRow.player))
            }
          }
        }
      }
    }
    }
  }
}
