//
//  Indie_Dev_BuddyApp.swift
//  Indie Dev Buddy
//
//  Created by Shawn Crawford on 11/5/26.
//

import SwiftUI

@main
struct Indie_Dev_BuddyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Install Command-Line Tool…", action: CLIInstallation.install)
            }
        }
    }
}
