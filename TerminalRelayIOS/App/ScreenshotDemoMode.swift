import Foundation

enum ScreenshotDemoMode {
    static let launchArgument = "--terminal-relay-screenshot-demo"
    static let terminalLaunchArgument = "--terminal-relay-screenshot-demo-terminal"
    static let scrollUITestLaunchArgument = "--terminal-relay-ui-test-scroll"

    static var runsScrollUITest: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains(scrollUITestLaunchArgument)
#else
        false
#endif
    }

    static var isEnabled: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains(launchArgument) || runsScrollUITest
#else
        false
#endif
    }

    static var opensTerminal: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains(terminalLaunchArgument) || runsScrollUITest
#else
        false
#endif
    }
}

#if DEBUG
enum DemoWorkspace {
    private static let sessionIdentifiers = [
        "00000000-0000-4000-8000-000000002001",
        "00000000-0000-4000-8000-000000002002",
        "00000000-0000-4000-8000-000000002003",
    ]

    static let worker = WorkerProfile(
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
        name: "Studio Worker",
        host: "buildbox.local",
        port: 22,
        username: "developer",
        expectedHostKeyFingerprint: "SHA256:7W16jOP8rCJB7JXwQ8wTt0dTiMNkZdJdYxPC5v/SdVA"
    )

    static let projects = ["ios-client", "api-gateway", "docs-site"]

    static let sessions = [
        WorkerSessionSnapshot(
            kind: .codex,
            repositoryName: "ios-client",
            attachedClientCount: 2,
            instanceToken: sessionIdentifiers[0],
            title: "Ship direct SSH onboarding",
            lastActivityAt: 1_800_000_000,
            reportedWorking: true,
            threadID: "00000000-0000-4000-8000-000000003001",
            presentation: .chat
        ),
        WorkerSessionSnapshot(
            kind: .claude,
            repositoryName: "ios-client",
            attachedClientCount: 1,
            instanceToken: sessionIdentifiers[1],
            title: "Review host-key pinning",
            lastActivityAt: 1_799_999_980,
            reportedWorking: false,
            threadID: "00000000-0000-4000-8000-000000003002",
            presentation: .chat
        ),
        WorkerSessionSnapshot(
            kind: .codex,
            repositoryName: "api-gateway",
            attachedClientCount: 1,
            instanceToken: sessionIdentifiers[2],
            title: "Refine agent approval cards",
            lastActivityAt: 1_799_999_960,
            reportedWorking: false,
            threadID: "00000000-0000-4000-8000-000000003003",
            presentation: .chat
        ),
    ]

    static let threads = [
        WorkerThreadSnapshot(
            kind: .codex,
            repositoryName: "ios-client",
            threadID: "00000000-0000-4000-8000-000000004001",
            title: "Explain the direct SSH boundary",
            updatedAt: 1_799_999_900,
            isArchived: false,
            activeInstanceToken: nil,
            reportedWorking: nil,
            capabilities: .dormantCodex
        ),
        WorkerThreadSnapshot(
            kind: .codex,
            repositoryName: "ios-client",
            threadID: "00000000-0000-4000-8000-000000004002",
            title: "Remove hosted-relay wording",
            updatedAt: 1_799_990_000,
            isArchived: true,
            activeInstanceToken: nil,
            reportedWorking: nil,
            capabilities: .archivedCodex
        ),
    ]

    static let overview = WorkerOverviewSnapshot(
        projects: projects,
        sessions: sessions,
        resources: WorkerResourceSnapshot(
            cpuUsedPercent: 18,
            memoryUsedPercent: 42,
            diskUsedPercent: 31
        ),
        accounts: [
            .codex: WorkerAccountSnapshot(
                account: "dev@studio.local",
                plan: "Team",
                limits: [
                    WorkerAccountLimitSnapshot(name: "5-hour", usedPercent: 24),
                    WorkerAccountLimitSnapshot(name: "Weekly", usedPercent: 36),
                ]
            ),
            .claude: WorkerAccountSnapshot(
                account: "dev@studio.local",
                plan: "Pro",
                limits: [
                    WorkerAccountLimitSnapshot(name: "Session", usedPercent: 18),
                    WorkerAccountLimitSnapshot(name: "Weekly", usedPercent: 29),
                ]
            ),
        ],
        accountErrors: [],
        connectionError: nil,
        updateStatus: nil
    )
}
#endif
