import Foundation

/// Claude gives the buddy its voice. Lines are written in batches ahead of time (so reminders
/// pop instantly and cost almost nothing), and chat runs live with tools that edit reminders.
@MainActor
final class BuddyBrain: ObservableObject {
    static let shared = BuddyBrain()

    struct LinePack: Codable {
        var key: String
        var date: Date
        var nag: [String: [String]]
        var praise: [String: [String]]
        var idle: [String]
        var sleepy: [String]
    }

    @Published private(set) var pack: LinePack?
    @Published private(set) var isRefreshing = false
    @Published var lastError: String?

    private let state = AppState.shared
    private var history: [JSON] = []
    private var historyKey = ""

    private init() {
        if let data = UserDefaults.standard.data(forKey: "linePack") {
            pack = try? JSONDecoder().decode(LinePack.self, from: data)
        }
    }

    private var bible: CharacterBible { CharacterLibrary.bible(state.selectedCharacter) }
    var buddyName: String { bible.name }
    var isAvailable: Bool { APIKeyStore.anthropic.load() != nil }

    // MARK: - Pre-written lines

    /// Changes whenever something the lines depend on changes.
    private var packKey: String {
        let reminders = state.reminders.map { "\($0.id)|\($0.title)|\($0.message)" }.joined(separator: ";")
        return [state.selectedCharacter, state.personality, reminders].joined(separator: "#")
    }

    func refreshIfNeeded() {
        guard isAvailable, !isRefreshing else { return }
        if let pack, pack.key == packKey, Date().timeIntervalSince(pack.date) < 6 * 3600 { return }
        Task { await refresh() }
    }

    func refresh() async {
        guard let key = APIKeyStore.anthropic.load(), !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let wantedKey = packKey
        let reminders = state.reminders.map { r -> JSON in
            ["id": r.id.uuidString, "emoji": r.emoji, "title": r.title, "message": r.message,
             "every_minutes": r.intervalMinutes]
        }
        let remindersJSON = String(data: (try? JSONSerialization.data(withJSONObject: reminders)) ?? Data(), encoding: .utf8) ?? "[]"

        let schema = Schema.object([
            "reminders": Schema.array(Schema.object([
                "id": Schema.string, "nag": Schema.array(Schema.string), "praise": Schema.array(Schema.string),
            ])),
            "idle": Schema.array(Schema.string),
            "sleepy": Schema.array(Schema.string),
        ])
        do {
            let json = try await Claude(apiKey: key).structured(
                system: persona,
                content: [Claude.text("""
                Write the speech-bubble lines you'll use today. Bubbles are tiny: keep every line under 55 characters, at most one emoji.
                Reminders (JSON): \(remindersJSON)

                - reminders: for EACH reminder id, 8 "nag" lines (it's time to do it; varied, playful, increasingly insistent, clearly about that reminder) and 6 "praise" lines (they just did it).
                - idle: 14 short ambient lines you say while hanging out on the dock (cozy observations, tiny jokes, encouragement, fun facts about hydration or breaks). Never nag here.
                - sleepy: 4 lines for quiet hours when you're dozing.
                Stay in character.
                """)],
                schema: schema, effort: "low")

            var nag: [String: [String]] = [:], praise: [String: [String]] = [:]
            for r in json["reminders"] as? [JSON] ?? [] {
                guard let id = r["id"] as? String else { continue }
                nag[id] = r["nag"] as? [String] ?? []
                praise[id] = r["praise"] as? [String] ?? []
            }
            let newPack = LinePack(key: wantedKey, date: Date(), nag: nag, praise: praise,
                                   idle: json["idle"] as? [String] ?? [], sleepy: json["sleepy"] as? [String] ?? [])
            pack = newPack
            lastError = nil
            UserDefaults.standard.set(try? JSONEncoder().encode(newPack), forKey: "linePack")
        } catch {
            lastError = error.localizedDescription
        }
    }

    func nagLine(_ r: Reminder) -> String {
        pack?.nag[r.id.uuidString]?.randomElement() ?? "\(r.emoji) \(r.message)"
    }

    func praiseLine(_ r: Reminder) -> String {
        pack?.praise[r.id.uuidString]?.randomElement()
            ?? ["Ahh, refreshing!", "Nice one!", "You're doing great!", "Proud of you!"].randomElement()!
    }

    func idleLine() -> String? { pack?.idle.randomElement() }
    func sleepyLine() -> String { pack?.sleepy.randomElement() ?? "Zzz… 💤" }

    private var persona: String {
        """
        You are \(bible.name), a tiny pixel-art companion who lives on the user's macOS dock and helps them build healthy habits.
        Look: \(bible.appearance)
        Voice: \(bible.voice)
        Personality the user picked: \(state.personality)
        """
    }

    // MARK: - Chat

    private static let tools: [JSON] = [
        tool("add_reminder", "Create a new recurring reminder.", [
            "emoji": Schema.string, "title": Schema.string,
            "message": Schema.string, "interval_minutes": Schema.integer,
        ]),
        tool("update_reminder", "Change an existing reminder, found by its title. Pass null for fields to keep.", [
            "title": Schema.string,
            "interval_minutes": Schema.nullable(Schema.integer),
            "message": Schema.nullable(Schema.string),
            "enabled": Schema.nullable(Schema.boolean),
        ]),
        tool("remove_reminder", "Delete a reminder, found by its title.", ["title": Schema.string]),
        tool("log_done", "Record that the user just did a reminder (e.g. drank water).", ["title": Schema.string]),
        tool("pause_reminders", "Pause all reminders for some minutes (0 resumes them now).", ["minutes": Schema.integer]),
    ]

    private static func tool(_ name: String, _ description: String, _ props: [String: JSON]) -> JSON {
        ["name": name, "description": description, "strict": true, "input_schema": Schema.object(props)]
    }

    private var chatSystem: String {
        persona + """

        The user is chatting with you through a tiny text box; your reply appears in a speech bubble, so answer in at most 2 short sentences.
        You can manage their reminders with tools. Act directly when they ask (e.g. "remind me to stretch every hour", "pause for 30 min", "I just drank water").
        Each user message starts with a [status] line describing the current reminders; it's context, not something the user typed.
        """
    }

    private var statusLine: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE HH:mm"
        let reminders = state.reminders.map { r in
            let mins = max(0, Int(r.nextDue.timeIntervalSinceNow / 60))
            return "\(r.emoji) \(r.title) every \(r.intervalMinutes)m, \(r.enabled ? "next in \(mins)m" : "off"), \(state.count(for: r.id)) today"
        }
        let paused = state.isSuppressed ? " Reminders are currently paused/quiet." : ""
        return "[status: \(fmt.string(from: Date())). \(reminders.isEmpty ? "No reminders." : reminders.joined(separator: "; ")).\(paused)]"
    }

    func chat(_ text: String) async -> String {
        guard let key = APIKeyStore.anthropic.load() else {
            return "Add an Anthropic API key in Settings so I can talk! 🗝️"
        }
        // The history is append-only; start a fresh conversation instead of trimming it.
        let key2 = state.selectedCharacter + state.personality
        if history.count > 40 || historyKey != key2 { history = []; historyKey = key2 }
        history.append(["role": "user", "content": "\(statusLine)\n\(text)"])

        let claude = Claude(apiKey: key)
        do {
            for _ in 0..<6 {
                let response = try await claude.send(system: chatSystem, messages: history, tools: Self.tools,
                                                     effort: "low", maxTokens: 4000)
                let content = response["content"] as? [JSON] ?? []
                history.append(["role": "assistant", "content": content])

                let calls = content.filter { $0["type"] as? String == "tool_use" }
                guard response["stop_reason"] as? String == "tool_use", !calls.isEmpty else {
                    let reply = Claude.textOf(response).trimmingCharacters(in: .whitespacesAndNewlines)
                    return reply.isEmpty ? "👍" : reply
                }
                let results: [JSON] = calls.map { call in
                    let output = run(call["name"] as? String ?? "", call["input"] as? JSON ?? [:])
                    return ["type": "tool_result", "tool_use_id": call["id"] as? String ?? "", "content": output]
                }
                history.append(["role": "user", "content": results])
            }
            return "Done! ✨"
        } catch {
            history = []
            return "Oops, my brain glitched: \(error.localizedDescription)"
        }
    }

    private func find(_ title: String) -> Reminder? {
        let t = title.lowercased()
        return state.reminders.first { $0.title.lowercased() == t }
            ?? state.reminders.first { $0.title.lowercased().contains(t) || t.contains($0.title.lowercased()) }
    }

    private func run(_ name: String, _ input: JSON) -> String {
        let title = input["title"] as? String ?? ""
        switch name {
        case "add_reminder":
            let minutes = max(1, input["interval_minutes"] as? Int ?? 30)
            state.add(Reminder(emoji: input["emoji"] as? String ?? "⭐️", title: title,
                               message: input["message"] as? String ?? title, intervalMinutes: minutes))
            return "Added \(title) every \(minutes) minutes."
        case "update_reminder":
            guard let r = find(title), let i = state.reminders.firstIndex(where: { $0.id == r.id }) else {
                return "No reminder titled \(title)."
            }
            if let m = input["interval_minutes"] as? Int { state.reminders[i].intervalMinutes = max(1, m) }
            if let msg = input["message"] as? String { state.reminders[i].message = msg }
            if let on = input["enabled"] as? Bool { state.reminders[i].enabled = on }
            return "Updated \(r.title)."
        case "remove_reminder":
            guard let r = find(title) else { return "No reminder titled \(title)." }
            state.reminders.removeAll { $0.id == r.id }
            return "Removed \(r.title)."
        case "log_done":
            guard let r = find(title) else { return "No reminder titled \(title)." }
            state.markDone(r.id)
            return "Logged \(r.title). \(state.count(for: r.id)) today."
        case "pause_reminders":
            let minutes = input["minutes"] as? Int ?? 0
            state.pausedUntil = minutes > 0 ? Date().addingTimeInterval(Double(minutes) * 60) : nil
            return minutes > 0 ? "Paused for \(minutes) minutes." : "Resumed."
        default:
            return "Unknown tool \(name)."
        }
    }
}
