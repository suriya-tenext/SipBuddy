import AppKit
import ImageIO
import Security

enum Puppet {
    case rig(HeroLook)
    case frames(SpriteSet)

    var aspect: CGFloat {
        switch self {
        case .rig: HeroRenderer.aspect
        case .frames(let set): set.aspect
        }
    }
}

/// What Claude decided this character is: look, palette, voice. Stored next to the sprites.
struct CharacterBible: Codable, Equatable {
    var name: String
    var tagline: String
    var appearance: String
    var palette: [String]
    var signatureProp: String
    var voice: String

    static let builtin = CharacterBible(
        name: "Pixel", tagline: "Your tiny hydration sidekick",
        appearance: "long brown hair, round black glasses, dark coat over a white shirt, carries a green cup",
        palette: [], signatureProp: "a green cup of water", voice: "warm, upbeat, a little goofy"
    )
}

/// Buddies come from four places:
/// - `hero:<id>`: built-in pixel heroes, drawn by code
/// - `hero-…/look.json`: heroes made in the Hero Builder
/// - `buddy-…/`: AI characters (`bible.json`, `hero.png`, one sheet per animation)
/// - `sheet-….png`: hand-imported two-row sheets
@MainActor
enum CharacterLibrary {
    static let defaultName = "hero:ironclad"
    static var presetNames: [String] { HeroLook.presets.map { "hero:\($0.id)" } }
    private static var cache: [String: SpriteSet] = [:]

    static func isPreset(_ name: String) -> Bool { name.hasPrefix("hero:") || name == "builtin" }

    static func look(_ name: String) -> HeroLook? {
        if name == "builtin" { return HeroLook.presets[0] }
        if name.hasPrefix("hero:") { return HeroLook.preset(String(name.dropFirst(5))) }
        guard let data = try? Data(contentsOf: url(name).appendingPathComponent("look.json")) else { return nil }
        return try? JSONDecoder().decode(HeroLook.self, from: data)
    }

    static func saveHero(_ look: HeroLook) throws -> String {
        let name = "hero-\(Int(Date().timeIntervalSince1970))"
        var saved = look
        saved.id = name
        try FileManager.default.createDirectory(at: url(name), withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: url(name).appendingPathComponent("look.json"))
        return name
    }

    static var folder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SipBuddy/Characters", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func url(_ name: String) -> URL { folder.appendingPathComponent(name) }

    static func names() -> [String] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        return entries.filter { name in
            name.hasSuffix(".png")
                || fm.fileExists(atPath: url(name).appendingPathComponent("walk.png").path)
                || fm.fileExists(atPath: url(name).appendingPathComponent("look.json").path)
        }.sorted { a, b in
            // Newest first: names end in a timestamp.
            (a.split(separator: "-").last ?? "") > (b.split(separator: "-").last ?? "")
        }
    }

    /// Heroes are live vector puppets; AI and imported characters are frame-based sprites.
    static func puppet(_ name: String) -> Puppet {
        if let look = look(name) { return .rig(look) }
        if let cached = cache[name] { return .frames(cached) }
        guard let set = load(name) else { return .rig(HeroLook.presets[0]) }
        cache[name] = set
        return .frames(set)
    }

    private static func load(_ name: String) -> SpriteSet? {
        let base = url(name)
        if name.hasSuffix(".png") {
            return ImageFiles.cgImage(at: base).flatMap(SpriteSlicer.legacySheet)
        }
        var crops: [Anim: [CGImage]] = [:]
        for anim in Anim.allCases {
            if let cg = ImageFiles.cgImage(at: base.appendingPathComponent("\(anim.rawValue).png")) {
                crops[anim] = SpriteSlicer.row(cg)
            }
        }
        return SpriteAssembler.assemble(crops)
    }

    static func bible(_ name: String) -> CharacterBible {
        if let look = look(name) { return look.bible }
        guard let data = try? Data(contentsOf: url(name).appendingPathComponent("bible.json")),
              let bible = try? JSONDecoder().decode(CharacterBible.self, from: data)
        else { return .builtin }
        return bible
    }

    static func newCharacterFolder() throws -> String {
        let name = "buddy-\(Int(Date().timeIntervalSince1970))"
        try FileManager.default.createDirectory(at: url(name), withIntermediateDirectories: true)
        return name
    }

    static func importSheet(from source: URL) throws -> String {
        let name = "sheet-\(Int(Date().timeIntervalSince1970)).png"
        try ImageFiles.pngData(from: source, maxSide: 4096).write(to: url(name))
        return name
    }

    static func delete(_ name: String) {
        guard !isPreset(name) else { return }
        try? FileManager.default.removeItem(at: url(name))
        cache[name] = nil
    }
}

enum ImageFiles {
    struct ReadError: LocalizedError {
        var errorDescription: String? { "Couldn't read that image." }
    }

    static func cgImage(at url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func cgImage(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func png(_ cg: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    /// Re-encodes any image (HEIC, JPEG, …) as PNG, downscaled to `maxSide`.
    static func pngData(from url: URL, maxSide: Int) throws -> Data {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ReadError() }
        return try thumbnailPNG(src, maxSide: maxSide)
    }

    static func pngData(_ data: Data, maxSide: Int) throws -> Data {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { throw ReadError() }
        return try thumbnailPNG(src, maxSide: maxSide)
    }

    private static func thumbnailPNG(_ src: CGImageSource, maxSide: Int) throws -> Data {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary), let data = png(cg)
        else { throw ReadError() }
        return data
    }
}

struct APIKeyStore {
    let service: String
    let environmentVariable: String

    static let openAI = APIKeyStore(service: "SipBuddy.openai", environmentVariable: "OPENAI_API_KEY")
    static let anthropic = APIKeyStore(service: "SipBuddy.anthropic", environmentVariable: "ANTHROPIC_API_KEY")

    func load() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty {
            return key
        }
        return ProcessInfo.processInfo.environment[environmentVariable]
    }

    func save(_ key: String) {
        let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
        SecItemDelete(base as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var add = base
        add[kSecValueData] = Data(trimmed.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
