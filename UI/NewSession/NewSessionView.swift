import AppKit
import SwiftUI

/// The default page for a new session (⌘N / ⌘T): pick an agent box to start.
/// Title and directory sit at the top, where they will appear on the card.
struct SessionSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    @State private var skipPermissions = UserDefaults.standard.bool(forKey: Preferences.Key.skipPermissions)
    /// Highlighted card; ↩ in the title field starts it.
    @AppStorage(Preferences.Key.defaultAgent) private var lastAgentID = "claude"
    @FocusState private var titleFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 30) {
                    DotMatrix(shimmer: 0.35)
                        .frame(width: 150, height: 150)

                    VStack(spacing: 8) {
                        Text("NEW SESSION")
                            .font(.caption.weight(.semibold))
                            .tracking(1.5)
                            .foregroundStyle(.tertiary)

                        // Placeholder = the title the session gets if left empty.
                        TextField(
                            defaultTitle,
                            text: Binding(
                                get: { model.draft?.title ?? "" },
                                set: { model.updateDraft(title: $0) }
                            )
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 26, weight: .bold))
                        .multilineTextAlignment(.center)
                        .focused($titleFocused)
                        .onSubmit { start(defaultAgent) }

                        Button { chooseDirectory() } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "folder")
                                Text(verbatim: (workingDirectory as NSString).abbreviatingWithTildeInPath)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.06)))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Change the working directory")
                    }

                    HStack(spacing: 12) {
                        ForEach(model.agents) { agent in
                            AgentBox(
                                agent: agent,
                                subtitle: subtitle(for: agent),
                                isDefault: agent.id == defaultAgent.id,
                                darkBackground: colorScheme == .dark
                            ) {
                                start(agent)
                            }
                        }
                    }

                    VStack(spacing: 12) {
                        Text("Press ↩ to start \(defaultAgent.name), or pick another")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Toggle("Skip permission prompts", isOn: $skipPermissions)
                            .toggleStyle(.checkbox)
                            .help("Starts the agent with its dangerous-permissions flag: no approvals, no sandbox prompts.")
                    }
                }
                .frame(maxWidth: 680)
                .padding(40)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height) // vertically centered
            }
        }
        .onAppear { titleFocused = true } // ↩ works immediately
    }

    private var defaultAgent: AgentDefinition {
        model.agents.first { $0.id == lastAgentID } ?? model.agents[0]
    }

    private func subtitle(for agent: AgentDefinition) -> String {
        switch agent.id {
        case "claude": "Anthropic"
        case "codex": "OpenAI"
        case "opencode": "Open source"
        default: "Your login shell"
        }
    }

    private var defaultTitle: String {
        let name = URL(fileURLWithPath: workingDirectory).lastPathComponent
        return name.isEmpty ? "Untitled" : name
    }

    private var workingDirectory: String {
        model.draft?.workingDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func start(_ agent: AgentDefinition) {
        lastAgentID = agent.id
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
    let subtitle: String
    let isDefault: Bool
    let darkBackground: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                icon
                    .frame(height: 32)
                VStack(spacing: 2) {
                    Text(agent.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 124)
            .padding(.horizontal, 8)
            .background(Color.white.opacity(hovering ? 0.10 : isDefault ? 0.07 : 0.04))
            .overlay(alignment: .topTrailing) {
                if isDefault {
                    Text("↩")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)))
                        .padding(8)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isDefault ? Color.accentColor.opacity(0.7)
                            : Color.white.opacity(hovering ? 0.25 : 0.10),
                        lineWidth: isDefault ? 1.5 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .scaleEffect(hovering ? 1.02 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
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
