import AppKit
import SwiftUI

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
            Button("Discard") { session.edits = [:]; session.error = nil }
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
