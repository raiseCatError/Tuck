import AppKit
import SwiftUI

@MainActor
struct FavoriteSettingsView: View {
    @State private var favorites = FavoritePreferences.all
    @State private var error = ""
    @State private var showError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Destinations").font(.largeTitle.weight(.semibold))
                Text("Save folders for quick Copy To and Move To actions in Finder.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            GroupBox("Favourite Folders") {
                VStack(spacing: 12) {
                    if favorites.isEmpty {
                        Text("No folders saved. Add a destination to make it appear in Finder.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(favorites) { favorite in
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            TextField("Name", text: Binding(
                                get: { favorites.first(where: { $0.id == favorite.id })?.title ?? "" },
                                set: { value in
                                    guard let i = favorites.firstIndex(where: { $0.id == favorite.id }) else { return }
                                    favorites[i].title = String(value.prefix(70))
                                    save()
                                }))
                                .accessibilityLabel("Destination name")
                            Spacer()
                            if let resolved = try? favorite.resolve() {
                                Text(resolved.path).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                                Button("Reveal") {
                                    NSWorkspace.shared.activateFileViewerSelecting([resolved])
                                }
                            } else {
                                Label("Unavailable", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                            Button(role: .destructive) {
                                favorites.removeAll { $0.id == favorite.id }
                                save()
                            } label: {
                                Image(systemName: "minus.circle")
                            }.accessibilityLabel("Remove \(favorite.title)")
                        }.padding(.vertical, 4)
                    }
                    HStack {
                        Spacer()
                        Button("Add Folder…") { addFolder() }
                            .disabled(favorites.count >= 8)
                    }
                }.padding(12)
            }
            Text("Up to eight favourites. Moving files always asks for confirmation; existing filenames are never overwritten. Unavailable or disconnected destinations are refused instead of redirected.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .alert("Unable to update favourites", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: { Text(error) }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.message = "Choose a folder to save as a Tuck destination"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard !favorites.contains(where: { (try? $0.resolve())?.standardizedFileURL == url.standardizedFileURL }) else {
                throw UndoError.unsafe("That folder is already saved.")
            }
            favorites.append(try FavoriteDestination.create(title: url.lastPathComponent, url: url))
            save()
        } catch {
            self.error = error.localizedDescription
            showError = true
        }
    }

    private func save() {
        do { try FavoritePreferences.write(favorites) }
        catch {
            self.error = error.localizedDescription
            showError = true
        }
    }
}
