import Foundation
import CoreGraphics

/// The multi-stage AI pipeline that turns a selfie + notes into a fully animated buddy:
///
/// 1. Claude (vision) studies the selfie and writes a character bible: name, look, palette, voice.
/// 2. The image model paints one hero reference of that character.
/// 3. Each animation is painted *from the hero image* (in parallel) so every sheet shares one design.
/// 4. Claude reviews every sheet against the hero and the frames we actually sliced;
///    failures are repainted with Claude's fix instructions.
@MainActor
final class CharacterDesigner: ObservableObject {
    enum StepState: Equatable {
        case waiting
        case working(String)
        case done(String?)
        case failed(String)
    }

    struct Step: Identifiable {
        let id: String
        let title: String
        var state: StepState
    }

    @Published private(set) var steps: [Step] = []
    @Published private(set) var isRunning = false
    @Published var error: String?

    private static let maxAttempts = 3

    private func set(_ id: String, _ state: StepState) {
        if let i = steps.firstIndex(where: { $0.id == id }) { steps[i].state = state }
    }

    /// Returns the new character's library name, or nil on failure (see `error`).
    func run(selfie: Data?, notes: String, anthropicKey: String, openAIKey: String, imageModel: String) async -> String? {
        isRunning = true
        error = nil
        steps = [Step(id: "bible", title: "Claude studies your look", state: .waiting),
                 Step(id: "hero", title: "Painting the hero reference", state: .waiting)]
            + Anim.allCases.map { Step(id: $0.rawValue, title: "Animating \($0.rawValue)", state: .waiting) }
        defer { isRunning = false }

        let claude = Claude(apiKey: anthropicKey)
        var name: String?
        do {
            let folderName = try CharacterLibrary.newCharacterFolder()
            name = folderName
            let folder = CharacterLibrary.url(folderName)

            // 1. Character bible
            set("bible", .working("thinking…"))
            let bible = try await writeBible(claude: claude, selfie: selfie, notes: notes)
            try JSONEncoder().encode(bible).write(to: folder.appendingPathComponent("bible.json"))
            set("bible", .done("Meet \(bible.name): \(bible.tagline)"))

            // 2. Hero reference
            set("hero", .working("painting…"))
            let heroRaw = try await ImageAPI.create(prompt: Self.heroPrompt(bible, hasPhoto: selfie != nil),
                                                    references: selfie.map { [$0] } ?? [],
                                                    size: "1024x1536", apiKey: openAIKey, model: imageModel)
            let hero = try ImageFiles.pngData(heroRaw, maxSide: 1024)
            try hero.write(to: folder.appendingPathComponent("hero.png"))
            set("hero", .done(nil))

            // 3 + 4. All animations in parallel, each with its own review/repaint loop.
            let results = await withTaskGroup(of: (Anim, Bool).self) { group in
                for anim in Anim.allCases {
                    group.addTask {
                        let ok = await self.makeAnimation(anim, bible: bible, hero: hero, folder: folder,
                                                          claude: claude, openAIKey: openAIKey, imageModel: imageModel)
                        return (anim, ok)
                    }
                }
                var out: [Anim: Bool] = [:]
                for await (anim, ok) in group { out[anim] = ok }
                return out
            }
            guard results[.walk] == true else { throw AIError(message: "The walk cycle couldn't be generated.") }
            return folderName
        } catch {
            self.error = error.localizedDescription
            if let name { CharacterLibrary.delete(name) }
            for i in steps.indices where !Self.isFinished(steps[i].state) {
                steps[i].state = .failed("stopped")
            }
            return nil
        }
    }

    private static func isFinished(_ s: StepState) -> Bool {
        switch s {
        case .done, .failed: true
        default: false
        }
    }

    // MARK: - Stage 1: bible

    private func writeBible(claude: Claude, selfie: Data?, notes: String) async throws -> CharacterBible {
        var content: [JSON] = []
        if let selfie { content.append(Claude.image(selfie)) }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        content.append(Claude.text("""
        Design a tiny pixel-art desktop-pet character that lives on the user's macOS dock and reminds them to drink water.
        \(selfie != nil ? "The photo is the user: the character should be a recognizable chibi version of them (hair, skin tone, glasses, facial hair, typical clothing style)." : "There is no photo; invent the character from the notes.")
        \(trimmed.isEmpty ? "" : "User's notes: \(trimmed)")

        Fields:
        - name: a short cute name for the buddy
        - tagline: one short playful line introducing them
        - appearance: a precise visual spec a pixel artist could follow: hair (style, color), face, eyewear, outfit pieces with exact colors, shoes, body proportions. 60–120 words. Describe only what's visible.
        - palette: 6–10 hex colors that define the character
        - signature_prop: what they carry (usually a water cup/bottle that fits their style)
        - voice: how they talk in 1 sentence (used to write their speech bubbles)
        """))

        let schema = Schema.object([
            "name": Schema.string, "tagline": Schema.string, "appearance": Schema.string,
            "palette": Schema.array(Schema.string), "signature_prop": Schema.string, "voice": Schema.string,
        ])
        let json = try await claude.structured(
            system: "You are the art director for a pixel-art desktop companion app. You design characters that read clearly at 100 px tall.",
            content: content, schema: schema, effort: "high")
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CharacterBible.self, from: data)
    }

    // MARK: - Stage 2 + 3 prompts

    private static func style(_ bible: CharacterBible) -> String {
        """
        Style: crisp high-quality pixel art desktop pet, chibi proportions (head about 1/3 of body height), clean dark 1-pixel outline, \
        flat shading with one highlight tone, limited palette (\(bible.palette.joined(separator: ", "))).
        Character: \(bible.appearance). Carries \(bible.signatureProp).
        """
    }

    static func heroPrompt(_ bible: CharacterBible, hasPhoto: Bool) -> String {
        """
        Pixel-art character reference of ONE character, full body, standing in a relaxed 3/4 pose turned slightly to the right, centered.
        \(hasPhoto ? "Base the likeness on the person in the reference photo." : "")
        \(style(bible))
        Transparent background. No text, no labels, no shadow, no ground, no scenery, no border.
        """
    }

    private static func motion(_ anim: Anim) -> String {
        switch anim {
        case .walk: "side-view walk cycle facing RIGHT while carrying the cup; contact, down, passing, up poses so it loops smoothly"
        case .idle: "idle loop facing the viewer turned slightly right: gentle breathing bob, one frame blinking"
        case .drink: "facing right: lifts the cup, drinks from it with eyes closed, then lowers it with a satisfied face"
        case .cheer: "joyful celebration: hops with arms up / fist pump, big smile, cup held safely"
        case .sleep: "sitting on the floor dozing off, head nodding forward, eyes closed, cup beside them"
        }
    }

    static func sheetPrompt(_ anim: Anim, bible: CharacterBible, fix: String?) -> String {
        """
        Using the character in the reference image EXACTLY (same design, colors, outfit, proportions and pixel scale), draw a sprite sheet:
        a single horizontal row of exactly \(anim.frameCount) frames, evenly spaced with wide empty gaps between them, on a transparent background.
        Animation: \(motion(anim)).
        Every frame: the same character at the same size, full body visible, feet on one shared baseline, frames never touch or overlap.
        \(style(bible))
        No text, no numbers, no labels, no grid lines, no ground, no shadows, no scenery, no border.
        \(fix.map { "Fix these problems from the previous attempt: \($0)" } ?? "")
        """
    }

    // MARK: - Stage 3 + 4: paint, slice, review, repaint

    private struct Review {
        var pass: Bool
        var score: Int
        var retryInstructions: String
    }

    private func makeAnimation(_ anim: Anim, bible: CharacterBible, hero: Data, folder: URL,
                               claude: Claude, openAIKey: String, imageModel: String) async -> Bool {
        let id = anim.rawValue
        var fix: String?
        var best: (sheet: Data, score: Int)?

        for attempt in 1...Self.maxAttempts {
            do {
                set(id, .working(attempt == 1 ? "painting…" : "repainting (try \(attempt))…"))
                let sheet = try await ImageAPI.create(prompt: Self.sheetPrompt(anim, bible: bible, fix: fix),
                                                      references: [hero], size: "1536x1024",
                                                      apiKey: openAIKey, model: imageModel)
                guard let cg = ImageFiles.cgImage(sheet) else { continue }
                let frames = await Task.detached { SpriteSlicer.row(cg) }.value

                set(id, .working("Claude is reviewing…"))
                let review = try await self.review(anim, sheet: sheet, frames: frames, hero: hero, claude: claude)
                if frames.count >= 2, review.score > (best?.score ?? -1) { best = (sheet, review.score) }
                if review.pass && frames.count >= 2 { break }
                fix = review.retryInstructions
            } catch {
                fix = nil
                if attempt == Self.maxAttempts && best == nil {
                    set(id, .failed(error.localizedDescription))
                    return false
                }
            }
        }

        guard let best else {
            set(id, .failed("no usable frames"))
            return false
        }
        do {
            try best.sheet.write(to: folder.appendingPathComponent("\(id).png"))
            set(id, .done("quality \(best.score)/10"))
            return true
        } catch {
            set(id, .failed(error.localizedDescription))
            return false
        }
    }

    private func review(_ anim: Anim, sheet: Data, frames: [CGImage], hero: Data, claude: Claude) async throws -> Review {
        var content: [JSON] = [
            Claude.text("Image 1: the reference character."), Claude.image(hero),
            Claude.text("Image 2: the generated sprite sheet for the \"\(anim.rawValue)\" animation (\(Self.motion(anim)))."),
            Claude.image(try ImageFiles.pngData(sheet, maxSide: 1536)),
        ]
        if let strip = SpriteAssembler.strip(frames), let png = ImageFiles.png(strip) {
            content.append(Claude.text("Image 3: the \(frames.count) frames our slicer extracted, in playback order (expected \(anim.frameCount))."))
            content.append(Claude.image(png))
        } else {
            content.append(Claude.text("Our slicer extracted no frames at all from image 2."))
        }
        content.append(Claude.text("""
        Grade this sheet. pass = true only if ALL hold:
        - every frame is clearly the same character as the reference (hair, face, eyewear, outfit colors, prop)
        - one full-body character per frame, consistent size, no cropped limbs
        - the frames form a believable "\(anim.rawValue)" sequence\(anim == .walk ? " facing right" : "")
        - no text, numbers, ground lines, shadows or scenery
        - the extracted frame count is within 1 of expected and no frame contains two characters or a fragment
        score: 1–10 overall quality. retry_instructions: short, concrete instructions to the image model that would fix the problems (empty if pass).
        """))
        let schema = Schema.object(["pass": Schema.boolean, "score": Schema.integer,
                                    "issues": Schema.array(Schema.string), "retry_instructions": Schema.string])
        let json = try await claude.structured(
            system: "You are a meticulous QA reviewer for game sprite sheets.",
            content: content, schema: schema, effort: "medium")
        return Review(pass: json["pass"] as? Bool ?? false,
                      score: json["score"] as? Int ?? 0,
                      retryInstructions: json["retry_instructions"] as? String ?? "")
    }
}
