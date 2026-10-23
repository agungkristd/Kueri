import AppKit
import SwiftUI

/// The connection is gone: says so at the top of the content, with the one button that matters.
/// Not in the connection bar: a small borderless button there was easy to miss.
struct ConnectionLostBar: View {
    let session: Session
    var body: some View {
        if session.connectionLost || session.reconnecting {
            HStack {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(.red)
                Text(session.error ?? "Connection lost").lineLimit(2).textSelection(.enabled)
                Spacer()
                Button { session.reconnect() } label: {
                    Label(session.reconnecting ? "Reconnecting…" : "Reconnect", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent).fixedSize()
                .disabled(session.reconnecting)
            }
            .padding(8)
            .background(Color.red.opacity(0.08))
        }
    }
}

/// Several rows selected: how many, and a button to delete them. Its own view, so selecting
/// rows only redraws this bar.
struct SelectionBar: View {
    let session: Session
    var body: some View {
        let n = session.selectedRows.count
        if n > 1, session.readOnlyReason == nil, session.editCount == 0 {
            HStack {
                Text("\(n) rows selected")
                Text("⌘-click or ⇧-click to change").foregroundStyle(.secondary).font(.callout)
                Spacer()
                Button("Delete \(n) Rows…", role: .destructive) { session.deleteRows(session.selectedRows) }
            }
            .bottomBar()
        }
    }
}

/// Shown under the grid whenever there are unsaved edits, whether or not Details is open.
struct SaveBar: View {
    @Bindable var session: Session
    var body: some View {
        HStack {
            Circle().fill(.orange).frame(width: 7, height: 7)
            Text("\(session.editCount) unsaved change\(session.editCount == 1 ? "" : "s")")
            Spacer()
            Button("Discard") { session.discardEdits(); session.error = nil }
                .disabled(session.saving)
            Button { session.saveAll() } label: {
                if session.saving { ProgressView().controlSize(.small) } else { Text("Save") }
            }
            .shortcut(.save)
            .buttonStyle(.borderedProminent)
            .disabled(session.saving)
            .help("Save changes (⌘S)")
        }
        .bottomBar()
    }
}
