import AppKit
import SwiftUI

/// The connection form: labels right-aligned in one column, fields in the other; long explanations
/// live in tooltips.
struct ConnectionFields: View {
    @Binding var draft: Conn

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                label("Type")
                Picker("Type", selection: $draft.kind) {
                    ForEach([Conn.Kind.postgres, .mysql, .sqlite, .redis], id: \.self) { Label($0.shortName, systemImage: $0.icon).tag($0) }
                }
                .labelsHidden().frame(width: 300, alignment: .leading)
            }
            if draft.kind == .sqlite {
                GridRow {
                    label("File")
                    HStack {
                        TextField("File", text: $draft.path, prompt: Text("/path/to/database.sqlite")).labelsHidden().selectAllOnFocus()
                        Button("Choose…") { pickFile() }
                    }
                }
            } else {
                GridRow {
                    label("Host")
                    HStack(spacing: 8) {
                        TextField("Host", text: $draft.host, prompt: Text("localhost")).labelsHidden().selectAllOnFocus()
                        Text("Port").foregroundStyle(.secondary)
                        TextField("Port", text: $draft.port, prompt: Text(draft.kind.defaults.port)).labelsHidden().selectAllOnFocus().frame(width: 70)
                    }
                }
                GridRow {
                    label(draft.kind == .redis ? "User (ACL)" : "User")
                    TextField("User", text: $draft.user, prompt: Text(draft.kind == .redis ? "optional" : draft.kind.defaults.user))
                        .labelsHidden().selectAllOnFocus()
                }
                GridRow {
                    label("Password")
                    SecureField("Password", text: Binding(get: { draft.password ?? "" }, set: { draft.password = $0.isEmpty ? nil : $0 }),
                                prompt: Text("none")).labelsHidden().selectAllOnFocus()
                }
                GridRow {
                    label(draft.kind == .redis ? "DB index" : "Database")
                    TextField("Database", text: $draft.database, prompt: Text(draft.kind == .redis ? "0" : "optional")).labelsHidden().selectAllOnFocus()
                }
                GridRow { Divider().gridCellColumns(2) }
                GridRow {
                    label("TLS / SSL")
                    HStack {
                        Picker("TLS / SSL", selection: Binding(get: { draft.tlsMode }, set: { draft.tls = $0 })) {
                            ForEach(TLSMode.allCases.filter { draft.kind != .redis || $0 != .prefer }, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 300, alignment: .leading)
                        .help("Required encrypts without checking the certificate (fine for a self-signed home server). Verify also checks the certificate and host name.")
                    }
                }
                if draft.kind == .postgres || draft.kind == .redis {
                    GridRow {
                        Color.clear.frame(width: 96, height: 1)
                        Toggle("Allow cleartext password", isOn: Binding(get: { draft.allowCleartextPassword ?? false },
                                                                        set: { draft.allowCleartextPassword = $0 }))
                            .help(draft.kind == .redis
                                  ? "Without TLS Verify or SSH, a Redis password is only sent to localhost unless this is on."
                                  : "Only for servers using the 'password' auth method.")
                    }
                }
                if draft.kind == .mysql {
                    GridRow {
                        Color.clear.frame(width: 96, height: 1)
                        Toggle("Allow public key retrieval", isOn: Binding(get: { draft.allowPublicKeyRetrieval ?? false },
                                                                          set: { draft.allowPublicKeyRetrieval = $0 }))
                            .help("MySQL 8 needs it to log in without TLS Verify. Only enable on a network you trust.")
                    }
                }
                GridRow {
                    Color.clear.frame(width: 96, height: 1)
                    Toggle("Connect over SSH", isOn: Binding(get: { draft.useSSH ?? false }, set: { draft.useSSH = $0 }))
                        .help("Uses your ~/.ssh config, keys and ssh-agent (no password login). Host and port above are as seen from the SSH server.")
                }
                if draft.useSSH == true {
                    GridRow {
                        label("SSH host")
                        HStack(spacing: 8) {
                            TextField("SSH host", text: Binding(get: { draft.sshHost ?? "" }, set: { draft.sshHost = $0 }), prompt: Text("bastion.example.com"))
                                .labelsHidden().selectAllOnFocus()
                            Text("Port").foregroundStyle(.secondary)
                            TextField("SSH port", text: Binding(get: { draft.sshPort ?? "22" }, set: { draft.sshPort = $0 }), prompt: Text("22"))
                                .labelsHidden().selectAllOnFocus().frame(width: 70)
                        }
                    }
                    GridRow {
                        label("SSH user")
                        TextField("SSH user", text: Binding(get: { draft.sshUser ?? "" }, set: { draft.sshUser = $0 }), prompt: Text(NSUserName()))
                            .labelsHidden().selectAllOnFocus()
                    }
                    GridRow {
                        label("Key")
                        HStack {
                            TextField("Key", text: Binding(get: { draft.sshKey ?? "" }, set: { draft.sshKey = $0 }), prompt: Text("ssh-agent / ~/.ssh/config"))
                                .labelsHidden()
                            Button("Choose…") { pickKey() }
                        }
                    }
                }
            }
            GridRow { Divider().gridCellColumns(2) }
            GridRow {
                Color.clear.frame(width: 96, height: 1)
                Toggle("Production database", isOn: Binding(get: { draft.isProduction ?? false }, set: { draft.isProduction = $0 }))
                    .help("Marks the connection in red and asks before UPDATE/DELETE without WHERE, DROP, TRUNCATE, saving edits and importing.")
            }
        }
        .textFieldStyle(.roundedBorder)
        .toggleStyle(.checkbox)
    }

    private func label(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).frame(width: 96, alignment: .trailing).gridColumnAlignment(.trailing)
    }

    private func pickKey() {
        let p = NSOpenPanel()
        p.showsHiddenFiles = true
        p.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if p.runModal() == .OK, let u = p.url { draft.sshKey = u.path }
    }

    private func pickFile() {
        let p = NSOpenPanel()
        p.allowsOtherFileTypes = true
        if p.runModal() == .OK, let u = p.url {
            draft.path = u.path
            if draft.name == Conn().name { draft.name = u.lastPathComponent }
        }
    }
}
