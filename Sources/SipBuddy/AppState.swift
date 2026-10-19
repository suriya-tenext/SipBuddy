import Foundation
import Combine

struct Reminder: Codable, Identifiable, Equatable {
    var id = UUID()
    var emoji: String
    var title: String
    var message: String
    var intervalMinutes: Int
    var enabled = true
    var lastDone = Date()

    var nextDue: Date { lastDone.addingTimeInterval(TimeInterval(intervalMinutes * 60)) }

    static let presets: [Reminder] = [
        Reminder(emoji: "💧", title: "Water", message: "Time to drink some water!", intervalMinutes: 45),
        Reminder(emoji: "🧘", title: "Stretch", message: "Stand up and stretch a bit!", intervalMinutes: 60),
        Reminder(emoji: "👀", title: "Eyes", message: "Look 20 ft away for 20 seconds", intervalMinutes: 20),
        Reminder(emoji: "🪑", title: "Posture", message: "Sit up straight!", intervalMinutes: 30),
        Reminder(emoji: "💊", title: "Meds", message: "Take your meds!", intervalMinutes: 240),
    ]

    static let placeholder = Reminder(emoji: "⭐️", title: "", message: "", intervalMinutes: 30)
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    private let defaults = UserDefaults.standard

    @Published var reminders: [Reminder] { didSet { save(reminders, "reminders") } }
    @Published var buddyHeight: Double { didSet { defaults.set(buddyHeight, forKey: "buddyHeight") } }
    @Published var walkSpeed: Double { didSet { defaults.set(walkSpeed, forKey: "walkSpeed") } }
    @Published var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: "soundEnabled") } }
    /// When on, the buddy stays off-screen and only walks in when a reminder is due.
    @Published var onlyForReminders: Bool { didSet { defaults.set(onlyForReminders, forKey: "onlyForReminders") } }
    @Published var quietHoursEnabled: Bool { didSet { defaults.set(quietHoursEnabled, forKey: "quietHoursEnabled") } }
    @Published var quietStart: Int { didSet { defaults.set(quietStart, forKey: "quietStart") } }
    @Published var quietEnd: Int { didSet { defaults.set(quietEnd, forKey: "quietEnd") } }
    @Published var selectedCharacter: String { didSet { defaults.set(selectedCharacter, forKey: "selectedCharacter") } }
    @Published var imageModel: String { didSet { defaults.set(imageModel, forKey: "imageModel") } }
    @Published var personality: String { didSet { defaults.set(personality, forKey: "personality") } }
    @Published var pausedUntil: Date?
    @Published private(set) var todayCounts: [String: Int]
    private var countsDate: String

    let isFirstLaunch: Bool

    static let personalities: [(String, String)] = [
        ("🌞 Cheerful", "Cheerful, warm and encouraging, with a goofy streak."),
        ("💅 Sassy", "Sassy and dramatic, playfully roasts the user when they forget, secretly adores them."),
        ("😌 Chill", "Laid-back and calm, speaks softly, cozy lo-fi vibes."),
        ("💪 Coach", "High-energy sports coach, hype and motivational, loves streaks."),
        ("🎭 Theatrical", "Over-the-top Shakespearean drama queen; every sip is an epic."),
        ("🐱 Cat", "Acts like a smug little cat; occasional 'nya', judges the user lovingly."),
    ]

    private init() {
        isFirstLaunch = defaults.object(forKey: "reminders") == nil
        if let data = defaults.data(forKey: "reminders"),
           let saved = try? JSONDecoder().decode([Reminder].self, from: data) {
            reminders = saved
        } else {
            reminders = [Reminder.presets[0]]
        }
        let savedHeight = defaults.object(forKey: "buddyHeight") as? Double ?? 0
        buddyHeight = savedHeight < 140 ? 180 : savedHeight
        walkSpeed = defaults.object(forKey: "walkSpeed") as? Double ?? 45
        soundEnabled = defaults.object(forKey: "soundEnabled") as? Bool ?? true
        onlyForReminders = defaults.object(forKey: "onlyForReminders") as? Bool ?? true
        quietHoursEnabled = defaults.bool(forKey: "quietHoursEnabled")
        quietStart = defaults.object(forKey: "quietStart") as? Int ?? 22
        quietEnd = defaults.object(forKey: "quietEnd") as? Int ?? 8
        let savedCharacter = defaults.string(forKey: "selectedCharacter")
        selectedCharacter = (savedCharacter == nil || savedCharacter == "builtin") ? CharacterLibrary.defaultName : savedCharacter!
        let savedModel = defaults.string(forKey: "imageModel")
        imageModel = (savedModel == nil || savedModel == "gpt-image-1") ? "gpt-image-2" : savedModel!
        personality = defaults.string(forKey: "personality") ?? Self.personalities[0].1
        countsDate = defaults.string(forKey: "countsDate") ?? ""
        todayCounts = defaults.dictionary(forKey: "todayCounts") as? [String: Int] ?? [:]
        rollCountsIfNeeded()
        if isFirstLaunch { save(reminders, "reminders") }
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func dayKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func rollCountsIfNeeded() {
        let today = Self.dayKey()
        if countsDate != today {
            countsDate = today
            todayCounts = [:]
            defaults.set(today, forKey: "countsDate")
            defaults.set(todayCounts, forKey: "todayCounts")
        }
    }

    // MARK: - Reminder actions

    func count(for id: UUID) -> Int {
        rollCountsIfNeeded()
        return todayCounts[id.uuidString] ?? 0
    }

    func reminder(_ id: UUID) -> Reminder? { reminders.first { $0.id == id } }

    func add(_ preset: Reminder) {
        var r = preset
        r.id = UUID()
        r.lastDone = Date()
        reminders.append(r)
    }

    func markDone(_ id: UUID) {
        rollCountsIfNeeded()
        guard let i = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[i].lastDone = Date()
        todayCounts[id.uuidString, default: 0] += 1
        defaults.set(todayCounts, forKey: "todayCounts")
    }

    func snooze(_ id: UUID, minutes: Int) {
        guard let i = reminders.firstIndex(where: { $0.id == id }) else { return }
        let interval = TimeInterval(reminders[i].intervalMinutes * 60)
        reminders[i].lastDone = Date().addingTimeInterval(-interval + TimeInterval(minutes * 60))
    }

    func skip(_ id: UUID) {
        guard let i = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[i].lastDone = Date()
    }

    /// Reminders are silent while paused or during quiet hours.
    var isSuppressed: Bool {
        if let pausedUntil, pausedUntil > Date() { return true }
        guard quietHoursEnabled, quietStart != quietEnd else { return false }
        let hour = Calendar.current.component(.hour, from: Date())
        return quietStart < quietEnd
            ? (hour >= quietStart && hour < quietEnd)
            : (hour >= quietStart || hour < quietEnd)
    }

    func dueReminder() -> Reminder? {
        guard !isSuppressed else { return nil }
        let now = Date()
        return reminders
            .filter { $0.enabled && $0.nextDue <= now }
            .min { $0.nextDue < $1.nextDue }
    }

    func nextUpcoming() -> Reminder? {
        reminders.filter(\.enabled).min { $0.nextDue < $1.nextDue }
    }
}
