import AppKit
import SwiftUI

@MainActor
struct WatchedFoldersSettingsView: View {
    @State private var rules = WatchRulePreferences.all
    @State private var paused = WatchRulePreferences.paused
    @State private var selectedRecipe: UUID?
    @State private var errorText = ""
    @State private var showError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Watched Folders").font(.largeTitle.weight(.semibold))
            Text("Optional local automation while Tuck is running. Only new, stable files in explicitly selected folders are processed.")
                .font(.subheadline).foregroundStyle(.secondary)
            Toggle("Pause all watched folders", isOn: Binding(
                get: { paused },
                set: { value in paused = value; WatchRulePreferences.paused = value }
            ))
            GroupBox("Rules") {
                VStack(alignment: .leading, spacing: 10) {
                    if rules.isEmpty {
                        Text("No watched folders configured. Add a recipe first, then choose an input folder.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(rules) { rule in
                        HStack {
                            Toggle(isOn: Binding(
                                get: { rules.first(where: { $0.id == rule.id })?.enabled ?? false },
                                set: { value in
                                    if let i = rules.firstIndex(where: { $0.id == rule.id }) {
                                        rules[i].enabled = value
                                        save()
                                    }
                                }
                            )) {
                                Text(rule.name).fontWeight(.medium)
                            }
                            Spacer()
                            if let folder = try? rule.resolveFolder() {
                                Text(folder.path).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            } else {
                                Label("Missing folder", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                            Button(role: .destructive) {
                                rules.removeAll { $0.id == rule.id }
                                save()
                            } label: { Image(systemName: "minus.circle") }
                                .accessibilityLabel("Remove \(rule.name)")
                        }
                        if let recipe = RecipePreferences.all.first(where: { $0.id == rule.recipeID }) {
                            Text("Recipe: \(recipe.title)").font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Recipe unavailable; rule will not run.")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    if !RecipePreferences.all.isEmpty {
                        HStack {
                            Picker("Recipe", selection: $selectedRecipe) {
                                Text("Choose a recipe").tag(UUID?.none)
                                ForEach(RecipePreferences.all) { recipe in
                                    Text(recipe.title).tag(Optional(recipe.id))
                                }
                            }
                            Button("Add Folder…") { addFolder() }
                                .disabled(selectedRecipe == nil || rules.count >= 8)
                        }
                    }
                }.padding(10)
            }
            Text("Rule limit: eight folders. Tuck watches direct child image files, skips symlinks and iCloud placeholders, waits for stable writes and excludes hidden/generated outputs. Existing files are not reprocessed on startup.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Watch rules work while the Tuck app is running. Tuck does not install a background login service or watch any folder without explicit opt-in.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            if selectedRecipe == nil { selectedRecipe = RecipePreferences.all.first?.id }
        }
        .alert("Watched folder configuration failed", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText) }
    }

    private func addFolder() {
        guard let recipeID = selectedRecipe else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose a folder to watch for stable new images"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            guard !rules.contains(where: {
                $0.recipeID == recipeID && (try? $0.resolveFolder()) == folder.standardizedFileURL
            }) else { throw UndoError.unsafe("This folder and recipe are already watched.") }
            let name = folder.lastPathComponent
            rules.append(try WatchedFolderRule.create(name: name, folder: folder, recipeID: recipeID))
            save()
        } catch { errorText = error.localizedDescription; showError = true }
    }

    private func save() {
        do { try WatchRulePreferences.save(rules) }
        catch { errorText = error.localizedDescription; showError = true }
    }
}
