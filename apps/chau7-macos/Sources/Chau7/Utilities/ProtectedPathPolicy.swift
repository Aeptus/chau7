import Foundation

enum ProtectedPathPolicy {
    private static let protectedRoots: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Downloads",
            "\(home)/Desktop",
            "\(home)/Documents",
            "\(home)/Library",
            "/Applications",
            "/System",
            "/Library"
        ]
    }()

    static func shouldSkipAutoAccess(path: String) -> Bool {
        guard let root = protectedRoot(for: path) else {
            return false
        }
        guard FeatureSettings.shared.allowProtectedFolderAccess else {
            return true
        }
        return !ensureAccess(for: root)
    }

    static func requestAccessToProtectedFolders() {
        guard FeatureSettings.shared.allowProtectedFolderAccess else { return }
        for root in protectedRoots {
            _ = ensureAccess(for: root)
        }
    }

    static func resetAccessChecks() {
        stateQueue.sync {
            checkedRoots.removeAll()
            deniedRoots.removeAll()
        }
    }

    private static let stateQueue = DispatchQueue(label: "com.chau7.protected-path-policy")
    private static var checkedRoots: Set<String> = []
    private static var deniedRoots: Set<String> = []

    private static func protectedRoot(for path: String) -> String? {
        let normalized = URL(fileURLWithPath: path).standardized.path
        for root in protectedRoots {
            if normalized == root || normalized.hasPrefix(root + "/") {
                return root
            }
        }
        return nil
    }

    private static func ensureAccess(for root: String) -> Bool {
        stateQueue.sync {
            if deniedRoots.contains(root) {
                return false
            }
            if checkedRoots.contains(root) {
                return true
            }
            checkedRoots.insert(root)
            if canAccess(root) {
                return true
            }
            deniedRoots.insert(root)
            return false
        }
    }

    private static func canAccess(_ path: String) -> Bool {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: path)
            return true
        } catch {
            return false
        }
    }
}
