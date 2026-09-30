import AppKit
import SwiftUI

/// The default page for a new session (⌘N / ⌘T): pick an agent box to start.
/// Title and working directory are editable here; title stays a placeholder
/// that can be renamed inline in the sidebar later.
struct SessionSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    @State private var skipPermissions = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New Session")
                        .font(.title2.bold())
                    Text(verbatim: workingDirectory)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(model.agents) { agent in
                        AgentBox(agent: agent, darkBackground: colorScheme == .dark) {
                            start(agent)
                        }
                    }
                }

                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(verbatim: workingDirectory)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Change…") { chooseDirectory() }
                }
                .padding(10)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $skipPermissions) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Skip permission prompts")
                            Text("Launches the agent in fully autonomous mode with its dangerous-permissions flag. No approvals, no sandbox prompts.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    TextField(
                        "Title (optional — editable in the sidebar)",
                        text: Binding(
                            get: { model.draft?.title ?? "" },
                            set: { model.updateDraft(title: $0) }
                        )
                    )
                }
                .frame(maxWidth: 420, alignment: .leading)
            }
            .padding(32)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var workingDirectory: String {
        model.draft?.workingDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func start(_ agent: AgentDefinition) {
        let skip = skipPermissions && !agent.dangerousArguments.isEmpty
        model.startDraft(agent: agent, skipPermissions: skip)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: workingDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            model.updateDraft(workingDirectory: url.path)
        }
    }
}

private struct AgentBox: View {
    let agent: AgentDefinition
    let darkBackground: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                icon
                    .frame(height: 34)
                Text(agent.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 110)
            .padding(.horizontal, 8)
            .background(
                hovering ? Color.white.opacity(0.10) : Color.white.opacity(0.05)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        hovering ? AnyShapeStyle(Color.white.opacity(0.25)) : AnyShapeStyle(Color.white.opacity(0.12)),
                        lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Start \(agent.name) in this directory")
    }

    @ViewBuilder
    private var icon: some View {
        if let logo = ProviderIcon.image(for: agent.id, darkBackground: darkBackground) {
            Image(nsImage: logo)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: "terminal")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
        }
    }
}
