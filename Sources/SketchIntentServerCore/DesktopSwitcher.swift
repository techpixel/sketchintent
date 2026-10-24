import CoreGraphics
import Darwin
import Foundation
import StreamProtocol

/// One display's desktops, ordered left to right.
struct DesktopLayout: Equatable {
    var display: String
    var spaceIDs: [UInt64]
    var currentIndex: Int
}

/// Moves between macOS desktops directly. Control–arrow is not used: that shortcut
/// is delivered to whichever app is focused, so it never changes the space.
enum DesktopSwitcher {
    private static let queue = DispatchQueue(label: "sketchintent.desktop-switch")
    private static let skyLight = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        RTLD_LAZY
    )
    private static let connectionID: @convention(c) () -> Int32 = load("CGSMainConnectionID")
    private static let copySpaces: @convention(c) (Int32) -> CFArray? = load("CGSCopyManagedDisplaySpaces")
    private static let setCurrentSpace: @convention(c) (Int32, CFString, UInt64) -> Void = load(
        "CGSManagedDisplaySetCurrentSpace"
    )

    static func switchDesktop(_ direction: DesktopDirection) {
        queue.async {
            guard let layout = currentLayout() else {
                print("[sketchintent] Could not read the Mac desktops.")
                return
            }
            guard let target = neighbor(of: direction, in: layout) else {
                let edge = direction == .right ? "last" : "first"
                print("[sketchintent] Already on the \(edge) desktop.")
                return
            }
            guard activate(target, on: layout.display) else {
                print("[sketchintent] Could not switch desktops.")
                return
            }
            let side = direction == .right ? "right" : "left"
            print("[sketchintent] Applied desktop switch to the \(side).")
        }
    }

    /// The space immediately to the left or right of the current one, if it exists.
    static func neighbor(of direction: DesktopDirection, in layout: DesktopLayout) -> UInt64? {
        let next = direction == .right ? layout.currentIndex + 1 : layout.currentIndex - 1
        guard layout.spaceIDs.indices.contains(next) else { return nil }
        return layout.spaceIDs[next]
    }

    static func currentLayout() -> DesktopLayout? {
        guard skyLight != nil else { return nil }
        let connection = connectionID()
        guard let displays = copySpaces(connection) as? [[String: Any]] else { return nil }
        let wanted = mainDisplayUUID()
        let display = displays.first { wanted != nil && $0["Display Identifier"] as? String == wanted } ?? displays.first
        guard let display, let name = display["Display Identifier"] as? String else { return nil }
        let spaces = display["Spaces"] as? [[String: Any]] ?? []
        let ids = spaces.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
        guard let current = (display["Current Space"] as? [String: Any])?["id64"] as? NSNumber,
              let index = ids.firstIndex(of: current.uint64Value),
              !ids.isEmpty else { return nil }
        return DesktopLayout(display: name, spaceIDs: ids, currentIndex: index)
    }

    private static func activate(_ spaceID: UInt64, on display: String) -> Bool {
        guard skyLight != nil else { return false }
        setCurrentSpace(connectionID(), display as CFString, spaceID)
        guard let layout = currentLayout() else { return false }
        return layout.spaceIDs[layout.currentIndex] == spaceID
    }

    /// The SDK no longer exports this by name. The symbol still maps a display to the
    /// identifier Mission Control uses.
    private static func mainDisplayUUID() -> String? {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let pointer = dlsym(handle, "CGDisplayCreateUUIDFromDisplayID") else { return nil }
        let create = unsafeBitCast(
            pointer,
            to: (@convention(c) (UInt32) -> CFUUID?).self
        )
        guard let uuid = create(CGMainDisplayID()) else { return nil }
        return CFUUIDCreateString(kCFAllocatorDefault, uuid) as String
    }

    private static func load<T>(_ name: String) -> T {
        guard let skyLight, let pointer = dlsym(skyLight, name) else {
            fatalError("SkyLight is missing \(name)")
        }
        return unsafeBitCast(pointer, to: T.self)
    }
}
