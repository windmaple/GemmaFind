import AppKit
import GemmaFindCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedFolder: String?
    @State private var newPattern = ""

    var body: some View {
        Form {
            Section {
                List(selection: $selectedFolder) {
                    ForEach(model.settings.folders, id: \.self) { folder in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: folder)).resizable().frame(width: 18, height: 18)
                            Text((folder as NSString).abbreviatingWithTildeInPath)
                            Spacer()
                            if !FileManager.default.fileExists(atPath: folder) {
                                Text("missing").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .tag(folder)
                    }
                }
                .frame(minHeight: 110)
                HStack {
                    Button("Add Folder…") { addFolder() }
                    Button("Remove") { if let f = selectedFolder { model.removeFolder(f); selectedFolder = nil } }
                        .disabled(selectedFolder == nil)
                    Spacer()
                }
            } header: {
                Text("Indexed folders")
            } footer: {
                Text("macOS will ask once for permission to read Documents, Desktop and Downloads.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Content types") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading) {
                    ForEach(FileKind.allCases, id: \.self) { kind in
                        Toggle(isOn: Binding(
                            get: { model.settings.enabledKinds.contains(kind) },
                            set: { on in
                                if on { model.settings.enabledKinds.insert(kind) } else { model.settings.enabledKinds.remove(kind) }
                            })) {
                            Label(kind.displayName, systemImage: kind.symbolName)
                        }
                    }
                }
            }

            Section {
                ForEach(model.settings.excludedPatterns, id: \.self) { p in
                    HStack {
                        Text(p).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button { model.settings.excludedPatterns.removeAll { $0 == p } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("e.g. */Archive/* or *.log", text: $newPattern)
                        .onSubmit(addPattern)
                    Button("Add", action: addPattern).disabled(newPattern.isEmpty)
                }
            } header: {
                Text("Exclusions")
            }

            Section("General") {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                LabeledContent("Shortcut", value: HotKeyManager.shortcutDisplay)
                LabeledContent("Model") {
                    Text("EmbeddingGemma 2 (740M, LiteRT-LM) · 768-d").foregroundStyle(.secondary)
                }
                LabeledContent("Index") {
                    Text(model.statusLine).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 560)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Index"
        if panel.runModal() == .OK { panel.urls.forEach(model.addFolder) }
    }

    private func addPattern() {
        let p = newPattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !model.settings.excludedPatterns.contains(p) else { return }
        model.settings.excludedPatterns.append(p)
        newPattern = ""
    }
}
