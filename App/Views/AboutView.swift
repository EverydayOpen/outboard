import AppKit
import OutboardCore
import SwiftUI

/// About (BUILD_PLAN §7.1 screen 9, docs/DESIGN.md §6.5): icon, name, version, what it is, the honesty statement, the
/// "not affiliated" line and, while any move has not been tried on a real Mac, the line that says so. A centred column that
/// scrolls rather than clips. Links go through the model, the only place that opens URLs (safety_greps G9); the version comes
/// from the model too (G7). Every sentence about what Outboard does is one a check in the app performs (BUILD_PLAN I12).
struct AboutView: View {
    @EnvironmentObject private var model: AppModel

    /// The recipes are Swift data in Core: this is true until each automated recipe has a `docs/VERIFY_LOG.md` entry.
    private let showsNotTried = Catalogue.automated.contains { !$0.verifiedOnRealMac }
    /// "Mail, Safari and Messages. Anything inside iCloud Drive. ..." from the education card, so the app and the site say the same.
    private let neverMoves = Education.cards.first { $0.id == "what-never-moves" }?.body

    var body: some View {
        ScrollView {
            column
                .frame(width: 420)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.xl)
        }
        .background(Dusk(strength: 0.6))
    }

    private var column: some View {
        VStack(spacing: Space.s) {
            OnFloor(height: 96) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
            }
            .modifier(HoverTilt(max: 8, glare: true))
            .accessibilityHidden(true)
            VStack(spacing: Space.xxs) {
                Text("Outboard").font(.system(size: 28, weight: .semibold)).tracking(-0.5)
                    .accessibilityAddTraits(.isHeader)
                Text("Version \(model.appVersion)").font(.system(.callout, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
            }
            Text("Finds the big folders that apps keep on your Mac and, for the ones with a known method, moves them to an external drive you choose. Free and open source (MIT License).")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            honesty
            if showsNotTried { notTried }
            leftAlone
            links
            CopyButton(title: "Copy Diagnostics") { Task { await model.copyDiagnostics() } }
                .help("Copies a table of which folders could be measured and which drives were checked, with no file names")
            footer
        }
        .multilineTextAlignment(.center)
    }

    /// What it does and what it does not promise. No sentence here claims more than a check in the app performs.
    private var honesty: some View {
        VStack(spacing: Space.xs) {
            Text("Outboard copies, compares and renames. It never deletes; after you confirm, the original goes to the Trash.")
            Text("It measures sizes without opening files. To check a copy it reads the files on both sides, only to compare them. It makes no network connections, has no account and needs no administrator password.")
            Text("While Outboard is running it notices a missing drive and puts a note where the folder was. Outboard can't stop you unplugging a drive or make that harmless. \(Education.guardQuit)")
            Text("Every file is compared by size and SHA-256. That does not show that your data is undamaged or that a drive is reliable, and Outboard has not been tried on every Mac or every drive.")
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Shown while any automated recipe is unverified (the README and the site carry the same line, G15).
    private var notTried: some View {
        VStack(spacing: Space.xxs) {
            Text(Names.notTriedMarker).font(.system(size: 13, weight: .semibold))
            Text("Those moves stay hidden until someone has tried them on a real Mac, unless you turn on “Show moves not yet tried on a real Mac” in Preferences.")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var leftAlone: some View {
        DisclosureGroup("What Outboard leaves alone") {
            VStack(alignment: .leading, spacing: Space.xxs) {
                if let neverMoves { Text(neverMoves) }
                Text("It doesn't watch for new installs or set apps up for you. Each move starts with you.")
                Text("It doesn't format, erase or eject a drive, and it doesn't change iCloud, Time Machine or power settings. On the drive it writes only the folders you move and one small file that marks the drive as yours.")
                Text("It makes no promise about how fast an app runs from an external drive.")
                Text("Your Mac gets the space back only after you confirm a move and empty the Trash.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
            .padding(.top, Space.xxs)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    private var links: some View {
        HStack(spacing: Space.s) {
            Button("Website") { model.openWebsite() }.help("Opens the Outboard website in your browser")
            Button("Releases") { model.openReleases() }.help("Opens the list of releases in your browser")
            Button("Report a Problem") { model.openIssues() }.help("Opens the issue form in your browser")
        }
        .buttonStyle(.borderless)   // not .link: that style keeps the system blue, and the app has one accent
        .foregroundStyle(Brand.aquaInk)
    }

    private var footer: some View {
        VStack(spacing: Space.xxs) {
            Text("\(Names.affiliation) Their names belong to their owners.")
                .fixedSize(horizontal: false, vertical: true)
            Text(Names.websiteShort).textSelection(.enabled)
            Text("© 2026 EverydayOpen")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
