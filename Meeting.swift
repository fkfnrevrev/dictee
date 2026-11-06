// Mode reunion : le micro et le son de l'ordi sont transcrits en local, par morceaux d'environ 30 secondes.
// L'audio n'est jamais ecrit sur disque : seul le texte est garde, dans un fichier Word du dossier choisi.

import AppKit
import AVFoundation
import ScreenCaptureKit

enum MeetingMode: String, CaseIterable {
    /// Visio : le micro (toi) et le son de l'ordi (les autres) sont separes.
    case online
    /// Tout le monde dans la meme piece : un seul micro.
    case room

    var label: String { self == .online ? "En ligne" : "En présentiel" }
    var symbol: String { self == .online ? "video" : "person.2" }
}

struct Utterance {
    var start: Double
    var speaker: String
    var text: String
}

struct LiveMeeting {
    var startedAt: Date
    var mode: MeetingMode
    var lines: [Utterance] = []
    var words = 0
    var warning: String?
    var saving = false
    var fileURL: URL
}

struct MeetingError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Audio

/// Convertit n'importe quel flux audio en 16 kHz mono 16 bits, le format attendu par Whisper.
final class Resampler {
    static let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private let converter: AVAudioConverter
    private let inputRate: Double

    init?(from format: AVAudioFormat) {
        guard format.sampleRate > 0, let converter = AVAudioConverter(from: format, to: Self.target) else { return nil }
        self.converter = converter
        inputRate = format.sampleRate
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / inputRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: capacity) else { return [] }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.int16ChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

/// Capte le son qui sort du Mac (Zoom, Meet, Teams...) avec ScreenCaptureKit.
/// L'image de l'ecran n'est pas utilisee : macOS l'exige juste pour ouvrir le flux.
final class SystemAudio: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var samples: [Int16] = []
    private let lock = NSLock()
    private var resampler: Resampler?
    private var format: AVAudioFormat?
    private let queue = DispatchQueue(label: "emile.son-de-l-ordi")
    var onFailure: ((Error) -> Void)?

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw MeetingError("Aucun écran trouvé") }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                              configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              var description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              let incoming = AVAudioFormat(streamDescription: &description)
        else { return }
        if format != incoming {
            format = incoming
            resampler = Resampler(from: incoming)
        }
        try? sampleBuffer.withAudioBufferList { list, _ in
            guard let resampler,
                  let pcm = AVAudioPCMBuffer(pcmFormat: incoming, bufferListNoCopy: list.unsafePointer)
            else { return }
            pcm.frameLength = AVAudioFrameCount(sampleBuffer.numSamples)
            let chunk = resampler.convert(pcm)
            lock.withLock { samples.append(contentsOf: chunk) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onFailure?(error) }
    }

    func take() -> [Int16] {
        lock.withLock {
            let chunk = samples
            samples.removeAll(keepingCapacity: true)
            return chunk
        }
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }
}

/// Accumule l'audio d'une personne et le coupe en morceaux, de preference sur une pause.
final class MeetingTrack {
    let speaker: String
    private var buffer: [Int16] = []
    /// Position du debut du buffer, en echantillons depuis le debut de la reunion.
    var offset = 0
    private let rate = 16000

    init(speaker: String) { self.speaker = speaker }

    func append(_ samples: [Int16], force: Bool) -> (start: Double, samples: [Int16])? {
        buffer.append(contentsOf: samples)
        let pause = buffer.count >= 20 * rate && rms(buffer.suffix(rate / 2)) < 150
        guard !buffer.isEmpty, force || pause || buffer.count >= 40 * rate else { return nil }
        let chunk = (Double(offset) / Double(rate), buffer)
        offset += buffer.count
        buffer = []
        return chunk
    }

    private func rms(_ slice: ArraySlice<Int16>) -> Double {
        guard !slice.isEmpty else { return 0 }
        return (slice.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(slice.count)).squareRoot()
    }
}

/// Repere les passages ou quelqu'un parle, par fenetres de 100 ms.
/// Whisper date mal une phrase precedee d'un long silence, et invente parfois du texte sur le silence.
func voiceRegions(_ samples: [Int16], rate: Int = 16000) -> [Range<Int>] {
    let window = rate / 10
    guard samples.count >= window else { return [] }
    var energies: [Double] = []
    var index = 0
    while index + window <= samples.count {
        var sum = 0.0
        for i in index..<(index + window) { sum += Double(samples[i]) * Double(samples[i]) }
        energies.append((sum / Double(window)).squareRoot())
        index += window
    }
    // Le seuil suit le bruit de fond de la piece (le 20e centile), avec un minimum.
    let floor = energies.sorted()[energies.count / 5]
    let threshold = max(120, floor * 3)
    var regions: [Range<Int>] = []
    var start: Int?
    var lastVoiced = 0
    for (i, energy) in energies.enumerated() {
        guard energy > threshold else { continue }
        if let s = start, i - lastVoiced > 12 {
            regions.append(s..<(lastVoiced + 1))
            start = i
        } else if start == nil {
            start = i
        }
        lastVoiced = i
    }
    if let s = start { regions.append(s..<(lastVoiced + 1)) }
    // Marge de 200 ms autour de chaque passage ; les bruits de moins de 400 ms sont ignores.
    return regions.filter { $0.count >= 4 }.map { region in
        max(0, (region.lowerBound - 2) * window)..<min(samples.count, (region.upperBound + 2) * window)
    }
}

// MARK: - Transcription

/// Phrases que Whisper invente parfois sur du bruit ou du silence.
private let hallucinations = ["merci.", "merci", "merci !", "sous-titrage", "sous-titres", "merci d'avoir regardé",
                              "abonnez-vous", "...", "musique", "applaudissements"]

/// Transcrit un morceau et le decoupe en phrases datees depuis le debut de la reunion.
func transcribeUtterances(_ samples: [Int16], start: Double, speaker: String, language: String) async throws -> [Utterance] {
    let json = try await inference(wav: wavData(from: samples), language: language, format: "verbose_json",
                                   prompt: "Réunion de travail, avec une ponctuation correcte.")
    let segments = json["segments"] as? [[String: Any]] ?? []
    var result: [Utterance] = []
    var current = ""
    var currentStart = 0.0

    func flush() {
        let text = cleaned(current)
        current = ""
        let lowered = text.lowercased()
        guard !text.isEmpty,
              !hallucinations.contains(where: { lowered.hasPrefix($0) && lowered.count < $0.count + 12 })
        else { return }
        result.append(Utterance(start: start + currentStart, speaker: speaker, text: text))
    }

    for segment in segments {
        guard let text = segment["text"] as? String else { continue }
        if current.isEmpty { currentStart = segment["start"] as? Double ?? 0 }
        // Whisper coupe parfois au milieu d'un mot : on recolle tel quel, puis on coupe sur la ponctuation.
        current += text.replacingOccurrences(of: "\n", with: "")
        if let last = current.trimmingCharacters(in: .whitespaces).last, ".?!…".contains(last) { flush() }
    }
    flush()
    return result
}

/// Sans casque, le micro reprend la voix des autres : on retire ces doublons du cote du micro.
func removingEcho(_ utterances: [Utterance], mic: String) -> [Utterance] {
    func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 })
    }
    let others = utterances.filter { $0.speaker != mic }.map { ($0.start, words($0.text)) }
    return utterances.filter { utterance in
        guard utterance.speaker == mic else { return true }
        let mine = words(utterance.text)
        guard !mine.isEmpty else { return true }
        return !others.contains { start, theirs in
            abs(start - utterance.start) < 6
                && Double(mine.intersection(theirs).count) / Double(max(1, min(mine.count, theirs.count))) >= 0.5
        }
    }
}

// MARK: - Fichier Word

enum MeetingDocument {
    static let fileFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "yyyy-MM-dd HH'h'mm"
        return formatter
    }()

    static func fileName(date: Date, title: String, author: String) -> String {
        let safe = { (text: String) in
            text.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var parts = [fileFormatter.string(from: date)]
        if !safe(title).isEmpty { parts.append(safe(title)) }
        parts.append(safe(author).isEmpty ? "Emile" : safe(author))
        return parts.joined(separator: " – ") + ".docx"
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                             : String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Met en page la transcription : titre, infos, puis une ligne par prise de parole.
    static func data(title: String, date: Date, author: String, mode: MeetingMode, duration: Double,
                     utterances: [Utterance]) -> Data? {
        let text = NSMutableAttributedString()
        let font = { (size: CGFloat, bold: Bool) -> NSFont in
            NSFont(name: bold ? "Arial-BoldMT" : "ArialMT", size: size) ?? .systemFont(ofSize: size, weight: bold ? .bold : .regular)
        }
        let orange = NSColor(red: 0.85, green: 0.38, blue: 0, alpha: 1)
        let blue = NSColor(red: 0.16, green: 0.33, blue: 0.62, alpha: 1)
        let gray = NSColor(white: 0.45, alpha: 1)

        func paragraph(spacing: CGFloat) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = spacing
            style.lineSpacing = 2
            return style
        }
        func add(_ string: String, size: CGFloat, bold: Bool = false, color: NSColor = .black, spacing: CGFloat = 8) {
            text.append(NSAttributedString(string: string, attributes: [
                .font: font(size, bold), .foregroundColor: color, .paragraphStyle: paragraph(spacing: spacing),
            ]))
        }

        let day = DateFormatter()
        day.locale = Locale(identifier: "fr_FR")
        day.dateFormat = "EEEE d MMMM yyyy 'à' HH'h'mm"
        let heading = title.trimmingCharacters(in: .whitespaces).isEmpty ? "Réunion" : title
        add(heading + "\n", size: 20, bold: true, spacing: 4)
        let minutes = max(1, Int((duration / 60).rounded()))
        add("\(day.string(from: date).capitalizedFirst) · \(minutes) min · \(mode.label.lowercased()) · transcrit par \(author) avec Emile\n",
            size: 10, color: gray, spacing: 18)

        // Les phrases d'une meme personne qui se suivent forment un seul paragraphe.
        var blocks: [Utterance] = []
        for utterance in utterances.sorted(by: { $0.start < $1.start }) {
            if var last = blocks.last, last.speaker == utterance.speaker, utterance.start - last.start < 90 {
                last.text += " " + utterance.text
                blocks[blocks.count - 1] = last
            } else {
                blocks.append(utterance)
            }
        }
        if blocks.isEmpty { add("Rien n'a encore été transcrit.\n", size: 11, color: gray) }
        for block in blocks {
            add(timestamp(block.start) + "   ", size: 9, color: gray)
            add(block.speaker, size: 11, bold: true, color: block.speaker == author ? orange : blue)
            add("  " + block.text + "\n", size: 11, spacing: 10)
        }

        return try? text.data(from: NSRange(location: 0, length: text.length),
                              documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Dossier

enum MeetingFolder {
    /// Dossier partage de l'equipe, cherche dans Google Drive pour ordinateur.
    static let teamPath = "VENTILO DRIVE/07_TRANSCRIPTIONS"
    static let fallback = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Réunions Emile", isDirectory: true)

    /// Dossier Drive trouve automatiquement, s'il existe.
    static func detectDrive() -> URL? {
        let storage = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        let accounts = (try? FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)) ?? []
        for account in accounts where account.lastPathComponent.hasPrefix("GoogleDrive") {
            for root in ["Mon Drive", "My Drive", "Mon disque", "Drive partagés", "Shared drives"] {
                let candidate = account.appendingPathComponent(root).appendingPathComponent(teamPath, isDirectory: true)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    /// Le dossier choisi dans les reglages, sinon le Drive de l'equipe, sinon Documents.
    static func current() -> URL {
        let chosen = UserDefaults.standard.string(forKey: Pref.meetingFolder) ?? ""
        if !chosen.isEmpty, FileManager.default.fileExists(atPath: chosen) { return URL(fileURLWithPath: chosen, isDirectory: true) }
        return detectDrive() ?? fallback
    }

    static func isCloud(_ url: URL) -> Bool { url.path.contains("/Library/CloudStorage/") }

    /// Chemin lisible, a partir du Drive : « VENTILO DRIVE › 07_TRANSCRIPTIONS ».
    static func shortPath(_ url: URL) -> String {
        let parts = url.pathComponents
        if let index = parts.firstIndex(where: { $0.hasPrefix("GoogleDrive") }), index + 2 < parts.count {
            return parts[(index + 2)...].joined(separator: " › ")
        }
        return url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }
}

// MARK: - Session

/// Une reunion en cours : recoit l'audio, le transcrit morceau par morceau et reecrit le fichier a chaque fois.
final class MeetingSession {
    let mode: MeetingMode
    let author: String
    let startedAt: Date
    let language: String
    private(set) var fileURL: URL
    private let folder: URL
    private let mic = Recorder()
    private let system = SystemAudio()
    private let micTrack: MeetingTrack
    private let systemTrack: MeetingTrack
    private var utterances: [Utterance] = []
    private var timer: Timer?
    private var chain: Task<Void, Never>?
    private var capturing = false
    private(set) var failures = 0
    var micLabel: String { micTrack.speaker }

    /// Appele sur le fil principal a chaque nouveau morceau transcrit.
    var onUpdate: (([Utterance]) -> Void)?
    var onWarning: ((String) -> Void)?
    var onLevel: ((Double) -> Void)?

    init(mode: MeetingMode, author: String, folder: URL, language: String, startedAt: Date = Date()) {
        self.mode = mode
        self.author = author
        self.folder = folder
        self.language = language
        self.startedAt = startedAt
        micTrack = MeetingTrack(speaker: mode == .online ? author : "Participants")
        systemTrack = MeetingTrack(speaker: "Interlocuteurs")
        fileURL = folder.appendingPathComponent(MeetingDocument.fileName(date: startedAt, title: "", author: author))
    }

    var transcript: [Utterance] {
        mode == .online ? removingEcho(utterances, mic: micTrack.speaker) : utterances
    }

    var wordCount: Int { transcript.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count } }

    /// Ouvre le micro et, en visio, le son de l'ordi. Renvoie une alerte si le son de l'ordi manque.
    func start() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        mic.onLevel = { [weak self] level in self?.onLevel?(level) }
        try mic.start()
        capturing = true
        if mode == .online {
            do {
                if !CGPreflightScreenCaptureAccess() {
                    CGRequestScreenCaptureAccess()
                    throw MeetingError("Autorise Emile dans « Enregistrement de l'écran » pour capter la voix des autres, puis relance Emile.")
                }
                system.onFailure = { [weak self] _ in self?.onWarning?("Le son de l'ordi s'est coupé : seul ton micro est transcrit.") }
                try await system.start()
                systemTrack.offset = Int(Date().timeIntervalSince(startedAt) * 16000)
            } catch {
                onWarning?((error as? MeetingError)?.message ?? "Son de l'ordi indisponible : seul ton micro est transcrit.")
            }
        }
        DispatchQueue.main.async {
            self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    private func tick() {
        feed(mic: mic.take(), system: system.take(), final: false)
    }

    /// Ajoute de l'audio et lance la transcription des morceaux prets.
    func feed(mic micSamples: [Int16], system systemSamples: [Int16], final: Bool) {
        for (track, samples) in [(micTrack, micSamples), (systemTrack, systemSamples)] {
            guard let chunk = track.append(samples, force: final), !isSilent(chunk.samples) else { continue }
            // On n'envoie que les passages parles, chacun avec son heure exacte.
            for region in voiceRegions(chunk.samples) {
                enqueue(Array(chunk.samples[region]), start: chunk.start + Double(region.lowerBound) / 16000,
                        speaker: track.speaker)
            }
        }
    }

    private func enqueue(_ samples: [Int16], start: Double, speaker: String) {
        let previous = chain
        let language = self.language
        chain = Task { @MainActor [weak self] in
            await previous?.value
            do {
                let found = try await transcribeUtterances(samples, start: start, speaker: speaker, language: language)
                guard let self else { return }
                self.utterances += found
                self.save()
                self.onUpdate?(self.transcript)
            } catch {
                self?.failures += 1
                self?.onWarning?("Un passage n'a pas pu être transcrit.")
                NSLog("Emile: reunion: \(error)")
            }
        }
    }

    /// Reecrit le fichier Word avec tout ce qui a ete transcrit.
    @discardableResult
    func save(title: String = "") -> Bool {
        guard !utterances.isEmpty,
              let data = MeetingDocument.data(title: title, date: startedAt, author: author, mode: mode,
                                              duration: Date().timeIntervalSince(startedAt), utterances: transcript)
        else { return false }
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            onWarning?("Impossible d'écrire dans le dossier des réunions.")
            NSLog("Emile: ecriture reunion: \(error)")
            return false
        }
    }

    /// Termine la reunion : transcrit la fin, attend les morceaux en cours et renomme le fichier avec le titre.
    func stop(title: String, completion: @escaping (URL?) -> Void) {
        timer?.invalidate()
        if capturing {
            let rest = mic.stop()
            let systemRest = system.take()
            Task { await system.stop() }
            capturing = false
            feed(mic: rest, system: systemRest, final: true)
        }
        let previous = chain
        Task { @MainActor in
            await previous?.value
            guard self.save(title: title) else {
                completion(nil)
                return
            }
            let named = self.folder.appendingPathComponent(
                MeetingDocument.fileName(date: self.startedAt, title: title, author: self.author))
            if named != self.fileURL, (try? FileManager.default.moveItem(at: self.fileURL, to: named)) != nil {
                self.fileURL = named
            }
            completion(self.fileURL)
        }
    }

    /// Sauvegarde d'urgence quand Emile quitte en pleine reunion.
    func emergencySave() {
        timer?.invalidate()
        _ = mic.stop()
        save()
    }
}

// MARK: - Liste des reunions du dossier

struct MeetingFile: Identifiable, Hashable {
    let url: URL
    let date: Date?
    let title: String
    let author: String
    var id: URL { url }

    init(url: URL) {
        self.url = url
        let parts = url.deletingPathExtension().lastPathComponent.components(separatedBy: " – ")
        date = parts.first.flatMap { MeetingDocument.fileFormatter.date(from: $0) }
        if date != nil, parts.count >= 2 {
            author = parts.last ?? ""
            title = parts.count >= 3 ? parts[1..<(parts.count - 1)].joined(separator: " – ") : "Réunion"
        } else {
            author = ""
            title = url.deletingPathExtension().lastPathComponent
        }
    }
}

final class MeetingLibrary: ObservableObject {
    static let shared = MeetingLibrary()

    @Published private(set) var files: [MeetingFile] = []
    @Published private(set) var folder = MeetingFolder.current()

    func refresh() {
        let folder = MeetingFolder.current()
        DispatchQueue.global(qos: .utility).async {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
            let files = urls.filter { $0.pathExtension.lowercased() == "docx" }
                .map(MeetingFile.init)
                .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            DispatchQueue.main.async {
                self.folder = folder
                if self.files != files { self.files = files }
            }
        }
    }
}

// MARK: - Chiffres des reunions (jamais le texte)

struct MeetingRecord: Codable {
    var date: Date
    var seconds: Double
    var words: Int
}

final class MeetingLog: ObservableObject {
    static let shared = MeetingLog(url: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Dictee/meetings.jsonl"))

    @Published private(set) var records: [MeetingRecord] = []
    private let url: URL

    init(url: URL) {
        self.url = url
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            records = text.split(separator: "\n").compactMap { try? JSONDecoder().decode(MeetingRecord.self, from: Data($0.utf8)) }
        }
    }

    func add(_ record: MeetingRecord) {
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

    /// Reunions des 7 derniers jours : nombre et minutes.
    func week(now: Date = Date()) -> (count: Int, minutes: Int) {
        let recent = records.filter { now.timeIntervalSince($0.date) < 7 * 86400 }
        return (recent.count, Int((recent.reduce(0) { $0 + $1.seconds } / 60).rounded()))
    }
}
