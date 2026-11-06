// Emile : maintiens fn, parle, relache. Le texte s'ecrit au curseur.
// Tout reste sur le Mac : whisper-server n'ecoute que sur 127.0.0.1 et l'audio n'est jamais ecrit sur disque.

import ApplicationServices
import AVFoundation
import Cocoa
import ServiceManagement

let hotkeyKeycode: Int64 = 63  // fn (globe), en bas a gauche du clavier
let hotkeyFlag = CGEventFlags.maskSecondaryFn.rawValue
let minimumDuration: TimeInterval = 0.3
let maximumDuration: TimeInterval = 300
let maximumMeeting: TimeInterval = 4 * 3600
/// Deux appuis brefs sur fn dans ce delai demarrent ou arretent une reunion.
let doubleTapWindow: TimeInterval = 0.4
let serverPort = 8178
let serverBase = URL(string: "http://127.0.0.1:\(serverPort)")!
let serverBinary = "/opt/homebrew/bin/whisper-server"
let modelPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Dictee/models/ggml-large-v3-turbo-q5_0.bin").path

// MARK: - Serveur Whisper local

final class WhisperServer {
    private var process: Process?
    private var stopping = false

    func isReady() async -> Bool {
        var request = URLRequest(url: serverBase.appendingPathComponent("health"))
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Reutilise un serveur deja lance, sinon en demarre un.
    func start() async {
        if await isReady() { return }
        launch()
    }

    private func launch() {
        guard !stopping else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: serverBinary)
        p.arguments = ["-m", modelPath, "--host", "127.0.0.1", "--port", String(serverPort)]
        // Les logs du serveur contiennent le texte dicte : on ne les garde pas.
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.launch() }
        }
        do {
            try p.run()
            process = p
        } catch {
            NSLog("Emile: impossible de lancer whisper-server: \(error)")
        }
    }

    func waitUntilReady(timeout: TimeInterval = 120) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await isReady() { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }

    func stop() {
        stopping = true
        process?.terminationHandler = nil
        process?.terminate()
    }
}

func transcribe(wav: Data, language: String) async throws -> String {
    let json = try await inference(wav: wav, language: language, format: "json",
                                   prompt: "Bonjour, voici une dictée avec une ponctuation correcte.")
    guard let text = json["text"] as? String else { throw invalidResponse }
    return cleaned(text)
}

private let invalidResponse = NSError(domain: "Dictee", code: 1, userInfo: [NSLocalizedDescriptionKey: "Réponse invalide du serveur"])

/// Envoie un WAV au serveur Whisper local et renvoie sa reponse JSON.
func inference(wav: Data, language: String, format: String, prompt: String) async throws -> [String: Any] {
    let boundary = "dictee-\(UUID().uuidString)"
    var body = Data()
    func field(_ name: String, _ value: String) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
    }
    field("language", language)
    field("response_format", format)
    if language == "fr" { field("prompt", prompt) }
    body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
    body.append(wav)
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

    var request = URLRequest(url: serverBase.appendingPathComponent("inference"))
    request.httpMethod = "POST"
    request.timeoutInterval = 300
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.httpBody = body

    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200,
          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw invalidResponse }
    return json
}

/// Retire les annotations et les textes que Whisper invente sur du silence.
func cleaned(_ raw: String) -> String {
    let text = raw
        .replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.lowercased().hasPrefix("sous-titr") ? "" : text
}

// MARK: - Enregistrement micro (en memoire uniquement)

final class Recorder {
    private var engine: AVAudioEngine?
    private var samples: [Int16] = []
    private let lock = NSLock()
    /// Appele sur le fil principal avec le volume courant, entre 0 et 1.
    var onLevel: ((Double) -> Void)?

    func start() throws {
        lock.withLock { samples.removeAll(keepingCapacity: true) }
        // Un moteur neuf a chaque fois : suit les changements de micro (AirPods, etc.).
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let resampler = Resampler(from: inputFormat) else {
            throw NSError(domain: "Dictee", code: 2, userInfo: [NSLocalizedDescriptionKey: "Micro indisponible"])
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let chunk = resampler.convert(buffer)
            self.lock.withLock { self.samples.append(contentsOf: chunk) }
            if let onLevel = self.onLevel, !chunk.isEmpty {
                let level = audioLevel(chunk)
                DispatchQueue.main.async { onLevel(level) }
            }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// Renvoie les echantillons captes depuis le dernier appel, sans arreter le micro.
    func take() -> [Int16] {
        lock.withLock {
            let chunk = samples
            samples.removeAll(keepingCapacity: true)
            return chunk
        }
    }

    /// Arrete le micro et renvoie les echantillons captes (16 kHz, mono).
    func stop() -> [Int16] {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        return lock.withLock { samples }
    }
}

func wavData(from samples: [Int16], sampleRate: UInt32 = 16000) -> Data {
    func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    let byteCount = UInt32(samples.count * 2)
    var data = Data("RIFF".utf8)
    data += le(36 + byteCount)
    data += Data("WAVEfmt ".utf8)
    data += le(UInt32(16)) + le(UInt16(1)) + le(UInt16(1))
    data += le(sampleRate) + le(sampleRate * 2) + le(UInt16(2)) + le(UInt16(16))
    data += Data("data".utf8)
    data += le(byteCount)
    samples.withUnsafeBytes { data.append(contentsOf: $0) }
    return data
}

/// Volume en dB ramene entre 0 (silence) et 1 (voix forte), pour la barre.
func audioLevel(_ chunk: [Int16]) -> Double {
    guard !chunk.isEmpty else { return 0 }
    let energy = chunk.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(chunk.count)
    let decibels = 20 * log10(max(energy.squareRoot(), 1) / 32768)
    return min(1, max(0, (decibels + 55) / 40))
}

func isSilent(_ samples: [Int16]) -> Bool {
    guard !samples.isEmpty else { return true }
    let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
    return (energy / Double(samples.count)).squareRoot() < 30
}

// MARK: - Application barre de menus

final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum State { case loading, idle, recording, transcribing, meeting }

    private let server = WhisperServer()
    private let recorder = Recorder()
    private let settingsWindow = MainWindow()
    private var overlay: OverlayPanel?
    private var statusItem: NSStatusItem!
    private var state = State.loading { didSet { stateChanged() } }
    private var note: String? { didSet { stateChanged() } }
    private var eventTap: CFMachPort?
    private var permissionTimer: Timer?
    private var startedAt = Date()
    private var limitTimer: Timer?
    private var confirmWork: DispatchWorkItem?
    private var confirmed = false
    private var lastText = ""
    private var meeting: MeetingSession?
    private var meetingLimit: Timer?
    private var fnDownAt: Date?
    private var lastTapUp: Date?
    private var swallowRelease = false

    private var language: String {
        get { UserDefaults.standard.string(forKey: Pref.language) ?? "fr" }
        set { UserDefaults.standard.set(newValue, forKey: Pref.language) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        overlay = OverlayPanel(model: appModel)
        recorder.onLevel = { level in appModel.push(level: level) }
        appModel.onStartMeeting = { [weak self] mode in self?.startMeeting(mode) }
        appModel.onStopMeeting = { [weak self] in self?.stopMeeting() }
        MeetingLibrary.shared.refresh()
        stateChanged()

        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        installEventTap()
        if eventTap == nil {
            // L'autorisation se donne dans Reglages Systeme : on reessaie sans redemarrer l'app.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                self?.installEventTap()
                if self?.eventTap != nil { timer.invalidate() }
            }
        }

        if !launchedAsLoginItem() { settingsWindow.show() }

        Task { @MainActor in
            await server.start()
            if await server.waitUntilReady() {
                state = .idle
            } else {
                note = "Le moteur Whisper n'a pas démarré"
            }
        }
    }

    /// Clic sur l'app alors qu'elle tourne deja : on rouvre les reglages.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        meeting?.emergencySave()
        _ = recorder.stop()
        server.stop()
    }

    private func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    // MARK: Raccourci clavier

    private func installEventTap() {
        guard eventTap == nil, AXIsProcessTrusted() else { return }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, _ in
                controller.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil)
        else { return }
        eventTap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        stateChanged()
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
        case .flagsChanged:
            guard event.getIntegerValueField(.keyboardEventKeycode) == hotkeyKeycode else { return }
            let now = Date()
            if event.flags.rawValue & hotkeyFlag != 0 {
                // Deuxieme appui bref : demarre ou arrete une reunion.
                if let lastTapUp, now.timeIntervalSince(lastTapUp) < doubleTapWindow {
                    self.lastTapUp = nil
                    swallowRelease = true
                    if state == .recording { cancel() }
                    toggleMeeting()
                    return
                }
                fnDownAt = now
                begin()
            } else {
                if swallowRelease {
                    swallowRelease = false
                    return
                }
                let short = fnDownAt.map { now.timeIntervalSince($0) < 0.25 } ?? false
                lastTapUp = short ? now : nil
                fnDownAt = nil
                finish()
            }
        default:
            // fn + autre touche (fleches, F1...) ou clic : c'est un raccourci, pas une dictee.
            lastTapUp = nil
            if state == .recording { cancel() }
        }
    }

    // MARK: Dictee

    private func begin() {
        guard state == .idle else { return }
        do {
            try recorder.start()
        } catch {
            note = error.localizedDescription
            return
        }
        note = nil
        startedAt = Date()
        confirmed = false
        state = .recording
        overlay?.reposition()
        // Le micro demarre tout de suite pour ne pas couper le premier mot, mais le son et la barre
        // attendent un instant : un raccourci comme fn+fleche ne declenche ainsi ni l'un ni l'autre.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .recording else { return }
            self.confirmed = true
            appModel.phase = .recording
            Sounds.play(start: true)
        }
        confirmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        // Securite : le micro ne reste jamais ouvert si le relachement de la touche est manque.
        limitTimer = Timer.scheduledTimer(withTimeInterval: maximumDuration, repeats: false) { [weak self] _ in
            self?.finish()
        }
    }

    private func stopRecording() -> [Int16] {
        confirmWork?.cancel()
        limitTimer?.invalidate()
        let samples = recorder.stop()
        appModel.level = 0
        return samples
    }

    private func cancel() {
        _ = stopRecording()
        state = .idle
    }

    private func finish() {
        guard state == .recording else { return }
        let samples = stopRecording()
        let duration = Date().timeIntervalSince(startedAt)
        let appID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "inconnu"
        if confirmed { Sounds.play(start: false) }
        guard duration >= minimumDuration, !isSilent(samples) else {
            state = .idle
            return
        }
        state = .transcribing
        let language = self.language
        Task { @MainActor in
            do {
                let text = try await transcribe(wav: wavData(from: samples), language: language)
                if !text.isEmpty {
                    lastText = text
                    paste(text + " ")
                    StatsStore.shared.add(words: text.split(whereSeparator: \.isWhitespace).count,
                                          seconds: duration, app: appID)
                }
            } catch {
                note = "Échec de la transcription"
                NSLog("Emile: \(error)")
            }
            state = .idle
        }
    }

    // MARK: Reunion

    private func toggleMeeting() {
        if state == .meeting {
            stopMeeting()
        } else {
            let mode = MeetingMode(rawValue: UserDefaults.standard.string(forKey: Pref.meetingMode) ?? "") ?? .online
            startMeeting(mode)
        }
    }

    private func startMeeting(_ mode: MeetingMode) {
        guard state == .idle else { return }
        let author = UserDefaults.standard.string(forKey: Pref.userName) ?? "Moi"
        let session = MeetingSession(mode: mode, author: author.isEmpty ? "Moi" : author,
                                     folder: MeetingFolder.current(), language: language)
        session.onUpdate = { [weak session] lines in
            appModel.meeting?.lines = Array(lines.suffix(4))
            appModel.meeting?.words = session?.wordCount ?? 0
        }
        session.onWarning = { appModel.meeting?.warning = $0 }
        session.onLevel = { appModel.push(level: $0) }
        meeting = session
        note = nil
        appModel.meetingTitle = ""
        appModel.meeting = LiveMeeting(startedAt: session.startedAt, mode: mode, fileURL: session.fileURL)
        state = .meeting
        overlay?.reposition()
        Sounds.play(start: true)
        meetingLimit = Timer.scheduledTimer(withTimeInterval: maximumMeeting, repeats: false) { [weak self] _ in
            self?.stopMeeting()
        }
        Task { @MainActor in
            do {
                try await session.start()
            } catch {
                meetingLimit?.invalidate()
                meeting = nil
                appModel.meeting = nil
                state = .idle
                note = "Réunion impossible : \(error.localizedDescription)"
            }
            appModel.refreshPermissions()
        }
    }

    private func stopMeeting() {
        guard state == .meeting, let session = meeting else { return }
        meetingLimit?.invalidate()
        appModel.meeting?.saving = true
        appModel.level = 0
        state = .transcribing
        Sounds.play(start: false)
        session.stop(title: appModel.meetingTitle) { [weak self] url in
            guard let self else { return }
            if let url {
                MeetingLog.shared.add(MeetingRecord(date: session.startedAt, seconds: Date().timeIntervalSince(session.startedAt),
                                                    words: session.wordCount))
                appModel.lastSavedMeeting = url
            } else {
                self.note = "Réunion terminée : rien n'a été transcrit"
            }
            self.meeting = nil
            appModel.meeting = nil
            MeetingLibrary.shared.refresh()
            self.state = .idle
        }
    }

    /// Colle le texte avec Cmd+V puis rend au presse-papiers son contenu d'origine.
    private func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // Demande aux gestionnaires de presse-papiers de ne pas historiser la dictee.
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.writeObjects([item])
        let ourChange = pasteboard.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard pasteboard.changeCount == ourChange else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }

    // MARK: Interface

    private var statusText: String {
        if let note { return note }
        switch state {
        case .loading: return "Chargement du modèle…"
        case .idle: return eventTap == nil ? "En attente de l'autorisation Accessibilité" : "Prêt : maintiens fn"
        case .recording: return "Écoute…"
        case .transcribing: return meeting != nil ? "Enregistrement de la réunion…" : "Transcription…"
        case .meeting: return "Réunion en cours : double-appuie sur fn pour arrêter"
        }
    }

    private func stateChanged() {
        switch state {
        case .loading: appModel.phase = .loading
        case .idle: appModel.phase = .idle
        case .recording: break  // la barre s'agrandit apres confirmation, voir begin()
        case .transcribing: appModel.phase = .transcribing
        case .meeting: appModel.phase = .meeting
        }
        appModel.status = statusText
        appModel.accessibilityGranted = eventTap != nil

        let symbol: String
        switch state {
        case .loading: symbol = "hourglass"
        case .idle: symbol = (note != nil || eventTap == nil) ? "exclamationmark.triangle" : "mic"
        case .recording: symbol = "mic.fill"
        case .transcribing: symbol = "text.bubble"
        case .meeting: symbol = "record.circle"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Emile")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.contentTintColor = state == .recording || state == .meeting ? .systemRed : nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(NSMenuItem(title: statusText, action: nil, keyEquivalent: ""))
        addItem(to: menu, "Réglages…", #selector(openSettings), key: ",")
        if eventTap == nil {
            addItem(to: menu, "Autoriser l'accessibilité…", #selector(openAccessibility))
        }
        menu.addItem(.separator())

        if state == .meeting {
            addItem(to: menu, "Arrêter la réunion et l'enregistrer", #selector(stopMeetingFromMenu))
        } else {
            for mode in MeetingMode.allCases {
                let item = addItem(to: menu, "Démarrer une réunion \(mode.label.lowercased())", #selector(startMeetingFromMenu(_:)))
                item.representedObject = mode.rawValue
                item.isEnabled = state == .idle
            }
        }
        addItem(to: menu, "Ouvrir le dossier des réunions", #selector(openMeetingFolder))
        menu.addItem(.separator())

        for (code, name) in [("fr", "Français"), ("en", "English"), ("auto", "Détection automatique")] {
            let item = addItem(to: menu, name, #selector(chooseLanguage(_:)))
            item.representedObject = code
            item.state = language == code ? .on : .off
        }
        menu.addItem(.separator())

        let copy = addItem(to: menu, "Copier la dernière dictée", #selector(copyLast))
        copy.isEnabled = !lastText.isEmpty
        menu.addItem(.separator())
        addItem(to: menu, "Quitter Emile", #selector(quit), key: "q")
    }

    @discardableResult
    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func openSettings() { settingsWindow.show() }

    @objc private func startMeetingFromMenu(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = MeetingMode(rawValue: raw) { startMeeting(mode) }
    }

    @objc private func stopMeetingFromMenu() { stopMeeting() }

    @objc private func openMeetingFolder() {
        let folder = MeetingFolder.current()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    @objc private func chooseLanguage(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String { language = code }
    }

    @objc private func copyLast() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastText, forType: .string)
    }

    @objc private func openAccessibility() { openAccessibilitySettings() }

    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - Point d'entree

/// `Emile --transcribe fichier.wav [langue]` : teste la chaine de transcription sans micro.
func runTranscribeTest(path: String, language: String) -> Never {
    let server = WhisperServer()
    Task {
        await server.start()
        guard await server.waitUntilReady(), let wav = FileManager.default.contents(atPath: path) else {
            print("ERREUR: serveur ou fichier indisponible")
            server.stop()
            exit(1)
        }
        do {
            print(try await transcribe(wav: wav, language: language))
            server.stop()
            exit(0)
        } catch {
            print("ERREUR: \(error)")
            server.stop()
            exit(1)
        }
    }
    dispatchMain()
}

/// Lit les echantillons d'un WAV 16 kHz mono 16 bits.
func samples(fromWAV path: String) -> [Int16] {
    guard let data = FileManager.default.contents(atPath: path), let range = data.range(of: Data("data".utf8)) else { return [] }
    let body = data[(range.upperBound + 4)...]
    return body.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
}

/// `Emile --meeting-test micro.wav ordi.wav dossier` : simule une reunion a partir de deux fichiers.
func runMeetingTest(mic: String, system: String, folder: String) -> Never {
    let server = WhisperServer()
    Task { @MainActor in
        await server.start()
        guard await server.waitUntilReady() else { print("ERREUR: serveur indisponible"); exit(1) }
        let micSamples = samples(fromWAV: mic), systemSamples = samples(fromWAV: system)
        let output = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let session = MeetingSession(mode: .online, author: "Martin", folder: output, language: "fr")
        let started = Date()
        var index = 0
        while index < max(micSamples.count, systemSamples.count) {
            let end = index + 16000
            session.feed(mic: Array(micSamples[min(index, micSamples.count)..<min(end, micSamples.count)]),
                         system: Array(systemSamples[min(index, systemSamples.count)..<min(end, systemSamples.count)]),
                         final: false)
            index = end
        }
        session.feed(mic: [], system: [], final: true)
        session.stop(title: "Test réunion") { url in
            print(String(format: "Temps de transcription : %.1f s", Date().timeIntervalSince(started)))
            for line in session.transcript.sorted(by: { $0.start < $1.start }) {
                print("[\(MeetingDocument.timestamp(line.start))] \(line.speaker) : \(line.text)")
            }
            print("FICHIER: \(url?.path ?? "aucun")")
            server.stop()
            exit(url == nil ? 1 : 0)
        }
    }
    dispatchMain()
}

let arguments = CommandLine.arguments
if arguments.count >= 5, arguments[1] == "--meeting-test" {
    Pref.register()
    runMeetingTest(mic: arguments[2], system: arguments[3], folder: arguments[4])
}
if arguments.count >= 3, arguments[1] == "--transcribe" {
    runTranscribeTest(path: arguments[2], language: arguments.count > 3 ? arguments[3] : "fr")
}

// Un seul Emile a la fois : si un autre tourne deja, on lui demande d'ouvrir ses reglages et on s'arrete.
if let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
    .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }),
   let url = running.bundleURL {
    let done = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in done.signal() }
    _ = done.wait(timeout: .now() + 3)
    exit(0)
}

Pref.register()
let controller = Controller()

// Un `kill` (comme pendant une reinstallation) ferme l'app proprement, moteur Whisper compris.
signal(SIGTERM, SIG_IGN)
let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminationSource.setEventHandler { NSApp.terminate(nil) }
terminationSource.resume()
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = controller
application.run()
