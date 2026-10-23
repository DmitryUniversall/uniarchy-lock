import QtQuick
import QtQuick.Effects
import Quickshell
import qs.Commons
import qs.Ui

// Minimal glass lock screen: crisp dimmed wallpaper, clock, a time-of-day
// greeting and a translucent pill password field styled from the theme's
// [lock] tokens.
Item {
  id: root

  property string backgroundPath: ""
  property int backgroundVersion: 0
  property bool fingerprintConfigured: false
  property bool authenticatingPassword: false
  property string failureMessage: ""
  property int failedAttempts: 0
  property bool inputEnabled: true
  property bool loadBackground: true
  property string passwordText: ""
  property bool syncingPasswordText: false
  // Desktop snapshot taken just before locking. The bar strip and each window
  // are cut out of it and slide apart, while the wallpaper stays in place.
  property string snapshotPath: ""
  property int snapshotVersion: 0
  // { border, rounding, windows: [{ x, y, w, h }] } for this screen.
  property var snapshotLayout: ({})
  property bool unlocking: false
  // 0 = desktop as captured, 1 = windows gone and the wallpaper dimmed.
  property real splitProgress: 1

  readonly property bool hasSnapshot: snapshot.status === Image.Ready
  readonly property var snapshotWindows: snapshotLayout && snapshotLayout.windows ? snapshotLayout.windows : []
  readonly property int windowBorder: snapshotLayout && snapshotLayout.border ? snapshotLayout.border : 0
  readonly property int windowRounding: snapshotLayout && snapshotLayout.rounding ? snapshotLayout.rounding : 0
  // While the backdrop is not fully opaque the surface must be transparent so
  // the compositor's session_lock_xray shows the live desktop underneath.
  readonly property bool seeThrough: backdrop.opacity < 0.999
  readonly property int barHeight: Style.bar.sizeHorizontal

  readonly property string userName: (Quickshell.env("USER") || Quickshell.env("LOGNAME") || "").toLowerCase()
  readonly property var englishLocale: Qt.locale("en_US")
  property date now: new Date()

  readonly property string placeholderText: "enter password"
  readonly property int fieldWidth: 340
  readonly property int fieldHeight: 50
  readonly property int outlineThickness: 1
  readonly property int clockFontSize: 92
  readonly property int dateFontSize: Style.font.title
  readonly property int greetingFontSize: Math.round(Style.font.heading * 1.5)
  readonly property int subtitleFontSize: Style.font.bodySmall
  readonly property int fieldFontSize: Style.font.title
  readonly property int passwordDotFontSize: Math.round(Style.font.heading * 1.1)
  readonly property int passwordDotLetterSpacing: Math.round(Style.font.heading * 0.3)
  // Space to keep clear on each side of the field for the fingerprint icon
  // (icon width plus a gap) so the centered dots never run under it.
  readonly property real fingerprintReserve: fingerprintConfigured ? Math.round(fingerprintIcon.implicitWidth + 10) : 0
  // Shrink the dots to fit once the password outgrows the field, so every
  // keystroke stays visible — otherwise long passwords clip with no feedback.
  readonly property real passwordDotScale: dotMetrics.advanceWidth > 0
    ? Math.min(1, (passwordInput.width - 4) / dotMetrics.advanceWidth)
    : 1
  readonly property bool showPasswordCursor: inputEnabled && !authenticatingPassword && failureMessage.length === 0
  readonly property bool errorState: failureMessage.length > 0
  readonly property var inputBorderSpec: errorState
    ? Border.surfaceSpec("lock", "border-error", Color.lock.borderError, root.outlineThickness, "border-alpha")
    : Border.surfaceSpec("lock", "border-active", Color.lock.borderActive, root.outlineThickness, "border-alpha")

  readonly property string greeting: {
    var hour = now.getHours()
    if (hour >= 5 && hour < 12) return "good morning"
    if (hour >= 12 && hour < 17) return "good afternoon"
    if (hour >= 17 && hour < 22) return "good evening"
    return "good night"
  }

  signal submitPassword(string password)
  signal passwordTextEdited(string password)
  signal clearFailureRequested()
  signal wakeRequested()

  // Cache-busts the lock background by appending `?v=`. Adding a query
  // string keeps Image's loader happy while forcing it to reload when the
  // user picks a new background mid-session.
  function fileUrl(path) {
    if (!path) return ""
    var encoded = String(path).split("/").map(encodeURIComponent).join("/")
    return "file://" + encoded + "?v=" + backgroundVersion
  }

  function forcePasswordFocus() {
    passwordInput.forceActiveFocus()
  }

  function clearPassword() {
    passwordTextEdited("")
  }

  function syncPasswordText() {
    if (passwordInput.text === passwordText) return
    syncingPasswordText = true
    passwordInput.text = passwordText
    syncingPasswordText = false
  }

  // Replays the staggered fade-in each time the lock (or its preview) is shown;
  // the view itself stays mounted between locks. With a snapshot the windows
  // slide apart over the wallpaper; without one the backdrop fades in over
  // the live desktop instead.
  function playIntro() {
    root.now = new Date()
    outroAnimation.stop()
    content.opacity = 1
    content.scale = 1
    splitProgress = hasSnapshot ? 0 : 1
    backdrop.opacity = hasSnapshot ? 1 : 0
    clockGroup.opacity = 0
    greetingGroup.opacity = 0
    inputField.opacity = 0
    if (hasSnapshot) splitAnimation.restart()
    else backdropInAnimation.restart()
    introAnimation.restart()
  }

  onPasswordTextChanged: syncPasswordText()
  onInputEnabledChanged: {
    if (inputEnabled) Qt.callLater(forcePasswordFocus)
  }
  onLoadBackgroundChanged: {
    if (loadBackground) playIntro()
  }
  // The surface's screen can resolve a beat after creation; restart the intro
  // with the snapshot if it only arrives once the fallback fade has begun.
  onHasSnapshotChanged: {
    if (hasSnapshot && loadBackground && !unlocking && introAnimation.running) playIntro()
  }
  onUnlockingChanged: {
    if (unlocking) {
      introAnimation.stop()
      splitAnimation.stop()
      backdropInAnimation.stop()
      outroAnimation.restart()
    }
  }
  Component.onCompleted: {
    syncPasswordText()
    if (inputEnabled) Qt.callLater(forcePasswordFocus)
    if (loadBackground) playIntro()
  }

  Timer {
    interval: 1000
    running: root.loadBackground
    repeat: true
    triggeredOnStart: true
    onTriggered: root.now = new Date()
  }

  // Measures the masked password at full size; passwordDotScale compares this
  // against the field width to decide how far the dots must shrink to fit.
  TextMetrics {
    id: dotMetrics
    font.family: Style.font.family
    font.pixelSize: root.passwordDotFontSize
    font.letterSpacing: root.passwordDotLetterSpacing
    text: "●".repeat(passwordInput.text.length)
  }

  ParallelAnimation {
    id: introAnimation

    SequentialAnimation {
      PropertyAction { targets: [clockGroup, greetingGroup, inputField]; property: "opacity"; value: 0 }
      PropertyAction { targets: [clockShift, greetingShift, inputShift]; property: "y"; value: 14 }
      PauseAnimation { duration: root.hasSnapshot ? 320 : 160 }
      ParallelAnimation {
        NumberAnimation { target: clockGroup; property: "opacity"; to: 1; duration: 650; easing.type: Easing.OutCubic }
        NumberAnimation { target: clockShift; property: "y"; to: 0; duration: 750; easing.type: Easing.OutCubic }
        SequentialAnimation {
          PauseAnimation { duration: 140 }
          ParallelAnimation {
            NumberAnimation { target: greetingGroup; property: "opacity"; to: 1; duration: 650; easing.type: Easing.OutCubic }
            NumberAnimation { target: greetingShift; property: "y"; to: 0; duration: 750; easing.type: Easing.OutCubic }
          }
        }
        SequentialAnimation {
          PauseAnimation { duration: 280 }
          ParallelAnimation {
            NumberAnimation { target: inputField; property: "opacity"; to: 1; duration: 650; easing.type: Easing.OutCubic }
            NumberAnimation { target: inputShift; property: "y"; to: 0; duration: 750; easing.type: Easing.OutCubic }
          }
        }
      }
    }
  }

  // Bar strip slides up, windows drift apart and the wallpaper dims.
  SequentialAnimation {
    id: splitAnimation

    PauseAnimation { duration: 60 }
    NumberAnimation { target: root; property: "splitProgress"; from: 0; to: 1; duration: 720; easing.type: Easing.InOutCubic }
  }

  NumberAnimation {
    id: backdropInAnimation
    target: backdrop
    property: "opacity"
    to: 1
    duration: 600
    easing.type: Easing.OutCubic
  }

  // Unlock: content lifts and fades, then the backdrop dissolves into the
  // live desktop before the service releases the session lock.
  ParallelAnimation {
    id: outroAnimation

    PropertyAction { target: root; property: "splitProgress"; value: 1 }
    NumberAnimation { target: content; property: "opacity"; to: 0; duration: 260; easing.type: Easing.InCubic }
    NumberAnimation { target: content; property: "scale"; to: 1.06; duration: 360; easing.type: Easing.InCubic }
    SequentialAnimation {
      PauseAnimation { duration: 80 }
      NumberAnimation { target: backdrop; property: "opacity"; to: 0; duration: 400; easing.type: Easing.InOutCubic }
    }
  }

  Item {
    id: backdrop
    anchors.fill: parent

    Rectangle {
      anchors.fill: parent
      color: Color.background
    }

    Image {
      id: wallpaper
      anchors.fill: parent
      source: root.loadBackground ? root.fileUrl(root.backgroundPath) : ""
      fillMode: Image.PreserveAspectCrop
      // Synchronous so it is already drawn under the windows on the first frame.
      asynchronous: false
      cache: false
      sourceSize.width: width
      sourceSize.height: height
    }

    // Light overall dim plus a soft darker band behind the centered content,
    // so text stays readable on bright wallpapers without blurring them.
    Item {
      anchors.fill: parent
      opacity: root.splitProgress

      Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.22)
      }

      Rectangle {
        anchors.fill: parent
        gradient: Gradient {
          GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.0) }
          GradientStop { position: 0.5; color: Qt.rgba(0, 0, 0, 0.3) }
          GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.0) }
        }
      }
    }
  }

  Item {
    id: snapshotLayer
    anchors.fill: parent
    visible: root.hasSnapshot && root.splitProgress < 1

    // Only a texture source for the pieces below; the wallpaper underneath
    // stands in for the rest of the desktop.
    Image {
      id: snapshot
      anchors.fill: parent
      source: root.snapshotPath ? root.fileUrl(root.snapshotPath).replace(/\?v=.*$/, "?v=" + root.snapshotVersion) : ""
      fillMode: Image.PreserveAspectCrop
      // Synchronous so the first lock frame already shows the desktop.
      asynchronous: false
      cache: false
      smooth: true
      visible: false
    }

    Repeater {
      model: root.snapshotWindows

      Item {
        id: windowPiece
        required property var modelData

        readonly property real baseX: modelData.x - root.windowBorder
        readonly property real baseY: modelData.y - root.windowBorder
        readonly property real baseWidth: modelData.w + root.windowBorder * 2
        readonly property real baseHeight: modelData.h + root.windowBorder * 2
        // Each window drifts away from the screen center, so side-by-side
        // windows part in opposite directions.
        readonly property real driftX: (baseX + baseWidth / 2 - root.width / 2) * 0.35
        readonly property real driftY: (baseY + baseHeight / 2 - root.height / 2) * 0.35 + root.height * 0.03

        x: baseX + driftX * root.splitProgress
        y: baseY + driftY * root.splitProgress
        width: baseWidth
        height: baseHeight
        scale: 1 - 0.08 * root.splitProgress
        opacity: Math.max(0, 1 - root.splitProgress * 1.2)
        layer.enabled: true
        layer.effect: MultiEffect {
          maskEnabled: true
          maskSource: windowMask
          maskThresholdMin: 0.5
          maskSpreadAtMin: 1.0
        }

        ShaderEffectSource {
          anchors.fill: parent
          sourceItem: snapshot
          sourceRect: Qt.rect(windowPiece.baseX, windowPiece.baseY, windowPiece.baseWidth, windowPiece.baseHeight)
        }

        Rectangle {
          id: windowMask
          anchors.fill: parent
          radius: root.windowRounding + root.windowBorder
          visible: false
          layer.enabled: true
        }
      }
    }

    ShaderEffectSource {
      id: barPiece
      x: 0
      y: -root.barHeight * 2 * Math.min(1, root.splitProgress * 1.4)
      width: parent.width
      height: root.barHeight
      opacity: Math.max(0, 1 - root.splitProgress * 1.6)
      sourceItem: snapshot
      sourceRect: Qt.rect(0, 0, snapshot.width, root.barHeight)
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    onClicked: { root.wakeRequested(); root.forcePasswordFocus() }
    onPositionChanged: root.wakeRequested()
  }

  Column {
    id: content
    anchors.centerIn: parent
    anchors.verticalCenterOffset: -Math.round(root.height * 0.03)
    spacing: 0

    Column {
      id: clockGroup
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: 2
      transform: Translate { id: clockShift }
      layer.enabled: true
      layer.effect: MultiEffect {
        shadowEnabled: true
        shadowColor: Qt.rgba(0, 0, 0, 0.75)
        shadowBlur: 1.0
        shadowVerticalOffset: 2
        shadowHorizontalOffset: 0
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        textFormat: Text.PlainText
        text: Qt.formatTime(root.now, "HH:mm")
        color: Color.lock.text
        font.family: Style.font.family
        font.pixelSize: root.clockFontSize
        font.weight: Font.Light
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        textFormat: Text.PlainText
        text: root.now.toLocaleDateString(root.englishLocale, "dddd, d MMMM").toLowerCase()
        color: Util.alpha(Color.lock.text, 0.85)
        font.family: Style.font.family
        font.pixelSize: root.dateFontSize
        font.letterSpacing: 1.5
      }
    }

    Item { width: 1; height: 54 }

    Column {
      id: greetingGroup
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: 8
      transform: Translate { id: greetingShift }
      layer.enabled: true
      layer.effect: MultiEffect {
        shadowEnabled: true
        shadowColor: Qt.rgba(0, 0, 0, 0.85)
        shadowBlur: 1.0
        shadowVerticalOffset: 1
        shadowHorizontalOffset: 0
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        textFormat: Text.PlainText
        text: root.greeting
        color: Color.lock.text
        font.family: Style.font.family
        font.pixelSize: root.greetingFontSize
        font.letterSpacing: 1
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        textFormat: Text.PlainText
        visible: root.userName.length > 0
        text: root.userName
        color: Util.alpha(Color.lock.text, 0.8)
        font.family: Style.font.family
        font.pixelSize: root.subtitleFontSize
        font.letterSpacing: 2.5
      }
    }

    Item { width: 1; height: 30 }

    BorderSurface {
      id: inputField
      anchors.horizontalCenter: parent.horizontalCenter
      width: root.fieldWidth
      height: root.fieldHeight
      color: Color.lock.background
      borderSpec: root.inputBorderSpec
      radius: height / 2
      clip: true
      transform: Translate { id: inputShift }

      TextInput {
        id: passwordInput
        anchors.fill: parent
        anchors.topMargin: inputField.borderTop
        // Reserve the fingerprint icon's width on both sides so the centered
        // dots stay symmetric and never slide under the icon as they grow.
        anchors.rightMargin: inputField.borderRight + 22 + root.fingerprintReserve
        anchors.bottomMargin: inputField.borderBottom
        anchors.leftMargin: inputField.borderLeft + 22 + root.fingerprintReserve
        verticalAlignment: TextInput.AlignVCenter
        horizontalAlignment: TextInput.AlignHCenter
        activeFocusOnPress: true
        clip: true
        enabled: root.inputEnabled && !root.authenticatingPassword
        readOnly: root.authenticatingPassword
        echoMode: TextInput.Password
        passwordCharacter: "●"
        passwordMaskDelay: 0
        color: Color.lock.text
        selectionColor: Color.lock.selection
        selectedTextColor: Color.lock.text
        font.family: Style.font.family
        font.pixelSize: text.length > 0 ? Math.max(1, Math.floor(root.passwordDotFontSize * root.passwordDotScale)) : root.fieldFontSize
        font.letterSpacing: text.length > 0 ? root.passwordDotLetterSpacing * root.passwordDotScale : 0
        cursorVisible: activeFocus && root.showPasswordCursor && text.length > 0
        cursorDelegate: Rectangle {
          width: 2
          color: Color.lock.text
          visible: passwordInput.cursorVisible
        }

        onTextChanged: {
          if (!root.syncingPasswordText) root.passwordTextEdited(text)
          if (text.length > 0) {
            root.wakeRequested()
          }
          if (text.length > 0 && root.failureMessage.length > 0) root.clearFailureRequested()
        }

        onAccepted: {
          var submitted = root.passwordText
          root.passwordTextEdited("")
          if (submitted.length > 0) root.submitPassword(submitted)
        }

        Keys.onPressed: function(event) {
          root.wakeRequested()
          if (event.key === Qt.Key_Escape || (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_U)) {
            root.passwordTextEdited("")
            event.accepted = true
          }
        }
      }

      Text {
        id: statusText
        textFormat: Text.PlainText
        anchors.fill: passwordInput
        text: root.authenticatingPassword ? "checking…" : (root.errorState ? root.failureMessage.toLowerCase() : root.placeholderText)
        visible: passwordInput.text.length === 0
        color: root.authenticatingPassword ? Color.lock.text : (root.errorState ? Color.lock.textError : Util.alpha(Color.lock.text, 0.7))
        font.family: Style.font.family
        font.pixelSize: root.fieldFontSize
        font.letterSpacing: 1
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight

        Behavior on color { ColorAnimation { duration: 200 } }
      }

      // Fingerprint hint pinned inside the field's right edge when a sensor is
      // enrolled, so the user knows they can touch to unlock instead of typing.
      Text {
        id: fingerprintIcon
        objectName: "fingerprintIndicator"
        anchors.right: parent.right
        anchors.rightMargin: inputField.borderRight + 20
        anchors.verticalCenter: parent.verticalCenter
        visible: root.fingerprintConfigured
        text: "󰈷"
        color: Util.alpha(Color.lock.text, 0.7)
        font.family: Style.font.family
        font.pixelSize: Math.round(root.fieldFontSize * 1.15)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
      }
    }
  }
}
