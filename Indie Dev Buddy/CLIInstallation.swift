import AppKit

@MainActor
enum CLIInstallation {
    static func install() {
        let manager = FileManager.default
        let directory = manager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
        let destination = directory.appendingPathComponent("indiedevbuddy")
        let alert = NSAlert()
        do {
            guard let executable = Bundle.main.url(forAuxiliaryExecutable: "indiedevbuddy"),
                  manager.isExecutableFile(atPath: executable.path) else {
                throw WorkspaceCommandError("This copy of Indie Dev Buddy is missing its bundled executable.")
            }
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            if (try? manager.destinationOfSymbolicLink(atPath: destination.path)) != executable.path {
                // Symbolic link creation fails if the path is already occupied.
                try manager.createSymbolicLink(at: destination, withDestinationURL: executable)
            }
            alert.messageText = "Command-line tool installed"
            alert.informativeText = """
            Installed at ~/.local/bin/indiedevbuddy.

            If ~/.local/bin is new to your shell, add this line to your shell configuration and open a new Terminal window:

            export PATH="$HOME/.local/bin:$PATH"
            """
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "Could not install the command-line tool"
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }
}
