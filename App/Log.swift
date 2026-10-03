import Foundation
import os

/// `make logs` shows this subsystem (the bundle ID, so Debug and Release logs stay apart).
let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "app")
