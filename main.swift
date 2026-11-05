// Dictee : maintiens Commande droite, parle, relache. Le texte s'ecrit au curseur.
// Tout reste sur le Mac : whisper-server n'ecoute que sur 127.0.0.1 et l'audio n'est jamais ecrit sur disque.

import ApplicationServices
import AVFoundation
import Cocoa
import ServiceManagement

let rightCommandKeycode: Int64 = 54
let rightCommandDeviceFlag: UInt64 = 0x10  // NX_DEVICERCMDKEYMASK
let minimumDuration: TimeInterval = 0.3
let maximumDuration: TimeInterval = 300
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
            NSLog("Dictee: impossible de lancer whisper-server: \(error)")
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
    let boundary = "dictee-\(UUID().uuidString)"
    var body = Data()
    func field(_ name: String, _ value: String) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
    }
    field("language", language)
    field("response_format", "json")
    if language == "fr" {
        field("prompt", "Bonjour, voici une dictée avec une ponctuation correcte.")
    }
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
          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let text = json["text"] as? String
    else { throw NSError(domain: "Dictee", code: 1, userInfo: [NSLocalizedDescriptionKey: "Réponse invalide du serveur"]) }
    return cleaned(text)
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

    func start() throws {
        lock.withLock { samples.removeAll(keepingCapacity: true) }
        // Un moteur neuf a chaque fois : suit les changements de micro (AirPods, etc.).
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        guard inputFormat.sampleRate > 0, let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw NSError(domain: "Dictee", code: 2, userInfo: [NSLocalizedDescriptionKey: "Micro indisponible"])
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / inputFormat.sampleRate) + 64
            guard let self, let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let channel = output.int16ChannelData?[0] else { return }
            let chunk = UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
            self.lock.withLock { self.samples.append(contentsOf: chunk) }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// Arrete le micro et renvoie les echantillons captes (16 kHz, mono).
    func stop() -> [Int16] {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        return lock.withLock { samples }
    }
}

func wavData(from samples: [Int16]) -> Data {
    func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    let byteCount = UInt32(samples.count * 2)
    var data = Data("RIFF".utf8)
    data += le(36 + byteCount)
    data += Data("WAVEfmt ".utf8)
    data += le(UInt32(16)) + le(UInt16(1)) + le(UInt16(1))
    data += le(UInt32(16000)) + le(UInt32(32000)) + le(UInt16(2)) + le(UInt16(16))
    data += Data("data".utf8)
    data += le(byteCount)
    samples.withUnsafeBytes { data.append(contentsOf: $0) }
    return data
}

func isSilent(_ samples: [Int16]) -> Bool {
    guard !samples.isEmpty else { return true }
    let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
    return (energy / Double(samples.count)).squareRoot() < 30
}

// MARK: - Application barre de menus

final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum State { case loading, idle, recording, transcribing }

    private let server = WhisperServer()
    private let recorder = Recorder()
    private var statusItem: NSStatusItem!
    private var state = State.loading { didSet { refreshIcon() } }
    private var note: String?
    private var eventTap: CFMachPort?
    private var permissionTimer: Timer?
    private var startedAt = Date()
    private var limitTimer: Timer?
    private var lastText = ""

    private var language: String {
        get { UserDefaults.standard.string(forKey: "language") ?? "fr" }
        set { UserDefaults.standard.set(newValue, forKey: "language") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()

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

        Task { @MainActor in
            await server.start()
            if await server.waitUntilReady() {
                state = .idle
            } else {
                note = "Le moteur Whisper n'a pas démarré"
                refreshIcon()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = recorder.stop()
        server.stop()
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
        refreshIcon()
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
        case .flagsChanged:
            guard event.getIntegerValueField(.keyboardEventKeycode) == rightCommandKeycode else { return }
            if event.flags.rawValue & rightCommandDeviceFlag != 0 { begin() } else { finish() }
        default:
            // Commande droite + autre touche ou clic : c'est un raccourci, pas une dictee.
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
            refreshIcon()
            return
        }
        note = nil
        startedAt = Date()
        state = .recording
        // Securite : le micro ne reste jamais ouvert si le relachement de la touche est manque.
        limitTimer = Timer.scheduledTimer(withTimeInterval: maximumDuration, repeats: false) { [weak self] _ in
            self?.finish()
        }
    }

    private func cancel() {
        limitTimer?.invalidate()
        _ = recorder.stop()
        state = .idle
    }

    private func finish() {
        guard state == .recording else { return }
        limitTimer?.invalidate()
        let samples = recorder.stop()
        guard Date().timeIntervalSince(startedAt) >= minimumDuration, !isSilent(samples) else {
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
                }
            } catch {
                note = "Échec de la transcription"
                NSLog("Dictee: \(error)")
            }
            state = .idle
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

    private func refreshIcon() {
        let symbol: String
        switch state {
        case .loading: symbol = "hourglass"
        case .idle: symbol = (note != nil || eventTap == nil) ? "exclamationmark.triangle" : "mic"
        case .recording: symbol = "mic.fill"
        case .transcribing: symbol = "text.bubble"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Dictee")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.contentTintColor = state == .recording ? .systemRed : nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status: String
        switch state {
        case .loading: status = "Chargement du modèle…"
        case .idle: status = "Prêt : maintiens Commande droite"
        case .recording: status = "Écoute…"
        case .transcribing: status = "Transcription…"
        }
        menu.addItem(NSMenuItem(title: note ?? status, action: nil, keyEquivalent: ""))

        if eventTap == nil {
            addItem(to: menu, "Autoriser l'accessibilité…", #selector(openAccessibility))
        }
        menu.addItem(.separator())

        for (code, name) in [("fr", "Français"), ("en", "English"), ("auto", "Détection automatique")] {
            let item = addItem(to: menu, name, #selector(chooseLanguage(_:)))
            item.representedObject = code
            item.state = language == code ? .on : .off
        }
        menu.addItem(.separator())

        let copy = addItem(to: menu, "Copier la dernière dictée", #selector(copyLast))
        copy.isEnabled = !lastText.isEmpty
        let login = addItem(to: menu, "Lancer au démarrage du Mac", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        addItem(to: menu, "Quitter Dictée", #selector(quit))
    }

    @discardableResult
    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func chooseLanguage(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String { language = code }
    }

    @objc private func copyLast() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastText, forType: .string)
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            note = "Démarrage automatique indisponible"
            refreshIcon()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - Point d'entree

/// `Dictee --transcribe fichier.wav [langue]` : teste la chaine de transcription sans micro.
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

let arguments = CommandLine.arguments
if arguments.count >= 3, arguments[1] == "--transcribe" {
    runTranscribeTest(path: arguments[2], language: arguments.count > 3 ? arguments[3] : "fr")
}

let controller = Controller()
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = controller
application.run()
