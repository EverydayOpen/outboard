import Foundation

/// The "line to copy" for a recipe that is set by an environment variable. The person pastes it into a shell, so the path in it is
/// the drive's mount point (a name anyone can choose, including `$(x)`, a backtick or an apostrophe) and is always single-quoted
/// POSIX style here, never trusted inside a recipe's own quotes. Outboard still never edits a shell file.
public enum EnvLine {
    /// Shown instead of the line when the path has a character that can't be quoted safely on one line.
    public static let setYourself = "Outboard can't print this line because the drive's name has a character a shell reads as something else. Set it yourself to the Outboard folder on the drive."

    /// `'...'` with each `'` written as `'\''`. nil when the path has a control or invisible formatting character (a newline would
    /// start a second command, and invisible characters would let the line show something other than what it does).
    public static func quote(_ path: String) -> String? {
        for scalar in path.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return nil
            default: break
            }
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Fills `{drive}` in a recipe's template (`export NAME={drive}/sub`, no quotes in the template) with the quoted data folder on the
    /// drive. nil when the template has no `{drive}` or the path can't be quoted.
    public static func render(_ template: String, mountPoint: String, recipeID: String) -> String? {
        guard let token = template.range(of: "{drive}") else { return nil }
        var mount = mountPoint
        while mount.count > 1, mount.hasSuffix("/") { mount.removeLast() }
        let path = mount + "/" + Names.driveFolder + "/" + recipeID + template[token.upperBound...]
        guard let quoted = quote(path) else { return nil }
        return String(template[..<token.lowerBound]) + quoted
    }
}
