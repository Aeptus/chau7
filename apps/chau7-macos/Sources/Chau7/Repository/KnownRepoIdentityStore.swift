import Foundation
import Chau7Core

struct KnownRepoIdentity: Codable, Equatable {
    let rootPath: String
    let lastConfirmedAt: Date
    let lastKnownBranch: String?
}

final class KnownRepoIdentityStore {
    static let shared = KnownRepoIdentityStore()
    private static let maxIdentities = 50

    private enum Keys {
        static let identities = "repository.knownRepoIdentities.v1"
    }

    private let queue = DispatchQueue(label: "com.chau7.known-repo-identities", qos: .utility)
    private let defaults: UserDefaults
    private var identities: [KnownRepoIdentity]

    init(defaults: UserDefaults = .standard, bootstrapRoots: [String]? = nil) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.identities),
           let decoded = try? JSONDecoder().decode([KnownRepoIdentity].self, from: data) {
            self.identities = decoded
        } else {
            let roots = bootstrapRoots ?? FeatureSettings.shared.recentRepoRoots
            self.identities = roots.map {
                KnownRepoIdentity(
                    rootPath: URL(fileURLWithPath: $0).standardized.path,
                    lastConfirmedAt: .distantPast,
                    lastKnownBranch: nil
                )
            }
            persist()
        }
    }

    func record(rootPath: String, branch: String? = nil, confirmedAt: Date = Date()) {
        let normalized = URL(fileURLWithPath: rootPath).standardized.path
        queue.sync {
            let previousBranch = identities.first(where: { $0.rootPath == normalized })?.lastKnownBranch
            identities.removeAll { $0.rootPath == normalized }
            identities.insert(
                KnownRepoIdentity(
                    rootPath: normalized,
                    lastConfirmedAt: confirmedAt,
                    lastKnownBranch: branch ?? previousBranch
                ),
                at: 0
            )
            if identities.count > Self.maxIdentities {
                identities.removeLast(identities.count - Self.maxIdentities)
            }
            persist()
        }
    }

    func allRoots() -> [String] {
        queue.sync { identities.map(\.rootPath) }
    }

    func identity(forRootPath rootPath: String) -> KnownRepoIdentity? {
        let normalized = URL(fileURLWithPath: rootPath).standardized.path
        return queue.sync {
            identities.first(where: { $0.rootPath == normalized })
        }
    }

    func resolveIdentity(forPath path: String) -> KnownRepoIdentity? {
        let normalized = URL(fileURLWithPath: path).standardized.path
        return queue.sync {
            guard let rootPath = KnownRepoRootResolver.resolve(
                currentDirectory: normalized,
                preferredRepoRoot: nil,
                recentRepoRoots: identities.map(\.rootPath)
            ) else {
                return nil
            }
            return identities.first(where: { $0.rootPath == rootPath })
        }
    }

    func replaceAll(with roots: [String]) {
        let normalizedRoots = roots.map { URL(fileURLWithPath: $0).standardized.path }
        queue.sync {
            identities = normalizedRoots.map {
                KnownRepoIdentity(rootPath: $0, lastConfirmedAt: .distantPast, lastKnownBranch: nil)
            }
            if identities.count > Self.maxIdentities {
                identities = Array(identities.prefix(Self.maxIdentities))
            }
            persist()
        }
    }

    func resolveRoot(forPath path: String) -> String? {
        let normalized = URL(fileURLWithPath: path).standardized.path
        return queue.sync {
            KnownRepoRootResolver.resolve(
                currentDirectory: normalized,
                preferredRepoRoot: nil,
                recentRepoRoots: identities.map(\.rootPath)
            )
        }
    }

    func hasKnownRepo(beneathProtectedRoot root: String) -> Bool {
        let normalized = URL(fileURLWithPath: root).standardized.path
        return queue.sync {
            identities.contains { identity in
                identity.rootPath == normalized || identity.rootPath.hasPrefix(normalized + "/")
            }
        }
    }

    func reset() {
        queue.sync {
            identities = []
            defaults.removeObject(forKey: Keys.identities)
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(identities) else { return }
        defaults.set(data, forKey: Keys.identities)
    }
}
