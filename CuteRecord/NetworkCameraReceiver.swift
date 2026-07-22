import AVFoundation
import Combine
import CoreImage
import Network

/// Receives JPEG frames from the iOS CuteRecord手机版 app over TCP
/// and converts them to CVPixelBuffer for the recording pipeline.
/// Connects directly by IP — enter the IP shown on the iOS app.
final class NetworkCameraReceiver: ObservableObject {
    @Published var isConnected = false
    @Published var isReceiving = false
    @Published var currentResolution: CGSize = .zero

    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onOverlayFrame: ((CVPixelBuffer) -> Void)?
    var onAudioData: ((Data) -> Void)?
    var onConfirmation: (() -> Void)?

    private var ackBuffer = Data()
    private var isAwaitingAck = false

    private var connection: NWConnection?
    private let ciContext = CIContext()
    private let receiveQueue = DispatchQueue(label: "com.cuterecord.netcam", qos: .userInitiated)
    private var frameCount: UInt64 = 0
    private var receiveBuffer = Data()
    private let port: UInt16 = 9876

    func connect(to ipAddress: String) {
        disconnect()
        ackBuffer.removeAll()

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        guard let port = NWEndpoint.Port(rawValue: self.port) else { return }
        let host = NWEndpoint.Host(ipAddress)
        connection = NWConnection(host: host, port: port, using: params)

        connection?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.isConnected = true
                    print("📡 已连接 iOS 设备: \(ipAddress)")
                case .failed(let err):
                    self?.isConnected = false
                    print("📡 连接失败: \(err)")
                case .cancelled:
                    self?.isConnected = false
                default: break
                }
            }
        }
        connection?.start(queue: receiveQueue)
        receiveAck()
    }

    /// Wait for a confirmation ('K') from the iOS app within timeout seconds.
    private let ackLock = NSLock()

    func waitForAck(timeout: TimeInterval = 3.0) async -> Bool {
        isAwaitingAck = true
        let deadline = Date().addingTimeInterval(timeout)
        while isAwaitingAck, Date() < deadline {
            ackLock.lock()
            let hasAck = ackBuffer.count >= 5 && ackBuffer[0] == UInt8(ascii: "K")
            if hasAck { ackBuffer.removeSubrange(0..<5) }
            ackLock.unlock()
            if hasAck { isAwaitingAck = false; return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        isAwaitingAck = false
        return false
    }

    /// Called when iPhone sends a command back (e.g., stop notification)
    var onCommandReceived: ((String) -> Void)?

    private func receiveAck() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, _, error in
            guard let self, error == nil, let data, !data.isEmpty else {
                self?.receiveAck(); return
            }
            self.ackLock.lock()
            self.ackBuffer.append(data)
            // Parse complete commands from buffer
            while self.ackBuffer.count >= 5 {
                let size = Int(self.ackBuffer[1..<5].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
                guard size > 0, size < 10_000 else { self.ackBuffer.removeAll(); break }
                let total = 5 + size
                guard self.ackBuffer.count >= total else { break }
                let cmdData = self.ackBuffer.subdata(in: 5..<total)
                self.ackBuffer.removeSubrange(0..<total)
                if let cmd = String(data: cmdData, encoding: .utf8) {
                    DispatchQueue.main.async { self.onCommandReceived?(cmd) }
                }
            }
            self.ackLock.unlock()
            self.receiveAck()
        }
    }

    /// Send a control command to the iOS app.
    /// Protocol: [1-byte prefix (0x00)][4-byte big-endian size][UTF-8 payload]
    func sendCommand(_ cmd: String) {
        guard let conn = connection, let data = cmd.data(using: .utf8) else { return }
        var size = UInt32(data.count).bigEndian
        var header = Data([0x00])  // prefix byte
        header.append(Data(bytes: &size, count: 4))
        conn.send(content: header + data, completion: .idempotent)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false
        isReceiving = false
        receiveBuffer.removeAll()
    }

    /// Read data from TCP stream and accumulate into receiveBuffer.
    /// Parse complete frames from the buffer.
    /// Protocol: [4 bytes: size big-endian] [jpeg data]
    private func receiveNextFrame() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { return }
            if error != nil {
                DispatchQueue.main.async { self.isConnected = false }
                return
            }
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
            }
            self.parseBuffer()
            self.receiveNextFrame()
        }
    }

    private func parseBuffer() {
        // Protocol: [1 byte: type 'V'|'A'][4 bytes: size big-endian][data]
        while receiveBuffer.count >= 5 {
            let type = receiveBuffer[0]
            let size = Int(receiveBuffer[1..<5].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
            guard size > 0, size < 10_000_000 else {
                receiveBuffer.removeAll(); return
            }
            let totalNeeded = 5 + size
            guard receiveBuffer.count >= totalNeeded else { return }
            let data = receiveBuffer.subdata(in: 5..<totalNeeded)
            receiveBuffer.removeSubrange(0..<totalNeeded)
            switch type {
            case UInt8(ascii: "V"):
                processJPEGFrame(data)
            case UInt8(ascii: "A"):
                onAudioData?(data)
            default: break
            }
        }
    }

    private func processJPEGFrame(_ jpegData: Data) {
        guard let ciImage = CIImage(data: jpegData) else { return }
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return }

        isReceiving = true
        currentResolution = CGSize(width: extent.width, height: extent.height)

        let w = Int(extent.width)
        let h = Int(extent.height)
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
             kCVPixelBufferWidthKey as String: w,
             kCVPixelBufferHeightKey as String: h] as CFDictionary,
            &pixelBuffer)
        guard let buffer = pixelBuffer else { return }

        ciContext.render(ciImage, to: buffer)
        frameCount += 1
        let ts = CMTime(value: CMTimeValue(frameCount), timescale: 24)
        onFrame?(buffer, ts)
        onOverlayFrame?(buffer)
    }
}
