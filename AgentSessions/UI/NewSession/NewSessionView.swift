import AppKit
import SwiftUI

/// New session sheet: title, working directory, agent.
struct NewSessionView: View {
    @Environment(\.dismiss) private var dismiss

    let onCreate: (String, String, AgentDefinition) -> Void

    @State private var title = ""
    @State private var workingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var agentID = AgentDefinition.builtIns.first?.id ?? "claude"

    private var selectedAgent: AgentDefinition {
        AgentDefinition.builtIns.first { $0.id == agentID } ?? .builtIns[0]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Session")
                .font(.title2.bold())

            Form {
                TextField("Title", text: $title, prompt: Text(placeholderTitle))

                HStack {
                    TextField("Working Directory", text: $workingDirectory)
                    Button("Choose…") { chooseDirectory() }
                }

                Picker("Agent", selection: $agentID) {
                    ForEach(AgentDefinition.builtIns) { agent in
                        Text(agent.name).tag(agent.id)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    onCreate(title, workingDirectory, selectedAgent)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!FileManager.default.fileExists(
                    atPath: workingDirectory,
                    isDirectory: nil))
            }
        }
        .padding()
        .frame(width: 520, height: 260)
    }

    private var placeholderTitle: String {
        let dir = URL(fileURLWithPath: workingDirectory).lastPathComponent
        return dir.isEmpty ? selectedAgent.name : "\(selectedAgent.name) — \(dir)"
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: workingDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            workingDirectory = url.path
        }
    }
}
