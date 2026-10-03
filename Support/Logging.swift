import Foundation
import os

/// Central logging entry points. Keep it boring.
enum Log {
    static let app = Logger(subsystem: subsystem, category: "app")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let backend = Logger(subsystem: subsystem, category: "tmux")
    static let terminal = Logger(subsystem: subsystem, category: "terminal")
    static let resolver = Logger(subsystem: subsystem, category: "resolver")

    private static let subsystem = "sh.simul.app"
}
