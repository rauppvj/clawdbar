using System;
using System.IO;
using System.Text;

namespace ClawdBar
{
    /// The account facts Claude Code keeps in %USERPROFILE%\.claude.json under
    /// `oauthAccount`.
    ///
    /// This matters because the OAuth token's own subscriptionType /
    /// rateLimitTier claims are minted at login and are *not* rewritten when
    /// the token is refreshed - a Max 5x account can carry a token that still
    /// says "pro" / "default_claude_ai" months later. The JSON file is
    /// rewritten by Claude Code as the account changes, so it is the fresher
    /// of the two.
    internal sealed class AccountProfile
    {
        /// e.g. "claude_max", "claude_pro".
        public string OrganizationType;
        /// e.g. "default_claude_max_5x" - carries the multiplier.
        public string OrganizationRateLimitTier;
        /// Set instead of the org tier on seat-based plans.
        public string UserRateLimitTier;
        public string SeatTier;
        public string OrganizationName;

        /// A per-user seat tier wins over the organization's, which is what a
        /// team member on a shared org would be billed against.
        public string Tier
        {
            get { return UserRateLimitTier != null ? UserRateLimitTier : OrganizationRateLimitTier; }
        }

        /// Nothing worth showing - treat as absent so the token claims are
        /// used instead.
        public bool IsEmpty
        {
            get { return OrganizationType == null && Tier == null && SeatTier == null; }
        }
    }

    /// Reads `oauthAccount` out of %USERPROFILE%\.claude.json.
    ///
    /// The file is a few hundred KB (sometimes several MB) of unrelated Claude
    /// Code state, so callers are expected to check ModifiedAtUtc() and only
    /// re-Load() when it moves.
    internal sealed class AccountProfileStore
    {
        public readonly string FilePath;

        public AccountProfileStore() : this(DefaultFilePath) { }

        public AccountProfileStore(string filePath)
        {
            FilePath = filePath;
        }

        public static string DefaultFilePath
        {
            get
            {
                return Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                    ".claude.json");
            }
        }

        /// Returns the profile, or null when the file is missing, unreadable,
        /// or carries no account block.
        public AccountProfile Load()
        {
            string text;
            try
            {
                if (!File.Exists(FilePath)) return null;
                text = File.ReadAllText(FilePath, Encoding.UTF8);
            }
            catch
            {
                return null;
            }

            JsonValue account = ExtractAccount(text);
            if (account == null || account.Type != JsonValue.Kind.Object) return null;

            var profile = new AccountProfile();
            profile.OrganizationType = Str(account, "organizationType");
            profile.OrganizationRateLimitTier = Str(account, "organizationRateLimitTier");
            profile.UserRateLimitTier = Str(account, "userRateLimitTier");
            profile.SeatTier = Str(account, "seatTier");
            profile.OrganizationName = Str(account, "organizationName");
            return profile.IsEmpty ? null : profile;
        }

        /// Parses only the `oauthAccount` object instead of the whole file.
        ///
        /// The macOS build hands the file to a streaming Foundation decoder
        /// that skips what it does not need; this port's JSON reader builds a
        /// full tree, and on a heavy user's multi-megabyte .claude.json that
        /// would be a visible hitch on the poll thread. Locating the key and
        /// parsing forward from its opening brace reads the same value for a
        /// fraction of the work - the parser stops at the matching brace.
        private static JsonValue ExtractAccount(string text)
        {
            int key = text.IndexOf("\"oauthAccount\"", StringComparison.Ordinal);
            if (key < 0) return null;

            int colon = text.IndexOf(':', key);
            if (colon < 0) return null;

            int brace = -1;
            for (int i = colon + 1; i < text.Length; i++)
            {
                char c = text[i];
                if (c == ' ' || c == '\t' || c == '\r' || c == '\n') continue;
                if (c == '{') brace = i;
                // Anything else (most likely `null`) means there is no account.
                break;
            }
            if (brace < 0) return null;

            return Json.TryParse(text.Substring(brace));
        }

        private static string Str(JsonValue owner, string key)
        {
            JsonValue member = owner[key];
            if (member == null || member.Type != JsonValue.Kind.String) return null;
            return member.StringValue.Length == 0 ? null : member.StringValue;
        }

        /// Last-write time of the backing file, for change detection without a
        /// full parse. null when the file is not there.
        public DateTime? ModifiedAtUtc()
        {
            try
            {
                var info = new FileInfo(FilePath);
                if (!info.Exists) return null;
                return info.LastWriteTimeUtc;
            }
            catch
            {
                return null;
            }
        }
    }
}
