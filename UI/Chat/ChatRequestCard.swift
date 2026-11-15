import SwiftUI

struct ChatRequestCard: View {
    let request: ChatAgentRequest
    let respond: (ChatAgentDecision, [String: [String]]) -> Void
    @State private var selected: [String: Set<String>] = [:]
    @State private var text: [String: String] = [:]
    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(request.title, systemImage: request.questions.isEmpty ? "hand.raised" : "questionmark.bubble")
                .font(.system(size: 13, weight: .semibold))
            if !request.detail.isEmpty {
                Text(request.detail).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.secondaryText)
                    .lineLimit(8).textSelection(.enabled)
                if request.detail.utf8.count > 512 || request.detail.contains("\n") {
                    Button("Full request") { showingDetails = true }.buttonStyle(.link).font(.system(size: 11))
                }
            }
            ForEach(request.questions) { question in
                VStack(alignment: .leading, spacing: 7) {
                    Text(question.prompt).font(.system(size: 12.5, weight: .medium))
                    ForEach(question.options) { option in
                        Toggle(isOn: Binding(get: { selected[question.id, default: []].contains(option.label) }, set: { on in
                            if !question.allowsMultiple { selected[question.id] = on ? [option.label] : [] }
                            else if on { selected[question.id, default: []].insert(option.label) }
                            else { selected[question.id]?.remove(option.label) }
                        })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label).font(.system(size: 12))
                                if !option.description.isEmpty { Text(option.description).font(.system(size: 11)).foregroundStyle(Theme.secondaryText) }
                            }
                        }.toggleStyle(.checkbox)
                    }
                    if question.isSecret {
                        SecureField("Your answer", text: binding(question.id)).textFieldStyle(.roundedBorder)
                    } else {
                        TextField(question.options.isEmpty ? "Your answer" : "Or write an answer", text: binding(question.id))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            HStack(spacing: 10) {
                Button(request.questions.isEmpty ? "Allow once" : "Send answer") { respond(.allow, answers) }
                    .buttonStyle(.borderedProminent).disabled(!complete)
                if request.allowsSessionApproval { Button("Allow for session") { respond(.allowSession, [:]) } }
                Button(request.questions.isEmpty ? "Deny" : "Cancel") { respond(request.questions.isEmpty ? .deny : .cancel, [:]) }
            }.controlSize(.small)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.35)))
        .sheet(isPresented: $showingDetails) {
            VStack(spacing: 0) {
                HStack { Text(request.title); Spacer(); Button("Done") { showingDetails = false }.keyboardShortcut(.cancelAction) }.padding(14)
                Divider()
                ChatOutputView(text: request.detail)
            }.frame(minWidth: 650, minHeight: 440)
        }
    }

    private var answers: [String: [String]] {
        request.questions.reduce(into: [:]) { result, question in
            let typed = text[question.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            let choices = question.options.map(\.label).filter { selected[question.id, default: []].contains($0) }
            result[question.id] = typed.isEmpty ? choices : question.allowsMultiple ? choices + [typed] : [typed]
        }
    }
    private var complete: Bool { request.questions.allSatisfy { !(answers[$0.id] ?? []).isEmpty } }
    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { text[id, default: ""] }, set: { text[id] = $0 })
    }
}
