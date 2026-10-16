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
        assert(TuckMenuModel.visible(in: .image).map(\.id) == ["terminal", "compress", "openWith", "newFile"])
        assert(!TuckMenuModel.visible(in: .folder).contains(.compress))
        TuckPreferences.setEnabled("terminal", to: false)
        assert(!TuckMenuModel.visible(in: .image).contains(.terminal))
        TuckPreferences.order = ["newFile", "newFile", "nonsense", "terminal"]
        assert(Set(TuckPreferences.order).count == TuckPreferences.defaults.count)
        print("MenuModelTests passed")
    }
}
