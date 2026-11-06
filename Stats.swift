// Statistiques de dictee : seulement des chiffres (date, mots, duree, app), jamais le texte dicte.

import AppKit
import SwiftUI

struct DictationRecord: Codable {
    var date: Date
    var words: Int
    var seconds: Double
    var app: String
}

enum AppCategory: String, CaseIterable {
    case ai = "IA", messages = "Messages", email = "E-mails", documents = "Documents"
    case code = "Code", browser = "Navigateur", other = "Autres"

    var symbol: String {
        switch self {
        case .ai: return "sparkles"
        case .messages: return "bubble.left"
        case .email: return "envelope"
        case .documents: return "doc.text"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .browser: return "globe"
        case .other: return "square.grid.2x2"
        }
    }

    /// Range une app dans une categorie d'apres son identifiant (ex. net.whatsapp.WhatsApp).
    static func of(_ bundleID: String) -> AppCategory {
        let id = bundleID.lowercased()
        let table: [(AppCategory, [String])] = [
            (.ai, ["openai", "chatgpt", "anthropic", "perplexity", "gemini", "mistral", "opencode"]),
            (.messages, ["whatsapp", "mobilesms", "slack", "discord", "telegram", "messenger", "signal", "teams"]),
            (.email, ["mail", "outlook", "spark", "superhuman"]),
            (.documents, ["com.apple.notes", "iwork", "com.microsoft.word", "com.microsoft.excel", "com.microsoft.powerpoint",
                          "textedit", "notion", "obsidian", "bear", "figma", "craft"]),
            (.code, ["terminal", "iterm", "vscode", "cursor", "xcode", "zed", "jetbrains", "warp", "ghostty"]),
            (.browser, ["chrome", "safari", "firefox", "thebrowser", "brave", "edgemac", "opera", "vivaldi"]),
        ]
        return table.first { _, keys in keys.contains { id.contains($0) } }?.0 ?? .other
    }
}

final class StatsStore: ObservableObject {
    static let shared = StatsStore(url: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Dictee/stats.jsonl"))

    @Published private(set) var records: [DictationRecord] = []
    private let url: URL

    init(url: URL) {
        self.url = url
        let decoder = JSONDecoder()
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            records = text.split(separator: "\n").compactMap { try? decoder.decode(DictationRecord.self, from: Data($0.utf8)) }
        }
    }

    func add(words: Int, seconds: Double, app: String) {
        add(DictationRecord(date: Date(), words: words, seconds: seconds, app: app))
    }

    /// Une ligne JSON par dictee, ajoutee a la fin du fichier.
    func add(_ record: DictationRecord) {
        records.append(record)
        guard var line = try? JSONEncoder().encode(record) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    func clear() {
        records = []
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Calculs

struct StatsSummary {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.locale = Locale(identifier: "fr_FR")
        return calendar
    }()

    let totalWords: Int
    let todayWords: Int
    let dictations: Int
    let wordsPerMinute: Int
    let minutesSaved: Int
    let categories: [(category: AppCategory, count: Int, share: Double)]
    let dayWords: [Date: Int]
    let currentStreak: Int
    let longestStreak: Int

    init(_ records: [DictationRecord], now: Date = Date()) {
        let calendar = Self.calendar
        let today = calendar.startOfDay(for: now)
        totalWords = records.reduce(0) { $0 + $1.words }
        let totalSeconds = records.reduce(0) { $0 + $1.seconds }
        dictations = records.count
        wordsPerMinute = totalSeconds > 0 ? Int((Double(totalWords) / (totalSeconds / 60)).rounded()) : 0
        // Estimation : 40 mots par minute au clavier.
        minutesSaved = max(0, Int((Double(totalWords) / 40 - totalSeconds / 60).rounded()))

        var days: [Date: Int] = [:]
        var counts: [AppCategory: Int] = [:]
        for record in records {
            days[calendar.startOfDay(for: record.date), default: 0] += record.words
            counts[AppCategory.of(record.app), default: 0] += 1
        }
        dayWords = days
        todayWords = days[today] ?? 0
        categories = counts.sorted { $0.value > $1.value }
            .map { ($0.key, $0.value, Double($0.value) / Double(max(1, records.count))) }

        // Serie en cours : jours consecutifs jusqu'a aujourd'hui (ou hier si rien encore aujourd'hui).
        var streak = 0
        var day = days[today] != nil ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        while days[day] != nil {
            streak += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        currentStreak = streak

        var longest = 0
        var run = 0
        var previous: Date?
        for day in days.keys.sorted() {
            if let previous, calendar.date(byAdding: .day, value: 1, to: previous) == day { run += 1 } else { run = 1 }
            longest = max(longest, run)
            previous = day
        }
        longestStreak = longest
    }
}

// MARK: - Ecran

let emileOrange = Color(red: 251 / 255, green: 108 / 255, blue: 0)

struct StatsView: View {
    @ObservedObject var stats: StatsStore
    @State private var confirmClear = false

    var body: some View {
        ScrollView {
            StatsContent(summary: StatsSummary(stats.records), onClear: { confirmClear = true })
        }
        .alert("Effacer toutes tes statistiques ?", isPresented: $confirmClear) {
            Button("Effacer", role: .destructive) { stats.clear() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Les chiffres seront supprimés de ce Mac.")
        }
    }
}

struct StatsContent: View {
    let summary: StatsSummary
    var onClear: () -> Void

    var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                Text("Statistiques").font(.largeTitle.weight(.semibold))

                if summary.dictations == 0 {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Pas encore de dictée").font(.title3.weight(.semibold))
                            Text("Maintiens fn, parle, puis relâche : tes chiffres apparaîtront ici.")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        StatCard(value: "\(summary.wordsPerMinute)", label: "MOTS PAR MINUTE",
                                 detail: "En moyenne, sur toutes tes dictées")
                        StatCard(value: summary.totalWords.formatted(), label: "MOTS DICTÉS",
                                 detail: "\(summary.todayWords.formatted()) aujourd'hui · \(summary.dictations.formatted()) dictées")
                        StatCard(value: "\(summary.minutesSaved) min", label: "TEMPS GAGNÉ",
                                 detail: "Estimé face à 40 mots par minute au clavier")
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    HStack(alignment: .top, spacing: 16) {
                        Card {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("Où tu dictes").font(.title2.weight(.semibold))
                                ForEach(summary.categories, id: \.category) { item in
                                    CategoryRow(category: item.category, count: item.count, share: item.share,
                                                fill: item.share / max(0.01, summary.categories.first?.share ?? 1))
                                }
                            }
                        }
                        Card {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(summary.currentStreak > 1 ? "Série de \(summary.currentStreak) jours"
                                         : summary.currentStreak == 1 ? "Série de 1 jour" : "Pas de série en cours")
                                        .font(.title2.weight(.semibold))
                                    Spacer()
                                    Text("RECORD : \(summary.longestStreak) J")
                                        .font(.caption.weight(.medium)).tracking(1).foregroundStyle(.secondary)
                                }
                                Heatmap(dayWords: summary.dayWords)
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Spacer()
                        Button("Effacer mes statistiques", action: onClear)
                    }
                }

                Text("Seuls des chiffres sont gardés, sur ce Mac : la date, le nombre de mots, la durée et l'app. Jamais le texte dicté.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

struct StatCard: View {
    let value: String
    let label: String
    let detail: String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text(value).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(label).font(.caption.weight(.medium)).tracking(1.2).foregroundStyle(.secondary)
                Divider().padding(.vertical, 6)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct CategoryRow: View {
    let category: AppCategory
    let count: Int
    let share: Double
    /// Longueur de la barre, la plus utilisee remplissant toute la largeur.
    let fill: Double

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category.symbol).frame(width: 20).foregroundStyle(.secondary)
            Text(category.rawValue).frame(width: 90, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.12))
                    Capsule().fill(emileOrange.opacity(0.4 + 0.6 * fill))
                        .frame(width: max(6, proxy.size.width * fill))
                }
            }
            .frame(height: 10)
            Text("\(Int((share * 100).rounded())) %").monospacedDigit().frame(width: 44, alignment: .trailing)
            Text("\(count)").monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
        }
    }
}

/// Une case par jour sur les 20 dernieres semaines, plus orange quand tu as beaucoup dicte.
struct Heatmap: View {
    let dayWords: [Date: Int]
    private let weeks = 20
    private let cell: CGFloat = 13

    var body: some View {
        let calendar = StatsSummary.calendar
        let today = calendar.startOfDay(for: Date())
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)!.start
        let first = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek)!
        let maximum = max(1, dayWords.values.max() ?? 1)
        let monthFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "fr_FR")
            formatter.dateFormat = "MMM"
            return formatter
        }()

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 3) {
                VStack(spacing: 3) {
                    Text(" ").font(.caption2).frame(height: 14)
                    ForEach(["L", "M", "M", "J", "V", "S", "D"].indices, id: \.self) { i in
                        Text(["L", "M", "M", "J", "V", "S", "D"][i])
                            .font(.caption2).foregroundStyle(.secondary).frame(width: 14, height: cell)
                    }
                }
                ForEach(0..<weeks, id: \.self) { week in
                    let weekStart = calendar.date(byAdding: .day, value: week * 7, to: first)!
                    let monthStarts = (0..<7).contains { calendar.component(.day, from: calendar.date(byAdding: .day, value: $0, to: weekStart)!) == 1 }
                    VStack(spacing: 3) {
                        Text(monthStarts ? monthFormatter.string(from: calendar.date(byAdding: .day, value: 6, to: weekStart)!) : " ")
                            .font(.caption2).foregroundStyle(.secondary).fixedSize().frame(width: cell, height: 14)
                        ForEach(0..<7, id: \.self) { offset in
                            let day = calendar.date(byAdding: .day, value: week * 7 + offset, to: first)!
                            RoundedRectangle(cornerRadius: 3)
                                .fill(color(for: day, today: today, maximum: maximum))
                                .frame(width: cell, height: cell)
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                Text("Moins").font(.caption).foregroundStyle(.secondary)
                ForEach([0.0, 0.3, 0.55, 0.8, 1.0], id: \.self) { level in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(level == 0 ? Color.secondary.opacity(0.12) : emileOrange.opacity(level))
                        .frame(width: 11, height: 11)
                }
                Text("Plus").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func color(for day: Date, today: Date, maximum: Int) -> Color {
        if day > today { return .clear }
        guard let words = dayWords[day], words > 0 else { return Color.secondary.opacity(0.12) }
        let ratio = Double(words) / Double(maximum)
        let level = ratio > 0.75 ? 1.0 : ratio > 0.5 ? 0.8 : ratio > 0.25 ? 0.55 : 0.3
        return emileOrange.opacity(level)
    }
}
