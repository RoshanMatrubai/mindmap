import AppKit
import MindmapCore
import Observation

/// File reads, parsing, EventKit and sidecar writes run on this worker, never on the UI thread.
actor ReminderCoordinator {
  private var backend: (any ReminderStore)?
  private var folder: URL?

  func store(in folder: URL) -> any ReminderStore {
    if let backend { return backend }
    self.folder = folder
    #if DEBUG
      if !DebugLaunch.realReminders {
        let fake = FakeReminderStore(
          access: UserDefaults.standard.bool(forKey: ReminderSyncController.enabledKey)
            ? .fullAccess : .notDetermined)
        backend = fake
        return fake
      }
      let name = "mindmap dev"
    #else
      let name = "mindmap"
    #endif
    let real = EventKitReminderStore(folder: folder, name: name)
    backend = real
    return real
  }

  func relocate(to folder: URL) async throws {
    if let real = backend as? EventKitReminderStore { try await real.relocate(to: folder) }
    self.folder = folder
  }

  func access(in folder: URL, request: Bool) async throws -> ReminderAccessState {
    let backend = store(in: folder)
    if request { _ = try await backend.requestAccess() }
    return try await backend.accessState()
  }

  /// Returns the synced records and the name of the account holding the list.
  func sync(
    in folder: URL, open: (URL, MapModel)?, file: URL? = nil, all: Bool, remindAt: Int
  ) async throws -> (records: [ReminderRecord], account: String) {
    let backend = store(in: folder)
    guard try await backend.accessState() == .fullAccess else {
      throw ReminderSyncError.accessDenied
    }
    let today = Date()
    let calendar = Calendar.current
    let urls: [URL]
    if all {
      urls = try MapFiles.list(in: folder).map(\.url)
    } else {
      urls = (open?.0 ?? file).map { [$0] } ?? []
    }
    // A failed read aborts the run, so an unreadable map cannot be mistaken for a deletion.
    let maps = try urls.map { url in
      let model: MapModel
      if let open, open.0 == url {
        model = open.1
      } else {
        model = MapParser.parse(
          text: try String(contentsOf: url, encoding: .utf8), today: today, calendar: calendar)
      }
      return ReminderMap(
        fileName: url.lastPathComponent, model: model,
        sidecar: ReminderSidecar.load(for: url) ?? ReminderSidecar())
    }
    let result = try await ReminderSync.run(
      store: backend, maps: maps, today: today, calendar: calendar, remindAt: remindAt,
      removeOrphans: all)
    for (url, map) in zip(urls, maps) {
      try ReminderSync.sidecar(for: map, records: result.records).save(for: url)
    }
    return result
  }

  func remove(in folder: URL) async throws {
    let backend = store(in: folder)
    // Revoked access must not trap sync on. The list and its ownership file stay, so a
    // later enable finds and reuses that list.
    guard try await backend.accessState() == .fullAccess else { return }
    try await backend.removeList()
    for file in try MapFiles.list(in: folder) { try ReminderSidecar.remove(for: file.url) }
  }
}

private enum ReminderSyncError: LocalizedError {
  case accessDenied
  var errorDescription: String? { "Reminders access is unavailable" }
}

/// Serial work preserves operation order across edits, rename, enable and disable.
@MainActor @Observable
final class ReminderSyncController {
  /// A new key: Calendar sync being on doesn't grant Reminders access, so the user turns this on.
  nonisolated static let enabledKey = "remindersSyncEnabled"
  private static let remindAtKey = "remindAt"
  private(set) var enabled = UserDefaults.standard.bool(forKey: enabledKey)
  /// Minutes after midnight.
  private(set) var remindAt =
    UserDefaults.standard.object(forKey: remindAtKey) == nil
    ? ReminderSync.defaultRemindAt
    : min(max(UserDefaults.standard.integer(forKey: remindAtKey), 0), 24 * 60 - 1)
  private(set) var access = ReminderAccessState.notDetermined
  private(set) var records: [ReminderRecord] = []
  private(set) var account: String?
  private(set) var lastError: String?
  private(set) var busy = false
  var confirmingRemoval = false
  @ObservationIgnored private let worker = ReminderCoordinator()
  @ObservationIgnored private var pending: Task<Void, Never>?
  @ObservationIgnored private var queued = 0
  @ObservationIgnored private var fileChangeDepth = 0
  private var changingFiles: Bool { fileChangeDepth > 0 }

  var status: String {
    let state: String
    switch access {
    case .notDetermined: state = "access not requested"
    case .fullAccess: state = "full access"
    case .denied: state = "access denied"
    case .restricted: state = "access restricted"
    }
    let count = "\(records.count) reminder" + (records.count == 1 ? "" : "s")
    return [state, count, account.map { "in " + $0 }, lastError].compactMap { $0 }
      .joined(separator: " · ")
  }

  var removalMessage: String {
    #if DEBUG
      "Remove the mindmap dev list and its \(records.count) reminders?"
    #else
      "Remove the mindmap list and its \(records.count) reminders?"
    #endif
  }

  private func enqueue(_ action: @escaping @MainActor () async throws -> Void) {
    let previous = pending
    queued += 1
    busy = true
    pending = Task {
      await previous?.value
      defer {
        queued -= 1
        busy = queued != 0
      }
      do {
        try await action()
        lastError = nil
      } catch {
        lastError = error.localizedDescription
        // Reminders errors can include task text, so never log their payload.
        log.error("reminders sync failed")
      }
    }
  }

  func drain() async { await pending?.value }

  func beginFileChange() async {
    fileChangeDepth += 1
    await drain()
  }

  func endFileChange(in folder: URL?, map: URL?) {
    fileChangeDepth -= 1
    if !changingFiles, let folder { sync(in: folder, open: nil, file: map) }
  }

  func relocate(to folder: URL) async -> Bool {
    await drain()
    do {
      try await worker.relocate(to: folder)
      return true
    } catch {
      lastError = error.localizedDescription
      return false
    }
  }

  func start(in folder: URL) {
    enqueue {
      self.access = try await self.worker.access(in: folder, request: false)
      if self.enabled {
        guard self.access == .fullAccess else { throw ReminderSyncError.accessDenied }
        (self.records, self.account) = try await self.worker.sync(
          in: folder, open: nil, all: true, remindAt: self.remindAt)
      }
    }
  }

  func setEnabled(_ value: Bool, in folder: URL) {
    guard value != enabled, !busy, !changingFiles else { return }
    if !value {
      confirmingRemoval = true
      return
    }
    enqueue {
      self.access = try await self.worker.access(in: folder, request: true)
      guard self.access == .fullAccess else { throw ReminderSyncError.accessDenied }
      self.enabled = true
      UserDefaults.standard.set(true, forKey: Self.enabledKey)
      (self.records, self.account) = try await self.worker.sync(
        in: folder, open: nil, all: true, remindAt: self.remindAt)
    }
  }

  /// "Remind at": moves every dated reminder's due time and alarm.
  func setRemindAt(_ minutes: Int, in folder: URL?) {
    guard minutes != remindAt else { return }
    remindAt = minutes
    UserDefaults.standard.set(minutes, forKey: Self.remindAtKey)
    if let folder { sync(in: folder, open: nil, all: true) }
  }

  func confirmRemoval(in folder: URL) {
    confirmingRemoval = false
    enqueue {
      try await self.worker.remove(in: folder)
      self.enabled = false
      UserDefaults.standard.set(false, forKey: Self.enabledKey)
      self.records = []
      self.account = nil
    }
  }

  func sync(in folder: URL, open: (URL, MapModel)?, file: URL? = nil, all: Bool = false) {
    guard enabled, !changingFiles else { return }
    enqueue {
      guard self.enabled else { return }
      self.access = try await self.worker.access(in: folder, request: false)
      (self.records, self.account) = try await self.worker.sync(
        in: folder, open: open, file: file, all: all, remindAt: self.remindAt)
    }
  }

  func line(for node: MapNode, in map: URL?) -> String? {
    guard enabled, node.depth > 0, node.priority == .high else { return nil }
    if let lastError { return lastError }
    guard
      let reminder = records.first(where: {
        $0.reminder.mapFileName == map?.lastPathComponent && $0.reminder.pathKey == node.pathKey
      })?.reminder
    else { return node.done ? nil : "not in reminders: syncing" }
    let when = reminder.alarm?.formatted(date: .abbreviated, time: .shortened) ?? "no date"
    return "in reminders: " + when + (reminder.completed ? ", completed" : "")
  }

  func openPrivacySettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
    else { return }
    NSWorkspace.shared.open(url)
  }
}
