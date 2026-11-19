import Foundation

/// Pre-flight plausibility for a user-typed remote address (v4.2.31).
///
/// The settings card and the quick-add sheet share this check: an obvious
/// paste mistake (a bare host like "github.com/user/repo") must be caught
/// BEFORE it becomes a saved remote that git can never talk to. The rule is
/// deliberately loose — anything carrying a URL scheme, an scp-style colon,
/// or an absolute path passes, and git itself reports the real errors for
/// the rest. The first cut (v4.2.30) only allowed https/git@/file:///local
/// and silently rejected VALID ssh://, http:// and git:// remotes.
public enum GitRemoteAddress {
    public static func looksIncomplete(_ raw: String) -> Bool {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return false }
        if url.hasPrefix("/") { return false }       // absolute local path
        if url.contains("://") { return false }      // any URL scheme
        if url.contains(":") { return false }        // scp-like user@host:path
        return true                                    // bare host / path fragment
    }
}
