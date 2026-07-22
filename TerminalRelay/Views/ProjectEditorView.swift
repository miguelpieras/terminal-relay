import SwiftUI

private enum ProjectSource: String, CaseIterable, Identifiable {
    case new
    case existing

    var id: Self { self }

    var title: String {
        switch self {
        case .new: "New repository"
        case .existing: "Existing repository"
        }
    }
}

struct ProjectEditorView: View {
    @EnvironmentObject private var githubService: GitHubProjectService

    @State private var draft: ProjectProfile
    @State private var source: ProjectSource
    @State private var projectName: String
    @State private var selectedRepositoryReference: String?
    @State private var repositorySearch = ""
    @State private var isSaving = false
    @State private var saveError: String?

    let workers: [ServerProfile]
    let onSave: (ProjectProfile) -> String?
    let onCancel: () -> Void

    private let isCreatingProject: Bool

    init(
        project: ProjectProfile,
        workers: [ServerProfile],
        onSave: @escaping (ProjectProfile) -> String?,
        onCancel: @escaping () -> Void
    ) {
        let isCreatingProject = project.repositoryName.isEmpty
        _draft = State(initialValue: project)
        _source = State(initialValue: isCreatingProject ? .new : .existing)
        _projectName = State(initialValue: project.repositoryName)
        _selectedRepositoryReference = State(
            initialValue: isCreatingProject ? nil : project.githubRepository
        )
        self.isCreatingProject = isCreatingProject
        self.workers = workers
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var normalizedProjectName: String {
        ProjectProfile.normalizedRepositoryName(from: projectName)
    }

    private var repositoryReference: String? {
        if !isCreatingProject { return draft.githubRepository }
        switch source {
        case .new:
            return normalizedProjectName.isEmpty ? nil : normalizedProjectName
        case .existing:
            return selectedRepositoryReference
        }
    }

    private var selectedRepository: GitHubRepository? {
        guard let selectedRepositoryReference else { return nil }
        return githubService.repositories.first {
            $0.nameWithOwner.caseInsensitiveCompare(selectedRepositoryReference) == .orderedSame
        }
    }

    private var pendingRepositoryName: String? {
        if !isCreatingProject { return draft.repositoryName }
        switch source {
        case .new:
            return normalizedProjectName.isEmpty ? nil : normalizedProjectName
        case .existing:
            return selectedRepository?.name
        }
    }

    private var filteredRepositories: [GitHubRepository] {
        let query = repositorySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return githubService.repositories }
        return githubService.repositories.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.nameWithOwner.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedWorker: ServerProfile? {
        workers.first { $0.id == draft.serverID }
    }

    private var canSave: Bool {
        repositoryReference != nil
            && selectedWorker != nil
            && !isSaving
            && !githubService.isLoading
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Form {
                if isCreatingProject {
                    Section {
                        Picker("Project source", selection: $source) {
                            ForEach(ProjectSource.allCases) { source in
                                Text(source.title).tag(source)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    if source == .new {
                        newRepositorySection
                    } else {
                        existingRepositorySection
                    }
                } else {
                    Section("Repository") {
                        LabeledContent("GitHub") {
                            Text(draft.githubRepository)
                                .textSelection(.enabled)
                        }
                    }
                }

                workerSection

                Section {
                    Label(
                        "The GitHub credential stays on this Mac. The worker receives only a writable deploy key for this repository.",
                        systemImage: "lock.shield"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)

            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(isCreatingProject ? "New Project" : draft.displayName)
        .task {
            await githubService.refreshRepositories()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(isCreatingProject ? "Add Project" : "Project Settings")
                    .font(.title2.weight(.semibold))
                Text(
                    isCreatingProject
                        ? "Choose a GitHub repository and a worker."
                        : "Move this project to another worker."
                )
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var newRepositorySection: some View {
        Section("New project") {
            TextField("Project name", text: $projectName, prompt: Text("terminal-relay"))

            LabeledContent("Repository") {
                Text("miguelpieras/\(normalizedProjectName.isEmpty ? "…" : normalizedProjectName)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Worker folder") {
                Text("/workspace/\(normalizedProjectName.isEmpty ? "…" : normalizedProjectName)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text("Terminal Relay creates a private repository initialized with a README.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var existingRepositorySection: some View {
        Section("GitHub repositories") {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find a repository", text: $repositorySearch)
                    .textFieldStyle(.plain)
                if githubService.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task { await githubService.refreshRepositories() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh repositories")
                }
            }

            List(filteredRepositories, selection: $selectedRepositoryReference) { repository in
                HStack(spacing: 8) {
                    Image(systemName: repository.isPrivate ? "lock" : "globe")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(repository.nameWithOwner)
                        .lineLimit(1)
                }
                .tag(repository.nameWithOwner)
            }
            .frame(minHeight: 180)
            .overlay {
                if !githubService.isLoading && filteredRepositories.isEmpty {
                    ContentUnavailableView(
                        "No Repositories",
                        systemImage: "folder",
                        description: Text(repositorySearch.isEmpty ? "No GitHub repositories are available." : "No repositories match your search.")
                    )
                }
            }

            if let githubError = githubService.errorMessage {
                Label(githubError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var workerSection: some View {
        Section("Worker") {
            Picker("Worker", selection: $draft.serverID) {
                ForEach(workers) { worker in
                    Text(worker.displayName).tag(worker.id)
                }
            }

            if let repositoryName = pendingRepositoryName {
                LabeledContent("Folder") {
                    Text("/workspace/\(repositoryName)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if isSaving {
                ProgressView()
                    .controlSize(.small)
                Text("Preparing GitHub and worker…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)

            Button(isCreatingProject ? "Add Project" : "Save") {
                Task { await save() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
        .padding(16)
    }

    private func save() async {
        guard let repositoryReference, let selectedWorker else { return }

        isSaving = true
        saveError = nil
        defer { isSaving = false }

        do {
            let repository = try await githubService.prepare(
                repositoryReference: repositoryReference,
                create: isCreatingProject && source == .new,
                on: selectedWorker
            )

            var saved = draft
            saved.repositoryOwner = repository.owner
            saved.repositoryName = repository.name
            saveError = onSave(saved)
        } catch {
            saveError = error.localizedDescription
            if isCreatingProject && source == .new {
                await githubService.refreshRepositories()
            }
        }
    }
}
