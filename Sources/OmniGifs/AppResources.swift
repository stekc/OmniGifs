import Foundation

enum AppResources {
    static let bundle: Bundle = {
        if Bundle.main.url(forResource: "clip-merges", withExtension: "txt") != nil {
            return .main
        }
        return .module
    }()
}
