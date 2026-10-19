import Foundation
import Testing
@testable import MAMCore

@Test func messageRoundTripAcrossArbitraryChunks() throws {
    let first = WireMessage(
        type: .hello,
        flags: 7,
        sequence: 42,
        presentationTimeMicroseconds: 123_456,
        payload: Data("hello".utf8)
    )
    let second = WireMessage(type: .videoFrame, sequence: 43, payload: Data(repeating: 0xAB, count: 257))
    let stream = first.encoded() + second.encoded()

    var parser = WireMessageParser()
    var decoded = [WireMessage]()
    for byte in stream {
        decoded += try parser.append(Data([byte]))
    }

    #expect(decoded == [first, second])
}

@Test func h264ConfigurationRoundTrip() throws {
    let configuration = H264Configuration(
        width: 1440,
        height: 900,
        sps: Data([0x67, 0x64, 0x00, 0x28]),
        pps: Data([0x68, 0xEE, 0x3C, 0x80])
    )

    #expect(try H264Configuration(decoding: configuration.encoded()) == configuration)
}

@Test func receiverDisplayProfileRoundTrip() throws {
    let profile = ReceiverDisplayProfile(
        pixelWidth: 2880,
        pixelHeight: 1800,
        logicalWidth: 1440,
        logicalHeight: 900,
        refreshRateMillihertz: 60_000
    )

    #expect(try ReceiverDisplayProfile(decoding: profile.encoded()) == profile)
}

@Test func receiverDisplayProfileRejectsZeroDimensions() throws {
    let profile = ReceiverDisplayProfile(
        pixelWidth: 0,
        pixelHeight: 1800,
        logicalWidth: 1440,
        logicalHeight: 900,
        refreshRateMillihertz: 60_000
    )

    #expect(throws: ReceiverDisplayProfileError.invalidValues) {
        try ReceiverDisplayProfile(decoding: profile.encoded())
    }
}

@Test func rejectsOversizedPayloadBeforeAllocation() throws {
    var bytes = WireMessage(type: .ping).encoded()
    var oversized = UInt32(WireMessage.maximumPayloadSize + 1).bigEndian
    withUnsafeBytes(of: &oversized) { bytes.replaceSubrange(8..<12, with: $0) }

    var parser = WireMessageParser()
    #expect(throws: WireProtocolError.payloadTooLarge(WireMessage.maximumPayloadSize + 1)) {
        try parser.append(bytes)
    }
}
