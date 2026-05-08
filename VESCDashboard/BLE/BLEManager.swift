import Foundation
import CoreBluetooth
import Combine

// Nordic UART Service — the de facto standard for VESC BLE modules
private enum NUS {
    static let service = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let tx      = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") // phone writes
    static let rx      = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") // phone reads/notifies
}

// Alternative service UUID used by some older VESC BLE modules
private let altServiceUUID = CBUUID(string: "0000FFE0-0000-1000-8000-00805F9B34FB")
private let altCharUUID    = CBUUID(string: "0000FFE1-0000-1000-8000-00805F9B34FB")

enum BLEConnectionState: Equatable {
    case idle
    case scanning
    case connecting
    case connected(String)   // device name
    case failed(String)
}

final class BLEManager: NSObject, ObservableObject {

    // MARK: - Published UI State (always on main thread)

    @Published var connectionState: BLEConnectionState = .idle
    @Published var discoveredDevices: [BLEDevice] = []
    @Published var isBluetoothReady = false

    /// Emits fully decoded VESC payloads (including command byte).
    let packetReceived = PassthroughSubject<[UInt8], Never>()
    /// Human-readable BLE event log entries.
    let logLine = PassthroughSubject<String, Never>()

    // MARK: - Private

    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var txChar: CBCharacteristic?
    private var rxChar: CBCharacteristic?

    /// Current device being connected/connected (set on BLE queue, read safely via copy)
    private var currentDevice: BLEDevice?

    /// Accumulate bytes across BLE notifications until we have a full packet.
    private var rxBuffer: [UInt8] = []
    private let maxBufferSize = 4096

    // Outbound packet queue — chunks pending BLE write (accessed only on bleQueue)
    private var writeQueue: [Data] = []

    private let bleQueue = DispatchQueue(label: "com.vescdash.ble", qos: .userInitiated)

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: bleQueue,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    // MARK: - Public API

    func startScanning() {
        guard central.state == .poweredOn else {
            emit("Cannot scan: Bluetooth not ready (state=\(central.state.rawValue))")
            return
        }
        DispatchQueue.main.async {
            self.discoveredDevices.removeAll()
            self.connectionState = .scanning
        }
        central.scanForPeripherals(
            withServices: [NUS.service, altServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        emit("Scanning for VESC devices…")
    }

    func stopScanning() {
        guard central.isScanning else { return }
        central.stopScan()
        emit("Scan stopped")
    }

    func connect(to device: BLEDevice) {
        stopScanning()
        currentDevice = device
        DispatchQueue.main.async { self.connectionState = .connecting }
        emit("Connecting to \(device.name)…")
        central.connect(device.peripheral, options: nil)
    }

    func disconnect() {
        guard let p = connectedPeripheral else { return }
        central.cancelPeripheralConnection(p)
    }

    /// Write raw bytes to the VESC. Enqueues on the BLE queue and respects MTU + flow control.
    func send(_ bytes: [UInt8]) {
        let data = Data(bytes)
        bleQueue.async { [weak self] in
            self?.writeQueue.append(data)
            self?.flushWriteQueue()
        }
    }

    // MARK: - Outbound queue (bleQueue only)

    /// Drains writeQueue using the peripheral's real MTU and canSendWriteWithoutResponse gating.
    private func flushWriteQueue() {
        guard let p = connectedPeripheral, let tx = txChar else {
            writeQueue.removeAll()
            return
        }
        // Use the negotiated MTU — typically 182–244 B on modern iOS; never below 20.
        let mtu = max(20, p.maximumWriteValueLength(for: .withoutResponse))

        while !writeQueue.isEmpty {
            guard p.canSendWriteWithoutResponse else {
                // Peripheral buffer full — readyToSendWriteWithoutResponse will resume us.
                return
            }
            let packet = writeQueue[0]
            if packet.count <= mtu {
                writeQueue.removeFirst()
                p.writeValue(packet, for: tx, type: .withoutResponse)
            } else {
                // Send one MTU-sized chunk and leave the remainder at the front.
                let chunk = Data(packet.prefix(mtu))
                writeQueue[0] = Data(packet.dropFirst(mtu))
                p.writeValue(chunk, for: tx, type: .withoutResponse)
            }
        }
    }

    // MARK: - Buffer Processing

    /// Consumes `rxBuffer`, emitting complete packet payloads as they arrive.
    private func drainBuffer() {
        // Guard against runaway growth (e.g. unsupported device flooding data)
        if rxBuffer.count > maxBufferSize {
            emit("Buffer overflow — clearing")
            rxBuffer.removeAll()
            return
        }

        while !rxBuffer.isEmpty {
            let start = rxBuffer[0]

            // Discard bytes that can't be packet starts
            guard start == 0x02 || start == 0x03 else {
                rxBuffer.removeFirst()
                continue
            }

            let isLong = (start == 0x03)
            let headerSize = isLong ? 3 : 2

            guard rxBuffer.count >= headerSize else { return } // need more data

            let payloadLen: Int
            if isLong {
                payloadLen = (Int(rxBuffer[1]) << 8) | Int(rxBuffer[2])
            } else {
                payloadLen = Int(rxBuffer[1])
            }

            // Sanity check length (VESC max payload ~512 bytes)
            guard payloadLen > 0, payloadLen <= 512 else {
                emit("Implausible payload length \(payloadLen) — discarding start byte")
                rxBuffer.removeFirst()
                continue
            }

            let totalSize = headerSize + payloadLen + 2 + 1 // hdr + payload + 2 CRC + stop
            guard rxBuffer.count >= totalSize else { return } // wait for rest of packet

            // Quick sanity: check stop byte before full parse
            guard rxBuffer[totalSize - 1] == 0x03 else {
                emit("Expected stop byte at \(totalSize - 1), got 0x\(String(rxBuffer[totalSize-1], radix:16)) — skipping")
                rxBuffer.removeFirst()
                continue
            }

            let packetBytes = Array(rxBuffer[0 ..< totalSize])
            rxBuffer.removeFirst(totalSize)

            do {
                let payload = try VESCProtocolParser.parsePacket(bytes: packetBytes)
                let cmd = payload.first.map { String($0) } ?? "?"
                emit("Packet OK cmd=\(cmd) len=\(payload.count)")
                // Deliver on main thread so subscribers don't need to dispatch
                DispatchQueue.main.async { self.packetReceived.send(payload) }
            } catch {
                emit("Parse error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Helpers

    private func emit(_ msg: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(ts)] \(msg)"
        DispatchQueue.main.async { self.logLine.send(line) }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let ready = central.state == .poweredOn
        DispatchQueue.main.async { self.isBluetoothReady = ready }

        switch central.state {
        case .poweredOn:
            emit("Bluetooth ready")
        case .poweredOff:
            emit("Bluetooth off")
            DispatchQueue.main.async { self.connectionState = .idle }
        case .unauthorized:
            DispatchQueue.main.async { self.connectionState = .failed("Bluetooth permission denied") }
        case .unsupported:
            DispatchQueue.main.async { self.connectionState = .failed("BLE not supported") }
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let device = BLEDevice(peripheral: peripheral, rssi: RSSI.intValue)
        DispatchQueue.main.async {
            if let idx = self.discoveredDevices.firstIndex(where: { $0.id == device.id }) {
                self.discoveredDevices[idx] = device
            } else {
                self.discoveredDevices.append(device)
            }
        }
        emit("Found \(device.name) RSSI=\(RSSI)")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedPeripheral = peripheral
        peripheral.delegate = self
        emit("Connected — discovering services…")
        peripheral.discoverServices([NUS.service, altServiceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        let msg = error?.localizedDescription ?? "unknown error"
        emit("Connection failed: \(msg)")
        DispatchQueue.main.async { self.connectionState = .failed(msg) }
        currentDevice = nil
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        connectedPeripheral = nil
        txChar = nil
        rxChar = nil
        rxBuffer.removeAll()
        writeQueue.removeAll()
        currentDevice = nil
        emit("Disconnected: \(error?.localizedDescription ?? "clean")")
        DispatchQueue.main.async { self.connectionState = .idle }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { emit("Service discovery error: \(error)"); return }

        for service in peripheral.services ?? [] {
            if service.uuid == NUS.service {
                peripheral.discoverCharacteristics([NUS.tx, NUS.rx], for: service)
            } else if service.uuid == altServiceUUID {
                peripheral.discoverCharacteristics([altCharUUID], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error { emit("Char discovery error: \(error)"); return }

        for char in service.characteristics ?? [] {
            switch char.uuid {
            case NUS.tx:
                txChar = char
                emit("TX char found")
            case NUS.rx:
                rxChar = char
                peripheral.setNotifyValue(true, for: char)
                emit("RX char found — subscribing")
            case altCharUUID:
                // Alt module: same char used for both TX and RX
                txChar = char
                rxChar = char
                peripheral.setNotifyValue(true, for: char)
                emit("Alt char found (TX+RX)")
            default:
                break
            }
        }

        if txChar != nil && rxChar != nil {
            let name = currentDevice?.name ?? peripheral.name ?? "Device"
            DispatchQueue.main.async { self.connectionState = .connected(name) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error { emit("Value update error: \(error)"); return }
        guard let data = characteristic.value, !data.isEmpty else { return }

        let bytes = [UInt8](data)
        emit("RX \(bytes.count)B: \(bytes.prefix(8).map { String(format:"%02X",$0) }.joined(separator:" "))\(bytes.count > 8 ? "…" : "")")
        rxBuffer.append(contentsOf: bytes)
        drainBuffer()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            emit("Notify subscribe error: \(error)")
        } else {
            emit("Notifications \(characteristic.isNotifying ? "enabled" : "disabled") on \(characteristic.uuid)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error { emit("Write error: \(error)") }
    }

    // Fired by iOS when the peripheral's transmit buffer has space again.
    func peripheral(_ peripheral: CBPeripheral,
                    readyToSendWriteWithoutResponse characteristic: CBCharacteristic) {
        flushWriteQueue()
    }
}
