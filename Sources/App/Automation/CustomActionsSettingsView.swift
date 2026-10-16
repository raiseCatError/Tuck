import AppKit
import SwiftUI

@MainActor
struct CustomActionsSettingsView: View {
    @State private var actions = CustomActionPreferences.all
    @State private var name = ""
    @State private var target = ""
    @State private var kind: CustomFinderAction.Kind = .executable
    @State private var selection: CustomFinderAction.Selection = .files
    @State private var needsConfirmation = true
    @State private var errorText = ""
    @State private var showingError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Custom Actions").font(.largeTitle.weight(.semibold))
            Text("Only actions you explicitly configure can run. Scripts receive selected paths as separate arguments, never as a shell command.")
                .font(.callout).foregroundStyle(.secondary)
            GroupBox("Saved Actions") {
                VStack(alignment: .leading, spacing: 10) {
                    if actions.isEmpty {
                        Text("No custom actions configured.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(actions) { item in
                        HStack {
                            Toggle(isOn: Binding(
                                get: { actions.first(where: { $0.id == item.id })?.enabled ?? false },
                                set: { enabled in change(item.id) { $0.enabled = enabled } }
                            )) {
                                Text(item.title).fontWeight(.medium)
                            }
                            Spacer()
                            Text(item.kind == .shortcut ? "Shortcut" : "Executable")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(item.selection.rawValue.capitalized)
                                .font(.caption).foregroundStyle(.secondary)
                            Button {
                                actions.removeAll { $0.id == item.id }
                                save()
                            } label: { Image(systemName: "minus.circle") }
                                .accessibilityLabel("Remove \(item.title)")
                        }
                        Text(item.target).lineLimit(1).truncationMode(.middle)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(8)
            }
            GroupBox("Add Action") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Action title", text: $name)
                    Picker("Kind", selection: $kind) {
                        Text("Executable").tag(CustomFinderAction.Kind.executable)
                        Text("macOS Shortcut").tag(CustomFinderAction.Kind.shortcut)
                    }
                    Picker("Selection", selection: $selection) {
                        Text("Files").tag(CustomFinderAction.Selection.files)
                        Text("Folders").tag(CustomFinderAction.Selection.folders)
                        Text("Files or folders").tag(CustomFinderAction.Selection.any)
                    }
                    HStack {
                        TextField(kind == .shortcut ? "Exact Shortcut name" : "Full executable path", text: $target)
                        if kind == .executable {
                            Button("Choose…") {
                                let panel = NSOpenPanel()
                                panel.canChooseDirectories = false
                                panel.canChooseFiles = true
                                panel.allowsMultipleSelection = false
                                if panel.runModal() == .OK { target = panel.url?.path ?? "" }
                            }
                        }
                    }
                    Toggle("Always confirm before running", isOn: $needsConfirmation)
                    HStack {
                        Spacer()
                        Button("Add Action") { add() }
                            .disabled(actions.count >= 16 || name.isEmpty || target.isEmpty)
                    }
                }.padding(10)
            }
            Text("Up to 16 user-created actions. The executable must have permission to run and must remain available. Scripts run for up to five minutes with restricted environment variables; they can still change your files, so only add code you trust.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .alert("Unable to save action", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText) }
    }

    private func change(_ id: UUID, update: (inout CustomFinderAction) -> Void) {
        guard let i = actions.firstIndex(where: { $0.id == id }) else { return }
        update(&actions[i])
        save()
    }

    private func add() {
        let action = CustomFinderAction(id: UUID(),
            title: name.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind, target: target, selection: selection,
            requiresConfirmation: needsConfirmation, enabled: true)
        guard action.valid else {
            errorText = "Enter a nonempty name and either an absolute executable path or Shortcut name."
            showingError = true
            return
        }
        actions.append(action)
        save()
        if !showingError { name = ""; target = "" }
    }

    private func save() {
        do { try CustomActionPreferences.save(actions) }
        catch { errorText = error.localizedDescription; showingError = true }
    }
}
