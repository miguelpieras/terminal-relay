import Foundation
import XCTest
@testable import TerminalRelay

final class MacChatProcessConnectionTests: XCTestCase {
    func testConnectStreamsStandardInputAndOutputThenDetachesOnce() throws {
        let connection = MacChatProcessConnection()
        let received = expectation(description: "stdout")
        let terminated = expectation(description: "terminated")
        let payload = Data("streamed chat record\n".utf8)
        let lock = NSLock()
        var output = Data()
        var terminationCount = 0

        try connection.connect(
            configuration: SSHLaunchConfiguration(executable: "/bin/cat", arguments: []),
            callbacks: .init(
                receiveStandardOutput: { data in
                    lock.lock()
                    output.append(data)
                    let isComplete = output == payload
                    lock.unlock()
                    if isComplete {
                        received.fulfill()
                    }
                },
                receiveStandardError: { _ in
                    XCTFail("cat unexpectedly wrote stderr")
                },
                terminate: { _ in
                    lock.lock()
                    terminationCount += 1
                    lock.unlock()
                    terminated.fulfill()
                }
            )
        )

        XCTAssertTrue(connection.isConnected)
        try connection.send(payload)
        wait(for: [received], timeout: 2)
        connection.disconnect()
        connection.disconnect()
        wait(for: [terminated], timeout: 2)

        lock.lock()
        let finalOutput = output
        let finalTerminationCount = terminationCount
        lock.unlock()
        XCTAssertEqual(finalOutput, payload)
        XCTAssertEqual(finalTerminationCount, 1)
        XCTAssertFalse(connection.isConnected)
    }

    func testStandardErrorAndExitAreDeliveredSeparately() throws {
        let connection = MacChatProcessConnection()
        let receivedError = expectation(description: "stderr")
        let terminated = expectation(description: "terminated")
        let lock = NSLock()
        var diagnostic = Data()

        try connection.connect(
            configuration: SSHLaunchConfiguration(
                executable: "/bin/sh",
                arguments: ["-c", "printf diagnostic >&2"]
            ),
            callbacks: .init(
                receiveStandardOutput: { _ in
                    XCTFail("process unexpectedly wrote stdout")
                },
                receiveStandardError: { data in
                    lock.lock()
                    diagnostic.append(data)
                    let isComplete = diagnostic == Data("diagnostic".utf8)
                    lock.unlock()
                    if isComplete {
                        receivedError.fulfill()
                    }
                },
                terminate: { status in
                    XCTAssertEqual(status, 0)
                    terminated.fulfill()
                }
            )
        )

        wait(for: [receivedError, terminated], timeout: 2)
        lock.lock()
        let finalDiagnostic = diagnostic
        lock.unlock()
        XCTAssertEqual(finalDiagnostic, Data("diagnostic".utf8))
    }

    func testRejectsSecondConnectionAndSendWithoutConnection() throws {
        let connection = MacChatProcessConnection()
        let terminated = expectation(description: "terminated")
        try connection.connect(
            configuration: SSHLaunchConfiguration(executable: "/bin/cat", arguments: []),
            callbacks: .init(
                receiveStandardOutput: { _ in },
                receiveStandardError: { _ in },
                terminate: { _ in terminated.fulfill() }
            )
        )

        XCTAssertThrowsError(
            try connection.connect(
                configuration: SSHLaunchConfiguration(executable: "/bin/cat", arguments: []),
                callbacks: .init(
                    receiveStandardOutput: { _ in },
                    receiveStandardError: { _ in },
                    terminate: { _ in }
                )
            )
        ) { error in
            XCTAssertEqual(error as? MacChatProcessConnectionError, .alreadyConnected)
        }

        connection.disconnect()
        wait(for: [terminated], timeout: 2)
        XCTAssertThrowsError(try connection.send(Data("after close".utf8))) { error in
            XCTAssertEqual(error as? MacChatProcessConnectionError, .notConnected)
        }
    }

    func testLaunchFailureLeavesConnectionReusable() {
        let connection = MacChatProcessConnection()

        XCTAssertThrowsError(
            try connection.connect(
                configuration: SSHLaunchConfiguration(
                    executable: "/path/that/does/not/exist",
                    arguments: []
                ),
                callbacks: .init(
                    receiveStandardOutput: { _ in },
                    receiveStandardError: { _ in },
                    terminate: { _ in }
                )
            )
        ) { error in
            XCTAssertEqual(error as? MacChatProcessConnectionError, .launchFailed)
        }
        XCTAssertFalse(connection.isConnected)
    }
}
