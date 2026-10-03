import Foundation

// The eight guided cards (APP6 §4.2, §4.7). Outboard measures the folder, checks the chosen drive, shows these numbered steps and an
// "Open <App>" button. It moves and writes nothing; the journal records only "guide viewed". Facts and steps are re-read against the
// vendor pages before the copy ships (VERIFY item 16); Steam, LM Studio and Android SDK are MEDIUM because the primary pages could
// not be fetched.

enum GuidedRecipes {
    static let macAppStoreLargeApps = Recipe(id: "mas-large-apps", version: 1, name: "App Store apps over 1 GB",
        bundleIDs: ["com.apple.AppStore"],
        processNames: [],
        source: nil,
        method: .guided(steps: [
            "Open the App Store and choose App Store, then Settings.",
            "Turn on Download and install large apps to a separate disk.",
            "Choose your Outboard drive. It must be an APFS drive.",
        ]),
        riskClass: .regenerable, onDriveMissing: .none, minMacOS: MinOS(15, 1), confidence: .high, beta: .b0,
        drive: .apfsOnlyGuided,
        missingDriveEffect: "macOS prompts you to download the app again.",
        sources: [
            "https://support.apple.com/guide/app-store/download-install-large-apps-a-separate-disk-fir06754f864/mac",
        ],
        verify: [
            "Which data stays on the Mac for such apps",
            "Behaviour on macOS 27",
        ])

    static let photosLibrary = Recipe(id: "photos-library", version: 1, name: "Photos library",
        bundleIDs: ["com.apple.Photos"],
        processNames: [],
        source: "~/Pictures/Photos Library.photoslibrary",
        method: .guided(steps: [
            "Quit Photos.",
            "In Finder, drag Photos Library to a folder on your Outboard drive.",
            "Hold the Option key and open Photos, then choose the library on the drive.",
            "In Photos, choose Settings, then General, then Use as System Photo Library.",
        ]),
        riskClass: .irreplaceable, onDriveMissing: .none, confidence: .high, beta: .b0,
        missingDriveEffect: "Photos stops using the library and starts a new empty one in the default place.",
        sources: ["https://support.apple.com/en-us/108345"],
        verify: [
            "macOS 26 and 27: whether Photos asks or silently starts a new library when the drive is missing",
            "Reports that a drive holding the System Photo Library fails to eject",
        ])

    static let musicMediaFolder = Recipe(id: "music-media-folder", version: 1, name: "Music media folder",
        bundleIDs: ["com.apple.Music"],
        processNames: [],
        source: "~/Music/Music/Media",
        method: .guided(steps: [
            "Quit other apps that use your music files, then open Music.",
            "Choose Music, then Settings, then the Files tab.",
            "Under Music Media folder location, click Change and choose a folder on your Outboard drive.",
            "To copy the music you already have, choose File, then Library, then Organize Library, then Consolidate files.",
        ]),
        riskClass: .expensive, onDriveMissing: .none, confidence: .medium, beta: .b0,
        missingDriveEffect: "Tracks stored on the drive may show as missing until it returns.",
        sources: ["https://support.apple.com/guide/music/change-where-music-files-are-stored-mus69248042d/mac"],
        verify: [
            "Whether Consolidate files copies into the new media folder",
            "What Music shows for tracks on a missing drive",
        ])

    static let finalCutLibrary = Recipe(id: "final-cut-library", version: 1, name: "Final Cut Pro libraries",
        bundleIDs: ["com.apple.FinalCut"],
        processNames: [],
        source: nil,
        method: .guided(steps: [
            "Quit Final Cut Pro.",
            "In Finder, drag the library (a .fcpbundle file) to a folder on your Outboard drive.",
            "Open Final Cut Pro and open the library from its new place.",
            "To move a library's media, cache or backups separately, use the storage locations in the library inspector.",
        ]),
        riskClass: .irreplaceable, onDriveMissing: .none, confidence: .high, beta: .b0,
        missingDriveEffect: "The library is missing from the sidebar until the drive returns.",
        sources: [
            "https://support.apple.com/en-us/119610",
            "https://support.apple.com/en-us/102116",
            "https://support.apple.com/guide/final-cut-pro/set-storage-locations-ver7db6ffe77/mac",
        ],
        verify: [
            "What Final Cut Pro shows for an offline library and for offline media",
        ])

    static let logicSoundLibrary = Recipe(id: "logic-sound-library", version: 1, name: "Logic Pro Sound Library",
        bundleIDs: ["com.apple.logic10", "com.apple.mainstage3"],
        processNames: [],
        source: "~/Music/Logic Pro Library.bundle",
        method: .guided(steps: [
            "Quit Logic Pro and MainStage.",
            "In Finder, open your Music folder and drag Logic Pro Library.bundle to your Outboard drive.",
            "Open Logic Pro. If it asks where the library is, choose the one on the drive.",
            "In older versions, choose Logic Pro, then Sound Library, then Relocate Sound Library instead.",
        ]),
        riskClass: .expensive, onDriveMissing: .none, confidence: .high, beta: .b0,
        missingDriveEffect: "Logic Pro asks you to Retry, Ignore (basic tones) or Reset (reinstall the library on your Mac).",
        sources: ["https://support.apple.com/en-us/111094"],
        verify: [
            "The bundle identifiers of Logic Pro and MainStage",
            "The library location and file name in the current Logic Pro release",
        ])

    static let steamLibrary = Recipe(id: "steam-library", version: 1, name: "Steam games",
        bundleIDs: ["com.valvesoftware.steam"],
        processNames: [],
        source: "~/Library/Application Support/Steam/steamapps",
        method: .guided(steps: [
            "Quit any game, then open Steam.",
            "Choose Steam, then Settings, then Storage.",
            "Add your Outboard drive as a storage location. It must be an APFS drive.",
            "Choose Make Default to send new installs there, and move installed games with Steam itself.",
        ]),
        riskClass: .expensive, onDriveMissing: .none, confidence: .medium, beta: .b0, drive: .apfsOnlyGuided,
        missingDriveEffect: "Games show as not installed until Steam sees the folder again.",
        sources: ["https://steamcommunity.com/discussions/forum/2/595137109171382721/"],
        verify: [
            "Steam's own support text (the page could not be read when this card was written)",
            "Which file systems Steam accepts for a library on a Mac",
        ])

    static let lmStudioModels = Recipe(id: "lmstudio-models", version: 1, name: "LM Studio models",
        bundleIDs: ["ai.elementlabs.lmstudio"],
        processNames: [],
        source: "~/.lmstudio/models",
        method: .guided(steps: [
            "Quit LM Studio.",
            "In Finder, copy the models folder to your Outboard drive. Keep the publisher, model and file layout.",
            "Open LM Studio, go to My Models, and change the models directory to the copy.",
            "When the models show up, you can remove the old folder yourself.",
        ]),
        riskClass: .expensive, onDriveMissing: .none, confidence: .medium, beta: .b0, drive: .apfsOnlyGuided,
        missingDriveEffect: "The models on the drive don't appear in LM Studio until it returns.",
        sources: [
            "https://lmstudio.ai/docs/app/basics/download-model",
            "https://github.com/lmstudio-ai/docs/issues/184",
        ],
        verify: [
            "The default models path and the layout in the current release",
            "Where the models directory setting is stored and its label in the current release",
        ])

    static let androidSdk = Recipe(id: "android-sdk", version: 1, name: "Android SDK",
        bundleIDs: ["com.google.android.studio"],
        processNames: [],
        source: "~/Library/Android/sdk",
        method: .guided(steps: [
            "Quit Android Studio.",
            "On your Outboard drive, make a folder named android-sdk inside the Outboard folder, then copy the sdk folder into it.",
            "Open Android Studio, then SDK Manager, and set Android SDK Location to the copy.",
            "For command-line tools, set ANDROID_HOME to the same folder. Outboard shows the line to copy; it doesn't edit your shell files.",
            "Emulators keep their devices in ANDROID_AVD_HOME. Set that separately if you want them on the drive.",
        ]),
        riskClass: .expensive, onDriveMissing: .none, confidence: .medium, beta: .b0, drive: .apfsOnlyGuided,
        missingDriveEffect: "Android Studio and Gradle can't find the SDK until the drive returns.",
        envLine: "export ANDROID_HOME={drive}/sdk",
        sources: ["https://developer.android.com/tools/variables"],
        verify: [
            "The SDK Location setting path in the current Android Studio release",
            "How the variable reaches Android Studio when it is started from the Dock",
        ])
}
