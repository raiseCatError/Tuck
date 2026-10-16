import Foundation

// Regression tests for the preference store. The helper used to force unwrap
// `UserDefaults(suiteName:)`, which Foundation returns nil for when the suite
// name equals the running bundle identifier. That trapped the helper on every
// launch, so every Finder action died before reaching Tuck.
@main
struct PreferencesTests {
    static func main() {
        // The helper resolves its own domain instead of trapping.
        let helper = TuckPreferences.resolveStore(domain: "dev.raisecaterror.tuck",
                                                  bundleIdentifier: "dev.raisecaterror.tuck")
        assert(helper === UserDefaults.standard, "helper must use its own standard domain")

        // The Finder extension keeps using the shared suite: a value written through
        // the resolved store is visible to any other reader of that suite.
        let extensionStore = TuckPreferences.resolveStore(domain: "dev.raisecaterror.tuck",
                                                          bundleIdentifier: "dev.raisecaterror.tuck.finder")
        assert(extensionStore !== UserDefaults.standard, "extension must use the shared suite")
        extensionStore.set("probe", forKey: "tests.suiteProbe")
        extensionStore.synchronize()
        assert(UserDefaults(suiteName: "dev.raisecaterror.tuck")?.string(forKey: "tests.suiteProbe") == "probe",
               "extension store is the shared preference file")
        extensionStore.removeObject(forKey: "tests.suiteProbe")
        extensionStore.synchronize()

        // The live accessor always reaches the shared preference file.
        TuckPreferences.store.set("probe", forKey: "tests.liveStore")
        TuckPreferences.store.synchronize()
        assert(UserDefaults(suiteName: "dev.raisecaterror.tuck")?.string(forKey: "tests.liveStore") == "probe",
               "TuckPreferences.store is the shared preference file")
        TuckPreferences.store.removeObject(forKey: "tests.liveStore")
        TuckPreferences.store.synchronize()

        // Keys survive a round trip through whichever store is active.
        let store = TuckPreferences.store
        let saved = store.object(forKey: "tests.roundTrip")
        defer { if let saved { store.set(saved, forKey: "tests.roundTrip") } else { store.removeObject(forKey: "tests.roundTrip") } }
        store.set("ok", forKey: "tests.roundTrip")
        assert(store.string(forKey: "tests.roundTrip") == "ok")

        // A present key is always a full 32-byte key, and it is never regenerated.
        if TuckPreferences.sharedKey == nil {
            assert(TuckPreferences.prepareKey(), "a missing key is created on demand")
        } else {
            assert(TuckPreferences.prepareKey() == false, "an existing key is never regenerated")
        }
        assert(TuckPreferences.sharedKey?.count == 32, "ipc key must be 32 bytes")

        print("PreferencesTests passed")
    }
}