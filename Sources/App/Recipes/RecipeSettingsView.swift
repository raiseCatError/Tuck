import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct RecipeSettingsView: View {
    @State private var recipes = RecipePreferences.all
    @State private var selectedID: UUID?
    @State private var newTitle = "Export for Web"
    @State private var stepKind: RecipeStep.Kind = .resizeLongestEdge
    @State private var stepValue = "1600"
    @State private var errorText = ""
    @State private var showError = false

    private var current: Int? { recipes.firstIndex { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recipes").font(.largeTitle.weight(.semibold))
            Text("Reusable, non-destructive image steps. Originals are unchanged; final copies go into an export folder.")
                .font(.subheadline).foregroundStyle(.secondary)
            GroupBox("Saved Recipes") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(recipes) { recipe in
                        HStack {
                            Button {
                                selectedID = recipe.id
                            } label: {
                                HStack {
                                    Image(systemName: recipe.id == selectedID ? "checkmark.circle.fill" : "circle")
                                    Text(recipe.title)
                                    Spacer()
                                }
                            }.buttonStyle(.plain)
                            Button {
                                guard recipes.count < 12 else { return }
                                let copy = SavedRecipe(title: recipe.title + " copy", steps: recipe.steps)
                                recipes.append(copy)
                                selectedID = copy.id
                                save()
                            } label: { Image(systemName: "plus.square.on.square") }
                                .accessibilityLabel("Duplicate \(recipe.title)")
                            Button(role: .destructive) {
                                recipes.removeAll { $0.id == recipe.id }
                                if selectedID == recipe.id { selectedID = nil }
                                save()
                            } label: { Image(systemName: "minus.circle") }
                                .accessibilityLabel("Delete \(recipe.title)")
                        }
                    }
                    HStack {
                        TextField("New recipe name", text: $newTitle)
                        Button("New Recipe") {
                            guard recipes.count < 12 else { return }
                            let starter = SavedRecipe(title: newTitle, steps: [
                                RecipeStep(kind: .resizeLongestEdge, value: "1600"),
                                RecipeStep(kind: .convert, value: "jpeg")
                            ])
                            recipes.append(starter)
                            selectedID = starter.id
                            save()
                        }.disabled(newTitle.isEmpty || recipes.count >= 12)
                    }
                    HStack {
                        Button("Import JSON…") { importRecipe() }
                        Button("Export JSON…") { exportRecipe() }.disabled(current == nil)
                        Spacer()
                    }
                }.padding(10)
            }
            if let index = current {
                GroupBox("Steps — \(recipes[index].title)") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Recipe name", text: Binding(
                            get: { recipes[index].title },
                            set: { recipes[index].title = $0; save() }
                        ))
                        List {
                            ForEach(recipes[index].steps) { step in
                                HStack {
                                    Image(systemName: "line.3.horizontal")
                                        .foregroundStyle(.tertiary)
                                    Text(step.title)
                                    Spacer()
                                    Button {
                                        recipes[index].steps.removeAll { $0.id == step.id }
                                        save()
                                    } label: { Image(systemName: "minus.circle") }
                                        .accessibilityLabel("Remove \(step.title)")
                                }
                            }
                            .onMove { offsets, target in
                                recipes[index].steps.move(fromOffsets: offsets, toOffset: target)
                                save()
                            }
                        }
                        .frame(height: 150)
                        HStack {
                            Picker("Add step", selection: $stepKind) {
                                Text("Resize longest edge").tag(RecipeStep.Kind.resizeLongestEdge)
                                Text("Convert format").tag(RecipeStep.Kind.convert)
                                Text("Strip metadata").tag(RecipeStep.Kind.stripMetadata)
                            }.frame(maxWidth: 270)
                            if stepKind != .stripMetadata {
                                TextField(stepKind == .convert ? "jpeg / png / heic / tiff / webp" : "1600",
                                          text: $stepValue)
                                    .frame(maxWidth: 180)
                            }
                            Button("Add Step") {
                                guard let index = current else { return }
                                let step = RecipeStep(kind: stepKind,
                                                      value: stepKind == .stripMetadata ? "" : stepValue)
                                guard step.valid && recipes[index].steps.count < 8 else {
                                    errorText = "Invalid step, or recipe already contains eight steps."
                                    showError = true
                                    return
                                }
                                recipes[index].steps.append(step)
                                save()
                            }
                        }
                        Text("Drag to reorder. Maximum eight steps per recipe, 12 recipes total. Format availability depends on installed native/optional codecs.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(10)
                }
            }
            Text("Recipes contain typed built-in actions only. Imported JSON cannot launch scripts, Shortcuts or network requests.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear { if selectedID == nil { selectedID = recipes.first?.id } }
        .alert("Unable to update recipe", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText) }
    }

    private func save() {
        do { try RecipePreferences.save(recipes) }
        catch { errorText = error.localizedDescription; showError = true }
    }
    private func importRecipe() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 64_000 else { throw UndoError.unsafe("JSON is too large.") }
            let parsed = try JSONDecoder().decode(SavedRecipe.self, from: data)
            guard parsed.valid, recipes.count < 12 else {
                throw UndoError.unsafe("Unsupported or invalid recipe, or the recipe limit was reached.")
            }
            let copy = SavedRecipe(title: parsed.title, steps: parsed.steps)
            recipes.append(copy); selectedID = copy.id; save()
        } catch { errorText = error.localizedDescription; showError = true }
    }
    private func exportRecipe() {
        guard let index = current else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "tuck-recipe.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try JSONEncoder().encode(recipes[index]).write(to: url, options: .atomic) }
        catch { errorText = error.localizedDescription; showError = true }
    }
}
