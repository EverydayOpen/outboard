import Foundation

/// Short names for sentences: the app to quit or open, and the one-word label on the text version of the card.
enum RecipeNames {
    /// The app named in "Quit <App>" and "Open <App>".
    static func appName(_ recipeID: String) -> String {
        switch recipeID {
        case "xcode-deriveddata", "xcode-archives": return "Xcode"
        case "huggingface-hub-cache": return "Hugging Face tools"
        case "ollama-models": return "Ollama"
        case "llamacpp-cache": return "llama.cpp"
        case "npm-cache": return "npm"
        case "ios-device-backups": return "Finder"
        case "mas-large-apps": return "App Store"
        case "photos-library": return "Photos"
        case "music-media-folder": return "Music"
        case "final-cut-library": return "Final Cut Pro"
        case "logic-sound-library": return "Logic Pro"
        case "steam-library": return "Steam"
        case "lmstudio-models": return "LM Studio"
        case "android-sdk": return "Android Studio"
        default: return Catalogue.recipe(recipeID)?.name ?? recipeID
        }
    }

    /// The label in the one-line text version of the card ("Xcode 41 GB, Ollama 30 GB").
    static func shortName(_ recipeID: String) -> String {
        switch recipeID {
        case "xcode-deriveddata": return "Xcode"
        case "xcode-archives": return "Xcode archives"
        case "huggingface-hub-cache": return "Hugging Face"
        case "ollama-models": return "Ollama"
        case "llamacpp-cache": return "llama.cpp"
        case "npm-cache": return "npm"
        case "ios-device-backups": return "iPhone backups"
        default: return Catalogue.recipe(recipeID)?.name ?? recipeID
        }
    }

    /// "is" or "are" for a noun phrase: plural when it ends in a plural word ("backups", "models", "archives").
    static func isPlural(_ phrase: String) -> Bool {
        let last = phrase.split(separator: " ").last.map(String.init)?.lowercased() ?? ""
        return last.hasSuffix("s") && !last.hasSuffix("ss") && last != "data"
    }

    /// "A", "A and B", "A, B and C".
    static func join(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    /// The first letter in capitals ("your Ollama models" -> "Your Ollama models").
    static func capitalized(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + s.dropFirst()
    }

    /// "Outboard drive" for a volume named Outboard, otherwise the name as it is.
    static func driveLabel(_ name: String) -> String {
        name.lowercased() == "outboard" ? "Outboard drive" : name
    }
}
