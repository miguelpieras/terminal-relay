import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var serverStore: ServerStore
    @EnvironmentObject private var sessionManager: SessionManager

    @State private var selectedServerID: UUID?
    @State private var editorProfile: ServerProfile?
    @State private var serverPendingDeletion: ServerProfile?

    private var selectedServer: ServerProfile? {
        serverStore.server(id: selectedServerID)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            if let selectedServer {
                ServerWorkspaceView(server: selectedServer)
            } else {
                WelcomeView {
                    editorProfile = ServerProfile()
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    editorProfile = ServerProfile()
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
                .help("Add server")

                Button {
                    if let selectedServer {
                        editorProfile = selectedServer
                    }
                } label: {
                    Label("Edit Server", systemImage: "pencil")
                }
                .disabled(selectedServer == nil)
                .help("Edit selected server")

                Button {
                    serverPendingDeletion = selectedServer
                } label: {
                    Label("Delete Server", systemImage: "trash")
                }
                .disabled(selectedServer == nil)
                .help("Delete selected server")
            }
        }
        .sheet(item: $editorProfile) { profile in
            ServerEditorView(profile: profile) { savedProfile in
                serverStore.save(savedProfile)
                selectedServerID = savedProfile.id
                editorProfile = nil
            } onCancel: {
                editorProfile = nil
            }
        }
        .confirmationDialog(
            "Delete \(serverPendingDeletion?.displayName ?? "server")?",
            isPresented: Binding(
                get: { serverPendingDeletion != nil },
                set: { if !$0 { serverPendingDeletion = nil } }
            )
        ) {
            Button("Delete Server", role: .destructive) {
                guard let profile = serverPendingDeletion else { return }
                sessionManager.closeSessions(for: profile)
                serverStore.delete(id: profile.id)
                selectedServerID = serverStore.servers.first?.id
                serverPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                serverPendingDeletion = nil
            }
        } message: {
            Text("Its active terminals will be stopped and its saved connection settings removed.")
        }
        .alert(
            "Terminal Relay",
            isPresented: Binding(
                get: { serverStore.persistenceError != nil },
                set: { if !$0 { serverStore.dismissPersistenceError() } }
            )
        ) {
            Button("OK") { serverStore.dismissPersistenceError() }
        } message: {
            Text(serverStore.persistenceError ?? "Unknown persistence error")
        }
        .onAppear {
            if selectedServerID == nil {
                selectedServerID = serverStore.servers.first?.id
            }
        }
        .onChange(of: selectedServerID) { _, newServerID in
            guard let newServerID else {
                sessionManager.selectedSessionID = nil
                return
            }
            guard let server = serverStore.server(id: newServerID) else {
                sessionManager.selectedSessionID = nil
                return
            }
            sessionManager.selectedSessionID = sessionManager.sessions(for: server).first?.id
        }
    }

    private var sidebar: some View {
        List(selection: $selectedServerID) {
            Section("Servers") {
                ForEach(serverStore.servers) { server in
                    ServerSidebarRow(server: server)
                        .tag(server.id)
                        .contextMenu {
                            Button("Edit") { editorProfile = server }
                            Divider()
                            Button("Delete", role: .destructive) {
                                serverPendingDeletion = server
                            }
                        }
                }
            }
        }
        .navigationTitle("Terminal Relay")
        .overlay {
            if serverStore.servers.isEmpty {
                ContentUnavailableView(
                    "No Servers",
                    systemImage: "server.rack",
                    description: Text("Add the first remote server to get started.")
                )
            }
        }
    }
}

private struct ServerSidebarRow: View {
    @EnvironmentObject private var sessionManager: SessionManager
    let server: ServerProfile

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayName)
                    .lineLimit(1)
                Text(server.destination)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            HStack(spacing: 4) {
                ForEach(AgentKind.allCases) { kind in
                    if sessionManager.session(server: server, kind: kind)?.status.occupiesSlot == true {
                        Circle()
                            .fill(kind == .codex ? Color.blue : Color.orange)
                            .frame(width: 7, height: 7)
                            .help("\(kind.displayName) is running")
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }
}

private struct WelcomeView: View {
    let addServer: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Remote agents, one workspace", systemImage: "rectangle.3.group.bubble.left")
        } description: {
            Text("Run Codex and Claude on your servers without moving projects or account credentials onto this Mac.")
        } actions: {
            Button("Add Server", action: addServer)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}
