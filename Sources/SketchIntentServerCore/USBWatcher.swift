import Foundation

/// Watches usbmuxd and connects to the SketchIntent app on each USB-attached iPad.
final class USBWatcher {
    private let port: UInt16
    /// Receives a connected tunnel. Call the completion when that session ends.
    var onSession: ((Int32, String, @escaping () -> Void) -> Void)?
    private let lock = NSLock()
    private var active = Set<Int>()
    private var lastReport = ""
    private var running = true

    init(port: UInt16) {
        self.port = port
    }

    func start() {
        let thread = Thread { [weak self] in
            self?.loop()
        }
        thread.name = "sketchintent.usbmux"
        thread.start()
    }

    private func setActive(_ deviceID: Int, connected: Bool) {
        lock.lock()
        if connected {
            active.insert(deviceID)
        } else {
            active.remove(deviceID)
        }
        lock.unlock()
    }

    private func loop() {
        while running {
            do {
                let devices = try Usbmux.listDevices().filter { $0.connectionType == "USB" }
                if devices.isEmpty {
                    report("Plug in the iPad with a USB cable and tap Trust.")
                }
                for device in devices where !isActive(device.deviceID) {
                    connect(device)
                }
            } catch {
                report("Waiting for usbmuxd (\(error)).")
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private func connect(_ device: USBDevice) {
        let fd: Int32
        do {
            fd = try Usbmux.connect(deviceID: device.deviceID, port: port)
        } catch let error as UsbmuxError where error.isRefused {
            if !hasActiveSession {
                report("iPad is on USB. Open the SketchIntent app on it.")
            }
            return
        } catch {
            report("USB connection failed: \(error)")
            return
        }

        guard let onSession else {
            POSIX.close(fd)
            return
        }
        let label = device.serialNumber.isEmpty ? "iPad \(device.deviceID)" : "iPad \(device.serialNumber)"
        setActive(device.deviceID, connected: true)
        report("USB connected to \(label).")
        onSession(fd, label) { [weak self] in
            self?.setActive(device.deviceID, connected: false)
        }
    }

    private var hasActiveSession: Bool {
        lock.lock()
        let active = !active.isEmpty
        lock.unlock()
        return active
    }

    private func isActive(_ deviceID: Int) -> Bool {
        lock.lock()
        let active = active.contains(deviceID)
        lock.unlock()
        return active
    }

    private func report(_ message: String) {
        guard message != lastReport else { return }
        lastReport = message
        print("[sketchintent] \(message)")
    }
}
