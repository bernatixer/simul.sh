import Foundation
@testable import SimulCore

@MainActor
func registerChatJSONProcessTests() {
    test("A closed agent input reports an error without terminating Simul") {
        let transport = ChatJSONProcess()
        var ready = false
        var failure: String?
        transport.onMessage = { _ in ready = true }
        transport.onError = { failure = $0 }
        try transport.start(executable: "/usr/bin/python3", arguments: ["-u", "-c", "import os,time; os.close(0); print('{}',flush=True); time.sleep(1)"],
                            environment: ProcessInfo.processInfo.environment, workingDirectory: "/tmp")
        defer { transport.close() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !ready && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try transport.send(["text": "message"])
        while failure == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        expect(failure != nil, "broken input is recoverable instead of SIGPIPE killing every session")
    }
    test("Chat transport retains ownership until a closing child exits") {
        let transport = ChatJSONProcess()
        var ready = false
        transport.onMessage = { _ in ready = true }
        try transport.start(executable: "/usr/bin/python3", arguments: ["-u", "-c", "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print('{}',flush=True); time.sleep(10)"],
                            environment: ProcessInfo.processInfo.environment, workingDirectory: "/tmp")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !ready && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let pid = transport.processID
        transport.close()
        expectEqual(transport.processID, pid, "a process ignoring SIGTERM is still an owned closing child")
        while transport.processID != nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        expectEqual(transport.processID, nil, "forced shutdown eventually releases the owned child")
    }
    test("Chat transport frames partial JSON, drains stderr and shuts down") {
        let transport = ChatJSONProcess()
        var messages: [String] = []
        var exitCode: Int32?
        var stderr = ""
        transport.onMessage = { if let value = $0["echo"] as? String { messages.append(value) } }
        transport.onExit = { exitCode = $0; stderr = $1 }
        let fixture = """
        import sys,json
        for line in sys.stdin:
            value=json.loads(line)
            if value.get('stop'): break
            wire=json.dumps({'echo':value['text']})+'\\n'
            sys.stdout.write(wire[:3]); sys.stdout.flush()
            sys.stdout.write(wire[3:]); sys.stdout.flush()
            sys.stderr.write('diagnostic\\n'); sys.stderr.flush()
        """
        try transport.start(executable: "/usr/bin/python3", arguments: ["-u", "-c", fixture],
                            environment: ProcessInfo.processInfo.environment, workingDirectory: "/tmp")
        try transport.send(["text": "one\ntwo"])
        try transport.send(["text": "three"])
        try transport.send(["stop": true])
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while exitCode == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        expectEqual(messages, ["one\ntwo", "three"], "partial frames and embedded newlines preserve message order")
        expectEqual(exitCode, 0, "exit is delivered after stdout drains")
        expect(stderr.contains("diagnostic"), "stderr is retained separately")
        transport.close()
        transport.close()
        await expectThrows("writing to a closed transport fails") { try transport.send(["text": "lost"]) }
    }
    test("Chat transport rejects malformed protocol output") {
        let transport = ChatJSONProcess()
        var failure: String?
        transport.onError = { failure = $0 }
        try transport.start(executable: "/usr/bin/python3", arguments: ["-u", "-c", "print('not JSON', flush=True)"],
                            environment: ProcessInfo.processInfo.environment, workingDirectory: "/tmp")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while failure == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        expect(failure != nil, "malformed output is an explicit transport failure")
        transport.close()
    }
}
