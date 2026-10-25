import Foundation
import HIDAcceleration
import StreamProtocol

/// Secondary click in a corner of the trackpad. `TrackpadCornerSecondaryClick` uses
/// 1 for the bottom-right corner and 2 for the bottom-left corner. Any other value is off.
enum TrackpadCornerClick: Equatable {
    case off
    case bottomRight
    case bottomLeft

    init(rawPreference: Int) {
        switch rawPreference {
        case 1: self = .bottomRight
        case 2: self = .bottomLeft
        default: self = .off
        }
    }
}

/// The Mac trackpad settings a virtual pad follows.
///
/// System Settings writes gesture keys into `com.apple.AppleMultitouchTrackpad` and,
/// for a Magic Trackpad, `com.apple.driver.AppleBluetoothMultitouch.trackpad`.
/// Natural scrolling is `com.apple.swipescrolldirection`. Tracking speed is
/// `HIDTrackpadAcceleration` in those trackpad domains, or `com.apple.trackpad.scaling`
/// in the global domain. The slider also publishes the live value through IOHID
/// under `HIDTrackpadAcceleration`. A missing key keeps the macOS default. A key
/// that is present wins over that default and over the IOHID value.
struct TrackpadPreferences: Equatable {
    /// `Clicking`. Off on a fresh macOS install.
    var tapToClick: Bool
    /// `TrackpadRightClick`. On by default: click or tap with two fingers.
    var twoFingerSecondaryClick: Bool
    /// `TrackpadCornerSecondaryClick`. Off by default.
    var cornerSecondaryClick: TrackpadCornerClick
    /// `com.apple.swipescrolldirection`. On by default since Lion: content follows the fingers.
    var naturalScrolling: Bool
    /// `TrackpadScroll`. On by default.
    var scroll: Bool
    /// `TrackpadHorizScroll`. On by default. Vertical scrolling stays available when this is off.
    var horizontalScroll: Bool
    /// `TrackpadMomentumScroll`. On by default.
    var momentumScroll: Bool
    /// Tracking speed on the System Settings scale, 0 (slow) through 3 (fast).
    /// The factory notch is 0.6875, which keeps one-finger movement unscaled.
    var trackingSpeed: Double
    /// `TrackpadThreeFingerDrag`. Off by default.
    var threeFingerDrag: Bool
    /// `Dragging`. Accessibility dragging (tap, then drag). Off by default.
    /// Read so a saved value is not mistaken for the factory default. One-finger
    /// moves stay pointer moves: applying drag lock would hold the mouse button
    /// across an ordinary finger drag.
    var dragging: Bool
    /// `DragLock`. Off by default. Paired with `dragging`.
    var dragLock: Bool
    /// `TrackpadPinch`. "Zoom in or out". On by default.
    var zoom: Bool = true

    /// The tracking-speed notch a Mac uses before the slider is moved.
    static let factoryTrackingSpeed = 0.6875

    static let factory = TrackpadPreferences(
        tapToClick: false,
        twoFingerSecondaryClick: true,
        cornerSecondaryClick: .off,
        naturalScrolling: true,
        scroll: true,
        horizontalScroll: true,
        momentumScroll: true,
        trackingSpeed: factoryTrackingSpeed,
        threeFingerDrag: false,
        dragging: false,
        dragLock: false
    )

    /// Live domains, including a tracking speed the user has applied in System Settings.
    static func load() -> TrackpadPreferences {
        let snapshot = TrackpadPreferenceSnapshot.live()
        return resolved(
            builtin: snapshot.builtin,
            bluetooth: snapshot.bluetooth,
            naturalScrolling: snapshot.naturalScrolling,
            globalTrackingSpeed: snapshot.globalTrackingSpeed,
            liveTrackingSpeed: snapshot.liveTrackingSpeed
        )
    }

    /// Same resolution as `load()`, using domains already copied from `UserDefaults`.
    static func load(userDefaults: UserDefaults) -> TrackpadPreferences {
        TrackpadPreferenceSnapshot.synchronize()
        return resolved(
            builtin: userDefaults.persistentDomain(forName: TrackpadPreferenceSnapshot.builtinDomain),
            bluetooth: userDefaults.persistentDomain(forName: TrackpadPreferenceSnapshot.bluetoothDomain),
            naturalScrolling: userDefaults.object(forKey: "com.apple.swipescrolldirection"),
            globalTrackingSpeed: userDefaults.object(forKey: "HIDTrackpadAcceleration")
                ?? userDefaults.object(forKey: "com.apple.trackpad.scaling")
        )
    }

    /// A key stored in only one trackpad domain wins over the factory value.
    /// When both domains store the key and they differ, the domain with
    /// `UserPreferences` set is the one the user saved. If both were saved,
    /// the built-in domain wins the tie.
    static func resolved(
        builtin: [String: Any]?,
        bluetooth: [String: Any]?,
        naturalScrolling: Any?,
        globalTrackingSpeed: Any? = nil,
        liveTrackingSpeed: Double? = nil
    ) -> TrackpadPreferences {
        var preferences = factory
        if let clicking = boolean(preference("Clicking", builtin: builtin, bluetooth: bluetooth)) {
            preferences.tapToClick = clicking
        }
        if let secondary = boolean(preference("TrackpadRightClick", builtin: builtin, bluetooth: bluetooth)) {
            preferences.twoFingerSecondaryClick = secondary
        }
        if let corner = integer(preference("TrackpadCornerSecondaryClick", builtin: builtin, bluetooth: bluetooth)) {
            preferences.cornerSecondaryClick = TrackpadCornerClick(rawPreference: corner)
        }
        if let scroll = boolean(preference("TrackpadScroll", builtin: builtin, bluetooth: bluetooth)) {
            preferences.scroll = scroll
        }
        if let horizontal = boolean(preference("TrackpadHorizScroll", builtin: builtin, bluetooth: bluetooth)) {
            preferences.horizontalScroll = horizontal
        }
        if let momentum = boolean(preference("TrackpadMomentumScroll", builtin: builtin, bluetooth: bluetooth)) {
            preferences.momentumScroll = momentum
        }
        if let threeFinger = boolean(preference("TrackpadThreeFingerDrag", builtin: builtin, bluetooth: bluetooth)) {
            preferences.threeFingerDrag = threeFinger
        }
        if let dragging = boolean(preference("Dragging", builtin: builtin, bluetooth: bluetooth)) {
            preferences.dragging = dragging
        }
        if let dragLock = boolean(preference("DragLock", builtin: builtin, bluetooth: bluetooth)) {
            preferences.dragLock = dragLock
        }
        if let pinch = boolean(preference("TrackpadPinch", builtin: builtin, bluetooth: bluetooth)) {
            preferences.zoom = pinch
        }
        if let natural = boolean(naturalScrolling) {
            preferences.naturalScrolling = natural
        }
        preferences.trackingSpeed = trackingSpeed(
            builtin: builtin,
            bluetooth: bluetooth,
            globalTrackingSpeed: globalTrackingSpeed,
            liveTrackingSpeed: liveTrackingSpeed
        )
        return preferences
    }

    private static func preference(
        _ key: String,
        builtin: [String: Any]?,
        bluetooth: [String: Any]?
    ) -> Any? {
        let fromBuiltin = builtin?[key]
        let fromBluetooth = bluetooth?[key]
        switch (fromBuiltin, fromBluetooth) {
        case (nil, nil):
            return nil
        case (let value?, nil):
            return value
        case (nil, let value?):
            return value
        case (let builtinValue?, let bluetoothValue?):
            if same(builtinValue, bluetoothValue) {
                return builtinValue
            }
            let builtinSaved = boolean(builtin?["UserPreferences"]) == true
            let bluetoothSaved = boolean(bluetooth?["UserPreferences"]) == true
            if bluetoothSaved && !builtinSaved {
                return bluetoothValue
            }
            return builtinValue
        }
    }

    /// Domain keys win over the global key, and a present key wins over the live
    /// IOHID value. The IOHID value is what the slider is applying when neither
    /// domain has written the key yet.
    private static func trackingSpeed(
        builtin: [String: Any]?,
        bluetooth: [String: Any]?,
        globalTrackingSpeed: Any?,
        liveTrackingSpeed: Double?
    ) -> Double {
        let stored = preference("HIDTrackpadAcceleration", builtin: builtin, bluetooth: bluetooth)
            ?? preference("com.apple.trackpad.scaling", builtin: builtin, bluetooth: bluetooth)
            ?? globalTrackingSpeed
        if let speed = speedValue(stored) {
            return clampSpeed(speed)
        }
        if let liveTrackingSpeed {
            return clampSpeed(liveTrackingSpeed)
        }
        return factoryTrackingSpeed
    }

    /// System Settings' scale is 0...3. The registry sometimes stores that same
    /// speed as a 16.16 fixed-point integer (`0.6875` is `45056`).
    private static func speedValue(_ value: Any?) -> Double? {
        guard let number = double(value) else { return nil }
        if abs(number) > 3 {
            return number / 65536
        }
        return number
    }

    private static func clampSpeed(_ speed: Double) -> Double {
        min(3, max(0, speed))
    }

    private static func same(_ lhs: Any, _ rhs: Any) -> Bool {
        guard let left = double(lhs), let right = double(rhs) else { return false }
        return left == right
    }

    private static func boolean(_ value: Any?) -> Bool? {
        switch value {
        case let flag as Bool:
            return flag
        case let number as Int:
            return number != 0
        case let number as NSNumber:
            return number.boolValue
        default:
            return nil
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        switch value {
        case let number as Int:
            return number
        case let number as NSNumber:
            return number.intValue
        default:
            return nil
        }
    }

    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as Double:
            return number
        case let number as Int:
            return Double(number)
        case let number as NSNumber:
            return number.doubleValue
        default:
            return nil
        }
    }
}

/// One read of the trackpad domains. `live()` asks cfprefsd again so a change
/// in System Settings is visible without restarting the server.
struct TrackpadPreferenceSnapshot {
    static let builtinDomain = "com.apple.AppleMultitouchTrackpad"
    static let bluetoothDomain = "com.apple.driver.AppleBluetoothMultitouch.trackpad"

    var builtin: [String: Any]?
    var bluetooth: [String: Any]?
    var naturalScrolling: Any?
    var globalTrackingSpeed: Any?
    var liveTrackingSpeed: Double?

    static func live() -> TrackpadPreferenceSnapshot {
        synchronize()
        return TrackpadPreferenceSnapshot(
            builtin: domain(builtinDomain),
            bluetooth: domain(bluetoothDomain),
            naturalScrolling: global("com.apple.swipescrolldirection"),
            globalTrackingSpeed: global("HIDTrackpadAcceleration") ?? global("com.apple.trackpad.scaling"),
            liveTrackingSpeed: liveAcceleration()
        )
    }

    static func synchronize() {
        let user = kCFPreferencesCurrentUser
        for name in [builtinDomain, bluetoothDomain] {
            CFPreferencesSynchronize(name as CFString, user, kCFPreferencesAnyHost)
        }
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, user, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, user, kCFPreferencesCurrentHost)
    }

    private static func domain(_ name: String) -> [String: Any]? {
        let domain = name as CFString
        guard let keys = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String],
              !keys.isEmpty else {
            return nil
        }
        return CFPreferencesCopyMultiple(
            keys as CFArray,
            domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String: Any]
    }

    /// Host-wide value first, then the per-machine value System Settings writes
    /// into the ByHost global domain.
    private static func global(_ key: String) -> Any? {
        if let value = globalValue(key, host: kCFPreferencesAnyHost) {
            return value
        }
        return globalValue(key, host: kCFPreferencesCurrentHost)
    }

    private static func globalValue(_ key: String, host: CFString) -> Any? {
        CFPreferencesCopyValue(
            key as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            host
        )
    }

    private static func liveAcceleration() -> Double? {
        var speed = 0.0
        guard SketchIntentCopyTrackpadAcceleration(&speed) == 0 else { return nil }
        return speed
    }
}

/// Turns a pad gesture into the mouse or scroll event that preference would produce.
enum TrackpadMapping {
    /// A one-finger tap in the bottom-right of this pad is always a right click.
    /// Control-click is the other Mac right-click, and this pad has no Control key.
    /// Anywhere else, a one-finger tap clicks when tap-to-click is on. The bottom-left
    /// corner is a right click only when that is the Mac secondary-click setting, and
    /// that corner still requires tap-to-click. A two-finger tap is the secondary
    /// button when two-finger secondary click is on, including when tap-to-click is off.
    static func click(fingers: Int, zone: TrackpadTapZone, preferences: TrackpadPreferences) -> TrackpadButton? {
        if fingers == 2 {
            return preferences.twoFingerSecondaryClick ? .right : nil
        }
        guard fingers == 1 else { return nil }
        if zone == .bottomRight {
            return .right
        }
        guard preferences.tapToClick else { return nil }
        if preferences.cornerSecondaryClick == .bottomLeft, zone == .bottomLeft {
            return .right
        }
        return .left
    }

    /// Finger deltas are y-down. Wheel deltas are the `CGEvent` scroll wheel:
    /// positive y scrolls up, which is content following a finger that moved down
    /// when natural scrolling is on. Nil when scrolling is turned off.
    static func wheelDelta(
        fingerDX: Int32,
        fingerDY: Int32,
        preferences: TrackpadPreferences
    ) -> (x: Int32, y: Int32)? {
        guard preferences.scroll else { return nil }
        var x: Int32 = preferences.horizontalScroll ? fingerDX : 0
        var y: Int32 = fingerDY
        if !preferences.naturalScrolling {
            x = -x
            y = -y
        }
        return (x, y)
    }

    /// Scales one-finger pointer travel by the System Settings tracking speed.
    /// 0 is visibly slower than unscaled movement, 0.6875 (the factory notch) stays
    /// one-to-one, and 3 is visibly faster.
    static func pointerScale(trackingSpeed: Double) -> Double {
        let speed = min(3, max(0, trackingSpeed))
        let neutral = TrackpadPreferences.factoryTrackingSpeed
        if abs(speed - neutral) < 0.0001 {
            return 1
        }
        if speed < neutral {
            return 0.35 + (speed / neutral) * 0.65
        }
        return 1 + ((speed - neutral) / (3 - neutral)) * 1.75
    }
}

/// Coasting scroll after a two-finger flick, in wheel pixels per second.
struct TrackpadMomentum: Equatable {
    var velocityX: Double
    var velocityY: Double

    /// Below this, a lift does not coast.
    static let minimumSpeed: Double = 140
    /// Coasting ends once the remaining speed drops under this.
    static let stopSpeed: Double = 24
    /// Exponential decay per second. A flick settles in about a second.
    static let friction: Double = 5

    /// Samples are already in wheel space. Needs two movements inside a short window.
    static func starting(samples: [(dx: Int32, dy: Int32, time: TimeInterval)]) -> TrackpadMomentum? {
        guard let last = samples.last else { return nil }
        let window = samples.filter { $0.time >= last.time - 0.09 && ($0.dx != 0 || $0.dy != 0) }
        guard window.count >= 2, let first = window.first else { return nil }
        let span = last.time - first.time
        guard span >= 0.012 else { return nil }
        let sumX = window.reduce(0) { $0 + Int($1.dx) }
        let sumY = window.reduce(0) { $0 + Int($1.dy) }
        let velocityX = Double(sumX) / span
        let velocityY = Double(sumY) / span
        guard hypot(velocityX, velocityY) >= minimumSpeed else { return nil }
        return TrackpadMomentum(velocityX: velocityX, velocityY: velocityY)
    }

    /// One frame. `next` is nil when this frame is the last movement.
    func advance(dt: Double) -> (dx: Int32, dy: Int32, next: TrackpadMomentum?) {
        let dx = Self.pixels(velocityX * dt)
        let dy = Self.pixels(velocityY * dt)
        let decay = exp(-Self.friction * dt)
        let next = TrackpadMomentum(velocityX: velocityX * decay, velocityY: velocityY * decay)
        if hypot(next.velocityX, next.velocityY) < Self.stopSpeed {
            return (dx, dy, nil)
        }
        return (dx, dy, next)
    }

    private static func pixels(_ value: Double) -> Int32 {
        let rounded = value.rounded()
        if rounded >= Double(Int32.max) { return Int32.max }
        if rounded <= Double(Int32.min) { return Int32.min }
        return Int32(rounded)
    }
}
