// Comptes rendus de reunion ecrits par Claude, via Claude Code installe sur le Mac (avec l'abonnement Claude).
// Seul le texte de la transcription est envoye a Claude, jamais l'audio.

import AppKit

/// Lance `claude -p` en arriere-plan, sans outils : Claude lit le texte et repond, rien d'autre.
enum ClaudeCLI {
    static var path: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.local/bin/claude", "\(home)/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(prompt: String, input: String, timeout: TimeInterval = 600) async throws -> String {
        guard let path else { throw MeetingError("Claude Code n'est pas installé sur ce Mac.") }
        let workDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Dictee")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = ["-p", prompt, "--tools", "", "--no-session-persistence", "--strict-mcp-config",
                                     "--output-format", "text"]
                process.currentDirectoryURL = workDir
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                process.environment = environment
                let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = stderr
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                stdin.fileHandleForWriting.write(Data(input.utf8))
                try? stdin.fileHandleForWriting.close()
                let output = stdout.fileHandleForReading.readDataToEndOfFile()
                let errors = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0, !text.isEmpty {
                    continuation.resume(returning: text)
                } else {
                    let detail = (text + " " + String(decoding: errors, as: UTF8.self)).lowercased()
                    let message = detail.contains("login") || detail.contains("auth") || detail.contains("log in")
                        ? "Claude Code n'est pas connecté : ouvre le Terminal, tape claude puis connecte-toi."
                        : detail.contains("limit") ? "Limite d'utilisation de Claude atteinte : nouvel essai plus tard."
                        : "Claude n'a pas répondu : nouvel essai plus tard."
                    NSLog("Emile: claude a echoue (\(process.terminationStatus)): \(detail.prefix(300))")
                    continuation.resume(throwing: MeetingError(message))
                }
            }
        }
    }
}

// MARK: - Compte rendu

struct MeetingSummary {
    var title: String
    var sections: [(heading: String, lines: [String])]

    static let prompt = """
    Tu reçois sur l'entrée standard la transcription automatique d'une réunion de travail, en français. \
    Chaque ligne commence par l'heure et la personne qui parle. « Interlocuteurs » regroupe les autres \
    participants d'une visio ; « Participants » désigne tout le monde quand la réunion était en présentiel. \
    La reconnaissance vocale peut faire des erreurs : corrige les mots évidents, mais n'invente rien.

    Écris le compte rendu de cette réunion. Réponds uniquement dans ce format, sans rien avant ni après :
    TITRE: un titre court qui dit de quoi parle la réunion
    # Résumé
    trois à six phrases qui racontent l'essentiel
    # Décisions
    - une décision par ligne
    # Tâches
    - qui fait quoi, et pour quand si c'est dit
    # Chiffres et infos clés
    - prix, dates, quantités, objectifs, noms de produits
    # Personnes et entreprises citées
    - nom : rôle ou contexte
    # Questions en suspens
    - ce qui reste à trancher ou à vérifier
    Si une partie est vide, écris « - Rien de noté. »
    """

    /// Lit la reponse de Claude : TITRE, puis des parties « # » avec des lignes.
    init(parsing text: String) {
        var title = ""
        var sections: [(String, [String])] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.uppercased().hasPrefix("TITRE:") {
                title = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("#") {
                sections.append((line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")), []))
            } else {
                if sections.isEmpty { sections.append(("Résumé", [])) }
                sections[sections.count - 1].1.append(line.replacingOccurrences(of: "**", with: ""))
            }
        }
        self.title = title
        self.sections = sections
    }

    func document(for transcript: MeetingFile) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let orange = NSColor(red: 0.85, green: 0.38, blue: 0, alpha: 1)
        let gray = NSColor(white: 0.45, alpha: 1)
        func font(_ size: CGFloat, _ bold: Bool) -> NSFont {
            NSFont(name: bold ? "Arial-BoldMT" : "ArialMT", size: size) ?? .systemFont(ofSize: size, weight: bold ? .bold : .regular)
        }
        func add(_ string: String, size: CGFloat = 11, bold: Bool = false, color: NSColor = .black,
                 before: CGFloat = 0, after: CGFloat = 6, indent: CGFloat = 0) {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = before
            style.paragraphSpacing = after
            style.lineSpacing = 2
            style.headIndent = indent
            text.append(NSAttributedString(string: string + "\n", attributes: [
                .font: font(size, bold), .foregroundColor: color, .paragraphStyle: style,
            ]))
        }

        let shownTitle = transcript.title != "Réunion" ? transcript.title : (title.isEmpty ? "Réunion" : title)
        add("Compte rendu · \(shownTitle)", size: 20, bold: true, after: 4)
        var info: [String] = []
        if let date = transcript.date { info.append(MeetingSummary.dayFormatter.string(from: date).capitalizedFirst) }
        if !transcript.author.isEmpty { info.append("transcrit par \(transcript.author)") }
        info.append("transcription : \(transcript.url.deletingPathExtension().lastPathComponent)")
        add(info.joined(separator: " · "), size: 10, color: gray, after: 14)

        for section in sections {
            add(section.heading, size: 13, bold: true, color: orange, before: 8, after: 4)
            for line in section.lines {
                if line.hasPrefix("- ") || line.hasPrefix("• ") {
                    add("•  " + line.dropFirst(2), indent: 14)
                } else {
                    add(line)
                }
            }
        }
        add("Compte rendu écrit automatiquement par Claude à partir de la transcription. Vérifie les points importants.",
            size: 9, color: gray, before: 14)
        return text
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "EEEE d MMMM yyyy 'à' HH'h'mm"
        return formatter
    }()
}

func docxData(_ text: NSAttributedString) -> Data? {
    try? text.data(from: NSRange(location: 0, length: text.length),
                   documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
}

func readDocx(_ url: URL) -> NSAttributedString? {
    try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                            documentAttributes: nil)
}

// MARK: - Service

/// Cherche les transcriptions sans compte rendu et les fait resumer par Claude, une a la fois.
final class SummaryService: ObservableObject {
    static let shared = SummaryService()
    static let journalName = "00_Journal des réunions.docx"

    enum State: Equatable {
        case waiting, working, done, skipped, failed(String)
    }

    @Published private(set) var states: [String: State] = [:]
    @Published private(set) var summaryCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var busy = false
    private var urgent: Set<String> = []
    private var failedAt: [String: Date] = [:]
    private var timer: Timer?

    var enabled: Bool { UserDefaults.standard.bool(forKey: Pref.summaryEnabled) }
    var available: Bool { ClaudeCLI.path != nil }

    /// Ou ranger les comptes rendus : 08_RESUMES a cote de 07_TRANSCRIPTIONS, sinon un sous-dossier « Résumés ».
    static func folder(for transcripts: URL) -> URL {
        if transcripts.lastPathComponent == "07_TRANSCRIPTIONS" {
            return transcripts.deletingLastPathComponent().appendingPathComponent("08_RESUMES", isDirectory: true)
        }
        return transcripts.appendingPathComponent("Résumés", isDirectory: true)
    }

    static var folder: URL { folder(for: MeetingFolder.current()) }
    static var journal: URL { folder.appendingPathComponent(journalName) }

    func summaryURL(for file: MeetingFile) -> URL { Self.folder.appendingPathComponent(file.url.lastPathComponent) }

    func state(for file: MeetingFile) -> State {
        if FileManager.default.fileExists(atPath: summaryURL(for: file).path) { return .done }
        return states[file.url.lastPathComponent] ?? .waiting
    }

    func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.scan() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.scan() }
    }

    /// Une reunion vient de se terminer sur ce Mac : on la resume tout de suite.
    func summarizeSoon(_ url: URL) {
        urgent.insert(url.lastPathComponent)
        states[url.lastPathComponent] = .waiting
        scan()
    }

    /// Cherche le travail a faire. Les fichiers d'autres Mac attendent 10 minutes sans changement :
    /// ainsi on ne resume pas une reunion encore en cours, et celui qui l'a enregistree s'en charge d'abord.
    func scan(force: Bool = false) {
        guard enabled, available, !busy else { return }
        let transcripts = MeetingFolder.current()
        let summaries = Self.folder(for: transcripts)
        let skipped = Set(UserDefaults.standard.stringArray(forKey: Pref.summarySkipped) ?? [])
        let files = (try? FileManager.default.contentsOfDirectory(
            at: transcripts, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        let done = Set((try? FileManager.default.contentsOfDirectory(atPath: summaries.path)) ?? [])
        summaryCount = done.filter { $0.hasSuffix(".docx") && $0 != Self.journalName }.count

        let candidates = files.filter { $0.pathExtension.lowercased() == "docx" }.filter { url in
            let name = url.lastPathComponent
            guard !done.contains(name), !skipped.contains(name), url != appModel.meeting?.fileURL else { return false }
            if let failed = failedAt[name], Date().timeIntervalSince(failed) < 1800, !force { return false }
            if urgent.contains(name) || force { return true }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            return Date().timeIntervalSince(modified) > 600
        }
        .sorted { a, b in urgent.contains(a.lastPathComponent) && !urgent.contains(b.lastPathComponent) }

        for url in candidates where states[url.lastPathComponent] == nil { states[url.lastPathComponent] = .waiting }
        guard let next = candidates.first else { return }
        busy = true
        states[next.lastPathComponent] = .working
        Task { @MainActor in
            await self.summarize(next, into: summaries)
            self.busy = false
            self.scan(force: force)
        }
    }

    @MainActor
    private func summarize(_ url: URL, into summaries: URL) async {
        let name = url.lastPathComponent
        urgent.remove(name)
        let file = MeetingFile(url: url)
        guard let transcript = readDocx(url)?.string, transcript.split(whereSeparator: \.isWhitespace).count >= 40 else {
            // Trop court pour un compte rendu : on ne reessaie pas.
            var skipped = UserDefaults.standard.stringArray(forKey: Pref.summarySkipped) ?? []
            skipped.append(name)
            UserDefaults.standard.set(skipped, forKey: Pref.summarySkipped)
            states[name] = .skipped
            return
        }
        do {
            let reply = try await ClaudeCLI.run(prompt: MeetingSummary.prompt, input: transcript)
            let summary = MeetingSummary(parsing: reply)
            guard !summary.sections.isEmpty, let data = docxData(summary.document(for: file)) else {
                throw MeetingError("Réponse de Claude illisible : nouvel essai plus tard.")
            }
            try FileManager.default.createDirectory(at: summaries, withIntermediateDirectories: true)
            try data.write(to: summaries.appendingPathComponent(name), options: .atomic)
            states[name] = .done
            lastError = nil
            summaryCount += 1
            rebuildJournal(in: summaries)
        } catch {
            failedAt[name] = Date()
            let message = (error as? MeetingError)?.message ?? error.localizedDescription
            states[name] = .failed(message)
            lastError = message
        }
    }

    /// Le journal rassemble tous les comptes rendus, du plus recent au plus ancien, dans un seul fichier.
    func rebuildJournal(in summaries: URL) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: summaries.path)) ?? [])
            .filter { $0.hasSuffix(".docx") && $0 != Self.journalName }
            .sorted(by: >)
        let journal = NSMutableAttributedString()
        let title = NSFont(name: "Arial-BoldMT", size: 22) ?? .boldSystemFont(ofSize: 22)
        let small = NSFont(name: "ArialMT", size: 10) ?? .systemFont(ofSize: 10)
        journal.append(NSAttributedString(string: "Journal des réunions\n", attributes: [.font: title]))
        journal.append(NSAttributedString(
            string: "Tous les comptes rendus, du plus récent au plus ancien. Mis à jour automatiquement par Emile à chaque nouveau compte rendu.\n\n",
            attributes: [.font: small, .foregroundColor: NSColor(white: 0.45, alpha: 1)]))
        for name in names {
            guard let summary = readDocx(summaries.appendingPathComponent(name)) else { continue }
            journal.append(summary)
            journal.append(NSAttributedString(string: "\n――――――――――――――――――――\n\n",
                                              attributes: [.font: small, .foregroundColor: NSColor(white: 0.7, alpha: 1)]))
        }
        if let data = docxData(journal) {
            try? data.write(to: summaries.appendingPathComponent(Self.journalName), options: .atomic)
        }
    }

    // Pour le mode test : resume un fichier tout de suite, ou il se trouve.
    func summarizeForTest(_ url: URL, into folder: URL, completion: @escaping (State) -> Void) {
        Task { @MainActor in
            await summarize(url, into: folder)
            completion(states[url.lastPathComponent] ?? .waiting)
        }
    }
}
