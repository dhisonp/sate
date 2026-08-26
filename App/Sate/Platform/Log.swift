import Foundation
import OSLog

enum Log {
    static let network = Logger(subsystem: "com.dhison.sate", category: "Network")
    static let state = Logger(subsystem: "com.dhison.sate", category: "State")
    static let persist = Logger(subsystem: "com.dhison.sate", category: "Persistence")
    static let lifecycle = Logger(subsystem: "com.dhison.sate", category: "Lifecycle")
    static let keychain = Logger(subsystem: "com.dhison.sate", category: "Keychain")
}
