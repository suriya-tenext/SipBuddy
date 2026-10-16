import Foundation

struct RGB: Codable, Equatable, Hashable {
    var r: UInt8, g: UInt8, b: UInt8

    init(_ hex: UInt32) {
        r = UInt8(hex >> 16 & 0xFF); g = UInt8(hex >> 8 & 0xFF); b = UInt8(hex & 0xFF)
    }

    init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }

    func scaled(_ f: Double) -> RGB {
        func c(_ v: UInt8) -> UInt8 { UInt8(max(0, min(255, (Double(v) * f).rounded()))) }
        return RGB(r: c(r), g: c(g), b: c(b))
    }

    var hex: String { String(format: "#%02X%02X%02X", r, g, b) }

    /// Blends toward `other` by `t` (0 = self, 1 = other).
    func mixed(with other: RGB, _ t: Double) -> RGB {
        func c(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(a) * (1 - t) + Double(b) * t).rounded()) }
        return RGB(r: c(r, other.r), g: c(g, other.g), b: c(b, other.b))
    }
}

/// A paper-doll hero: every part is a choice, so any combination animates cleanly.
struct HeroLook: Codable, Equatable {
    enum Hair: String, Codable, CaseIterable { case short, long, spiky, bun, ponytail, curly, bald }
    enum Mask: String, Codable, CaseIterable { case none, domino, shades, cowl, helmet, armor, fullface }
    enum Ears: String, Codable, CaseIterable { case none, pointy, cat, antenna }
    enum Emblem: String, Codable, CaseIterable { case none, star, bolt, drop, circle, diamond, heart, core, spider }
    enum Outfit: String, Codable, CaseIterable { case bodysuit, tux, bare, armor }
    enum Build: String, Codable, CaseIterable { case regular, big }
    enum Attitude: String, Codable, CaseIterable { case cheerful, stoic, fierce }
    enum Figure: String, Codable, CaseIterable { case masculine, feminine }

    var id: String
    var name: String
    var tagline: String
    var voice: String

    var skin: RGB
    var hair: RGB
    var hairStyle: Hair
    var suit: RGB
    var accent: RGB
    var pants: RGB
    var boots: RGB
    var gloves: RGB
    var belt: Bool
    var cape: RGB?
    var mask: Mask
    var maskColor: RGB
    var ears: Ears
    var emblem: Emblem
    var emblemColor: RGB
    var glasses: Bool
    var cup: RGB
    // Optional so heroes saved by older versions still load.
    var outfit: Outfit?
    var build: Build?
    var beard: Bool?
    var attitude: Attitude?
    var figure: Figure?

    var isFeminine: Bool { figure == .feminine }

    var appearance: String {
        var parts = ["\(hairStyle.rawValue) \(hair.hex) hair", "\(suit.hex) suit with \(accent.hex) accents"]
        if let cape { parts.append("\(cape.hex) cape") }
        if mask != .none { parts.append("\(maskColor.hex) \(mask.rawValue)") }
        if emblem != .none { parts.append("\(emblem.rawValue) chest emblem") }
        if ears != .none { parts.append("\(ears.rawValue) ears") }
        if glasses { parts.append("glasses") }
        return parts.joined(separator: ", ")
    }

    var bible: CharacterBible {
        CharacterBible(name: name, tagline: tagline, appearance: appearance,
                       palette: [skin, hair, suit, accent, cape ?? accent].map(\.hex),
                       signatureProp: "a \(cup.hex) cup of water", voice: voice)
    }
}

extension HeroLook {
    private static func make(_ id: String, _ name: String, _ tagline: String, _ voice: String,
                             skin: UInt32, hair: UInt32, hairStyle: Hair, suit: UInt32, accent: UInt32,
                             pants: UInt32, boots: UInt32, gloves: UInt32, belt: Bool = true, cape: UInt32? = nil,
                             mask: Mask = .none, maskColor: UInt32 = 0x222222, ears: Ears = .none,
                             emblem: Emblem = .none, emblemColor: UInt32 = 0xFFFFFF, glasses: Bool = false,
                             cup: UInt32 = 0x4CAE4F, outfit: Outfit = .bodysuit, build: Build = .regular,
                             beard: Bool = false, attitude: Attitude = .cheerful) -> HeroLook {
        HeroLook(id: id, name: name, tagline: tagline, voice: voice, skin: RGB(skin), hair: RGB(hair), hairStyle: hairStyle,
                 suit: RGB(suit), accent: RGB(accent), pants: RGB(pants), boots: RGB(boots), gloves: RGB(gloves),
                 belt: belt, cape: cape.map(RGB.init), mask: mask, maskColor: RGB(maskColor), ears: ears,
                 emblem: emblem, emblemColor: RGB(emblemColor), glasses: glasses, cup: RGB(cup),
                 outfit: outfit, build: build, beard: beard, attitude: attitude, figure: .masculine)
    }

    /// Original characters (no franchise names or logos), each with its own look and voice.
    static let heroes: [HeroLook] = [
        make("ironclad", "Ironclad", "Hydration systems: online. ⚙️", "cocky, witty genius inventor; calls water 'coolant' and every sip a 'system upgrade'",
             skin: 0xE8B894, hair: 0x2A1E18, hairStyle: .short, suit: 0xB01E28, accent: 0xE0A93A,
             pants: 0xE0A93A, boots: 0xB01E28, gloves: 0xB01E28, belt: false, mask: .armor, maskColor: 0xB01E28,
             emblem: .core, emblemColor: 0x9FF3FF, cup: 0xC9CED6, outfit: .armor),
        make("sterling", "Mr. Sterling", "He's back. And he's thirsty.", "stoic retired professional; very short, deadly serious sentences; treats hydration like a sacred contract; sometimes mentions his dog",
             skin: 0xE6BFA0, hair: 0x1A1614, hairStyle: .long, suit: 0x17181D, accent: 0x0C0C0E,
             pants: 0x17181D, boots: 0x0C0C0E, gloves: 0xE6BFA0, belt: false, cup: 0x9FD8F5,
             outfit: .tux, beard: true, attitude: .stoic),
        make("skyline", "Skyline", "Swinging by to remind you to drink!", "quippy, upbeat teen hero who cracks jokes nonstop",
             skin: 0xF2C6A0, hair: 0x3A2A1A, hairStyle: .short, suit: 0xD62C2C, accent: 0x2347A8,
             pants: 0x2347A8, boots: 0xD62C2C, gloves: 0xD62C2C, belt: false, mask: .fullface, maskColor: 0xD62C2C,
             emblem: .spider, emblemColor: 0x141414, cup: 0xD62C2C),
        make("brawn", "Brawn", "BRAWN SMASH… THIRST.", "huge gentle giant who talks in short ALL-CAPS smash sentences but is secretly very sweet",
             skin: 0x6DBE45, hair: 0x1B1B1B, hairStyle: .spiky, suit: 0x6DBE45, accent: 0x6A3D9A,
             pants: 0x6A3D9A, boots: 0x6DBE45, gloves: 0x6DBE45, belt: false, cup: 0x6A3D9A,
             outfit: .bare, build: .big, attitude: .fierce),
        make("pixel", "Pixel", "Your cozy desk sidekick", "warm, upbeat, a little goofy",
             skin: 0xF2C6A0, hair: 0x5A3A2A, hairStyle: .long, suit: 0x2D2D38, accent: 0xF0F0F0,
             pants: 0x23232B, boots: 0x5A3222, gloves: 0xF2C6A0, belt: false, glasses: true),
        make("hydro", "Captain Hydro", "Defender of the daily 8 glasses!", "booming heroic announcer who treats every sip like saving the city",
             skin: 0xC68A5E, hair: 0xF4D06F, hairStyle: .short, suit: 0x2F6FDE, accent: 0xD93A3A,
             pants: 0x2F6FDE, boots: 0xD93A3A, gloves: 0xF4F4F4, cape: 0xD93A3A, mask: .domino, maskColor: 0x1E3F8A,
             emblem: .drop, emblemColor: 0xFFFFFF, cup: 0x9FD8F5),
        make("volt", "Volt", "Charged up and ready to hydrate ⚡", "hyper, talks fast, loves puns about energy",
             skin: 0xFFD9B8, hair: 0x1B1B1B, hairStyle: .spiky, suit: 0xF4C430, accent: 0x1B1B1B,
             pants: 0x1B1B1B, boots: 0xF4C430, gloves: 0x1B1B1B, emblem: .bolt, emblemColor: 0x1B1B1B, cup: 0xF4C430),
        make("owl", "Night Owl", "Watches over your late-night coding 🌙", "dry, mysterious, speaks in short moody lines with secret warmth",
             skin: 0xE0B48C, hair: 0x1B1B1B, hairStyle: .short, suit: 0x5B4E9E, accent: 0x7FE0D0,
             pants: 0x2E2A5A, boots: 0x7FE0D0, gloves: 0x2E2A5A, cape: 0x3A3470, mask: .cowl, maskColor: 0x2E2A5A,
             ears: .cat, emblem: .circle, emblemColor: 0xE8E4FF, cup: 0x7FE0D0),
        make("comet", "Crimson Comet", "Fastest hydration in the galaxy", "cocky space racer, competitive, counts everything as a lap record",
             skin: 0x8D5A3B, hair: 0x1B1B1B, hairStyle: .bald, suit: 0xC8323C, accent: 0xF2C230,
             pants: 0xC8323C, boots: 0xF2C230, gloves: 0xF2C230, mask: .helmet, maskColor: 0xC8323C,
             emblem: .star, emblemColor: 0xF2C230, cup: 0xF2C230),
        make("frost", "Frost", "Cool, calm and very hydrated ❄️", "serene and elegant, speaks softly like falling snow",
             skin: 0xF7DCCB, hair: 0xDDEEFF, hairStyle: .long, suit: 0xE8F4FF, accent: 0x6CB8F0,
             pants: 0x6CB8F0, boots: 0xE8F4FF, gloves: 0x6CB8F0, cape: 0x9FD3F7, emblem: .diamond, emblemColor: 0x3A8FD9,
             cup: 0x9FD3F7),
        make("cat", "Shadow Cat", "Sneaks up when you forget to drink", "smug feline thief, playful, occasionally says nya",
             skin: 0xFFE0C2, hair: 0x2B1E3A, hairStyle: .ponytail, suit: 0x1E1A24, accent: 0x9B59D0,
             pants: 0x1E1A24, boots: 0x9B59D0, gloves: 0x9B59D0, mask: .domino, maskColor: 0x9B59D0, ears: .cat,
             emblem: .heart, emblemColor: 0x9B59D0, cup: 0x9B59D0),
        make("astro", "Astro", "Mission control says: drink water", "cheerful astronaut using mission-control jargon",
             skin: 0xD9A07A, hair: 0x3A2A1A, hairStyle: .bald, suit: 0xF2F2F2, accent: 0xF28C28,
             pants: 0xF2F2F2, boots: 0x8A8F99, gloves: 0xF28C28, mask: .helmet, maskColor: 0xF2F2F2, ears: .antenna,
             emblem: .star, emblemColor: 0xF28C28, cup: 0xF28C28),
        make("ember", "Ember", "Hot-headed, but stays hydrated 🔥", "fiery, dramatic, overreacts to everything",
             skin: 0xFFD2B0, hair: 0xF2582A, hairStyle: .spiky, suit: 0x33303A, accent: 0xF28C28,
             pants: 0x33303A, boots: 0xF2582A, gloves: 0xF28C28, cape: 0xF2582A, emblem: .diamond, emblemColor: 0xF28C28,
             cup: 0xF2582A),
        make("sprout", "Sprout", "A tiny plant parent who needs water too 🌱", "gentle, wholesome, compares everything to plants",
             skin: 0x6B4430, hair: 0x2A1A12, hairStyle: .bun, suit: 0x5DAA68, accent: 0xF7E6B5,
             pants: 0x3E5C8A, boots: 0xF7E6B5, gloves: 0x6B4430, belt: false, cup: 0x5DAA68),
        make("ninja", "Hush", "Silent. Swift. Sipping.", "a quiet ninja of few words, speaks in haiku-like fragments",
             skin: 0xF0C8A0, hair: 0x1B1B1B, hairStyle: .ponytail, suit: 0x2E3440, accent: 0xC8323C,
             pants: 0x2E3440, boots: 0x1B1B1B, gloves: 0x2E3440, mask: .shades, maskColor: 0x1B1B1B,
             emblem: .none, cup: 0xC8323C),
    ]

    /// A heroine for every hero: same costume and powers, her own name, voice and hair.
    static let heroines: [HeroLook] = {
        func her(_ heroID: String, _ name: String, _ tagline: String, _ voice: String,
                 hair: Hair? = nil, hairColor: UInt32? = nil, _ tweak: (inout HeroLook) -> Void = { _ in }) -> HeroLook {
            var l = heroes.first { $0.id == heroID }!
            l.id = heroID + "-her"
            l.name = name; l.tagline = tagline; l.voice = voice
            l.figure = .feminine
            l.beard = false
            if let hair { l.hairStyle = hair }
            if let hairColor { l.hair = RGB(hairColor) }
            tweak(&l)
            return l
        }
        return [
            her("ironclad", "Alloy", "Hydration protocols: engaged. ✨", "brilliant, confident engineer; calls water 'coolant' and every sip an 'efficiency upgrade'",
                hair: .ponytail, hairColor: 0x7A3B1E),
            her("sterling", "Ms. Sterling", "She's back. And she's thirsty.", "stoic retired professional; very short, deadly serious sentences; treats hydration like a sacred contract; sometimes mentions her cat",
                hair: .long),
            her("skyline", "Skyla", "Swinging in with your water break!", "quippy, upbeat teen hero who cracks jokes nonstop",
                hair: .ponytail, hairColor: 0xE8C77A),
            her("brawn", "Jade", "JADE SMASH… THIRST.", "mighty gentle giant who talks in short ALL-CAPS smash sentences but is secretly very sweet",
                hair: .long),
            her("pixel", "Pixie", "Your cozy desk sidekick", "warm, upbeat, a little goofy", hair: .bun),
            her("hydro", "Captain Marina", "Defender of the daily 8 glasses!", "booming heroic announcer who treats every sip like saving the city",
                hair: .long),
            her("volt", "Volta", "Charged up and ready to hydrate ⚡", "hyper, talks fast, loves puns about energy", hair: .ponytail),
            her("owl", "Nightingale", "Watches over your late-night coding 🌙", "dry, mysterious, speaks in short moody lines with secret warmth",
                hair: .ponytail),
            her("comet", "Scarlet Comet", "Fastest hydration in the galaxy", "cocky space racer, competitive, counts everything as a lap record"),
            her("frost", "Flurry", "Cool, calm and very hydrated ❄️", "serene and elegant, speaks softly like falling snow"),
            her("cat", "Velvet", "Sneaks up when you forget to drink", "smug feline thief, playful, occasionally says nya"),
            her("astro", "Astra", "Mission control says: drink water", "cheerful astronaut using mission-control jargon"),
            her("ember", "Blaze", "Hot-headed, but stays hydrated 🔥", "fiery, dramatic, overreacts to everything", hair: .long),
            her("sprout", "Blossom", "A tiny plant parent who needs water too 🌸", "gentle, wholesome, compares everything to plants", hair: .curly),
            her("ninja", "Whisper", "Silent. Swift. Sipping.", "a quiet ninja of few words, speaks in haiku-like fragments"),
        ]
    }()

    static let presets: [HeroLook] = heroes + heroines

    static func preset(_ id: String) -> HeroLook? { presets.first { $0.id == id } }
}

