import SwiftUI

@Observable
class LanguageManager {
    static let shared = LanguageManager()

    var language: String {
        didSet {
            UserDefaults.standard.set([language], forKey: "AppleLanguages")
            UserDefaults.standard.synchronize()
        }
    }

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first ?? "zh-Hans"
        self.language = saved
    }
}
