import XCTest
@testable import TerminalRelay

final class ChatProtocolTests: XCTestCase {
    func testRoundTripsEnvelopeAcrossEveryUTF8ByteBoundary() throws {
        let envelope = ChatTestFixtures.event(
            "message.completed",
            sequence: 1,
            itemID: "message-1",
            payload: .object(["text": .string("Hello 👋🏼 café 日本語")])
        )
        let line = try ChatNDJSONEncoder.encode(envelope)

        for split in 0...line.count {
            var decoder = ChatNDJSONDecoder()
            let first = try decoder.append(Data(line.prefix(split)))
            let second = try decoder.append(Data(line.dropFirst(split)))
            XCTAssertEqual(first + second, [envelope], "Failed at byte boundary \(split)")
            XCTAssertNoThrow(try decoder.finish())
        }
    }

    func testAcceptsCRLFAndMultipleRecords() throws {
        let first = ChatTestFixtures.event("session.heartbeat", sequence: 1)
        let second = ChatTestFixtures.event("session.heartbeat", sequence: 2)
        var data = try ChatNDJSONEncoder.encode(first)
        data.removeLast()
        data.append(contentsOf: [0x0D, 0x0A])
        data.append(try ChatNDJSONEncoder.encode(second))

        var decoder = ChatNDJSONDecoder()
        XCTAssertEqual(try decoder.append(data), [first, second])
        XCTAssertNoThrow(try decoder.finish())
    }

    func testAcceptsOnlyDefinedAttachmentLocalSequenceZeroControls() throws {
        let hello = ChatTestFixtures.event(
            "session.hello",
            sequence: 0,
            payload: .object(["connectionState": .string("streaming")])
        )
        var helloDecoder = ChatNDJSONDecoder()
        XCTAssertEqual(try helloDecoder.append(ChatNDJSONEncoder.encode(hello)), [hello])

        let error = ChatTestFixtures.event(
            "error",
            sequence: 0,
            payload: .object(["message": .string("Attach failed")])
        )
        var errorDecoder = ChatNDJSONDecoder()
        XCTAssertEqual(try errorDecoder.append(ChatNDJSONEncoder.encode(error)), [error])

        let invalid = ChatTestFixtures.event("message.delta", sequence: 0, itemID: "message")
        var invalidDecoder = ChatNDJSONDecoder()
        XCTAssertThrowsError(try invalidDecoder.append(ChatNDJSONEncoder.encode(invalid))) { error in
            guard case ChatProtocolError.invalidEnvelope = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsInvalidUTF8WithoutEchoingPayload() {
        var decoder = ChatNDJSONDecoder()
        var data = Data(#"{"super-secret-marker":""#.utf8)
        data.append(0xFF)
        data.append(Data(#""}"#.utf8))
        data.append(0x0A)
        XCTAssertThrowsError(try decoder.append(data)) { error in
            guard case ChatProtocolError.invalidUTF8 = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertFalse(error.localizedDescription.contains("super-secret-marker"))
        }
    }

    func testRejectsDeepAndOversizedRecordsBeforeDecoding() {
        var deepDecoder = ChatNDJSONDecoder()
        let deeplyNested = Data((String(repeating: "[", count: 33) + "0" + String(repeating: "]", count: 33) + "\n").utf8)
        XCTAssertThrowsError(try deepDecoder.append(deeplyNested)) { error in
            guard case ChatProtocolError.nestingTooDeep = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        var oversizedDecoder = ChatNDJSONDecoder()
        let oversized = Data(repeating: 0x20, count: ChatNDJSONDecoder.maximumRecordBytes + 1)
        XCTAssertThrowsError(try oversizedDecoder.append(oversized)) { error in
            guard case ChatProtocolError.recordTooLarge = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsUnterminatedRecordAndUnsupportedVersion() throws {
        let envelope = ChatTestFixtures.event("session.heartbeat", sequence: 1)
        var line = try ChatNDJSONEncoder.encode(envelope)
        line.removeLast()
        var decoder = ChatNDJSONDecoder()
        XCTAssertEqual(try decoder.append(line), [])
        XCTAssertThrowsError(try decoder.finish()) { error in
            XCTAssertEqual(error as? ChatProtocolError, .unterminatedRecord)
        }

        let unsupported = ChatEnvelope(
            v: 2,
            type: "session.heartbeat",
            eventID: "00000000-0000-4000-8000-000000000004",
            relayID: ChatTestFixtures.relayID,
            provider: .codex,
            providerThreadID: ChatTestFixtures.threadID,
            sequence: 1
        )
        var unsupportedDecoder = ChatNDJSONDecoder()
        XCTAssertThrowsError(
            try unsupportedDecoder.append(JSONEncoder.chat.encode(unsupported) + Data([0x0A]))
        ) { error in
            guard case ChatProtocolError.unsupportedVersion(2, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCommandPayloadsUseProtocolFieldNamesAndLimits() throws {
        let attach = try ChatCommand.attach(
            afterSequence: 42,
            snapshotGeneration: ChatTestFixtures.generation
        ).envelope(identity: ChatTestFixtures.identity)
        XCTAssertEqual(attach.type, "session.attach")
        XCTAssertEqual(attach.payload["afterSeq"]?.int64Value, 42)
        XCTAssertEqual(
            attach.payload["snapshotGeneration"]?.stringValue,
            ChatTestFixtures.generation
        )
        let freshAttach = try ChatCommand.attach(
            afterSequence: nil,
            snapshotGeneration: nil
        ).envelope(identity: ChatTestFixtures.identity)
        XCTAssertEqual(freshAttach.payload["afterSeq"]?.int64Value, 0)
        XCTAssertEqual(freshAttach.payload["snapshotGeneration"], .null)

        let turn = try ChatCommand.startTurn(
            text: "Hello",
            attachments: [
                ChatAttachmentReference(
                    id: "11111111-1111-4111-8111-111111111111",
                    path: "/worker/private/file.txt",
                    displayName: "Notes.txt",
                    mediaType: "text/plain",
                    kind: .file,
                    byteCount: 12
                ),
            ],
            options: ChatLaunchOptions(model: "test-model", reasoningEffort: "high")
        ).envelope(identity: ChatTestFixtures.identity)
        XCTAssertEqual(turn.type, "turn.start")
        XCTAssertEqual(turn.payload["text"]?.stringValue, "Hello")
        XCTAssertEqual(turn.payload["model"]?.stringValue, "test-model")
        XCTAssertEqual(turn.payload["reasoningEffort"]?.stringValue, "high")
        XCTAssertEqual(turn.payload["attachments"]?.arrayValue?.count, 1)
        let attachment = try XCTUnwrap(turn.payload["attachments"]?.arrayValue?.first)
        XCTAssertEqual(attachment["id"]?.stringValue, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(attachment["path"]?.stringValue, "/worker/private/file.txt")
        XCTAssertEqual(attachment["displayName"]?.stringValue, "Notes.txt")
        XCTAssertEqual(attachment["mediaType"]?.stringValue, "text/plain")
        XCTAssertEqual(attachment["kind"]?.stringValue, "file")
        XCTAssertEqual(attachment["byteCount"]?.int64Value, 12)

        let encoded = try ChatNDJSONEncoder.encode(turn)
        XCTAssertEqual(encoded.last, 0x0A)
        XCTAssertFalse(encoded.dropLast().contains(0x0A))
    }

    func testAttachmentReferenceDecodesLegacyImageShape() throws {
        let data = Data(
            #"{"id":"attachment","path":"/worker/private/image.png","displayName":"image.png","mediaType":"image/png"}"#.utf8
        )

        let attachment = try JSONDecoder.chat.decode(
            ChatAttachmentReference.self,
            from: data
        )

        XCTAssertEqual(attachment.kind, .image)
        XCTAssertNil(attachment.byteCount)
        XCTAssertEqual(attachment.displayName, "image.png")
    }

    func testAttachmentPolicyEnforcesCountAndByteLimitsWithoutOverflow() {
        XCTAssertTrue(
            ChatAttachmentPolicy.accepts(
                byteCount: ChatAttachmentPolicy.maximumFileBytes,
                existingCount: ChatAttachmentPolicy.maximumCount - 1,
                existingBytes: ChatAttachmentPolicy.maximumTurnBytes
                    - ChatAttachmentPolicy.maximumFileBytes
            )
        )
        XCTAssertFalse(
            ChatAttachmentPolicy.accepts(
                byteCount: ChatAttachmentPolicy.maximumFileBytes + 1,
                existingCount: 0,
                existingBytes: 0
            )
        )
        XCTAssertFalse(
            ChatAttachmentPolicy.accepts(
                byteCount: 1,
                existingCount: ChatAttachmentPolicy.maximumCount,
                existingBytes: 0
            )
        )
        XCTAssertFalse(
            ChatAttachmentPolicy.accepts(
                byteCount: 1,
                existingCount: 0,
                existingBytes: Int.max
            )
        )
    }

    func testAttachmentDraftSanitizesTheWorkerExtensionAndRetainsBytes() {
        let draft = ChatAttachmentDraft(
            id: "22222222-2222-4222-8222-222222222222",
            displayName: "Quarterly Notes.PDF",
            mediaType: "application/pdf",
            kind: .file,
            fileExtension: "P.D/F-too-long",
            data: Data("opaque".utf8)
        )

        XCTAssertEqual(draft.fileExtension, "pdftoolong")
        XCTAssertEqual(draft.byteCount, 6)
        XCTAssertEqual(draft.reference(path: "/private/item.pdf").kind, .file)
    }

    func testCommandWriterSerializesConcurrentWrites() async throws {
        actor Recorder {
            var values: [Data] = []
            func append(_ value: Data) { values.append(value) }
        }
        let recorder = Recorder()
        let writer = ChatCommandWriter { data in
            await recorder.append(data)
        }
        let commands = try (0..<20).map { index in
            try ChatCommand.ping.envelope(
                identity: ChatTestFixtures.identity,
                requestID: String(format: "00000000-0000-4000-8%03d-%012d", index, index)
            )
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for command in commands {
                group.addTask {
                    try await writer.send(command)
                }
            }
            try await group.waitForAll()
        }
        let values = await recorder.values
        XCTAssertEqual(values.count, commands.count)
        XCTAssertTrue(values.allSatisfy { $0.last == 0x0A })
    }
}
