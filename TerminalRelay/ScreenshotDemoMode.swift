import Foundation

enum ScreenshotDemoMode {
    static let launchArgument = "--terminal-relay-screenshot-demo"

    static var isEnabled: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains(launchArgument)
#else
        false
#endif
    }

    struct Fixture {
        let worker: ServerProfile
        let projects: [ProjectProfile]
        let sessions: [(project: ProjectProfile, snapshot: WorkerSessionSnapshot)]
        let threads: [WorkerThreadSnapshot]
    }

    static func fixture() -> Fixture {
        let sessionIdentifiers = [
            "00000000-0000-4000-8000-000000002001",
            "00000000-0000-4000-8000-000000002002",
            "00000000-0000-4000-8000-000000002003",
        ]
        let worker = ServerProfile(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            name: "Private Worker",
            host: "worker.example.com",
            username: "example-user",
            codexAccountLabel: "demo@example.com",
            claudeAccountLabel: "demo@example.com"
        )
        let projects = [
            ProjectProfile(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000001001")!,
                serverID: worker.id,
                repositoryOwner: "example-org",
                repositoryName: "atlas"
            ),
            ProjectProfile(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000001002")!,
                serverID: worker.id,
                repositoryOwner: "example-org",
                repositoryName: "launchpad"
            ),
            ProjectProfile(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000001003")!,
                serverID: worker.id,
                repositoryOwner: "example-org",
                repositoryName: "northstar"
            ),
        ]
        let sessions = [
            (
                projects[0],
                WorkerSessionSnapshot(
                    kind: .codex,
                    repositoryName: projects[0].repositoryName,
                    attachedClientCount: 2,
                    instanceToken: sessionIdentifiers[0],
                    title: "Build adaptive iPad workspace",
                    lastActivityAt: 1_800_000_000,
                    reportedWorking: true,
                    threadID: "00000000-0000-4000-8000-000000003001"
                )
            ),
            (
                projects[0],
                WorkerSessionSnapshot(
                    kind: .claude,
                    repositoryName: projects[0].repositoryName,
                    attachedClientCount: 1,
                    instanceToken: sessionIdentifiers[1],
                    title: "Review private pairing flow",
                    lastActivityAt: 1_799_999_980,
                    reportedWorking: false,
                    threadID: "00000000-0000-4000-8000-000000003002"
                )
            ),
            (
                projects[1],
                WorkerSessionSnapshot(
                    kind: .codex,
                    repositoryName: projects[1].repositoryName,
                    attachedClientCount: 1,
                    instanceToken: sessionIdentifiers[2],
                    title: "Prepare App Store release",
                    lastActivityAt: 1_799_999_960,
                    reportedWorking: false,
                    threadID: "00000000-0000-4000-8000-000000003003"
                )
            ),
        ]
        let threads = [
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
        return Fixture(
            worker: worker,
            projects: projects,
            sessions: sessions,
            threads: threads
        )
    }

    static func isolatedDefaults() -> UserDefaults {
        let suiteName = "com.mpieras.TerminalRelay.ScreenshotDemo.State"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
