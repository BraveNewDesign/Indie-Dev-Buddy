//
//  Indie_Dev_BuddyApp.swift
//  Indie Dev Buddy
//
//  Created by Shawn Crawford on 11/5/26.
//

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
        }
    }
}
