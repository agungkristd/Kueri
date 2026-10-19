import AppKit
import SwiftUI

struct ConnectionsView: View {
    @Environment(Store.self) private var store
    @State private var selection: UUID?
    @State private var draft = Conn()
    @State private var error: String?
    @State private var connecting = false
    @State private var tested: String?
    @State private var pendingDelete: Conn?
    @FocusState private var renaming: Bool
    var notice: String?
    let onOpen: (Session) -> Void

    var body: some View {
        // A plain split, not NavigationSplitView: this screen has no sidebar to hide, and the split
        // view controller behind NavigationSplitView costs ~140 ms of launch time.
        HSplitView { sidebar.frame(minWidth: 220, idealWidth: 260, maxWidth: 400); detail }
            .navigationTitle("Kueri")
            .focusedSceneValue(\.renameConnection) { renaming = true }
            .background(TabTitle(title: draft.name.isEmpty ? "Kueri" : draft.name))
        .onChange(of: draft.kind) { old, new in
            // Only swap defaults the user hasn't customised.
            let o = old.defaults, n = new.defaults
            if draft.port == o.port { draft.port = n.port }
            if draft.user == o.user { draft.user = n.user }
            if draft.database == o.database { draft.database = n.database }
        }
        .onChange(of: selection) { _, id in
            guard let c = store.conns.first(where: { $0.id == id }) else { return }
            draft = c; error = nil; tested = nil
        }
        .onChange(of: draft) { old, new in if old.id == new.id { tested = nil } } // a changed form needs a new test
    }

    private var sidebar: some View {
            List(selection: $selection) {
              ForEach(store.conns) { c in
                HStack {
                    Image(systemName: c.kind.icon).foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading) {
                        Text(c.name)
                        Text(c.kind == .sqlite ? c.path : "\(c.user)@\(c.host):\(c.port)/\(c.database)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { pendingDelete = c } label: { Image(systemName: "trash").foregroundStyle(.red) }
                        .buttonStyle(.borderless)
                        .help("Delete \(c.name)")
                }
                // Every other row slightly shaded, like the grid, so long lists stay easy to follow.
                .listRowBackground(rowBackground(c))
              }
              .onMove { store.conns.move(fromOffsets: $0, toOffset: $1) } // drag to reorder; saved with the list
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let c = store.conns.first(where: { ids.contains($0.id) }) {
                    Button("Connect") { open(c) }
                    Button("Rename") { selection = c.id; draft = c; error = nil; renaming = true }
                    Button("Delete", role: .destructive) { pendingDelete = c }
                }
            } primaryAction: { ids in // double-click / Return
                if let c = store.conns.first(where: { ids.contains($0.id) }) { open(c) }
            }
            // A toolbar keeps the title at the leading edge like other Mac apps; SwiftUI only makes one
            // when it has an item, so this one is an empty, hidden spacer.
            .toolbar { ToolbarItem(placement: .navigation) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) } }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    Button { new() } label: { Label("New Connection", systemImage: "plus") }
                        .buttonStyle(.borderless).help("Clear the form for a new connection")
                        .padding(.horizontal, 12).frame(height: Self.barHeight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor))
                }
            }
            .confirmationDialog("Delete \"\(pendingDelete?.name ?? "")\"?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                Button("Delete", role: .destructive) { if let c = pendingDelete { delete(c) } }
            } message: { Text("Its saved password is removed too.") }
    }

    private var detail: some View {
            // Fills the detail area: header on top, fields below (scrolling only if the window is short),
            // actions in a bar along the bottom edge.
            VStack(spacing: 0) {
                header.padding(.horizontal, 28).padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                ScrollView {
                    fields.frame(maxWidth: 900, alignment: .leading)
                        .padding(.horizontal, 28).padding(.vertical, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                footer.padding(.horizontal, 8).frame(height: Self.barHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
    }

    private var summary: String {
        switch draft.kind {
        case .sqlite: draft.path.isEmpty ? "No file chosen" : draft.path
        default:
            (draft.user.isEmpty ? "" : draft.user + "@") + (draft.host.isEmpty ? "localhost" : draft.host)
                + (draft.port.isEmpty ? "" : ":" + draft.port) + (draft.database.isEmpty ? "" : "/" + draft.database)
                + (draft.useSSH == true ? " via \(draft.sshHost ?? "ssh")" : "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: draft.kind.icon).font(.system(size: 22)).foregroundStyle(.secondary).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    TextField("Name", text: $draft.name, prompt: Text("Connection name"))
                        .labelsHidden().textFieldStyle(.plain).font(.title3.weight(.semibold)).fixedSize()
                        .selectAllOnFocus().focused($renaming).onSubmit { save() }
                    Button { renaming = true } label: { Image(systemName: "pencil").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary) }
                        .buttonStyle(.borderless).help("Rename")
                }
                Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if draft.isProduction == true {
                Text("Production").font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(ConnectionBar.production))
            }
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).frame(width: 96, alignment: .trailing).gridColumnAlignment(.trailing)
    }

    /// Labels right-aligned in one column, fields in the other; long explanations live in tooltips.
    private var fields: some View {
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

    @ViewBuilder private var footer: some View {
        HStack(spacing: 8) {
            if connecting { ProgressView().controlSize(.small) }
            if let error = error ?? notice {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    .lineLimit(3).textSelection(.enabled).font(.callout)
            } else if let tested {
                Label(tested, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            }
            Spacer()
            Button("Test Connection") { test() }.disabled(connecting)
            Button("Save") { save() }
            Button("Connect") { connect() }.keyboardShortcut(.defaultAction).disabled(connecting)
        }
        .padding(.horizontal, 20)
    }
    /// Bottom bars of the list and the form line up as one strip.
    static let barHeight: CGFloat = 48

    /// Connects with the current form, reports the server version, and disconnects.
    func test() {
        connecting = true; error = nil; tested = nil
        let c = draft
        Task {
            defer { connecting = false }
            do {
                let s = try await Session.open(c)
                tested = "Connected" + (s.serverVersion.isEmpty ? "" : " · \(s.serverVersion)")
            } catch { self.error = error.localizedDescription }
        }
    }

    private func rowBackground(_ c: Conn) -> some View {
        let odd = !(store.conns.firstIndex(of: c) ?? 0).isMultiple(of: 2)
        return RoundedRectangle(cornerRadius: 6).fill(odd ? Color.primary.opacity(0.06) : .clear).padding(.horizontal, 10)
    }

    func new() { draft = Conn(); selection = nil }

    func save() {
        if let i = store.conns.firstIndex(where: { $0.id == draft.id }) { store.conns[i] = draft } else { store.conns.append(draft) }
        selection = draft.id
    }

    func delete(_ c: Conn) {
        store.conns.removeAll { $0.id == c.id }
        if draft.id == c.id { new() }
    }

    func pickKey() {
        let p = NSOpenPanel()
        p.showsHiddenFiles = true
        p.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if p.runModal() == .OK, let u = p.url { draft.sshKey = u.path }
    }

    func pickFile() {
        let p = NSOpenPanel()
        p.allowsOtherFileTypes = true
        if p.runModal() == .OK, let u = p.url {
            draft.path = u.path
            if draft.name == Conn().name { draft.name = u.lastPathComponent }
        }
    }

    func open(_ c: Conn) {
        selection = c.id
        draft = c
        connect()
    }

    func connect() {
        save()
        connecting = true; error = nil
        Task {
            defer { connecting = false }
            do { onOpen(try await Session.open(draft)) } catch { self.error = error.localizedDescription }
        }
    }
}
