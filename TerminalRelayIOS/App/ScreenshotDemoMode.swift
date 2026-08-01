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

enum DemoWorkspace {
    private static let sessionIdentifiers = [
        "00000000-0000-4000-8000-000000002001",
        "00000000-0000-4000-8000-000000002002",
        "00000000-0000-4000-8000-000000002003",
    ]

    static let worker = WorkerProfile(
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
        name: "Private Worker",
        host: "worker.example.com",
        port: 22,
        username: "example-user",
        expectedHostKeyFingerprint: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    )

    static let projects = ["atlas", "launchpad", "northstar"]

    static let sessions = [
        WorkerSessionSnapshot(
            kind: .codex,
            repositoryName: "atlas",
            attachedClientCount: 2,
            instanceToken: sessionIdentifiers[0],
            title: "Build adaptive iPad workspace",
            lastActivityAt: 1_800_000_000,
            reportedWorking: true,
            threadID: "00000000-0000-4000-8000-000000003001",
            presentation: .chat
        ),
        WorkerSessionSnapshot(
            kind: .claude,
            repositoryName: "atlas",
            attachedClientCount: 1,
            instanceToken: sessionIdentifiers[1],
            title: "Review private pairing flow",
            lastActivityAt: 1_799_999_980,
            reportedWorking: false,
            threadID: "00000000-0000-4000-8000-000000003002",
            presentation: .chat
        ),
        WorkerSessionSnapshot(
            kind: .codex,
            repositoryName: "launchpad",
            attachedClientCount: 1,
            instanceToken: sessionIdentifiers[2],
            title: "Prepare App Store release",
            lastActivityAt: 1_799_999_960,
            reportedWorking: false,
            threadID: "00000000-0000-4000-8000-000000003003",
            presentation: .chat
        ),
    ]

    static let threads = [
        WorkerThreadSnapshot(
            kind: .codex,
            repositoryName: "atlas",
            threadID: "00000000-0000-4000-8000-000000004001",
            title: "Polish onboarding empty state",
            updatedAt: 1_799_999_900,
            isArchived: false,
            activeInstanceToken: nil,
            reportedWorking: nil,
            capabilities: .dormantCodex
        ),
        WorkerThreadSnapshot(
            kind: .codex,
            repositoryName: "atlas",
            threadID: "00000000-0000-4000-8000-000000004002",
            title: "Retire old pairing copy",
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
                account: "demo@example.com",
                plan: "Team",
                limits: [
                    WorkerAccountLimitSnapshot(name: "5-hour", usedPercent: 24),
                    WorkerAccountLimitSnapshot(name: "Weekly", usedPercent: 36),
                ]
            ),
            .claude: WorkerAccountSnapshot(
                account: "demo@example.com",
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
