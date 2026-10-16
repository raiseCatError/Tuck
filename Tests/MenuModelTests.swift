import Foundation

@main
struct MenuModelTests {
    static func main() {
        let store = TuckPreferences.store
        let savedOrder = store.stringArray(forKey: "menuOrder")
        let savedEnabled = TuckPreferences.defaults.map { ($0, store.object(forKey: "enabled.\($0)")) }
        defer {
            if let savedOrder { store.set(savedOrder, forKey: "menuOrder") } else { store.removeObject(forKey: "menuOrder") }
            for (id, value) in savedEnabled {
                if let value { store.set(value, forKey: "enabled.\(id)") }
                else { store.removeObject(forKey: "enabled.\(id)") }
            }
        }
        TuckPreferences.order = ["terminal", "compress", "openWith", "newFile"]
        let visibleInImage = TuckMenuModel.visible(in: .image).map(\.id)
        assert(visibleInImage == ["terminal", "compress", "openWith", "imageToolkit", "metadata", "copyAs", "rename"])
        assert(!visibleInImage.contains("newFile"))
        assert(!visibleInImage.contains("pdfToolkit"))
        assert(!TuckMenuModel.visible(in: .folder).contains(where: { $0.id == "compress" }))
        TuckPreferences.setEnabled("terminal", to: false)
        assert(!TuckMenuModel.visible(in: .image).contains(where: { $0.id == "terminal" }))
        TuckPreferences.order = ["newFile", "newFile", "nonsense", "terminal"]
        assert(Set(TuckPreferences.order).count == TuckPreferences.defaults.count)
        print("MenuModelTests passed")
    }
}
