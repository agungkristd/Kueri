import SwiftUI

/// A field control's icon: same symbol size, weight, colour and box for every button in the row.
struct FieldIcon: View {
    let name: String
    var body: some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
    }
}
