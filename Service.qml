import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import "MediaModel.js" as MediaModel

Item {
  id: root

  property var shell: null
  property string preferredPlayerKey: ""
  property var playerStartedAt: ({})
  property var pendingTrackOsd: null
  property int playSerial: 0

  // ---------------------------------------------------------- autoplay related
  // When on, a locally streamed track that finishes on its own (mpv reaches
  // EOF, not a manual stop/replace) queues the next entry from YouTube's
  // auto-generated "radio" playlist for that video.
  property bool autoplayRelated: false
  property string lastLocalVideoId: ""
  property var autoplayHistory: []
  // Set right before we intentionally kill playerProc (new pick, explicit
  // stop) so its onExited handler can tell that apart from mpv finishing the
  // file on its own.
  property bool intentionalStop: false

  function rememberAutoplayHistory(id) {
    var hist = autoplayHistory.slice()
    hist.push(id)
    if (hist.length > 6) hist.splice(0, hist.length - 6)
    autoplayHistory = hist
  }

  // Repeat (MPRIS LoopStatus: Track) makes mpv loop the same file forever,
  // so it never reaches EOF and autoplay would never get a chance to fire.
  // The two are mutually exclusive: turning one on clears the other.
  function toggleAutoplayRelated() {
    autoplayRelated = !autoplayRelated
    if (autoplayRelated) clearRepeatOnActivePlayer()
  }

  function clearRepeatOnActivePlayer() {
    var p = activePlayer
    if (p && p.loopSupported && p.loopState === MprisLoopState.Track)
      p.loopState = MprisLoopState.None
  }

  function handleRelatedOutput(raw) {
    var lines = String(raw || "").split("\n")
    var skip = {}
    for (var i = 0; i < autoplayHistory.length; i++) skip[autoplayHistory[i]] = true
    for (var j = 0; j < lines.length; j++) {
      var id = lines[j].trim()
      if (id && !skip[id]) {
        playResult(id)
        return
      }
    }
    showOsd("No related track found", "media", null)
  }

  function playRelated(seedId) {
    if (!seedId) return
    showOsd("Finding related track…", "media", null)
    relatedProc.running = false
    relatedProc.seedId = seedId
    Qt.callLater(function() { relatedProc.running = true })
  }

  Process {
    id: relatedProc
    property string seedId: ""
    // YouTube's own auto-generated "radio" mix for this video. The seed
    // itself is usually the first entry, which handleRelatedOutput skips via
    // autoplayHistory.
    command: ["yt-dlp", "--flat-playlist", "--no-warnings", "--ignore-config",
              "--print", "%(id)s",
              "https://www.youtube.com/watch?v=" + seedId + "&list=RD" + seedId]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleRelatedOutput(text)
    }

    onExited: function(exitCode) {
      if (exitCode !== 0) root.showOsd("Related track lookup failed", "media", null)
    }
  }

  // ---------------------------------------------------------- search & play
  // Search runs yt-dlp against YouTube; the pick is streamed by mpv, which
  // registers on MPRIS via /etc/mpv/scripts/mpris.so. That means the picked
  // track flows back through this same service as an ordinary player, so the
  // bar widget's now-playing readout and transport controls need no special
  // casing for locally started playback.
  readonly property int searchLimit: 8
  property string searchQuery: ""
  property var searchResults: []
  property bool searching: false
  property string searchError: ""

  function search(query) {
    var q = String(query || "").trim()
    searchQuery = q
    searchError = ""
    if (!q) {
      searchResults = []
      searching = false
      searchProc.running = false
      return
    }
    searching = true
    searchResults = []
    // Drop any in-flight query before starting the next one: restarting while
    // running would otherwise leave the old process to overwrite our results.
    searchProc.running = false
    searchProc.query = q
    Qt.callLater(function() { if (root.searchQuery === q) searchProc.running = true })
  }

  function clearSearch() {
    searchProc.running = false
    searchQuery = ""
    searchResults = []
    searching = false
    searchError = ""
  }

  // Set while waiting for mpv to claim its MPRIS bus, holding the player keys
  // that existed beforehand so the newcomer can be identified.
  property var localPlaybackPending: null

  function playResult(videoId) {
    var id = String(videoId || "").trim()
    if (!id) return false

    var before = ({})
    for (var i = 0; i < players.length; i++) {
      var key = playerKey(players[i])
      if (key) before[key] = true
    }
    localPlaybackPending = { before: before, attempts: 0 }

    // Silence the current source first. mpv opens its own audio stream, so
    // without this the picked track plays on top of whatever was already
    // going instead of replacing it.
    pausePlayer(activePlayer)

    // Only mark this an "intentional" stop if there's actually a running
    // process to kill — that's the only case onExited will fire and consume
    // the flag. Setting it unconditionally left it stuck at true forever
    // whenever there was nothing to kill (e.g. the very first track, or any
    // track started after the previous one had already ended on its own),
    // which made every later natural end look "intentional" and silently
    // disabled autoplay for good.
    if (playerProc.running) intentionalStop = true
    playerProc.running = false
    playerProc.videoId = id
    lastLocalVideoId = id
    rememberAutoplayHistory(id)
    Qt.callLater(function() { playerProc.running = true })
    localPlayerTimer.restart()
    return true
  }

  // Promote the player mpv just registered to the active source, so the bar
  // shows the track the user picked rather than the one it paused.
  function adoptLocalPlayer() {
    var pending = localPlaybackPending
    if (!pending) return

    for (var i = 0; i < players.length; i++) {
      var key = playerKey(players[i])
      if (!key || pending.before[key]) continue
      preferredPlayerKey = key
      localPlaybackPending = null
      localPlayerTimer.stop()
      return
    }

    // mpv resolves the stream before claiming the bus, which takes a few
    // seconds on a cold DNS cache. Give up rather than poll forever.
    pending.attempts = pending.attempts + 1
    if (pending.attempts > 80) {
      localPlaybackPending = null
      localPlayerTimer.stop()
      return
    }
    localPlaybackPending = pending
    localPlayerTimer.restart()
  }

  Timer {
    id: localPlayerTimer
    interval: 250
    repeat: false
    onTriggered: root.adoptLocalPlayer()
  }

  function stopPlayback() {
    // Same guard as playResult: only latch the flag when there's a running
    // process whose onExited will actually consume it.
    if (playerProc.running) intentionalStop = true
    playerProc.running = false
  }

  function formatDuration(total) {
    var secs = Math.max(0, Math.round(Number(total) || 0))
    if (secs === 0) return ""
    var mins = Math.floor(secs / 60)
    var rest = secs % 60
    return mins + ":" + (rest < 10 ? "0" + rest : String(rest))
  }

  function applySearchOutput(raw) {
    var lines = String(raw || "").split("\n")
    var out = []
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (!line || !line.trim()) continue
      // Tab-separated because titles routinely contain every other separator.
      var parts = line.split("\t")
      if (parts.length < 2 || !parts[0]) continue
      out.push({
        videoId: parts[0],
        title: parts[1] || parts[0],
        uploader: parts.length > 2 ? parts[2] : "",
        duration: root.formatDuration(parts.length > 3 ? parts[3] : 0)
      })
    }
    searchResults = out
  }

  Process {
    id: searchProc
    property string query: ""
    command: ["yt-dlp", "--flat-playlist", "--no-warnings", "--ignore-config",
              "--print", "%(id)s\t%(title)s\t%(uploader)s\t%(duration)s",
              "ytsearch" + root.searchLimit + ":" + query]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySearchOutput(text)
    }

    onExited: function(exitCode) {
      root.searching = false
      if (exitCode !== 0 && root.searchResults.length === 0) root.searchError = "Search failed"
      else if (root.searchResults.length === 0) root.searchError = "No results"
    }
  }

  Process {
    id: playerProc
    property string videoId: ""
    // mpv autoloads the MPRIS script from /etc/mpv/scripts, so no --script
    // flag is needed for this player to appear in Mpris.players.
    command: ["mpv", "--no-video", "--no-terminal",
              "https://www.youtube.com/watch?v=" + videoId]

    // Fires both when mpv reaches EOF on its own and when we kill it
    // ourselves (new pick, explicit stop). intentionalStop tells those apart
    // so autoplay only kicks in on a genuine natural end.
    onExited: function(exitCode) {
      var wasIntentional = root.intentionalStop
      root.intentionalStop = false
      if (wasIntentional) return
      if (root.autoplayRelated && root.lastLocalVideoId) root.playRelated(root.lastLocalVideoId)
    }
  }

  readonly property var players: Mpris.players ? Mpris.players.values : []
  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []
  readonly property var playbackStreams: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isStream && isPlaybackStream(n) && n.audio) list.push(n)
    }
    return list
  }
  readonly property var sourcePlayers: orderedSourcePlayers()
  readonly property var sourceCyclePlayers: orderedCycleSourcePlayers()
  readonly property var activePlayer: selectActivePlayer()
  readonly property bool hasMedia: activePlayer !== null && (activePlayer.trackTitle || activePlayer.trackArtist)
  readonly property string title: activePlayer ? (activePlayer.trackTitle || "") : ""
  readonly property string artist: activePlayer ? (activePlayer.trackArtist || "") : ""
  readonly property string album: activePlayer && activePlayer.trackAlbum ? activePlayer.trackAlbum : ""
  readonly property string artUrl: activePlayer && activePlayer.trackArtUrl ? activePlayer.trackArtUrl : ""
  readonly property string identity: activePlayer ? (activePlayer.identity || activePlayer.desktopEntry || "") : ""

  function isProxyPlayer(player) {
    return MediaModel.isProxyPlayer(player)
  }

  function hasMetadata(player) {
    return MediaModel.hasMetadata(player)
  }

  function hasTrackMetadata(player) {
    return MediaModel.hasTrackMetadata(player)
  }

  function playerCanControl(player) {
    return MediaModel.playerCanControl(player)
  }

  function canHandleAction(player, action) {
    return MediaModel.canHandleAction(player, action)
  }

  function canCycleSource(player) {
    return MediaModel.canCycleSource(player)
  }

  function nodeProps(node) {
    return MediaModel.nodeProps(node)
  }

  function isPlaybackStream(node) {
    return MediaModel.isPlaybackStream(node)
  }

  function streamLabelKey(label) {
    return MediaModel.streamLabelKey(label)
  }

  function rawStreamLabel(node) {
    return MediaModel.rawStreamLabel(node)
  }

  function playerAppLabel(player) {
    return MediaModel.playerAppLabel(player)
  }

  function playerHasPlaybackStream(player) {
    return MediaModel.playerHasPlaybackStream(player, playbackStreams)
  }

  function playerKey(player) {
    return MediaModel.playerKey(player)
  }

  function playerForKey(key) {
    if (!key) return null
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (playerKey(p) === key) return p
    }
    return null
  }

  function playerOrder(player, fallback) {
    var key = playerKey(player)
    var value = key ? playerStartedAt[key] : undefined
    return value === undefined ? fallback : value
  }

  function syncPlayingOrder() {
    var next = {}
    var alive = {}
    var serial = playSerial

    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      var key = playerKey(p)
      if (!key) continue

      alive[key] = true
      if (!p.isPlaying) continue

      if (playerStartedAt[key] === undefined) {
        serial += 1
        next[key] = serial
      } else {
        next[key] = playerStartedAt[key]
      }
    }

    if (preferredPlayerKey && !alive[preferredPlayerKey]) preferredPlayerKey = ""

    playSerial = serial
    playerStartedAt = next
  }

  function orderedSourcePlayers() {
    var list = []
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (hasMetadata(p)) list.push(p)
    }

    list.sort(function(a, b) {
      if (!!a.isPlaying !== !!b.isPlaying) return a.isPlaying ? -1 : 1
      if (isProxyPlayer(a) !== isProxyPlayer(b)) return isProxyPlayer(a) ? 1 : -1
      if (a.isPlaying && b.isPlaying) {
        var orderDelta = playerOrder(a, 1000) - playerOrder(b, 1000)
        if (orderDelta !== 0) return orderDelta
      }
      return labelFor(a).localeCompare(labelFor(b))
    })

    return list
  }

  function orderedCycleSourcePlayers() {
    var list = []
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (canCycleSource(p)) list.push(p)
    }

    list.sort(function(a, b) {
      if (isProxyPlayer(a) !== isProxyPlayer(b)) return isProxyPlayer(a) ? 1 : -1
      return labelFor(a).localeCompare(labelFor(b))
    })

    return list
  }

  function oldestPlayingPlayer(requirePlaybackStream) {
    var oldest = null
    var oldestOrder = 0
    var playingProxy = null
    var proxyOrder = 0

    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!p) continue

      var proxyPlayer = isProxyPlayer(p)
      if (p.isPlaying) {
        if (requirePlaybackStream && !playerHasPlaybackStream(p)) continue

        var order = playerOrder(p, i + 1000)
        if (!proxyPlayer && (!oldest || order < oldestOrder)) {
          oldest = p
          oldestOrder = order
        } else if (proxyPlayer && (!playingProxy || order < proxyOrder)) {
          playingProxy = p
          proxyOrder = order
        }
      }
    }

    return oldest || playingProxy || null
  }

  function selectActivePlayer() {
    var preferred = null
    var trackPlayer = null
    var trackProxy = null
    var streamPlayer = null
    var streamProxy = null
    var controllablePlayer = null
    var controllableProxy = null
    var identityPlayer = null
    var identityProxy = null

    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!p) continue

      var proxy = isProxyPlayer(p)

      if (preferredPlayerKey && playerKey(p) === preferredPlayerKey && hasMetadata(p)) preferred = p

      if (playerHasPlaybackStream(p)) {
        if (!proxy && !streamPlayer) streamPlayer = p
        else if (proxy && !streamProxy) streamProxy = p
      } else if (hasTrackMetadata(p)) {
        if (!proxy && !trackPlayer) trackPlayer = p
        else if (proxy && !trackProxy) trackProxy = p
      } else if (playerCanControl(p)) {
        if (!proxy && !controllablePlayer) controllablePlayer = p
        else if (proxy && !controllableProxy) controllableProxy = p
      } else if (hasMetadata(p)) {
        if (!proxy && !identityPlayer) identityPlayer = p
        else if (proxy && !identityProxy) identityProxy = p
      }
    }

    if (preferred && preferred.isPlaying) return preferred
    var streamCandidate = streamPlayer || streamProxy
    var streamPreferred = preferred && playerHasPlaybackStream(preferred) ? preferred : null
    return oldestPlayingPlayer(true) || oldestPlayingPlayer(false) || streamPreferred || streamCandidate || preferred || trackPlayer || trackProxy || controllablePlayer || controllableProxy || identityPlayer || identityProxy || null
  }

  function labelFor(player) {
    return MediaModel.labelFor(player)
  }

  function osdMessage(player, fallback) {
    return MediaModel.osdMessage(player, fallback)
  }

  function trackSignature(player) {
    return MediaModel.trackSignature(player)
  }

  function showOsd(actionLabel, iconName, player) {
    if (!shell) return
    shell.summon("omarchy.osd", JSON.stringify({
      icon: iconName || "media",
      message: osdMessage(player || activePlayer, actionLabel)
    }))
  }

  function scheduleOsd(actionLabel, iconName, player, waitForTrackChange, beforeTrackSignature) {
    if (waitForTrackChange) {
      pendingTrackOsd = {
        actionLabel: actionLabel,
        iconName: iconName,
        player: player,
        playerKey: playerKey(player),
        before: beforeTrackSignature,
        attempts: 0
      }
      trackOsdTimer.restart()
    } else {
      Qt.callLater(function() { root.showOsd(actionLabel, iconName, player) })
    }
  }

  function flushPendingTrackOsd(force) {
    var pending = pendingTrackOsd
    if (!pending) return

    var player = playerForKey(pending.playerKey) || pending.player
    if (force || MediaModel.trackChanged(pending.before, player) || pending.attempts >= 10) {
      pendingTrackOsd = null
      trackOsdTimer.stop()
      root.showOsd(pending.actionLabel, pending.iconName, player)
      return
    }

    pending.attempts = pending.attempts + 1
    pendingTrackOsd = pending
    trackOsdTimer.restart()
  }

  function selectPlayer(key) {
    var player = playerForKey(key)
    if (!player || !hasMetadata(player)) return false
    preferredPlayerKey = playerKey(player)
    return true
  }

  function playPlayer(player) {
    if (!player) return false
    if (player.canPlay) {
      player.play()
      return true
    }
    return false
  }

  function pausePlayer(player) {
    if (!player) return false
    if (player.canPause) {
      player.pause()
      return true
    }
    if (player.canTogglePlaying && player.isPlaying) {
      player.togglePlaying()
      return true
    }
    return false
  }

  function switchSource(delta, transferPlayback, showFeedback) {
    var list = sourceCyclePlayers
    if (!list || list.length === 0) return false

    var activeKey = playerKey(activePlayer)
    var index = 0
    for (var i = 0; i < list.length; i++) {
      if (playerKey(list[i]) === activeKey) {
        index = i
        break
      }
    }

    index = (index + delta + list.length) % list.length
    var current = activePlayer
    var next = list[index]
    var currentWasPlaying = current && current.isPlaying
    var currentKey = playerKey(current)
    var nextKey = playerKey(next)

    preferredPlayerKey = nextKey

    if (transferPlayback && currentWasPlaying && next && nextKey !== currentKey) {
      var nextWasPlaying = next.isPlaying
      var nextStarted = nextWasPlaying || playPlayer(next)
      if (nextStarted) pausePlayer(current)
    }

    if (showFeedback !== false) Qt.callLater(function() {
      root.showOsd("Source", "media-source", next)
    })

    return true
  }

  function playerForAction(action, targetKey) {
    var targeted = playerForKey(targetKey)
    if (targeted) return targeted

    if (action === "pause" || action === "playPause") {
      var oldest = oldestPlayingPlayer(true) || oldestPlayingPlayer(false)
      if (oldest) return oldest
    }

    if (canHandleAction(activePlayer, action)) return activePlayer

    var list = sourcePlayers
    for (var i = 0; i < list.length; i++) {
      if (canHandleAction(list[i], action)) return list[i]
    }

    return activePlayer
  }

  function runAction(action, showFeedback, targetKey) {
    var player = playerForAction(action, targetKey)
    var key = playerKey(player)
    var actionLabel = "Play/pause"
    var iconName = "media"
    var beforeTrackSignature = trackSignature(player)
    var handled = false

    if (action === "next") {
      actionLabel = "Next"
      iconName = "media-next"
      if (player && player.canGoNext) {
        player.next()
        handled = true
      }
    } else if (action === "previous") {
      actionLabel = "Previous"
      iconName = "media-previous"
      if (player && player.canGoPrevious) {
        player.previous()
        handled = true
      }
    } else if (action === "play") {
      actionLabel = "Play"
      iconName = "media-play"
      if (player && player.canPlay) {
        player.play()
        handled = true
      } else if (player && player.canTogglePlaying && !player.isPlaying) {
        player.togglePlaying()
        handled = true
      }
    } else if (action === "pause") {
      actionLabel = "Pause"
      iconName = "media-pause"
      if (player && player.canPause) {
        player.pause()
        handled = true
      } else if (player && player.canTogglePlaying && player.isPlaying) {
        player.togglePlaying()
        handled = true
      }
    } else if (action === "playPause") {
      actionLabel = player && player.isPlaying ? "Pause" : "Play"
      iconName = player && player.isPlaying ? "media-pause" : "media-play"
      if (player && player.isPlaying && player.canPause) {
        player.pause()
        handled = true
      } else if (player && !player.isPlaying && player.canPlay) {
        player.play()
        handled = true
      } else if (player && player.canTogglePlaying) {
        player.togglePlaying()
        handled = true
      }
    }

    if (handled && key) preferredPlayerKey = key
    if (showFeedback !== false)
      scheduleOsd(actionLabel, iconName, player, handled && (action === "next" || action === "previous"), beforeTrackSignature)
    return handled
  }

  // Recompute play-order reactively instead of polling every 500ms.
  // syncPlayingOrder only depends on the set of players and each player's
  // isPlaying state: onPlayersChanged covers players appearing/disappearing,
  // and the Instantiator wires isPlayingChanged for each live player.
  Component.onCompleted: root.syncPlayingOrder()
  onPlayersChanged: {
    root.syncPlayingOrder()
    // Catch the new mpv bus as soon as it appears instead of on the next tick.
    if (root.localPlaybackPending) root.adoptLocalPlayer()
  }

  Instantiator {
    model: root.players
    delegate: Connections {
      required property var modelData
      target: modelData
      function onIsPlayingChanged() { root.syncPlayingOrder() }
    }
  }

  Timer {
    id: trackOsdTimer
    interval: 120
    repeat: false
    onTriggered: root.flushPendingTrackOsd(false)
  }

  PwObjectTracker { objects: root.playbackStreams }

  function statusJson() {
    var p = activePlayer
    return JSON.stringify({
      hasPlayer: p !== null,
      hasMedia: root.hasMedia,
      playing: p ? !!p.isPlaying : false,
      identity: p ? (p.identity || "") : "",
      desktopEntry: p ? (p.desktopEntry || "") : "",
      title: p ? (p.trackTitle || "") : "",
      artist: p ? (p.trackArtist || "") : "",
      album: p && p.trackAlbum ? p.trackAlbum : "",
      artUrl: p && p.trackArtUrl ? p.trackArtUrl : "",
      canGoNext: p ? !!p.canGoNext : false,
      canGoPrevious: p ? !!p.canGoPrevious : false,
      canTogglePlaying: p ? !!p.canTogglePlaying : false
    })
  }

  IpcHandler {
    target: "media"

    function status(): string {
      return root.statusJson()
    }

    function playPause(): string {
      return root.runAction("playPause", true) ? "ok" : "unhandled"
    }

    function next(): string {
      return root.runAction("next", true) ? "ok" : "unhandled"
    }

    function previous(): string {
      return root.runAction("previous", true) ? "ok" : "unhandled"
    }

    function play(): string {
      return root.runAction("play", true) ? "ok" : "unhandled"
    }

    function pause(): string {
      return root.runAction("pause", true) ? "ok" : "unhandled"
    }

    function sourceNext(): string {
      return root.switchSource(1, false, true) ? "ok" : "unhandled"
    }

    function sourcePrevious(): string {
      return root.switchSource(-1, false, true) ? "ok" : "unhandled"
    }

    function sourceSwitch(): string {
      return root.switchSource(1, true, true) ? "ok" : "unhandled"
    }

    function sourceSwitchPrevious(): string {
      return root.switchSource(-1, true, true) ? "ok" : "unhandled"
    }

    function search(query: string): string {
      root.search(query)
      return "ok"
    }

    function results(): string {
      return JSON.stringify({
        query: root.searchQuery,
        searching: root.searching,
        error: root.searchError,
        results: root.searchResults
      })
    }

    function playId(videoId: string): string {
      return root.playResult(videoId) ? "ok" : "unhandled"
    }

    function stop(): string {
      root.stopPlayback()
      return "ok"
    }

    function ping(): string {
      return "ok"
    }
  }
}
