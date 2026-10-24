import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Pam
import Quickshell.Wayland
import qs.Commons

Item {
  id: root

  property var shell: null
  property string omarchyPath: ""

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: home + "/.local/state"
  readonly property string userName: Quickshell.env("USER") || Quickshell.env("LOGNAME")
  readonly property string currentBackgroundLink: stateHome + "/omarchy/current/background"

  property bool lockRequested: false
  property bool pendingSessionLock: false
  property bool authenticatingPassword: false
  property bool fingerprintAuthenticating: false
  property bool passwordPamConfigured: false
  property bool fingerprintConfigured: false
  property bool previewVisible: false
  property string enteredPassword: ""
  property string pendingPassword: ""
  property string failureMessage: ""
  property int failedAttempts: 0
  property string backgroundPath: ""
  property int backgroundVersion: 0
  property string lastEvent: "init"
  property string lastEventAt: ""
  property bool strandedLock: false
  property bool strandedLockResolved: false

  // Desktop snapshot the lock view animates away on lock. Lives in the
  // per-user runtime dir and is removed again on unlock.
  readonly property string snapshotDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omarchy-lock-snapshot"
  readonly property int snapshotWaitMs: 1500
  readonly property int unlockOutroMs: 520
  property bool snapshotReady: false
  // snapshot.sh output: { border, rounding, monitors: { <name>: [windows] } }
  property var snapshotWindows: ({})
  property int snapshotVersion: 0
  property double snapshotStartedAt: 0
  property bool previewPending: false
  property bool unlocking: false
  property bool previewUnlocking: false
  property bool previewAmbient: false

  // Inline settings from this plugin's entry in shell.json; anything missing
  // falls back to these defaults.
  readonly property string pluginId: "uniarchy.lock"
  readonly property string shellConfigPath: home + "/.config/omarchy/shell.json"
  readonly property var defaultSettings: ({
    clockFormat: "HH:mm",
    dateFormat: "dddd, d MMMM",
    greeting: true,
    showUser: true,
    dim: 0.22,
    animations: true,
    keyboardLayout: true,
    battery: true,
    powerButtons: true,
    alwaysOnAfter: 30,
    alwaysOnBrightness: 15,
    screenOffAfter: 120
  })
  property var settings: defaultSettings

  // Keyboard state shown in the password field.
  property string keyboardLayout: ""
  property bool capsLock: false
  property bool keyboardRefreshPending: false

  // "" | "failed": flashes when a finger is read but does not match.
  property string fingerprintFeedback: ""
  // Dimmed clock-only screen shown after alwaysOnAfter seconds of inactivity.
  property bool ambient: false
  property bool backlightDimmed: false

  readonly property bool locked: lockRequested || sessionLock.locked || sessionLock.secure
  readonly property bool authenticating: authenticatingPassword || fingerprintAuthenticating

  function realScreenCount() {
    var screens = Quickshell.screens || []
    var count = 0

    for (var i = 0; i < screens.length; i++) {
      var screen = screens[i]
      if (screen && screen.name && screen.width > 0 && screen.height > 0) count += 1
    }

    return count
  }

  function hasRealScreen() {
    return realScreenCount() > 0
  }

  function queueSessionLock() {
    pendingSessionLock = true
    if (!sessionLockStabilizeTimer.running) logEvent("lock-pending: screen-stabilizing")
    sessionLockStabilizeTimer.restart()
    if (!pendingSessionLockTimer.running) pendingSessionLockTimer.start()
  }

  function requestSessionLock() {
    if (!lockRequested || sessionLock.locked || sessionLock.secure) return
    if (sessionLockStabilizeTimer.running) return
    // Give the desktop snapshot a moment to land, but never hold the lock long.
    if (snapshotProc.running && Date.now() - snapshotStartedAt < snapshotWaitMs) return

    if (!hasRealScreen()) {
      if (!pendingSessionLock || lastEvent !== "lock-pending: no-real-screen") logEvent("lock-pending: no-real-screen")
      pendingSessionLock = true
      if (!pendingSessionLockTimer.running) pendingSessionLockTimer.start()
      return
    }

    pendingSessionLock = false
    pendingSessionLockTimer.stop()
    sessionLock.locked = true
  }

  // ext-session-lock outlives its client, and a restart carries no lock over, so
  // a session locked this early is an orphan behind Hyprland's failsafe. Outputs
  // are often still absent here, so ask until the answer means something.
  function checkStrandedLock() {
    if (strandedLockResolved || strandedLockCheckProc.running) return

    // A lock this shell took is nobody's orphan.
    if (locked || lockRequested) {
      strandedLockResolved = true
      return
    }

    strandedLockCheckProc.running = true
  }

  function recoverStrandedLock() {
    if (!strandedLock || locked || !passwordPamConfigured) return

    strandedLock = false
    logEvent("lock-stranded: recovering")
    beginLock()
  }

  function applySettings(text) {
    var entry = null
    try {
      var config = JSON.parse(String(text || "{}"))
      var plugins = Array.isArray(config.plugins) ? config.plugins : []
      for (var i = 0; i < plugins.length; i++) {
        if (plugins[i] && plugins[i].id === pluginId) entry = plugins[i]
      }
    } catch (e) {
      // Keep the last good settings while shell.json is mid-edit.
      return
    }

    var next = {}
    for (var key in defaultSettings) {
      var value = entry && entry[key] !== undefined ? entry[key] : defaultSettings[key]
      next[key] = typeof defaultSettings[key] === "number" ? Number(value) : value
    }
    settings = next
  }

  function refreshKeyboard() {
    if (!settings.keyboardLayout) return
    if (keyboardProc.running) {
      keyboardRefreshPending = true
      return
    }
    keyboardRefreshPending = false
    keyboardProc.running = true
  }

  // Picks the keyboard someone types on: fcitx5's virtual keyboard and power
  // or video buttons also show up as keyboards but never carry the layout.
  function readKeyboard(text) {
    var keyboards = []
    try {
      keyboards = (JSON.parse(String(text || "{}")).keyboards || []).filter(function(k) {
        return k && k.name && !/virtual|fcitx|button|video-bus|hotkey|switch/i.test(k.name)
      })
    } catch (e) {
      return
    }
    if (keyboards.length === 0) return

    var keyboard = keyboards[0]
    for (var i = 0; i < keyboards.length; i++) {
      if (keyboards[i].main) keyboard = keyboards[i]
      if (keyboards[i].active_layout_index > keyboard.active_layout_index) keyboard = keyboards[i]
    }

    var layouts = String(keyboard.layout || "").split(",")
    var code = layouts[keyboard.active_layout_index] || layouts[0] || ""
    var names = { us: "en", gb: "en" }
    keyboardLayout = layouts.length > 1 ? (names[code] || code).substring(0, 3) : ""
    capsLock = !!keyboard.capsLock
  }

  function enterAmbient() {
    if (!lockRequested || unlocking || ambient) return
    ambient = true
    logEvent("ambient")
    var brightness = Math.round(Number(settings.alwaysOnBrightness) || 0)
    if (brightness > 0 && !backlightDimmed) {
      backlightDimmed = true
      backlightProc.command = ["bash", "-c", "d=$(omarchy-hw-display) && brightnessctl -q -d \"$d\" -s set \"$1%\"", "_", String(brightness)]
      backlightProc.running = true
    }
  }

  function leaveAmbient() {
    ambient = false
    if (!backlightDimmed) return
    backlightDimmed = false
    // A dim still being applied restores once it lands (see backlightProc).
    if (!backlightProc.running) backlightRestoreProc.running = true
  }

  function armAmbientTimer() {
    var after = Number(settings.alwaysOnAfter) || 0
    var off = Number(settings.screenOffAfter) || 0
    if (after <= 0 || (off > 0 && after >= off)) {
      ambientTimer.stop()
      return
    }
    ambientTimer.interval = after * 1000
    ambientTimer.restart()
  }

  function powerAction(action) {
    if (!lockRequested || unlocking) return
    var commands = {
      suspend: "systemctl suspend",
      reboot: "omarchy-system-reboot",
      shutdown: "omarchy-system-shutdown"
    }
    if (!commands[action] || powerProc.running) return
    logEvent("power: " + action)
    powerProc.command = ["bash", "-c", commands[action]]
    powerProc.running = true
  }

  function closePreview() {
    previewOutroTimer.stop()
    previewUnlocking = false
    previewAmbient = false
    previewVisible = false
    clearSnapshot()
  }

  function snapshotLayoutFor(screen) {
    if (!screen) screen = (Quickshell.screens || [])[0]
    var monitors = snapshotWindows && snapshotWindows.monitors ? snapshotWindows.monitors : {}
    return {
      border: snapshotWindows.border || 0,
      rounding: snapshotWindows.rounding || 0,
      windows: screen && monitors[screen.name] ? monitors[screen.name] : []
    }
  }

  function snapshotPathFor(screen) {
    if (!screen) screen = (Quickshell.screens || [])[0]
    if (!snapshotReady || !screen || !screen.name) return ""
    return snapshotDir + "/" + screen.name + ".ppm"
  }

  function captureSnapshot() {
    snapshotReady = false
    if (snapshotProc.running) return

    var names = []
    var screens = Quickshell.screens || []
    for (var i = 0; i < screens.length; i++) {
      if (screens[i] && screens[i].name) names.push(screens[i].name)
    }

    snapshotStartedAt = Date.now()
    var script = decodeURIComponent(Qt.resolvedUrl("snapshot.sh").toString().replace(/^file:\/\//, ""))
    snapshotProc.command = ["bash", script, snapshotDir].concat(names)
    snapshotProc.running = true
  }

  function clearSnapshot() {
    snapshotReady = false
    if (!snapshotCleanupProc.running) snapshotCleanupProc.running = true
  }

  function refreshBackground() {
    if (!readlinkProc.running) readlinkProc.running = true
  }

  function refreshFingerprintStatus() {
    if (!fingerprintCheckProc.running) fingerprintCheckProc.running = true
  }

  function logEvent(event) {
    lastEvent = event
    lastEventAt = new Date().toISOString()
    console.log("omarchy lock " + lastEventAt + " " + event)
  }

  function resetAuthenticationState() {
    enteredPassword = ""
    pendingPassword = ""
    failureMessage = ""
    failedAttempts = 0
    fingerprintFeedback = ""
    authenticatingPassword = false
    fingerprintAuthenticating = false
    fingerprintRetryTimer.stop()
    if (passwordPam.active) passwordPam.abort()
    if (fingerprintPam.active) fingerprintPam.abort()
  }

  function beginLock() {
    if (!passwordPamConfigured) {
      logEvent("lock-denied: missing-pam")
      return false
    }

    resetAuthenticationState()
    unlocking = false
    leaveAmbient()
    if (settings.animations) captureSnapshot()
    refreshKeyboard()
    lockRequested = true
    armBlankTimer()
    logEvent("lock-requested")
    queueSessionLock()

    Qt.callLater(function() {
      root.refreshBackground()
      root.refreshFingerprintStatus()
    })

    return true
  }

  function finishUnlock() {
    if (!root.locked && !lockRequested) return
    if (unlocking) return

    // Keep the session locked while the view fades out over the live desktop
    // (misc:session_lock_xray), then release it.
    if (sessionLock.locked && settings.animations) {
      unlocking = true
      resetAuthenticationState()
      runWake()
      idleBlankTimer.stop()
      ambientTimer.stop()
      logEvent("unlock-outro")
      unlockOutroTimer.restart()
      return
    }

    completeUnlock()
  }

  function completeUnlock() {
    unlockOutroTimer.stop()
    unlocking = false
    lockRequested = false
    pendingSessionLock = false
    sessionLockStabilizeTimer.stop()
    pendingSessionLockTimer.stop()
    resetAuthenticationState()
    idleBlankTimer.stop()
    ambientTimer.stop()
    leaveAmbient()
    sessionLock.locked = false
    logEvent("unlocked")
    runWake()
    clearSnapshot()
  }

  function armBlankTimer() {
    armAmbientTimer()
    var off = Number(settings.screenOffAfter) || 0
    if (off <= 0) {
      idleBlankTimer.stop()
      return
    }
    idleBlankTimer.interval = off * 1000
    idleBlankTimer.armedAt = Date.now()
    idleBlankTimer.restart()
  }

  function runWake() {
    if (!wakeProcess.running) wakeProcess.running = true
    if (ambient || backlightDimmed) leaveAmbient()
    if (lockRequested) armBlankTimer()
  }

  function runBlank() {
    if (!blankProcess.running) blankProcess.running = true
  }

  function submitPassword(value) {
    var password = String(value || "")
    if (!lockRequested || authenticatingPassword || password.length === 0) return

    runWake()
    pendingPassword = password
    failureMessage = ""
    authenticatingPassword = true

    if (!passwordPam.start()) {
      handlePasswordFailure()
      return
    }

    Qt.callLater(respondToPasswordPrompt)
  }

  function respondToPasswordPrompt() {
    if (!authenticatingPassword || !passwordPam.active || !passwordPam.responseRequired) return
    passwordPam.respond(pendingPassword)
  }

  function handlePasswordFailure() {
    if (!lockRequested) return

    authenticatingPassword = false
    enteredPassword = ""
    pendingPassword = ""
    failedAttempts += 1
    failureMessage = "Authentication failed (" + failedAttempts + ")"
    runWake()
  }

  function startFingerprint() {
    if (!lockRequested || !sessionLock.secure || !fingerprintConfigured) return
    if (fingerprintPam.active || fingerprintAuthenticating) return

    fingerprintAuthenticating = true
    if (!fingerprintPam.start()) {
      fingerprintAuthenticating = false
    }
  }

  function handleFingerprintFinished(result) {
    fingerprintAuthenticating = false

    if (!lockRequested) return
    if (result === PamResult.Success) {
      finishUnlock()
    } else if (fingerprintConfigured) {
      fingerprintRetryTimer.restart()
    }
  }

  WlSessionLock {
    id: sessionLock

    locked: false

    onSecureStateChanged: {
      root.logEvent("secure=" + secure)
      if (secure) {
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
        root.startFingerprint()
      }
    }

    onLockStateChanged: {
      root.logEvent("session-locked=" + locked)

      if (locked) {
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
      }

      if (!locked && root.lockRequested) {
        unlockOutroTimer.stop()
        root.unlocking = false
        root.clearSnapshot()
        root.lockRequested = false
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
        root.resetAuthenticationState()
        root.runWake()
      }
    }

    WlSessionLockSurface {
      id: lockSurface
      // Transparent only while the view is fading over the desktop.
      color: lockView.seeThrough ? "transparent" : Color.background

      LockView {
        id: lockView
        anchors.fill: parent
        backgroundPath: root.backgroundPath
        backgroundVersion: root.backgroundVersion
        snapshotPath: root.snapshotPathFor(lockSurface.screen)
        snapshotVersion: root.snapshotVersion
        snapshotLayout: root.snapshotLayoutFor(lockSurface.screen)
        unlocking: root.unlocking
        fingerprintConfigured: root.fingerprintConfigured
        authenticatingPassword: root.authenticatingPassword
        failureMessage: root.failureMessage
        failedAttempts: root.failedAttempts
        inputEnabled: root.lockRequested && !root.unlocking
        settings: root.settings
        keyboardLayout: root.keyboardLayout
        capsLock: root.capsLock
        fingerprintFeedback: root.fingerprintFeedback
        fingerprintScanning: root.fingerprintAuthenticating
        ambient: root.ambient
        onKeyboardStateRequested: root.refreshKeyboard()
        onPowerRequested: function(action) { root.powerAction(action) }
        loadBackground: root.locked
        passwordText: root.enteredPassword
        onPasswordTextEdited: function(password) { root.enteredPassword = password }
        onSubmitPassword: function(password) { root.submitPassword(password) }
        onClearFailureRequested: root.failureMessage = ""
        onWakeRequested: root.runWake()
      }

    }
  }

  PanelWindow {
    id: previewWindow
    visible: root.previewVisible
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-lock-preview"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    LockView {
      anchors.fill: parent
      backgroundPath: root.backgroundPath
      backgroundVersion: root.backgroundVersion
      snapshotPath: root.snapshotPathFor(previewWindow.screen)
      snapshotVersion: root.snapshotVersion
      snapshotLayout: root.snapshotLayoutFor(previewWindow.screen)
      unlocking: root.previewUnlocking
      settings: root.settings
      keyboardLayout: root.keyboardLayout
      capsLock: root.capsLock
      fingerprintScanning: root.fingerprintConfigured
      ambient: root.previewAmbient
      fingerprintConfigured: root.fingerprintConfigured
      authenticatingPassword: false
      failureMessage: ""
      failedAttempts: 0
      inputEnabled: false
      loadBackground: root.previewVisible
      passwordText: ""
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: root.closePreview()
    }
  }

  PamContext {
    id: passwordPam
    config: "omarchy-lock-password"
    user: root.userName

    onResponseRequiredChanged: root.respondToPasswordPrompt()
    onPamMessage: root.respondToPasswordPrompt()

    onCompleted: function(result) {
      root.authenticatingPassword = false
      root.pendingPassword = ""

      if (!root.lockRequested) return
      if (result === PamResult.Success) root.finishUnlock()
      else root.handlePasswordFailure()
    }

    onError: function(error) {
      root.handlePasswordFailure()
    }
  }

  PamContext {
    id: fingerprintPam
    config: "omarchy-lock-fingerprint"
    user: root.userName

    // pam_fprintd reports each unmatched read as a message and only fails the
    // conversation after several, so flash on the message itself.
    onPamMessage: {
      var text = String(message || "")
      if (!root.lockRequested || !/match|fail/i.test(text)) return
      root.fingerprintFeedback = "failed"
      root.runWake()
      fingerprintFeedbackTimer.restart()
    }

    onCompleted: function(result) {
      root.handleFingerprintFinished(result)
    }

    onError: function(error) {
      root.fingerprintAuthenticating = false
      if (root.lockRequested && root.fingerprintConfigured) fingerprintRetryTimer.restart()
    }
  }

  Timer {
    id: fingerprintRetryTimer
    interval: 250
    repeat: false
    onTriggered: root.startFingerprint()
  }

  Process {
    id: readlinkProc
    command: ["readlink", "-f", root.currentBackgroundLink]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = String(text || "").trim()
        if (next !== root.backgroundPath) {
          root.backgroundPath = next
          root.backgroundVersion += 1
        }
      }
    }
  }

  Process {
    id: fingerprintCheckProc
    command: ["bash", "-c", "if [[ -f /etc/pam.d/omarchy-lock-fingerprint ]] && command -v fprintd-list >/dev/null 2>&1 && fprintd-list \"$USER\" 2>/dev/null | grep -qi finger; then echo yes; else echo no; fi"]
    stdout: StdioCollector { id: fingerprintCheckStdout; waitForEnd: true }
    onExited: {
      root.fingerprintConfigured = String(fingerprintCheckStdout.text || "").trim() === "yes"
      if (root.lockRequested && root.fingerprintConfigured) root.startFingerprint()
      else if (!root.fingerprintConfigured && fingerprintPam.active) fingerprintPam.abort()
    }
  }

  Process {
    id: strandedLockCheckProc
    command: ["bash", "-c", "omarchy-hyprland-session-locked"]
    onExited: function(exitCode) {
      // No output to read the lock off yet.
      if (exitCode === 2) return

      root.strandedLockResolved = true

      // A lock taken while this was in flight is this shell's own.
      root.strandedLock = exitCode === 0 && !root.locked && !root.lockRequested
      root.recoverStrandedLock()
    }
  }

  Process {
    id: snapshotProc
    stdout: StdioCollector { id: snapshotStdout; waitForEnd: true }
    onExited: function(exitCode) {
      try {
        root.snapshotWindows = JSON.parse(String(snapshotStdout.text || "{}"))
      } catch (e) {
        root.snapshotWindows = ({})
      }
      root.snapshotReady = exitCode === 0
      root.snapshotVersion += 1
      if (root.previewPending) {
        root.previewPending = false
        root.previewVisible = true
      }
    }
  }

  Process {
    id: snapshotCleanupProc
    command: ["rm", "-rf", root.snapshotDir]
  }

  FileView {
    path: root.shellConfigPath
    watchChanges: true
    onFileChanged: reload()
    onLoaded: root.applySettings(text())
  }

  Process {
    id: keyboardProc
    command: ["hyprctl", "-j", "devices"]
    stdout: StdioCollector { id: keyboardStdout; waitForEnd: true }
    onExited: {
      root.readKeyboard(keyboardStdout.text)
      if (root.keyboardRefreshPending) root.refreshKeyboard()
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!root.lockRequested || !event || String(event.name) !== "activelayout") return
      root.refreshKeyboard()
    }
  }

  Process { id: powerProc }
  Process {
    id: backlightProc
    onExited: if (!root.backlightDimmed) backlightRestoreProc.running = true
  }

  Process {
    id: backlightRestoreProc
    command: ["bash", "-c", "d=$(omarchy-hw-display) && brightnessctl -q -d \"$d\" -r"]
  }

  Timer {
    id: ambientTimer
    repeat: false
    onTriggered: root.enterAmbient()
  }

  Timer {
    id: fingerprintFeedbackTimer
    interval: 1400
    repeat: false
    onTriggered: root.fingerprintFeedback = ""
  }

  Timer {
    id: previewOutroTimer
    interval: root.unlockOutroMs
    repeat: false
    onTriggered: root.closePreview()
  }

  Timer {
    id: unlockOutroTimer
    interval: root.unlockOutroMs
    repeat: false
    onTriggered: if (root.unlocking) root.completeUnlock()
  }

  Process {
    id: wakeProcess
    command: ["bash", "-c", "omarchy-system-wake"]
  }

  Process {
    id: blankProcess
    command: ["bash", "-c", "omarchy-brightness-keyboard off; omarchy-brightness-display off"]
  }

  Timer {
    id: idleBlankTimer
    // Set from settings.screenOffAfter by armBlankTimer().
    interval: 120000
    repeat: false
    property double armedAt: 0
    onTriggered: {
      // A countdown frozen by suspend fires right after resume, which would
      // blank the freshly woken unlock screen under the user. Wall-clock time
      // exposes the gap: take a fresh run-up instead of blanking.
      if (Date.now() - armedAt > interval + 2000) {
        root.armBlankTimer()
        return
      }
      // Only a password check in flight should hold the display up. The
      // fingerprint PAM stays armed for the whole lock, so gating on
      // `authenticating` here would keep the panel lit until unlock.
      if (root.lockRequested && !root.authenticatingPassword) root.runBlank()
    }
  }

  Timer {
    id: sessionLockStabilizeTimer
    interval: 500
    repeat: false
    onTriggered: root.requestSessionLock()
  }

  Timer {
    id: pendingSessionLockTimer
    interval: 100
    repeat: true
    onTriggered: root.requestSessionLock()
  }

  Timer {
    id: strandedLockRetryTimer
    interval: 500
    repeat: true
    // Covers the compositor settling; screens coming back re-arm it.
    readonly property int budget: 20
    property int remaining: 20
    running: !root.strandedLockResolved && remaining > 0

    function rearm() {
      if (!root.strandedLockResolved) remaining = budget
    }

    onTriggered: {
      remaining -= 1
      root.checkStrandedLock()
    }
  }

  Connections {
    target: Quickshell
    function onScreensChanged() {
      root.requestSessionLock()

      // A monitor still coming up has no workspace, so cannot answer yet.
      strandedLockRetryTimer.rearm()
      root.checkStrandedLock()
    }
  }

  onAuthenticatingPasswordChanged: {
    if (!lockRequested) return
    if (authenticatingPassword) idleBlankTimer.stop()
    else armBlankTimer()
  }

  FileView {
    path: "/etc/pam.d/omarchy-lock-password"
    watchChanges: true
    printErrors: false
    onLoaded: root.passwordPamConfigured = true
    onLoadFailed: root.passwordPamConfigured = false
    onFileChanged: reload()
  }

  // No lock before PAM is known good. An answer from before then may be stale --
  // the failsafe can be cleared from a TTY -- so re-ask rather than act on it.
  onPasswordPamConfiguredChanged: {
    if (!passwordPamConfigured) return

    strandedLock = false
    strandedLockResolved = false
    strandedLockRetryTimer.rearm()
    checkStrandedLock()
  }

  Component.onCompleted: {
    refreshBackground()
    refreshFingerprintStatus()
    checkStrandedLock()
  }

  IpcHandler {
    target: "lock"

    function lock(): string {
      if (!root.passwordPamConfigured) return "missing-pam"
      if (!root.locked && !root.beginLock()) return "failed"
      return "ok"
    }

    function isLocked(): string {
      return root.locked ? "true" : "false"
    }

    function status(): string {
      return JSON.stringify({
        locked: root.locked,
        requested: root.lockRequested,
        pending: root.pendingSessionLock,
        sessionLocked: sessionLock.locked,
        secure: sessionLock.secure,
        realScreens: root.realScreenCount(),
        passwordPam: root.passwordPamConfigured,
        fingerprint: root.fingerprintConfigured,
        authenticating: root.authenticating,
        lastEvent: root.lastEvent,
        lastEventAt: root.lastEventAt,
        ambient: root.ambient,
        keyboardLayout: root.keyboardLayout,
        settings: root.settings
      })
    }

    function preview(): string {
      root.previewUnlocking = false
      root.refreshKeyboard()
      root.refreshBackground()
      root.refreshFingerprintStatus()
      root.previewVisible = false
      root.previewPending = true
      root.captureSnapshot()
      return "ok"
    }

    function hidePreview(): string {
      root.closePreview()
      return "ok"
    }

    // Toggles the always-on look on an open preview.
    function previewAmbient(): string {
      if (!root.previewVisible) return "no-preview"
      root.previewAmbient = !root.previewAmbient
      return root.previewAmbient ? "on" : "off"
    }

    // Plays the unlock fade on an open preview, for trying the animation out.
    function previewUnlock(): string {
      if (!root.previewVisible) return "no-preview"
      root.previewUnlocking = true
      previewOutroTimer.restart()
      return "ok"
    }
  }
}
