import AppKit
import MindmapCore
import Observation

/// File reads, parsing, EventKit and sidecar writes run on this worker, never on the UI thread.
actor CalendarCoordinator {
  private var backend: (any CalendarStore)?
  private var folder: URL?

  func store(in folder: URL) -> any CalendarStore {
    if let backend { return backend }
    self.folder = folder
    #if DEBUG
      if !DebugLaunch.realCalendar {
        let fake = FakeCalendarStore(
          access: UserDefaults.standard.bool(forKey: "calendarSyncEnabled")
            ? .fullAccess : .notDetermined)
        backend = fake
        return fake
      }
      let name = "mindmap dev"
    #else
      let name = "mindmap"
    #endif
    let real = EventKitCalendarStore(folder: folder, name: name)
    backend = real
    return real
  }

  func relocate(to folder: URL) async throws {
    if let real = backend as? EventKitCalendarStore { try await real.relocate(to: folder) }
    self.folder = folder
  }

  func access(in folder: URL, request: Bool) async throws -> CalendarAccessState {
    let backend = store(in: folder)
    if request { _ = try await backend.requestAccess() }
    return try await backend.accessState()
  }

  /// Returns the synced records and the name of the account holding the calendar.
  func sync(in folder: URL, open: (URL, MapModel)?, file: URL? = nil, all: Bool) async throws
    -> (records: [CalendarEventRecord], account: String)
  {
    let backend = store(in: folder)
    guard try await backend.accessState() == .fullAccess else {
      throw CalendarSyncError.accessDenied
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
      return CalendarMap(
        fileName: url.lastPathComponent, model: model,
        sidecar: CalendarSidecar.load(for: url) ?? CalendarSidecar())
    }
    let account = try await backend.ensureCalendar()
    let records = try await backend.events()
    let operations = CalendarSync.plan(
      maps: maps, current: records, today: today, calendar: calendar, removeOrphans: all)
    let result = try await backend.apply(operations)
    for (url, map) in zip(urls, maps) {
      try CalendarSync.sidecar(for: map, records: result).save(for: url)
    }
    return (result, account)
  }

  func remove(in folder: URL) async throws {
    let backend = store(in: folder)
    // Revoked access must not trap sync on. The calendar and its ownership file stay, so a
    // later enable finds and reuses that calendar.
    guard try await backend.accessState() == .fullAccess else { return }
    try await backend.removeCalendar()
    for file in try MapFiles.list(in: folder) { try CalendarSidecar.remove(for: file.url) }
  }
}

private enum CalendarSyncError: LocalizedError {
  case accessDenied
  var errorDescription: String? { "Calendar access is unavailable" }
}

/// Serial work preserves operation order across edits, rename, enable and disable.
@MainActor @Observable
final class CalendarSyncController {
  private(set) var enabled = UserDefaults.standard.bool(forKey: "calendarSyncEnabled")
  private(set) var access = CalendarAccessState.notDetermined
  private(set) var records: [CalendarEventRecord] = []
  private(set) var account: String?
  private(set) var lastError: String?
  private(set) var busy = false
  var confirmingRemoval = false
  @ObservationIgnored private let worker = CalendarCoordinator()
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
    let events = "\(records.count) synced event" + (records.count == 1 ? "" : "s")
    return [state, events, account.map { "in " + $0 }, lastError].compactMap { $0 }
      .joined(separator: " · ")
  }

  var removalMessage: String {
    #if DEBUG
      "Remove the mindmap dev calendar and its \(records.count) events?"
    #else
      "Remove the mindmap calendar and its \(records.count) events?"
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
        // Calendar errors can include task text, so never log their payload.
        log.error("calendar sync failed")
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
        guard self.access == .fullAccess else { throw CalendarSyncError.accessDenied }
        (self.records, self.account) = try await self.worker.sync(in: folder, open: nil, all: true)
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
      guard self.access == .fullAccess else { throw CalendarSyncError.accessDenied }
      self.enabled = true
      UserDefaults.standard.set(true, forKey: "calendarSyncEnabled")
      (self.records, self.account) = try await self.worker.sync(in: folder, open: nil, all: true)
    }
  }

  func confirmRemoval(in folder: URL) {
    confirmingRemoval = false
    enqueue {
      try await self.worker.remove(in: folder)
      self.enabled = false
      UserDefaults.standard.set(false, forKey: "calendarSyncEnabled")
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
        in: folder, open: open, file: file, all: all)
    }
  }

  func line(for node: MapNode, in map: URL?) -> String? {
    guard enabled, node.depth > 0, node.priority == .high else { return nil }
    if let lastError { return lastError }
    guard node.due != nil else { return "not on calendar: no date" }
    guard
      let event = records.first(where: {
        $0.event.mapFileName == map?.lastPathComponent && $0.event.pathKey == node.pathKey
      })
    else { return node.done ? nil : "not on calendar: syncing" }
    return "on calendar: " + event.event.date.formatted(date: .abbreviated, time: .omitted)
  }

  func openPrivacySettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
    else { return }
    NSWorkspace.shared.open(url)
  }
}
