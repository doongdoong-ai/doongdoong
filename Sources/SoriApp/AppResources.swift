import Foundation

enum AppResources {
    static var directory: URL {
        // SwiftPM's generated accessor looks beside the .app, which is unsuitable for distribution.
        // Prefer the resource bundle inside Contents/Resources and use SwiftPM only during development.
        if let base = Bundle.main.resourceURL,
           let bundle = Bundle(url: base.appendingPathComponent("Sori_SoriApp.bundle")),
           let resources = bundle.resourceURL { return resources }
        return Bundle.module.resourceURL!
    }
}
