//
//  Indie_Dev_BuddyApp.swift
//  Indie Dev Buddy
//
//  Created by Shawn Crawford on 11/5/26.
//

import AppKit
import SwiftUI
import Sparkle

@main
struct Indie_Dev_BuddyApp: App {
    @State private var socialPublishingRuntime = SocialPublishingRuntime()
    private let updaterController: SPUStandardUpdaterController?

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let feedURL = info["SUFeedURL"] as? String ?? ""
        let publicKey = info["SUPublicEDKey"] as? String ?? ""
        if !feedURL.isEmpty, !publicKey.isEmpty,
           !feedURL.contains("$("), !publicKey.contains("$(") {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        } else {
            updaterController = nil
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(socialPublishingRuntime)
                .task { socialPublishingRuntime.start() }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                if let updaterController {
                    Button("Check for Updates…") {
                        updaterController.checkForUpdates(nil)
                    }
                }
                Button("Install Command-Line Tool…", action: CLIInstallation.install)
            }
            WorkspaceCommands()
        }
        Settings {
            WorkspaceSettingsView(updater: updaterController?.updater)
        }
    }
}

struct WorkspaceCommandActions {
    let recent: [URL]
    let hasWorkspace: Bool
    let isBusy: Bool
    let open: () -> Void
    let create: () -> Void
    let openRecent: (URL) -> Void
    let newContent: (ContentKind) -> Void
    let newRecord: (ManagementCreateRequest) -> Void
    let find: () -> Void
    let refresh: () -> Void
}

struct WorkspaceSaveAction {
    let perform: (@escaping (Bool) -> Void) -> Void

    init(_ perform: @escaping (@escaping (Bool) -> Void) -> Void) {
        self.perform = perform
    }
}

extension FocusedValues {
    @Entry var workspaceCommands: WorkspaceCommandActions?
    @Entry var workspaceSaveAction: WorkspaceSaveAction?
}

private struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspaceCommands) private var workspace
    @FocusedValue(\.workspaceSaveAction) private var saveAction

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Menu("New") {
                Button("Workspace…") { workspace?.create() }
                Divider()
                Group {
                    Button("App") { workspace?.newRecord(.app) }
                    Button("Identity") { workspace?.newRecord(.identity) }
                    Button("Website") { workspace?.newRecord(.website) }
                    Button("Social Account") { workspace?.newRecord(.socialAccount) }
                    Divider()
                    Button("Blog Article") { workspace?.newContent(.blog) }
                    Button("Social Post") { workspace?.newContent(.social) }
                    Button("Idea") { workspace?.newContent(.idea) }
                }
                .disabled(workspace?.hasWorkspace != true)
            }
            .disabled(workspace == nil || workspace?.isBusy == true)
            Button("Open Workspace…") { workspace?.open() }
                .keyboardShortcut("o")
                .disabled(workspace == nil || workspace?.isBusy == true)
            Menu("Open Recent") {
                ForEach(workspace?.recent ?? [], id: \.path) { url in
                    Button(url.lastPathComponent) { workspace?.openRecent(url) }
                        .help(url.path)
                }
            }
            .disabled(workspace?.recent.isEmpty != false || workspace?.isBusy == true)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { saveAction?.perform { _ in } }
                .keyboardShortcut("s")
                .disabled(saveAction == nil || workspace?.isBusy == true)
        }
        CommandGroup(after: .textEditing) {
            Button("Find in Workspace") { workspace?.find() }
                .keyboardShortcut("f")
                .disabled(workspace?.hasWorkspace != true || workspace?.isBusy == true)
        }
        CommandGroup(after: .sidebar) {
            Button("Refresh Workspace") { workspace?.refresh() }
                .disabled(workspace?.hasWorkspace != true || workspace?.isBusy == true)
        }
    }
}

private struct WorkspaceSettingsView: View {
    let updater: SPUUpdater?
    @AppStorage(WorkspaceSession.recentWorkspacesKey) private var recentWorkspaceData = Data()
    @State private var automaticUpdateChecks = false
    @State private var canCheckForUpdates = false

    var body: some View {
        Form {
            Section("Updates") {
                if let updater {
                    Toggle("Automatically check for updates", isOn: $automaticUpdateChecks)
                        .onAppear { automaticUpdateChecks = updater.automaticallyChecksForUpdates }
                        .onChange(of: automaticUpdateChecks) { _, value in
                            updater.automaticallyChecksForUpdates = value
                        }
                    Button("Check for Updates…") { updater.checkForUpdates() }
                        .disabled(!canCheckForUpdates)
                        .onReceive(updater.publisher(for: \.canCheckForUpdates)) { canCheckForUpdates = $0 }
                } else {
                    Text("Updates are unavailable in this build.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Workspaces") {
                let workspaces = (try? WorkspaceRegistry.workspaces()) ?? []
                if workspaces.isEmpty {
                    Text("No workspaces have been opened.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(WorkspaceSession.orderedWorkspaces(workspaces, recentData: recentWorkspaceData), id: \.path) { url in
                        LabeledContent(url.lastPathComponent) {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                .disabled(!FileManager.default.fileExists(atPath: url.path))
                        }
                        .help(url.path)
                    }
                }
            }

            Section("Command-Line Tool") {
                Button("Install Command-Line Tool…", action: CLIInstallation.install)
                Text("Run indiedevbuddy in Terminal to work with workspace files.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .frame(minHeight: 280, idealHeight: 380, maxHeight: 600)
    }
}
