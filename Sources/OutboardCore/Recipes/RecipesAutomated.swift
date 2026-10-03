import Foundation

// The seven automated recipes (BUILD_PLAN §2, APP6 §4.2). Data, not code: a recipe decides which folder is renamed, so every change
// goes through `RecipeValidator`, CODEOWNERS and, for `verifiedOnRealMac: true`, a `docs/VERIFY_LOG.md` entry from a named tester.
// Consent texts come from the safety-ux research (§5.2 to §5.6) with "Overflow" replaced by "your Outboard drive"; the line
// "Not yet tried on a real Mac." is added by the consent sheet from the flag, never written into a recipe's own text.
// `RecipeValidator` and the grep G15 require every `Recipe(id:` below to start a line.

enum AutomatedRecipes {
    static let xcodeDerivedData = Recipe(id: "xcode-deriveddata", version: 1, name: "Xcode build data",
        bundleIDs: ["com.apple.dt.Xcode", "com.apple.iphonesimulator", "com.apple.dt.Instruments"],
        processNames: ["xcodebuild", "Xcode", "Simulator", "Instruments"],
        source: "~/Library/Developer/Xcode/DerivedData",
        method: .defaults(domain: "com.apple.dt.Xcode", keys: [
            DefaultsKeySpec(name: "IDECustomDerivedDataLocation", type: .string, value: .destinationPath, neutral: nil, valueVerified: true),
            // VERIFY (CI experiment E1): which mode value means "absolute custom path", and that 0 means the default location.
            DefaultsKeySpec(name: "IDEDerivedDataPathMode", type: .int, value: .int(2), neutral: .int(0), valueVerified: false),
        ], restore: .writePrior),
        riskClass: .regenerable, onDriveMissing: .revertSetting, confidence: .medium, beta: .b1,
        consent: ConsentText(
            what: "Xcode's build data",
            whatChanges: "The DerivedData folder (build products and indexes) is copied to your Outboard drive and checked file by file. Then the same setting you'd change in Xcode, Settings, Locations, is pointed at the copy.",
            whatToKnow: [
                "Xcode can rebuild this folder, so losing it costs build time, not your work.",
                "While Outboard is running, it puts the setting back if your Outboard drive is unplugged, so Xcode uses its normal folder on your Mac and builds start from scratch there. It points the setting at the drive again when the drive returns and Xcode is closed. If Xcode is open when the drive is unplugged, the setting is not changed until you quit Xcode, so until then Xcode still points at the missing drive.",
                "Your original stays as DerivedData.before-move until you confirm. You can roll back until then.",
                "Some developers report that tests for macOS frameworks, and Swift package plugins, fail when DerivedData is on an external drive (Apple Developer Forums, Swift Package Manager issue 6948). If that happens, roll back.",
            ],
            checkboxes: [
                ConsentCheckbox(id: "quit-xcode", text: "I have quit Xcode, Simulator and Instruments."),
                ConsentCheckbox(id: "default-folder", text: "I understand that while Outboard is running, builds use the default folder when my Outboard drive is not connected."),
            ]),
        missingDriveEffect: "While Outboard is running, Xcode goes back to its normal build folder on your Mac until the drive returns.",
        sources: [
            "https://github.com/fastlane/fastlane/pull/12232",
            "https://pewpewthespells.com/blog/xcode_build_locations.html",
            "https://developer.apple.com/forums/thread/812321",
            "https://github.com/apple/swift-package-manager/issues/6948",
        ],
        verify: [
            "CI experiment E1: the IDEDerivedDataPathMode value for an absolute path, and that mode 0 means the default location",
            "Whether defaults write is honoured by Xcode while it is closed, and by xcodebuild",
            "Whether the two documented external-drive breakages still occur on Xcode 26 and 27",
            "What Xcode does with the setting when the folder is missing at launch",
        ])

    static let xcodeArchives = Recipe(id: "xcode-archives", version: 1, name: "Xcode archives",
        bundleIDs: ["com.apple.dt.Xcode"],
        processNames: ["xcodebuild", "Xcode"],
        source: "~/Library/Developer/Xcode/Archives",
        method: .defaults(domain: "com.apple.dt.Xcode", keys: [
            // VERIFY: the key is read by fastlane; whether the Locations pane writes it, and which mode key goes with it, is open.
            DefaultsKeySpec(name: "IDECustomDistributionArchivesLocation", type: .string, value: .destinationPath,
                            neutral: .string("~/Library/Developer/Xcode/Archives"), valueVerified: false),
        ], restore: .writePrior),
        riskClass: .irreplaceable, onDriveMissing: .leaveAlone, confidence: .medium, beta: .b4,
        consent: ConsentText(
            what: "your Xcode archives",
            whatChanges: "Your archives (the builds you have shipped, with their debug symbols) are copied to your Outboard drive and checked file by file. Then Xcode's archive location is pointed at the copy.",
            whatToKnow: [
                "If your Outboard drive is unplugged, Xcode's Organizer will not list these archives. Outboard leaves the setting alone, and while it is running it tells you the drive is away.",
                "Time Machine may not back up your Outboard drive. After this move your archives are not in your Time Machine backup unless you check that the drive is included in Time Machine settings.",
                "Your original stays as Archives.before-move until you confirm. We suggest keeping it for a while.",
            ],
            checkboxes: [
                ConsentCheckbox(id: "quit-xcode", text: "I have quit Xcode."),
                ConsentCheckbox(id: "archives-on-drive-only", text: "I understand these archives will be on my Outboard drive only, and Time Machine may not include them."),
            ]),
        missingDriveEffect: "Xcode's Organizer can't list these archives until the drive returns.",
        sources: [
            "https://github.com/fastlane/fastlane/pull/8898",
            "https://developer.apple.com/forums/thread/733640",
        ],
        verify: [
            "Whether IDECustomDistributionArchivesLocation is what Xcode's Locations pane writes for Archives, and its mode key",
            "Organizer behaviour with the volume absent",
            "Time Machine's default for external volumes (the Time Machine sentence in the consent text)",
        ])

    static let huggingFaceHub = Recipe(id: "huggingface-hub-cache", version: 1, name: "Hugging Face models",
        bundleIDs: [],
        processNames: ["huggingface-cli", "hf"],
        source: "~/.cache/huggingface/hub",
        companionSources: ["~/.cache/huggingface/xet"],
        method: .symlink,
        riskClass: .expensive, onDriveMissing: .parkPlaceholder, confidence: .high, beta: .b2,
        consent: ConsentText(
            what: "your Hugging Face models",
            whatChanges: "The Hugging Face hub cache (and the xet cache beside it, when there is one) is copied to your Outboard drive and checked file by file. Then a link is put where each folder was. The folder above them, which holds your access token, stays on your Mac.",
            whatToKnow: [
                "While Outboard is running, it puts a note where the folder was if your Outboard drive is unplugged. That is meant to make tools that use this cache stop with an error; without the note they find a missing folder, or start downloading again to your Mac.",
                "Your original stays as hub.before-move until you confirm.",
                "This is a community method, not a Hugging Face setting.",
            ],
            checkboxes: [
                ConsentCheckbox(id: "no-python", text: "No Python session, notebook or app is using Hugging Face models right now."),
                ConsentCheckbox(id: "models-away", text: "I understand these tools won't find their models when my Outboard drive is not connected."),
            ]),
        missingDriveEffect: "Tools that use the Hugging Face cache stop with an error, or download again to your Mac, until the drive returns.",
        envLine: "export HF_HUB_CACHE={drive}/hub",
        sources: [
            "https://huggingface.co/docs/huggingface_hub/guides/manage-cache",
            "https://huggingface.co/docs/huggingface_hub/package_reference/environment_variables",
        ],
        verify: [
            "What each Hugging Face tool does when the cache folder is a note file instead of a folder",
            "That the copy keeps the cache's relative links and the verifier compares their targets",
            "Whether a missing HF_HUB_CACHE parent under /Volumes creates a folder on the boot volume (CI experiment E3)",
        ])

    static let ollamaModels = Recipe(id: "ollama-models", version: 1, name: "Ollama models",
        bundleIDs: ["com.electron.ollama"],
        processNames: ["ollama", "Ollama"],
        source: "~/.ollama/models",
        method: .symlink,
        riskClass: .expensive, onDriveMissing: .parkPlaceholder, confidence: .high, beta: .b2,
        consent: ConsentText(
            what: "your Ollama models",
            whatChanges: "The models folder inside .ollama is copied to your Outboard drive and checked file by file. Then a link is put where it was. The rest of .ollama (keys, history) stays on your Mac.",
            whatToKnow: [
                "While your Outboard drive is unplugged, Ollama will not see your models, and it may look as if they were deleted. They are on the drive. While Outboard is running, it puts a note where the folder was, which is meant to make Ollama report an error instead of starting an empty models folder.",
                "Your original stays as models.before-move until you confirm.",
                "This is a community method. Ollama's own Settings has a Model location field; Outboard does not change it.",
            ],
            checkboxes: [
                ConsentCheckbox(id: "quit-ollama", text: "I have quit Ollama, including its menu bar icon, and no ollama command is running."),
                ConsentCheckbox(id: "models-away", text: "I understand Ollama won't find its models when my Outboard drive is not connected."),
            ]),
        missingDriveEffect: "Ollama won't find its models, and new downloads may land on your Mac, until the drive returns.",
        envLine: "export OLLAMA_MODELS={drive}/models",
        mayRelaunch: true,
        sources: [
            "https://docs.ollama.com/faq",
            "https://github.com/ollama/ollama",
        ],
        verify: [
            "That a note file at ~/.ollama/models makes the Ollama app and CLI report an error instead of recreating a folder",
            "Whether a link to a parked or missing target survives the app's startup check",
            "Ollama's launch-at-login behaviour (whether it restarts after being quit)",
        ])

    static let llamaCppCache = Recipe(id: "llamacpp-cache", version: 1, name: "llama.cpp models",
        bundleIDs: [],
        processNames: ["llama-cli", "llama-server", "llama-run", "llama-bench"],
        source: "~/Library/Caches/llama.cpp",
        method: .symlink,
        riskClass: .expensive, onDriveMissing: .parkPlaceholder, confidence: .high, beta: .b2,
        consent: ConsentText(
            what: "your llama.cpp models",
            whatChanges: "The llama.cpp download cache is copied to your Outboard drive and checked file by file. Then a link is put where it was.",
            whatToKnow: [
                "While your Outboard drive is unplugged, llama.cpp will not find models it downloaded before. While Outboard is running, it puts a note where the folder was, which is meant to make it stop with an error.",
                "Your original stays as llama.cpp.before-move until you confirm.",
                "This is a community method, not a llama.cpp setting.",
            ],
            checkboxes: [
                ConsentCheckbox(id: "no-llamacpp", text: "No llama.cpp program is running."),
                ConsentCheckbox(id: "models-away", text: "I understand llama.cpp won't find these models when my Outboard drive is not connected."),
            ]),
        missingDriveEffect: "llama.cpp can't find the models it downloaded before, and may download them again to your Mac.",
        envLine: "export LLAMA_CACHE={drive}/llama.cpp",
        sources: ["https://github.com/ggml-org/llama.cpp"],
        verify: [
            "That the cache layout is preserved by the copy (links inside the Hugging Face integration)",
            "What llama.cpp does when its cache folder is a note file",
        ])

    static let npmCache = Recipe(id: "npm-cache", version: 1, name: "npm cache",
        bundleIDs: [],
        processNames: [],   // npm and npx normally run as node, so no name can match; the check is "has files open in the cache" (see the consent text)
        source: "~/.npm",
        method: .symlink,
        riskClass: .regenerable, onDriveMissing: .parkPlaceholder, confidence: .high, beta: .b2,
        consent: ConsentText(
            what: "your npm cache",
            whatChanges: "The .npm folder is copied to your Outboard drive and checked file by file. Then a link is put where it was.",
            whatToKnow: [
                "npm calls this folder strictly a cache: it fetches packages again when something is missing, so losing it costs time, not your work.",
                "While your Outboard drive is unplugged, npm will report an error or fetch packages again. While Outboard is running, it puts a note where the folder was.",
                "Your original stays as .npm.before-move until you confirm.",
                "Outboard can't tell an npm command from another node program by name. It looks for programs that have files open in the cache, and relies on the box below for the rest.",
            ],
            checkboxes: [
                ConsentCheckbox(id: "no-npm", text: "No npm command is running."),
                ConsentCheckbox(id: "cache-away", text: "I understand npm has no cache when my Outboard drive is not connected."),
            ]),
        missingDriveEffect: "npm can't use its cache and fetches packages again, or reports an error, until the drive returns.",
        envLine: "export npm_config_cache={drive}/npm",
        sources: [
            "https://docs.npmjs.com/cli/v10/commands/npm-cache",
            "https://docs.npmjs.com/cli/v10/using-npm/config#cache",
        ],
        verify: [
            "What npm does when ~/.npm is a note file instead of a folder (CI experiment E4)",
            "The process name npm and npx show while they run (believed to be node), and whether an open-files check sees a running install",
        ])

    static let iosDeviceBackups = Recipe(id: "ios-device-backups", version: 1, name: "iPhone backups",
        bundleIDs: [],
        processNames: [],
        source: "~/Library/Application Support/MobileSync/Backup",
        method: .symlink,
        riskClass: .irreplaceable, onDriveMissing: .parkPlaceholder, needsFDA: true, sensitive: true, confidence: .medium, beta: .b3,
        consent: ConsentText(
            what: "your iPhone and iPad backups",
            whatChanges: "The folder where Finder and Apple Devices keep device backups is copied to your Outboard drive and checked file by file. Then a link is put where the folder was. This is a widely used method, not an Apple setting.",
            whatToKnow: [
                "If your Outboard drive is unplugged, Finder and Apple Devices will not find your backups and may not be able to back up a device. While Outboard is running, it puts a note where the folder was, which is meant to make them stop with an error instead of starting a new set.",
                "Time Machine may not back up your Outboard drive. After this move your device backups are not in your Time Machine backup unless you check that the drive is included in Time Machine settings.",
                "Your original stays as Backup.before-move until you confirm. We suggest connecting a device and making a backup to the new location first.",
                "Outboard can't tell by itself whether Finder or Apple Devices is syncing a device. It relies on the first box below, so tick it only when that is true.",
                "macOS protects this folder. Outboard needs Full Disk Access to move it, and will ask you to allow that in System Settings. It changes nothing until you do.",
            ],
            checkboxes: [
                ConsentCheckbox(id: "device-disconnected", text: "My iPhone or iPad is disconnected, and Finder and Apple Devices are not syncing it."),
                ConsentCheckbox(id: "backups-on-drive-only", text: "I understand these backups will be on my Outboard drive only."),
                ConsentCheckbox(id: "community-method", text: "I understand this is a community method, not an Apple setting."),
            ]),
        missingDriveEffect: "Finder and Apple Devices can't find your backups, and may not be able to back up a device, until the drive returns.",
        sources: [
            "https://discussions.apple.com/thread/256152634",
            "https://www.imore.com/how-move-your-iphone-or-ipad-backups-external-hard-drive",
            "https://setapp.com/how-to/backup-iphone-to-external-drive",
        ],
        verify: [
            "Whether linking under MobileSync needs Full Disk Access on macOS 15 and 26, and the exact error without it",
            "What Finder and Apple Devices do when the Backup folder is a note file (fail, crash or recreate)",
            "Whether sizing this folder needs Full Disk Access",
            "The process names Finder and Apple Devices use while a device backs up, so the running check can match them by name",
            "Time Machine's default for external volumes (the Time Machine sentence in the consent text)",
        ])
}
