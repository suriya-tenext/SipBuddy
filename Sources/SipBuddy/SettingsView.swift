import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            RemindersTab().tabItem { Label("Reminders", systemImage: "bell") }
            BuddiesTab().tabItem { Label("Buddies", systemImage: "person.3") }
            BuilderTab().tabItem { Label("Hero Builder", systemImage: "paintpalette") }
            StudioTab().tabItem { Label("AI Studio", systemImage: "sparkles") }
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
        }
        .padding()
        .frame(width: 720, height: 620)
    }
}

// MARK: - Reminders

private struct RemindersTab: View {
    @ObservedObject private var state = AppState.shared

    private func binding(_ id: UUID) -> Binding<Reminder> {
        Binding(
            get: { state.reminder(id) ?? .placeholder },
            set: { new in
                if let i = state.reminders.firstIndex(where: { $0.id == id }) { state.reminders[i] = new }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.reminders.isEmpty {
                ContentUnavailableView("No reminders", systemImage: "bell.slash",
                                       description: Text("Add one below and your buddy will nudge you."))
            } else {
                List {
                    ForEach(state.reminders) { r in
                        ReminderRow(reminder: binding(r.id), todayCount: state.count(for: r.id)) {
                            state.reminders.removeAll { $0.id == r.id }
                        }
                    }
                }
            }
            HStack {
                Menu("Add reminder") {
                    ForEach(Reminder.presets) { p in
                        Button("\(p.emoji)  \(p.title) · every \(p.intervalMinutes) min") { state.add(p) }
                    }
                    Divider()
                    Button("Custom…") {
                        state.add(Reminder(emoji: "⭐️", title: "Custom", message: "Reminder time!", intervalMinutes: 30))
                    }
                }
                .fixedSize()
                Spacer()
                if state.isSuppressed {
                    Label("Reminders paused right now", systemImage: "moon.zzz").foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ReminderRow: View {
    @Binding var reminder: Reminder
    let todayCount: Int
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $reminder.enabled).labelsHidden()
            TextField("", text: $reminder.emoji)
                .frame(width: 36)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Title", text: $reminder.title).font(.headline)
                TextField("What should your buddy say?", text: $reminder.message).font(.callout)
            }
            Stepper("every \(reminder.intervalMinutes) min", value: $reminder.intervalMinutes, in: 5...480, step: 5)
                .fixedSize()
            Text("\(todayCount) today")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 54)
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .textFieldStyle(.plain)
    }
}

// MARK: - Buddies

/// Shared list of saved buddies so every tab sees new ones immediately.
@MainActor
final class LibraryModel: ObservableObject {
    static let shared = LibraryModel()
    @Published private(set) var names = CharacterLibrary.names()
    @Published var error: String?
    /// Which roster the Buddies tab shows; starts on the one the current buddy belongs to.
    @Published var showHeroines = CharacterLibrary.look(AppState.shared.selectedCharacter)?.isFeminine ?? false
    func reload() { names = CharacterLibrary.names() }
}

private struct BuddiesTab: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var brain = BuddyBrain.shared
    @ObservedObject private var library = LibraryModel.shared

    private let columns = [GridItem(.adaptive(minimum: 118), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                personalityBox
                HStack {
                    Picker("", selection: $library.showHeroines) {
                        Text("Heroes").tag(false)
                        Text("Heroines").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    Text("Size")
                    Slider(value: $state.buddyHeight, in: 100...360).frame(width: 160)
                }
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach((library.showHeroines ? HeroLook.heroines : HeroLook.heroes).map { "hero:\($0.id)" }, id: \.self) { thumb($0) }
                }
                HStack {
                    Text("Your buddies").font(.headline)
                    Spacer()
                    Button("Import sheet…") { importSheet() }
                }
                if library.names.isEmpty {
                    Text("Make one in Hero Builder or AI Studio.").foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(library.names, id: \.self) { thumb($0) }
                    }
                }
                if let error = library.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .padding(.horizontal, 4)
        }
    }

    private func thumb(_ name: String) -> some View {
        CharacterThumb(name: name, selected: state.selectedCharacter == name)
            .onTapGesture { state.selectedCharacter = name }
            .contextMenu {
                if !CharacterLibrary.isPreset(name) {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([CharacterLibrary.url(name)])
                    }
                    Button("Delete", role: .destructive) { delete(name) }
                }
            }
    }

    private var personalityBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Personality").font(.headline)
                    Spacer()
                    if brain.isRefreshing {
                        ProgressView().controlSize(.small)
                        Text("Claude is writing new lines…").font(.caption).foregroundStyle(.secondary)
                    } else if let n = brain.pack?.idle.count, n > 0 {
                        Text("✓ \(n) idle lines + reminder lines ready").font(.caption).foregroundStyle(.secondary)
                    } else if !brain.isAvailable {
                        Text("Add an Anthropic key in General to give your buddy a voice").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    ForEach(AppState.personalities, id: \.0) { label, value in
                        Button(label) { state.personality = value }
                            .buttonStyle(.bordered)
                            .tint(state.personality == value ? .accentColor : nil)
                    }
                }
                TextField("Or describe your own personality", text: $state.personality, axis: .vertical)
                    .lineLimit(1...2)
                    .textFieldStyle(.roundedBorder)
                if let e = brain.lastError {
                    Text(e).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(6)
        }
    }

    private func importSheet() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Pick a sprite sheet: row 1 = walk cycle facing right, row 2 = drinking (optional)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let name = try CharacterLibrary.importSheet(from: url)
            library.reload()
            state.selectedCharacter = name
        } catch {
            library.error = error.localizedDescription
        }
    }

    private func delete(_ name: String) {
        if state.selectedCharacter == name { state.selectedCharacter = CharacterLibrary.defaultName }
        CharacterLibrary.delete(name)
        library.reload()
    }
}

// MARK: - Hero Builder

@MainActor
private final class HeroBuilderModel: ObservableObject {
    @Published var look: HeroLook
    @Published var previewAnim: Anim? = nil
    @Published var savedName: String?

    init() {
        let start = CharacterLibrary.look(AppState.shared.selectedCharacter) ?? HeroLook.presets[1]
        look = start
    }

    func randomize() {
        func color() -> RGB {
            let c = NSColor(hue: .random(in: 0...1), saturation: .random(in: 0.45...0.85),
                            brightness: .random(in: 0.45...0.95), alpha: 1)
            return RGB(color: Color(nsColor: c))
        }
        let skins: [UInt32] = [0xFFE0C2, 0xF2C6A0, 0xE0B48C, 0xC68A5E, 0x8D5A3B, 0x6B4430]
        let hairs: [UInt32] = [0x1B1B1B, 0x3A2A1A, 0x5A3A2A, 0xF4D06F, 0xF2582A, 0xDDEEFF, 0x9B59D0, 0x3FA7D6]
        var l = look
        l.skin = RGB(skins.randomElement()!)
        l.hair = RGB(hairs.randomElement()!)
        l.hairStyle = HeroLook.Hair.allCases.randomElement()!
        l.suit = color(); l.accent = color(); l.pants = Bool.random() ? l.suit : color()
        l.boots = Bool.random() ? l.accent : color(); l.gloves = Bool.random() ? l.accent : l.skin
        l.cape = Bool.random() ? color() : nil
        l.mask = HeroLook.Mask.allCases.randomElement()!
        l.maskColor = Bool.random() ? l.accent : color()
        l.ears = [.none, .none, .pointy, .cat, .antenna].randomElement()!
        l.emblem = HeroLook.Emblem.allCases.randomElement()!
        l.emblemColor = Bool.random() ? l.accent : RGB(0xFFFFFF)
        l.glasses = Int.random(in: 0..<5) == 0
        l.belt = Bool.random()
        l.cup = color()
        look = l
    }
}

private extension RGB {
    init(color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(r: UInt8(ns.redComponent * 255), g: UInt8(ns.greenComponent * 255), b: UInt8(ns.blueComponent * 255))
    }
    var color: Color { Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }
}

private struct BuilderTab: View {
    @ObservedObject private var state = AppState.shared
    @StateObject private var model = HeroBuilderModel()

    private func color(_ kp: WritableKeyPath<HeroLook, RGB>) -> Binding<Color> {
        Binding(get: { model.look[keyPath: kp].color }, set: { model.look[keyPath: kp] = RGB(color: $0) })
    }

    private func option<T>(_ kp: WritableKeyPath<HeroLook, T?>, _ fallback: T) -> Binding<T> {
        Binding(get: { model.look[keyPath: kp] ?? fallback }, set: { model.look[keyPath: kp] = $0 })
    }

    private var capeOn: Binding<Bool> {
        Binding(get: { model.look.cape != nil },
                set: { model.look.cape = $0 ? (model.look.cape ?? model.look.accent) : nil })
    }

    private var capeColor: Binding<Color> {
        Binding(get: { (model.look.cape ?? model.look.accent).color }, set: { model.look.cape = RGB(color: $0) })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 10) {
                HeroPreview(look: model.look, anim: model.previewAnim)
                    .frame(width: 230, height: 290)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.secondary.opacity(0.08)))
                Picker("", selection: $model.previewAnim) {
                    Text("All").tag(Anim?.none)
                    ForEach(Anim.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Anim?.some($0)) }
                }
                .labelsHidden()
                .frame(width: 200)
                HStack {
                    Menu("Start from") {
                        ForEach(HeroLook.presets, id: \.id) { p in Button(p.name) { model.look = p } }
                    }
                    Button("🎲 Random") { model.randomize() }
                }
                .frame(width: 200)
                Button(model.savedName == nil ? "Save & use this hero" : "Saved ✓") { save() }
                    .buttonStyle(.borderedProminent)
                    .frame(width: 200)
            }

            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Name")
                        TextField("Hero name", text: $model.look.name).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Tagline")
                        TextField("Catchphrase", text: $model.look.tagline).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Voice")
                        TextField("How they talk", text: $model.look.voice).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Attitude")
                        Picker("", selection: option(\.attitude, .cheerful)) {
                            ForEach(HeroLook.Attitude.allCases, id: \.self) { Text($0.rawValue.capitalized) }
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 260)
                    }
                    Divider().gridCellColumns(2)
                    GridRow {
                        Text("Body")
                        HStack {
                            Picker("", selection: option(\.figure, .masculine)) {
                                Text("Male").tag(HeroLook.Figure.masculine)
                                Text("Female").tag(HeroLook.Figure.feminine)
                            }.pickerStyle(.segmented).labelsHidden().frame(width: 130)
                            Picker("", selection: option(\.build, .regular)) {
                                ForEach(HeroLook.Build.allCases, id: \.self) { Text($0.rawValue.capitalized) }
                            }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
                            Picker("", selection: option(\.outfit, .bodysuit)) {
                                ForEach(HeroLook.Outfit.allCases, id: \.self) { o in
                                    Text(o == .tux ? "Suit & tie" : o == .bare ? "Bare" : o == .armor ? "Armor" : "Bodysuit")
                                }
                            }.labelsHidden().frame(width: 120)
                        }
                    }
                    GridRow {
                        Text("Skin")
                        ColorPicker("", selection: color(\.skin), supportsOpacity: false).labelsHidden()
                    }
                    GridRow {
                        Text("Hair")
                        HStack {
                            Picker("", selection: $model.look.hairStyle) {
                                ForEach(HeroLook.Hair.allCases, id: \.self) { Text($0.rawValue.capitalized) }
                            }.labelsHidden().frame(width: 130)
                            ColorPicker("", selection: color(\.hair), supportsOpacity: false).labelsHidden()
                        }
                    }
                    GridRow {
                        Text("Mask")
                        HStack {
                            Picker("", selection: $model.look.mask) {
                                ForEach(HeroLook.Mask.allCases, id: \.self) { Text($0.rawValue.capitalized) }
                            }.labelsHidden().frame(width: 130)
                            ColorPicker("", selection: color(\.maskColor), supportsOpacity: false).labelsHidden()
                            Toggle("Glasses", isOn: $model.look.glasses)
                            Toggle("Beard", isOn: option(\.beard, false))
                        }
                    }
                    GridRow {
                        Text("Ears")
                        Picker("", selection: $model.look.ears) {
                            ForEach(HeroLook.Ears.allCases, id: \.self) { Text($0.rawValue.capitalized) }
                        }.labelsHidden().frame(width: 130)
                    }
                    Divider().gridCellColumns(2)
                    GridRow {
                        Text("Suit")
                        HStack {
                            ColorPicker("Main", selection: color(\.suit), supportsOpacity: false)
                            ColorPicker("Accent", selection: color(\.accent), supportsOpacity: false)
                            Toggle("Belt", isOn: $model.look.belt)
                        }
                    }
                    GridRow {
                        Text("Emblem")
                        HStack {
                            Picker("", selection: $model.look.emblem) {
                                ForEach(HeroLook.Emblem.allCases, id: \.self) { Text($0.rawValue.capitalized) }
                            }.labelsHidden().frame(width: 130)
                            ColorPicker("", selection: color(\.emblemColor), supportsOpacity: false).labelsHidden()
                        }
                    }
                    GridRow {
                        Text("Cape")
                        HStack {
                            Toggle("", isOn: capeOn).labelsHidden()
                            ColorPicker("", selection: capeColor, supportsOpacity: false).labelsHidden()
                                .disabled(model.look.cape == nil)
                        }
                    }
                    GridRow {
                        Text("Below")
                        HStack {
                            ColorPicker("Pants", selection: color(\.pants), supportsOpacity: false)
                            ColorPicker("Boots", selection: color(\.boots), supportsOpacity: false)
                            ColorPicker("Gloves", selection: color(\.gloves), supportsOpacity: false)
                        }
                    }
                    GridRow {
                        Text("Cup")
                        ColorPicker("", selection: color(\.cup), supportsOpacity: false).labelsHidden()
                    }
                }
                .padding(.trailing, 8)
            }
        }
        .padding(.top, 6)
        .onChange(of: model.look) { model.savedName = nil }
    }

    private func save() {
        guard let name = try? CharacterLibrary.saveHero(model.look) else { return }
        LibraryModel.shared.reload()
        state.selectedCharacter = name
        model.savedName = name
    }
}

/// Live plush preview: cycles through every animation, or loops one.
private struct HeroPreview: View {
    let look: HeroLook
    let anim: Anim?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let current = anim ?? Anim.allCases[Int(t / 3) % Anim.allCases.count]
            VStack(spacing: 6) {
                if let image = HeroRenderer.image(look, PoseLibrary.preview(current, t), height: 480) {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 240)
                }
                Text(current.rawValue).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - AI Studio

@MainActor
private final class StudioModel: ObservableObject {
    @Published var notes = ""
    @Published var selfieURL: URL?
    let designer = CharacterDesigner()
}

private struct StudioTab: View {
    @StateObject private var model = StudioModel()

    var body: some View {
        ScrollView {
            StudioBox(model: model, designer: model.designer)
                .padding(.horizontal, 4)
        }
    }
}

/// Selfie + notes in, live progress of the AI pipeline out.
private struct StudioBox: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var designer: CharacterDesigner
    @ObservedObject private var state = AppState.shared

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("AI Character Studio", systemImage: "wand.and.stars").font(.headline)
                    Spacer()
                    Text("Claude directs · \(state.imageModel) paints").font(.caption).foregroundStyle(.secondary)
                }
                Text("Turn a selfie into a fully animated buddy. Claude designs the character, the image model paints it, and Claude reviews every animation.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 12) {
                    selfieWell
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Anything to add? e.g. \"make me a wizard\", \"wearing my red hoodie\", \"cat ears\"",
                                  text: $model.notes, axis: .vertical)
                            .lineLimit(3...4)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button(designer.isRunning ? "Creating…" : "Create my buddy") { create() }
                                .buttonStyle(.borderedProminent)
                                .disabled(designer.isRunning || (model.selfieURL == nil && model.notes.trimmingCharacters(in: .whitespaces).isEmpty))
                            Text("≈ 6–12 image generations · 2–4 min").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !designer.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(designer.steps) { step in StepRow(step: step) }
                    }
                    .padding(.top, 4)
                }
                if let error = designer.error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .padding(6)
        }
    }

    private var selfieWell: some View {
        Button { pickSelfie() } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.1))
                if let url = model.selfieURL, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "person.crop.circle.badge.plus").font(.title)
                        Text("Selfie").font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(width: 96, height: 96)
        }
        .buttonStyle(.plain)
        .contextMenu { if model.selfieURL != nil { Button("Remove selfie") { model.selfieURL = nil } } }
    }

    private func pickSelfie() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK { model.selfieURL = panel.url }
    }

    private func create() {
        guard let anthropic = APIKeyStore.anthropic.load(), let openAI = APIKeyStore.openAI.load() else {
            designer.error = "Add both API keys in the General tab first (Anthropic for Claude, OpenAI for images)."
            return
        }
        Task {
            do {
                let selfie = try model.selfieURL.map { try ImageFiles.pngData(from: $0, maxSide: 1024) }
                if let name = await designer.run(selfie: selfie, notes: model.notes, anthropicKey: anthropic,
                                                 openAIKey: openAI, imageModel: state.imageModel) {
                    LibraryModel.shared.reload()
                    state.selectedCharacter = name
                }
            } catch {
                designer.error = error.localizedDescription
            }
        }
    }
}

private struct StepRow: View {
    let step: CharacterDesigner.Step

    var body: some View {
        HStack(spacing: 8) {
            Group {
                switch step.state {
                case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
                case .working: ProgressView().controlSize(.mini)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
            .frame(width: 16)
            Text(step.title)
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .font(.callout)
    }

    private var detail: String {
        switch step.state {
        case .waiting: ""
        case .working(let s): s
        case .done(let s): s ?? "done"
        case .failed(let s): s
        }
    }
}

private struct CharacterThumb: View {
    let name: String
    let selected: Bool

    var body: some View {
        let puppet = CharacterLibrary.puppet(name)
        let bible = CharacterLibrary.bible(name)
        VStack(spacing: 4) {
            TimelineView(.animation(minimumInterval: selected ? 1 / 30 : 1 / 8)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                switch puppet {
                case .rig(let look):
                    // The selected buddy walks; the rest idle (blink, breathe).
                    let pose = selected ? PoseLibrary.walk(phase: t * 7.5, t) : PoseLibrary.idle(t + Double(abs(name.hashValue % 100)))
                    if let image = HeroRenderer.image(look, pose, height: 220) {
                        Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fit)
                    }
                case .frames(let set):
                    let frame = set.frame(.walk, at: t)
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .interpolation(frame.height < 90 ? .none : .high)
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: 96, height: 100)
            Text(name.hasSuffix(".png") ? "Imported" : bible.name).font(.caption).lineLimit(1)
                .help(bible.tagline)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(selected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }
}

// MARK: - General

@MainActor
private final class KeysModel: ObservableObject {
    @Published var anthropic = APIKeyStore.anthropic.load() ?? ""
    @Published var openAI = APIKeyStore.openAI.load() ?? ""
    @Published var saved = false
}

private struct GeneralTab: View {
    @ObservedObject private var state = AppState.shared
    @StateObject private var keys = KeysModel()

    var body: some View {
        Form {
            Section("Buddy") {
                Slider(value: $state.walkSpeed, in: 15...120) { Text("Walk speed") }
                Toggle("Play a sound when a reminder pops up", isOn: $state.soundEnabled)
            }
            Section("Quiet hours") {
                Toggle("Let my buddy sleep during quiet hours", isOn: $state.quietHoursEnabled)
                Picker("From", selection: $state.quietStart) { hourOptions }
                    .disabled(!state.quietHoursEnabled)
                Picker("Until", selection: $state.quietEnd) { hourOptions }
                    .disabled(!state.quietHoursEnabled)
            }
            Section {
                SecureField("Anthropic API key (Claude: design, QA, personality, chat)", text: $keys.anthropic)
                SecureField("OpenAI API key (image generation)", text: $keys.openAI)
                TextField("Image model", text: $state.imageModel)
                HStack {
                    Spacer()
                    Button(keys.saved ? "Saved ✓" : "Save keys") {
                        APIKeyStore.anthropic.save(keys.anthropic)
                        APIKeyStore.openAI.save(keys.openAI)
                        keys.saved = true
                        BuddyBrain.shared.refreshIfNeeded()
                    }
                }
            } header: {
                Text("AI")
            } footer: {
                Text("Keys are stored in your macOS Keychain. Claude model: \(Claude.model).")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: keys.anthropic) { keys.saved = false }
        .onChange(of: keys.openAI) { keys.saved = false }
    }

    private var hourOptions: some View {
        ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
    }
}
