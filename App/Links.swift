import Foundation

/// Every address the app can open, and the only file with a System Settings deep link (safety_greps G9). Opened only on a click, by
/// `AppModel`. `website` must equal `site/site.json` `baseURL` and `Names.website` (`tools/doctor.sh --ci` checks).
enum Links {
    static let website = URL(string: "https://everydayopen.github.io/outboard")!
    static let releases = URL(string: "https://github.com/EverydayOpen/outboard/releases")!
    static let issues = URL(string: "https://github.com/EverydayOpen/outboard/issues/new/choose")!
    static let diskUtilityGuide = URL(string: "https://support.apple.com/guide/disk-utility/welcome/mac")!    // VERIFY the page

    // Strings, not URLs: `AppModel` builds the URL and opens it only outside a demo launch.
    static let fullDiskAccess = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"    // VERIFY on macOS 13, 15 and 26; text steps always sit beside the button
    static let loginItems = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"                              // VERIFY on macOS 13, 15 and 26
}
