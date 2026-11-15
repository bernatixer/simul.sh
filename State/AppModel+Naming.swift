import Foundation

extension AppModel {
    func updateConversationName(_ id: Session.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              sessions[index].titleOrigin != .provided,
              let state = chats.sessions[id]?.state else { return }
        var session = sessions[index]
        let changed: Bool
        if let title = state.conversationTitle {
            changed = session.useTitle(title, origin: .provider)
        } else if session.titleOrigin == .placeholder, let prompt = state.conversation.entries.lazy.compactMap({ entry -> String? in
            if case let .prompt(_, text, _) = entry, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            return nil
        }).first {
            changed = session.useTitle(prompt, origin: .prompt)
        } else { return }
        guard changed else { return }
        sessions[index] = session
        saveSessions()
    }

}
