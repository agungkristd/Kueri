import SwiftUI

struct StructureView: View {
    @Bindable var session: Session
    let table: String
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                LabeledContent("Name") { Text(table).textSelection(.enabled).fontWeight(.medium) }
                LabeledContent("Primary") {
                    HStack(spacing: 4) {
                        if session.primaryKey.isEmpty { Text("none").foregroundStyle(.secondary) }
                        ForEach(session.primaryKey, id: \.self) { k in
                            Text(k).font(.callout.monospaced())
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.3)))
                        }
                    }
                }
                Spacer()
                Text("\(session.result.rows.count) columns").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if let e = session.error {
                Text(e).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            ResultGrid(result: session.result, selection: $session.selectedRow)
        }
    }
}
