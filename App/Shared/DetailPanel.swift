import MindmapCore
import SwiftUI

/// Prototype `#P`: always along the bottom of the graph pane, on the Mac and the iPad. A hint
/// without a selection; otherwise the name, its path and the node's fields.
struct DetailPanel: View {
  @Bindable var store: MapStore

  #if os(macOS)
    private let hint =
      "click a node to highlight its branch. double-click empty space for a new group, or a label to rename it. return adds a task, tab a subtask, delete removes it."
  #else
    private let hint =
      "tap a node to highlight its branch. double-tap empty space for a new group, or a label to rename it. long-press a node for more."
  #endif

  var body: some View {
    Group {
      if let detail = store.detail {
        content(detail)
      } else {
        Text(hint)
          .font(.system(size: 12))
          .foregroundStyle(color(0x636366))
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(minHeight: 84, alignment: .topLeading)
    .background(color(0x1e1e1e))
    .overlay(alignment: .top) { Rectangle().fill(color(0x2a2a2a)).frame(height: 1) }
    .overlay(alignment: .topTrailing) {
      if let notice = store.notice {
        Text(notice)
          .font(.system(size: 11))
          .foregroundStyle(color(0xc2a26a))
          .padding(.horizontal, 16)
          .padding(.top, 12)
      }
    }
  }

  private func content(_ detail: NodeDetail) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(detail.name.lowercased())
        .font(.system(size: 14))
        .foregroundStyle(color(0xf2f2f7))
      Text(detail.path.isEmpty ? "group" : detail.path.joined(separator: " › ").lowercased())
        .font(.system(size: 11))
        .foregroundStyle(color(0x636366))
        .padding(.top, 2)
      HStack(alignment: .top, spacing: 26) {
        switch detail.kind {
        case .group(let tasks, let nextDue, let high):
          field("tasks") { value("\(tasks)") }
          field("next due") { value(nextDue ?? "none") }
          field("high priority") { value("\(high)") }
        case .task(let due, let priority, let done, let leaf):
          field("due") { value(due ?? "no date") }
          field("priority") {
            value(priority?.rawValue ?? "none", priority.map(Self.priorityColor) ?? 0xd1d1d6)
          }
          field("status") {
            HStack(spacing: 4) {
              if leaf { checkbox(done) { store.toggleDone(detail.index) } }
              value(done ? "done" : "open")
            }
          }
        }
        field("urgency") { value("\(detail.urgencyPercent)%") }
        if !detail.linked.isEmpty {
          field("linked to") {
            HStack(spacing: 0) {
              ForEach(Array(detail.linked.enumerated()), id: \.offset) { i, node in
                linkButton(node.name.lowercased()) { store.selectLinked(node.index) }
                if i < detail.linked.count - 1 { value(", ") }
              }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(color(0xd1d1d6))
          }
        }
      }
      .padding(.top, 10)
      if let line = store.reminderLine {
        Text(line).font(.system(size: 11)).foregroundStyle(color(0x7f9cd1)).padding(.top, 6)
      }
    }
  }

  /// The done checkbox: AppKit's on the Mac; a tappable square on the iPad (iOS has no checkbox).
  @ViewBuilder
  private func checkbox(_ done: Bool, toggle: @escaping () -> Void) -> some View {
    #if os(macOS)
      Toggle("done", isOn: Binding(get: { done }, set: { _ in toggle() }))
        .toggleStyle(.checkbox)
        .labelsHidden()
        .controlSize(.small)
    #else
      Button(action: toggle) {
        Image(systemName: done ? "checkmark.square.fill" : "square")
          .font(.system(size: 17))
          .foregroundStyle(color(done ? 0x6a4ff0 : 0xa1a1a6))
          .frame(minWidth: 30, minHeight: 30)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .hoverEffect()
      .accessibilityLabel(done ? "mark not done" : "mark done")
    #endif
  }

  @ViewBuilder
  private func linkButton(_ title: String, action: @escaping () -> Void) -> some View {
    #if os(macOS)
      Button(title, action: action)
        .buttonStyle(.plain)
        .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
    #else
      Button(title, action: action)
        .buttonStyle(.plain)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .hoverEffect()
    #endif
  }

  private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label).font(.system(size: 10.5)).foregroundStyle(color(0x636366))
      content()
    }
  }

  private func value(_ text: String, _ hex: UInt32 = 0xd1d1d6) -> some View {
    Text(text).font(.system(size: 12.5)).foregroundStyle(color(hex))
  }

  static func priorityColor(_ priority: MapPriority) -> UInt32 {
    switch priority {
    case .high: 0xc98589
    case .medium: 0xc2a26a
    case .low, .chill: 0x7f9cd1
    }
  }

  private func color(_ hex: UInt32) -> Color {
    Color(
      .sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
      blue: Double(hex & 255) / 255)
  }
}
