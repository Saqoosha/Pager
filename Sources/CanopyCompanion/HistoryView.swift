import SwiftUI

enum HistoryRoute: Hashable {
    case detail(String)
    case settings
}

struct HistoryListView: View {
    @State private var items: [NotificationHistoryItem] = []
    @State private var loadError: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            if let error = loadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if items.isEmpty && loadError == nil {
                Text("No notifications yet")
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                NavigationLink(value: HistoryRoute.detail(item.id)) {
                    HistoryRow(item: item)
                }
            }
            .onDelete(perform: delete)
        }
        .navigationTitle("History")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink(value: HistoryRoute.settings) {
                    Image(systemName: "gearshape")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    do {
                        try HistoryStore.deleteAll()
                        items = []
                    } catch {
                        loadError = "Clear failed: \(error.localizedDescription)"
                    }
                } label: {
                    Text("Clear All")
                }
                .disabled(items.isEmpty)
            }
        }
        .refreshable { reload() }
        .onAppear { reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reload() }
        }
    }

    private func reload() {
        do {
            items = try HistoryStore.loadAll()
            loadError = nil
        } catch {
            loadError = "Load failed: \(error.localizedDescription)"
            items = []
        }
    }

    private func delete(at offsets: IndexSet) {
        do {
            for i in offsets {
                try HistoryStore.delete(id: items[i].id)
            }
            items.remove(atOffsets: offsets)
        } catch {
            loadError = "Delete failed: \(error.localizedDescription)"
            reload()
        }
    }
}

private struct HistoryRow: View {
    let item: NotificationHistoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(.subheadline.bold())
                .lineLimit(2)
            Text(NotificationHistoryItem.displayableBody(item.body))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(item.receivedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let decision = item.decision {
                    DecisionBadge(decision: decision)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct DecisionBadge: View {
    let decision: String

    var body: some View {
        Text(decision)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background)
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }

    private var background: Color {
        switch decision {
        case "allow", "allowAlways": return .green
        case "deny": return .red
        default: return .gray
        }
    }
}

struct HistoryDetailView: View {
    let id: String
    @State private var item: NotificationHistoryItem?
    @State private var missing = false
    @State private var loadError: String?

    var body: some View {
        Group {
            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.headline)
                            Text(item.receivedAt.formatted(date: .abbreviated, time: .standard))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let decision = item.decision {
                                Label(decision, systemImage: icon(for: decision))
                                    .foregroundStyle(color(for: decision))
                                    .font(.subheadline)
                            }
                        }
                        Divider()
                        Text(NotificationHistoryItem.displayableBody(item.body))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding()
                }
                .navigationTitle(item.toolName ?? "Notification")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            UIPasteboard.general.string = NotificationHistoryItem.displayableBody(item.body)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                    }
                }
            } else if let loadError {
                ContentUnavailableView(
                    "Failed to load notification",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else if missing {
                ContentUnavailableView(
                    "Notification not found",
                    systemImage: "tray",
                    description: Text("It may have been cleared or pruned.")
                )
            } else {
                ProgressView()
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        do {
            if let found = try HistoryStore.item(withId: id) {
                item = found
            } else {
                missing = true
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func icon(for decision: String) -> String {
        switch decision {
        case "allow", "allowAlways": return "checkmark.circle.fill"
        case "deny": return "xmark.circle.fill"
        default: return "questionmark.circle"
        }
    }

    private func color(for decision: String) -> Color {
        switch decision {
        case "allow", "allowAlways": return .green
        case "deny": return .red
        default: return .gray
        }
    }
}
