import Foundation

public enum WireMessageType: UInt16, Sendable {
    case hello = 1
    case videoConfiguration = 2
    case videoFrame = 3
    case requestKeyframe = 4
    case ping = 5
    case pong = 6
    case receiverDisplayProfile = 7
}

public struct WireMessage: Equatable, Sendable {
    public static let magic: UInt32 = 0x4D_41_4D_31 // "MAM1"
    public static let headerSize = 28
    public static let maximumPayloadSize = 64 * 1024 * 1024

    public let type: WireMessageType
    public let flags: UInt16
    public let sequence: UInt64
    public let presentationTimeMicroseconds: UInt64
    public let payload: Data

    public init(
        type: WireMessageType,
        flags: UInt16 = 0,
        sequence: UInt64 = 0,
        presentationTimeMicroseconds: UInt64 = 0,
        payload: Data = Data()
    ) {
        self.type = type
        self.flags = flags
        self.sequence = sequence
        self.presentationTimeMicroseconds = presentationTimeMicroseconds
        self.payload = payload
    }

    public func encoded() -> Data {
        var data = Data(capacity: Self.headerSize + payload.count)
        data.appendBigEndian(Self.magic)
        data.appendBigEndian(type.rawValue)
        data.appendBigEndian(flags)
        data.appendBigEndian(UInt32(payload.count))
        data.appendBigEndian(sequence)
        data.appendBigEndian(presentationTimeMicroseconds)
        data.append(payload)
        return data
    }
}

public enum WireProtocolError: Error, Equatable {
    case invalidMagic
    case unknownMessageType(UInt16)
    case payloadTooLarge(Int)
}

public struct WireMessageParser: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) throws -> [WireMessage] {
        buffer.append(data)
        var messages = [WireMessage]()

        while buffer.count >= WireMessage.headerSize {
            let magic: UInt32 = buffer.readBigEndian(at: 0)
            guard magic == WireMessage.magic else {
                buffer.removeAll(keepingCapacity: true)
                throw WireProtocolError.invalidMagic
            }

            let rawType: UInt16 = buffer.readBigEndian(at: 4)
            guard let type = WireMessageType(rawValue: rawType) else {
                buffer.removeAll(keepingCapacity: true)
                throw WireProtocolError.unknownMessageType(rawType)
            }

            let flags: UInt16 = buffer.readBigEndian(at: 6)
            let payloadLength = Int(buffer.readBigEndian(at: 8) as UInt32)
            guard payloadLength <= WireMessage.maximumPayloadSize else {
                buffer.removeAll(keepingCapacity: true)
                throw WireProtocolError.payloadTooLarge(payloadLength)
            }

            let messageLength = WireMessage.headerSize + payloadLength
            guard buffer.count >= messageLength else { break }

            let sequence: UInt64 = buffer.readBigEndian(at: 12)
            let pts: UInt64 = buffer.readBigEndian(at: 20)
            let payload = Data(buffer[WireMessage.headerSize..<messageLength])
            messages.append(
                WireMessage(
                    type: type,
                    flags: flags,
                    sequence: sequence,
                    presentationTimeMicroseconds: pts,
                    payload: payload
                )
            )
            buffer.removeSubrange(0..<messageLength)
        }

        return messages
    }
}

public struct H264Configuration: Equatable, Sendable {
    public let width: UInt32
    public let height: UInt32
    public let sps: Data
    public let pps: Data

    public init(width: UInt32, height: UInt32, sps: Data, pps: Data) {
        self.width = width
        self.height = height
        self.sps = sps
        self.pps = pps
    }

    public func encoded() -> Data {
        var data = Data(capacity: 16 + sps.count + pps.count)
        data.appendBigEndian(width)
        data.appendBigEndian(height)
        data.appendBigEndian(UInt32(sps.count))
        data.append(sps)
        data.appendBigEndian(UInt32(pps.count))
        data.append(pps)
        return data
    }

    public init(decoding data: Data) throws {
        guard data.count >= 16 else { throw H264ConfigurationError.truncated }
        width = data.readBigEndian(at: 0)
        height = data.readBigEndian(at: 4)
        let spsLength = Int(data.readBigEndian(at: 8) as UInt32)
        let spsStart = 12
        let spsEnd = spsStart + spsLength
        guard spsLength > 0, spsEnd + 4 <= data.count else {
            throw H264ConfigurationError.truncated
        }
        sps = Data(data[spsStart..<spsEnd])
        let ppsLength = Int(data.readBigEndian(at: spsEnd) as UInt32)
        let ppsStart = spsEnd + 4
        let ppsEnd = ppsStart + ppsLength
        guard ppsLength > 0, ppsEnd == data.count else {
            throw H264ConfigurationError.truncated
        }
        pps = Data(data[ppsStart..<ppsEnd])
    }
}

public enum H264ConfigurationError: Error {
    case truncated
}

public struct ReceiverDisplayProfile: Equatable, Sendable {
    public static let encodedSize = 20

    public let pixelWidth: UInt32
    public let pixelHeight: UInt32
    public let logicalWidth: UInt32
    public let logicalHeight: UInt32
    public let refreshRateMillihertz: UInt32

    public init(
        pixelWidth: UInt32,
        pixelHeight: UInt32,
        logicalWidth: UInt32,
        logicalHeight: UInt32,
        refreshRateMillihertz: UInt32
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.refreshRateMillihertz = refreshRateMillihertz
    }

    public func encoded() -> Data {
        var data = Data(capacity: Self.encodedSize)
        data.appendBigEndian(pixelWidth)
        data.appendBigEndian(pixelHeight)
        data.appendBigEndian(logicalWidth)
        data.appendBigEndian(logicalHeight)
        data.appendBigEndian(refreshRateMillihertz)
        return data
    }

    public init(decoding data: Data) throws {
        guard data.count == Self.encodedSize else {
            throw ReceiverDisplayProfileError.invalidLength(data.count)
        }
        let pixelWidth: UInt32 = data.readBigEndian(at: 0)
        let pixelHeight: UInt32 = data.readBigEndian(at: 4)
        let logicalWidth: UInt32 = data.readBigEndian(at: 8)
        let logicalHeight: UInt32 = data.readBigEndian(at: 12)
        let refreshRateMillihertz: UInt32 = data.readBigEndian(at: 16)
        guard
            pixelWidth > 0, pixelHeight > 0,
            logicalWidth > 0, logicalHeight > 0,
            refreshRateMillihertz > 0
        else {
            throw ReceiverDisplayProfileError.invalidValues
        }
        self.init(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            refreshRateMillihertz: refreshRateMillihertz
        )
    }
}

public enum ReceiverDisplayProfileError: Error, Equatable {
    case invalidLength(Int)
    case invalidValues
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    func readBigEndian<T: FixedWidthInteger>(at offset: Int) -> T {
        let size = MemoryLayout<T>.size
        return self[offset..<(offset + size)].withUnsafeBytes { rawBuffer in
            var value: T = 0
            Swift.withUnsafeMutableBytes(of: &value) { destination in
                destination.copyBytes(from: rawBuffer)
            }
            return T(bigEndian: value)
        }
    }
}
