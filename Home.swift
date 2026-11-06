// Accueil (dashboard) et liste des reunions.

import AppKit
import Combine
import SwiftUI

/// Meme degrade que la barre : orange #FB6C00 qui se fond dans le noir.
let emileGradient = LinearGradient(stops: [
    .init(color: emileOrange, location: 0),
    .init(color: Color(red: 0.42, green: 0.15, blue: 0.02), location: 0.55),
    .init(color: Color(red: 0.05, green: 0.05, blue: 0.05), location: 1),
], startPoint: .topLeading, endPoint: .bottomTrailing)

// MARK: - Accueil

struct HomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var stats: StatsStore
    @ObservedObject var library: MeetingLibrary
    @ObservedObject var log: MeetingLog
    var onSeeAll: () -> Void
    private let refresh = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            HomeContent(model: model, summary: StatsSummary(stats.records), files: library.files,
                        folder: library.folder, week: log.week(), onSeeAll: onSeeAll)
        }
        .onAppear {
            library.refresh()
            model.refreshPermissions()
        }
        .onReceive(refresh) { _ in
            library.refresh()
            model.refreshPermissions()
        }
    }
}

struct HomeContent: View {
    @ObservedObject var model: AppModel
    let summary: StatsSummary
    let files: [MeetingFile]
    let folder: URL
    let week: (count: Int, minutes: Int)
    var onSeeAll: () -> Void
    @AppStorage(Pref.userName) private var userName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            MeetingHero(model: model, folder: folder)
            if let saved = model.lastSavedMeeting, model.meeting == nil {
                SavedBanner(url: saved) { model.lastSavedMeeting = nil }
            }
            HStack(alignment: .top, spacing: 18) {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Dernières réunions").font(.title2.weight(.semibold))
                            Spacer()
                            if files.count > 5 {
                                Button("Tout voir", action: onSeeAll).buttonStyle(.link)
                            }
                        }
                        .padding(.bottom, 6)
                        if files.isEmpty {
                            EmptyMeetings()
                        } else {
                            ForEach(Array(files.prefix(5).enumerated()), id: \.element.id) { index, file in
                                if index > 0 { Divider().padding(.leading, 50) }
                                MeetingRow(file: file, live: file.url == model.meeting?.fileURL)
                            }
                        }
                    }
                }
                VStack(spacing: 18) {
                    WeekCard(week: week, todayWords: summary.todayWords)
                    FolderCard(folder: folder)
                }
                .frame(width: 290)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(maxWidth: 980, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting).font(.system(size: 30, weight: .semibold))
                Text(Self.dayFormatter.string(from: Date()).capitalizedFirst).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Pill(symbol: "flame.fill", text: summary.currentStreak > 0 ? "\(summary.currentStreak) j" : "0 j", tint: emileOrange)
                Pill(symbol: "text.cursor", text: "\(summary.totalWords.formatted()) mots", tint: .secondary)
                Pill(symbol: "bolt.fill", text: "\(summary.wordsPerMinute) mots/min", tint: .secondary)
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let name = userName.trimmingCharacters(in: .whitespaces)
        let hello = hour >= 18 || hour < 5 ? "Bonsoir" : "Bonjour"
        return name.isEmpty ? hello : "\(hello) \(name)"
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "EEEE d MMMM"
        return formatter
    }()
}

struct Pill: View {
    let symbol: String
    let text: String
    var tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).monospacedDigit()
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
    }
}

// MARK: Grande carte reunion

struct MeetingHero: View {
    @ObservedObject var model: AppModel
    let folder: URL

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 22).fill(emileGradient)
            HeroWave(level: model.meeting != nil ? model.level : 0.18, live: model.meeting != nil)
                .frame(width: 300, height: 120)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 28)
                .allowsHitTesting(false)
            Group {
                if let meeting = model.meeting { live(meeting) } else { idle }
            }
            .padding(26)
        }
        .frame(maxWidth: .infinity, minHeight: 210)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .shadow(color: emileOrange.opacity(0.18), radius: 18, y: 8)
        .environment(\.colorScheme, .dark)
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RÉUNIONS").font(.caption.weight(.semibold)).tracking(1.6).foregroundStyle(.white.opacity(0.7))
            Text("Transcris ta prochaine réunion")
                .font(.system(size: 28, weight: .semibold)).foregroundStyle(.white)
            Text("Le son reste sur ton Mac. Seul le texte part dans \(MeetingFolder.shortPath(folder)).")
                .foregroundStyle(.white.opacity(0.75))
                .frame(maxWidth: 460, alignment: .leading)
            HStack(spacing: 10) {
                ForEach(MeetingMode.allCases, id: \.self) { mode in
                    Button { model.onStartMeeting?(mode) } label: {
                        Label(mode.label, systemImage: mode.symbol)
                    }
                    .buttonStyle(HeroButton(primary: mode == .online))
                    .disabled(model.phase != .idle)
                }
                Text("ou double-appuie sur fn").font(.callout).foregroundStyle(.white.opacity(0.6)).padding(.leading, 4)
            }
            .padding(.top, 6)
            if !model.screenAudioGranted {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2")
                    Text("En ligne, Emile a besoin de « Enregistrement de l'écran » pour entendre les autres.")
                    Button("Autoriser") { openScreenRecordingSettings() }.buttonStyle(.link).foregroundStyle(.white)
                }
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.top, 2)
            }
        }
    }

    private func live(_ meeting: LiveMeeting) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Circle().fill(Color(red: 1, green: 0.3, blue: 0.25)).frame(width: 8, height: 8)
                Text(meeting.saving ? "ENREGISTREMENT…" : "EN COURS · \(meeting.mode.label.uppercased())")
                    .font(.caption.weight(.semibold)).tracking(1.6)
            }
            .foregroundStyle(.white.opacity(0.85))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(MeetingDocument.timestamp(context.date.timeIntervalSince(meeting.startedAt)))
                    .font(.system(size: 46, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white)
            }
            TextField("Nom de la réunion (facultatif)", text: $model.meetingTitle)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Capsule().fill(.white.opacity(0.12)))
                .foregroundStyle(.white)
                .frame(maxWidth: 380)
            VStack(alignment: .leading, spacing: 5) {
                if meeting.lines.isEmpty {
                    Text("Le texte apparaît ici toutes les 30 secondes environ.").foregroundStyle(.white.opacity(0.6))
                } else {
                    ForEach(Array(meeting.lines.suffix(3).enumerated()), id: \.offset) { _, line in
                        (Text(line.speaker).bold() + Text("  " + line.text))
                            .foregroundStyle(.white.opacity(0.88))
                            .lineLimit(2)
                    }
                }
            }
            .font(.callout)
            .frame(maxWidth: 440, alignment: .leading)
            if let warning = meeting.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(Color(red: 1, green: 0.85, blue: 0.5))
            }
            HStack(spacing: 12) {
                if meeting.saving {
                    ProgressView().controlSize(.small)
                    Text("On transcrit la fin…").foregroundStyle(.white.opacity(0.75))
                } else {
                    Button { model.onStopMeeting?() } label: { Label("Arrêter et enregistrer", systemImage: "stop.fill") }
                        .buttonStyle(HeroButton(primary: true))
                    Text("\(meeting.words) mots").font(.callout).foregroundStyle(.white.opacity(0.6)).monospacedDigit()
                }
            }
            .padding(.top, 2)
        }
    }
}

struct HeroButton: ButtonStyle {
    var primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 16).padding(.vertical, 9)
            .foregroundStyle(primary ? Color.black : Color.white)
            .background(Capsule().fill(primary ? Color.white : Color.white.opacity(0.14)))
            .overlay(Capsule().strokeBorder(.white.opacity(primary ? 0 : 0.22)))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

/// Grandes barres decoratives a droite de la carte ; elles suivent la voix pendant une reunion.
struct HeroWave: View {
    var level: Double
    var live: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !live)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 6) {
                ForEach(0..<18, id: \.self) { i in
                    let shape = 0.35 + 0.65 * sin(Double(i) / 17 * .pi)
                    let wobble = live ? 0.6 + 0.4 * sin(t * 5 + Double(i) * 0.7) : 0.75 + 0.25 * sin(Double(i) * 1.9)
                    Capsule()
                        .fill(.white.opacity(0.13))
                        .frame(width: 6, height: max(6, 120 * shape * wobble * (live ? 0.35 + 0.65 * level : 0.6)))
                }
            }
        }
    }
}

struct SavedBanner: View {
    let url: URL
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Réunion enregistrée").font(.headline)
                Text(url.lastPathComponent).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Ouvrir") { NSWorkspace.shared.open(url) }
            Button("Afficher") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button { onClose() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.green.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.green.opacity(0.25)))
    }
}

struct WeekCard: View {
    let week: (count: Int, minutes: Int)
    let todayWords: Int

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("CETTE SEMAINE").font(.caption.weight(.medium)).tracking(1.2).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(week.count)").font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(week.count > 1 ? "réunions" : "réunion").foregroundStyle(.secondary)
                }
                Divider()
                row("clock", week.minutes >= 60 ? "\(week.minutes / 60) h \(String(format: "%02d", week.minutes % 60)) transcrites"
                                                : "\(week.minutes) min transcrites")
                row("mic", "\(todayWords.formatted()) mots dictés aujourd'hui")
            }
        }
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.callout).foregroundStyle(.secondary)
    }
}

struct FolderCard: View {
    let folder: URL

    var body: some View {
        let cloud = MeetingFolder.isCloud(folder)
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("DOSSIER").font(.caption.weight(.medium)).tracking(1.2).foregroundStyle(.secondary)
                Label(cloud ? "Synchronisé avec Google Drive" : "Drive pas encore relié",
                      systemImage: cloud ? "checkmark.icloud.fill" : "exclamationmark.icloud.fill")
                    .font(.headline)
                    .foregroundStyle(cloud ? Color.green : emileOrange)
                Text(cloud ? MeetingFolder.shortPath(folder)
                     : "Installe Google Drive pour ordinateur, puis ajoute VENTILO DRIVE à « Mon Drive ». En attendant, les réunions vont dans Documents.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Ouvrir le dossier") {
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(folder)
                }
                .padding(.top, 2)
            }
        }
    }
}

struct EmptyMeetings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "waveform").font(.title).foregroundStyle(emileOrange)
            Text("Pas encore de réunion").font(.headline)
            Text("Lance-en une ci-dessus : le fichier Word apparaîtra ici, et chez Noé aussi.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 18)
    }
}

// MARK: Ligne de reunion

struct MeetingRow: View {
    let file: MeetingFile
    var live = false
    @State private var hover = false

    var body: some View {
        Button { NSWorkspace.shared.open(file.url) } label: {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 9)
                    .fill(emileOrange.opacity(0.12))
                    .frame(width: 36, height: 36)
                    .overlay(Image(systemName: live ? "record.circle" : "doc.text.fill")
                        .foregroundStyle(live ? Color.red : emileOrange))
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.title).font(.body.weight(.medium)).lineLimit(1)
                    Text(live ? "En cours…" : Self.when(file.date)).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if !file.author.isEmpty { Avatar(name: file.author) }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .opacity(hover ? 1 : 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hover ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Ouvrir") { NSWorkspace.shared.open(file.url) }
            Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
        }
    }

    static func when(_ date: Date?) -> String {
        guard let date else { return "" }
        let calendar = Calendar.current
        let time = DateFormatter()
        time.locale = Locale(identifier: "fr_FR")
        time.dateFormat = "HH'h'mm"
        if calendar.isDateInToday(date) { return "Aujourd'hui, \(time.string(from: date))" }
        if calendar.isDateInYesterday(date) { return "Hier, \(time.string(from: date))" }
        time.dateFormat = "EEE d MMM, HH'h'mm"
        return time.string(from: date)
    }
}

struct Avatar: View {
    let name: String

    var body: some View {
        // Toi en orange, les autres en bleu, comme dans les fichiers Word.
        let me = UserDefaults.standard.string(forKey: Pref.userName) ?? ""
        let color = name.caseInsensitiveCompare(me) == .orderedSame ? emileOrange : Color(red: 0.25, green: 0.5, blue: 0.95)
        HStack(spacing: 6) {
            Circle().fill(color.opacity(0.18)).frame(width: 24, height: 24)
                .overlay(Text(String(name.prefix(1)).uppercased()).font(.caption.weight(.bold)).foregroundStyle(color))
            Text(name).font(.callout).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Page Reunions

struct MeetingsView: View {
    @ObservedObject var library: MeetingLibrary
    @ObservedObject var model: AppModel
    @State private var query = ""
    private let refresh = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            MeetingsContent(files: library.files, folder: library.folder, live: model.meeting?.fileURL, query: $query)
        }
        .onAppear { library.refresh() }
        .onReceive(refresh) { _ in library.refresh() }
    }
}

struct MeetingsContent: View {
    let files: [MeetingFile]
    let folder: URL
    var live: URL?
    @Binding var query: String

    private var filtered: [MeetingFile] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return files }
        return files.filter { $0.title.localizedCaseInsensitiveContains(text) || $0.author.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Réunions").font(.largeTitle.weight(.semibold))
                    Text("\(files.count) transcription\(files.count > 1 ? "s" : "") dans \(MeetingFolder.shortPath(folder))")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(folder)
                } label: { Label("Ouvrir le dossier", systemImage: "folder") }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Chercher une réunion ou une personne", text: $query).textFieldStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))

            Card {
                VStack(alignment: .leading, spacing: 0) {
                    if filtered.isEmpty {
                        if files.isEmpty { EmptyMeetings() } else {
                            Text("Aucune réunion ne correspond.").foregroundStyle(.secondary).padding(.vertical, 12)
                        }
                    }
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, file in
                        if index > 0 { Divider().padding(.leading, 50) }
                        MeetingRow(file: file, live: file.url == live)
                    }
                }
            }
            Text("Demande à Claude : « résume ma dernière réunion » ou « qu'a-t-on décidé avec ce client ? ». Il lit ces fichiers dans le Drive.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(maxWidth: 980, alignment: .leading)
    }
}
