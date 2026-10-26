import Foundation

enum AppInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    static let repositoryURL = URL(string: "https://github.com/Ayanprakash35/OpenLyrics")!
    static let releasesURL = URL(string: "https://github.com/Ayanprakash35/OpenLyrics/releases")!
}
