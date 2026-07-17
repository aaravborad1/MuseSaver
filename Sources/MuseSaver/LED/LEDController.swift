import AppKit
import CoreBluetooth

/// Drives generic BLE LED strips that use the Triones / "Happy Lighting"
/// protocol: service FFD5, write characteristic FFD9, color command
/// 0x56 R G B 0x00 0xF0 0xAA. Covers most no-name strips controlled by the
/// Happy Lighting / QHM / Triones phone apps.
///
/// Note: BLE strips accept a single connection — the phone app must be
/// disconnected for the Mac to take over.
@MainActor
final class LEDController: NSObject {
    private var central: CBCentralManager?
    private var strip: CBPeripheral?
    private var colorCharacteristic: CBCharacteristic?
    private var pendingColor: NSColor?

    private(set) var isConnected = false {
        didSet { onStateChange?() }
    }
    private(set) var isEnabled = false
    var onStateChange: (() -> Void)?

    private let serviceUUIDs = [CBUUID(string: "FFD5"), CBUUID(string: "FFD0")]
    private let colorCharUUID = CBUUID(string: "FFD9")
    private let namePrefixes = ["triones", "qhm-", "ledble", "happy", "elk-", "lotus", "ble-"]

    func enable() {
        guard !isEnabled else { return }
        isEnabled = true
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func disable() {
        isEnabled = false
        if let strip { central?.cancelPeripheralConnection(strip) }
        central?.stopScan()
        central = nil
        strip = nil
        colorCharacteristic = nil
        isConnected = false
    }

    /// Sends the album color to the strip, boosted to look vivid on LEDs
    /// (screen-tuned colors read muddy on a diode).
    func setColor(_ color: NSColor) {
        guard isEnabled else { return }
        guard let characteristic = colorCharacteristic, let strip else {
            pendingColor = color
            return
        }
        guard let rgb = Self.vividRGB(from: color) else { return }
        let command: [UInt8] = [0x56, rgb.r, rgb.g, rgb.b, 0x00, 0xF0, 0xAA]
        let type: CBCharacteristicWriteType =
            characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        strip.writeValue(Data(command), for: characteristic, type: type)
    }

    private func powerOn() {
        guard let characteristic = colorCharacteristic, let strip else { return }
        let type: CBCharacteristicWriteType =
            characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        strip.writeValue(Data([0xCC, 0x23, 0x33]), for: characteristic, type: type)
    }

    private static func vividRGB(from color: NSColor) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return nil }
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        let vivid = NSColor(hue: hue,
                            saturation: min(sat * 1.5, 1.0),
                            brightness: max(bri, 0.95),
                            alpha: 1)
        return (UInt8(vivid.redComponent * 255),
                UInt8(vivid.greenComponent * 255),
                UInt8(vivid.blueComponent * 255))
    }
}

extension LEDController: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            NSLog("MuseSaver LED: bluetooth state = \(central.state.rawValue)")
            guard central.state == .poweredOn, isEnabled else { return }
            NSLog("MuseSaver LED: scanning for strips…")
            // Scan unfiltered: many strips don't advertise their service UUID.
            central.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            let name = (peripheral.name ?? "").lowercased()
            let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
            let matchesService = advertised.contains(where: { serviceUUIDs.contains($0) })
            let matchesName = namePrefixes.contains(where: { name.hasPrefix($0) || name.contains($0) })

            if !name.isEmpty {
                NSLog("MuseSaver LED: saw '\(peripheral.name ?? "")' service=\(matchesService)")
            }
            guard matchesService || matchesName, strip == nil else { return }

            NSLog("MuseSaver LED: connecting to '\(peripheral.name ?? "unknown")'")
            strip = peripheral
            peripheral.delegate = self
            central.stopScan()
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            peripheral.discoverServices(serviceUUIDs)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            NSLog("MuseSaver LED: disconnected")
            strip = nil
            colorCharacteristic = nil
            isConnected = false
            // Strip may come back (powered off/on, phone app released it) — rescan.
            if isEnabled, central.state == .poweredOn {
                central.scanForPeripherals(withServices: nil, options: nil)
            }
        }
    }
}

extension LEDController: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: { serviceUUIDs.contains($0.uuid) }) else {
                // Some clones expose everything — look at all services.
                peripheral.services?.forEach { peripheral.discoverCharacteristics([colorCharUUID], for: $0) }
                return
            }
            peripheral.discoverCharacteristics([colorCharUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard let characteristic = service.characteristics?.first(where: { $0.uuid == colorCharUUID }) else {
                return
            }
            NSLog("MuseSaver LED: ready (char FFD9 on \(service.uuid))")
            colorCharacteristic = characteristic
            isConnected = true
            powerOn()
            if let pending = pendingColor {
                pendingColor = nil
                setColor(pending)
            }
        }
    }
}
