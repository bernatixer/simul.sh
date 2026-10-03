import AppKit
import SwiftUI

/// Settings (⌘,). Everything here maps to real behavior; terminal look and
/// feel stays in Ghostty's own config.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AgentSettings()
                .tabItem { Label("Agents", systemImage: "sparkles") }
            SidebarSettings()
                .tabItem { Label("Sidebar", systemImage: "sidebar.left") }
            TerminalSettings()
                .tabItem { Label("Terminal", systemImage: "terminal") }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Preferences.Key.defaultAgent) private var defaultAgent = "claude"
    @AppStorage(Preferences.Key.directoryMode) private var directoryMode = Preferences.DirectoryMode.currentSession.rawValue
    @AppStorage(Preferences.Key.customDirectory) private var customDirectory = ""
    @AppStorage(Preferences.Key.skipPermissions) private var skipPermissions = false
    @AppStorage(Preferences.Key.confirmClose) private var confirmClose = true

    var body: some View {
        Form {
            Section("New session defaults") {
                Picker("Agent", selection: $defaultAgent) {
                    ForEach(AgentDefinition.builtIns) { Text($0.name).tag($0.id) }
                }
                Picker("Folder", selection: $directoryMode) {
                    Text("Current session's folder").tag(Preferences.DirectoryMode.currentSession.rawValue)
                    Text("Home folder").tag(Preferences.DirectoryMode.home.rawValue)
                    if customDirectory.isEmpty {
                        Text("Choose…").tag(Preferences.DirectoryMode.custom.rawValue)
                    } else {
                        Text(verbatim: (customDirectory as NSString).abbreviatingWithTildeInPath)
                            .tag(Preferences.DirectoryMode.custom.rawValue)
                    }
                }
                .onChange(of: directoryMode) { previous, mode in
                    // Picking a specific folder with none set asks right away;
                    // cancelling keeps the previous choice.
                    if mode == Preferences.DirectoryMode.custom.rawValue, customDirectory.isEmpty,
                       !chooseFolder() {
                        directoryMode = previous
                    }
                }
                if directoryMode == Preferences.DirectoryMode.custom.rawValue, !customDirectory.isEmpty {
                    LabeledContent("") {
                        Button("Change Folder…") { _ = chooseFolder() }
                    }
                }
                Toggle("Skip permission prompts", isOn: $skipPermissions)
            }
            Section("Closing") {
                Toggle("Ask before closing a running agent (⌘W)", isOn: $confirmClose)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// True when a folder was picked.
    private func chooseFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = URL(fileURLWithPath: customDirectory.isEmpty ? NSHomeDirectory() : customDirectory)
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        customDirectory = url.path
        return true
    }
}

private struct AgentSettings: View {
    var body: some View {
        Form {
            Section {
                ForEach(AgentDefinition.builtIns.filter { !$0.isShell }) { agent in
                    ExtraArgumentsField(agent: agent)
                }
            } header: {
                Text("Extra arguments")
            } footer: {
                Text("Added every time the agent starts, e.g. `--model opus`. Applies to sessions started from now on.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ExtraArgumentsField: View {
    let agent: AgentDefinition
    @AppStorage private var arguments: String

    init(agent: AgentDefinition) {
        self.agent = agent
        _arguments = AppStorage(wrappedValue: "", Preferences.Key.extraArguments(agent.id))
    }

    var body: some View {
        TextField(agent.name, text: $arguments, prompt: Text("none"))
            .font(.system(.body, design: .monospaced))
    }
}

private struct SidebarSettings: View {
    @AppStorage(Preferences.Key.showDetails) private var showDetails = true
    @AppStorage(Preferences.Key.showLimits) private var showLimits = true

    var body: some View {
        Form {
            Section {
                Toggle("Show folder and branch on sessions", isOn: $showDetails)
                Toggle("Show plan limits", isOn: $showLimits)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TerminalSettings: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Ghostty config") {
                    Button("Open in Editor") { openGhosttyConfig() }
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("Fonts, colors and key bindings come from Ghostty's config. Restart Simul after editing.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Creates an empty config if there is none, then opens it.
    private func openGhosttyConfig() {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/ghostty/config")
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fileManager.createFile(atPath: url.path, contents: Data("# Ghostty config — see https://ghostty.org/docs/config\n".utf8))
        }
        NSWorkspace.shared.open(url)
    }
}
