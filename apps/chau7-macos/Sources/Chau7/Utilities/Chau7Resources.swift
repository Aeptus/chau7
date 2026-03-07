import Foundation

enum Chau7Resources {
    static let bundle: Bundle = {
        let mainBundle = Bundle.main
        let fileManager = FileManager.default

        if let resourceURL = mainBundle.resourceURL,
           fileManager.fileExists(atPath: resourceURL.appendingPathComponent("en.lproj/Localizable.strings").path) {
            return mainBundle
        }

        if let resourceURL = mainBundle.resourceURL {
            let candidateNames = [
                "Chau7_Chau7.bundle",
                "Chau7.bundle"
            ]

            for name in candidateNames {
                let url = resourceURL.appendingPathComponent(name)
                if let bundle = Bundle(url: url) {
                    return bundle
                }
            }

            if let bundleURL = try? fileManager.contentsOfDirectory(at: resourceURL, includingPropertiesForKeys: nil)
                .first(where: {
                    $0.pathExtension == "bundle"
                        && fileManager.fileExists(atPath: $0.appendingPathComponent("en.lproj/Localizable.strings").path)
                }),
                let bundle = Bundle(url: bundleURL) {
                return bundle
            }
        }

        // Search common app bundle locations explicitly (avoid Bundle.module to prevent fatalError).
        if let bundle = locateSwiftPMBundle() {
            return bundle
        }

        let executableURL = mainBundle.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let debugCandidates = [
            executableURL.deletingLastPathComponent().appendingPathComponent("Chau7_Chau7.bundle"),
            executableURL.deletingLastPathComponent().appendingPathComponent("../Chau7_Chau7.bundle").standardizedFileURL
        ]

        for url in debugCandidates {
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }

        return mainBundle
    }()

    private static func locateSwiftPMBundle() -> Bundle? {
        let fileManager = FileManager.default
        let executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let candidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources"),
            executableURL.deletingLastPathComponent(),
            executableURL.deletingLastPathComponent().appendingPathComponent("../Resources").standardizedFileURL
        ]

        let bundleNames = [
            "Chau7_Chau7.bundle",
            "Chau7.bundle"
        ]

        for base in candidates.compactMap({ $0 }) {
            for name in bundleNames {
                let url = base.appendingPathComponent(name)
                if let bundle = Bundle(url: url) {
                    return bundle
                }
            }
            if let bundleURL = try? fileManager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
                .first(where: {
                    $0.pathExtension == "bundle"
                        && fileManager.fileExists(atPath: $0.appendingPathComponent("en.lproj/Localizable.strings").path)
                }),
                let bundle = Bundle(url: bundleURL) {
                return bundle
            }
        }

        return nil
    }
}
