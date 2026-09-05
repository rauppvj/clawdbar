import Foundation

protocol AccountProfileLoading: Sendable {
    /// Returns the profile, or nil when the file is missing, unreadable, or
    /// carries no account block.
    func load() -> AccountProfile?
    /// Modification time of the backing file, for change detection without a
    /// full parse. nil when the file isn't there.
    func modifiedAt() -> Date?
}

/// Reads `oauthAccount` out of `~/.claude.json`.
///
/// The file is a few hundred KB of unrelated Claude Code state, so callers are
/// expected to check `modifiedAt()` and only re-`load()` when it moves.
struct AccountProfileStore: AccountProfileLoading {
    let fileURL: URL

    init(fileURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude.json")
    ) {
        self.fileURL = fileURL
    }

    private struct Envelope: Decodable {
        let oauthAccount: AccountProfile?
    }

    func load() -> AccountProfile? {
        guard let data = try? Data(contentsOf: fileURL),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let profile = envelope.oauthAccount,
              !profile.isEmpty
        else { return nil }
        return profile
    }

    func modifiedAt() -> Date? {
        try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
