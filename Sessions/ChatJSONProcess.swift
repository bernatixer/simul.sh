import Foundation

/// A single owned provider process. Blocking pipe reads and writes stay off the UI thread.
@MainActor
final class ChatJSONProcess {
    var onMessage: (([String: Any]) -> Void)?
    var onExit: ((Int32, String) -> Void)?
    var onError: ((String) -> Void)?
    var isRunning: Bool { process?.isRunning == true }
    var processID: Int32? { (process ?? closingChildren.first(where: \.isRunning))?.processIdentifier }

    private var process: Process?
    private var closingChildren: [Process] = []
    private var input: FileHandle?
    private var generation = UUID()
    private let writes = DispatchQueue(label: "sh.simul.chat.write")
    private var pendingBytes = 0

    func start(executable: String, arguments: [String], environment: [String: String], workingDirectory: String) throws {
        guard process == nil else { throw ChatAgentError.rejected("Chat is already connected.") }
        closingChildren.removeAll { !$0.isRunning }
        let child = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        // boffin: a closed agent pipe must not terminate the app and its other sessions.
        guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw ChatAgentError.rejected("Could not configure Chat's input pipe.")
        }
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.environment = environment
        child.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        let token = UUID()
        generation = token
        let diagnostics = ChatProcessDiagnostics()
        let readers = DispatchGroup()
        readers.enter()
        readers.enter()
        // boffin: drain both pipes before reporting exit so the last acknowledgement is kept.
        child.terminationHandler = { [weak self] child in
            readers.notify(queue: .global(qos: .utility)) {
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.input = nil
                    self.process = nil
                    self.onExit?(child.terminationStatus, diagnostics.text)
                }
            }
        }
        do { try child.run() }
        catch { readers.leave(); readers.leave(); throw error }
        process = child
        input = stdin.fileHandleForWriting
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { readers.leave(); try? stdout.fileHandleForReading.close() }
            var partial = Data()
            do {
                while true {
                    let chunk = stdout.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    partial.append(chunk)
                    while let newline = partial.firstIndex(of: 10) {
                        let line = Data(partial[..<newline])
                        partial.removeSubrange(...newline)
                        if line.isEmpty { continue }
                        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                            throw ChatAgentError.rejected("The agent sent an invalid JSON message.")
                        }
                        let message = ChatProcessMessage(object: object)
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == token else { return }
                            self.onMessage?(message.object)
                        }
                    }
                    guard partial.count <= 32 * 1024 * 1024 else {
                        throw ChatAgentError.rejected("The agent sent a message larger than 32 MB.")
                    }
                }
                if !partial.isEmpty { throw ChatAgentError.rejected("The agent closed an incomplete JSON message.") }
            } catch {
                let detail = error.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.onError?(detail)
                }
            }
        }
        DispatchQueue.global(qos: .utility).async {
            defer { readers.leave(); try? stderr.fileHandleForReading.close() }
            while true {
                let chunk = stderr.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                diagnostics.append(chunk)
            }
        }
    }

    func send(_ object: [String: Any]) throws {
        guard isRunning, let input else { throw ChatAgentError.rejected("Chat is disconnected.") }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        data.append(10)
        guard pendingBytes + data.count <= 64 * 1024 * 1024 else {
            throw ChatAgentError.rejected("Chat is still sending a large message. Wait before sending another.")
        }
        pendingBytes += data.count
        let token = generation
        writes.async { [weak self, data] in
            let failure: String?
            do { try input.write(contentsOf: data); failure = nil }
            catch { failure = error.localizedDescription }
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.pendingBytes -= data.count
                if let failure { self.onError?("Could not write to the agent: \(failure)") }
            }
        }
    }

    func close() {
        generation = UUID()
        pendingBytes = 0
        let child = process
        process = nil
        let handle = input
        input = nil
        writes.async { try? handle?.close() }
        guard let child, child.isRunning else { return }
        closingChildren.append(child)
        child.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }
}

private struct ChatProcessMessage: @unchecked Sendable {
    let object: [String: Any]
}

private final class ChatProcessDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var tail = Data()
    var text: String { lock.withLock { String(decoding: tail, as: UTF8.self) } }
    func append(_ data: Data) {
        lock.withLock {
            tail.append(data)
            if tail.count > 32 * 1024 { tail = Data(tail.suffix(32 * 1024)) }
        }
    }
}
