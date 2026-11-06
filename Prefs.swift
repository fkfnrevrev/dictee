// Reglages partages, etat affiche par la barre et la fenetre, et sons.

import AppKit
import ServiceManagement

enum Pref {
    static let language = "language"
    static let barVisible = "barVisible"
    static let barAlways = "barAlwaysVisible"
    static let barSize = "barSize"
    static let barOpacity = "barOpacity"
    static let barOffset = "barOffset"
    static let barStyle = "barStyle"
    static let soundOn = "soundEnabled"
    static let soundName = "soundName"
    static let soundAtEnd = "soundAtEnd"
    static let soundVolume = "soundVolume"
    static let userName = "userName"
    static let meetingFolder = "meetingFolder"
    static let meetingMode = "meetingMode"
    static let summaryEnabled = "summaryEnabled"
    static let summarySkipped = "summarySkipped"

    static func register() {
        UserDefaults.standard.register(defaults: [
            language: "fr",
            barVisible: true, barAlways: true, barSize: 1.0, barOpacity: 0.92, barOffset: 14.0, barStyle: "orange",
            soundOn: true, soundName: "bulle", soundAtEnd: true, soundVolume: 0.35,
            userName: NSFullUserName().split(separator: " ").first.map(String.init) ?? "Moi",
            meetingFolder: "", meetingMode: MeetingMode.online.rawValue, summaryEnabled: true,
        ])
    }
}

final class AppModel: ObservableObject {
    enum Phase { case loading, idle, recording, transcribing, meeting }

    @Published var phase = Phase.loading
    @Published var level = 0.0
    @Published var status = "Chargement du modèle…"
    @Published var accessibilityGranted = false
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    /// Etat simule par le bouton « Tester la barre » ; prioritaire sur l'etat reel.
    @Published var demoPhase: Phase?

    var displayedPhase: Phase { demoPhase ?? phase }

    // Reunion en cours, affichee dans l'accueil et dans la barre.
    @Published var meeting: LiveMeeting?
    @Published var meetingTitle = ""
    @Published var lastSavedMeeting: URL?
    @Published var screenAudioGranted = CGPreflightScreenCaptureAccess()
    var onStartMeeting: ((MeetingMode) -> Void)?
    var onStopMeeting: (() -> Void)?

    func refreshPermissions() { screenAudioGranted = CGPreflightScreenCaptureAccess() }

    /// Lisse le volume pour que les vagues bougent sans a-coups.
    func push(level newLevel: Double) {
        level = newLevel > level ? level * 0.5 + newLevel * 0.5 : level * 0.8 + newLevel * 0.2
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Emile: demarrage automatique: \(error)")
        }
        loginEnabled = SMAppService.mainApp.status == .enabled
    }

    func runDemo() {
        guard demoPhase == nil, phase == .idle || phase == .loading else { return }
        demoPhase = .recording
        Sounds.play(start: true)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
            self?.push(level: Double.random(in: 0.2...0.95))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            timer.invalidate()
            self?.level = 0
            self?.demoPhase = .transcribing
            Sounds.play(start: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in self?.demoPhase = nil }
    }
}

let appModel = AppModel()

func openScreenRecordingSettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
}

func openAccessibilitySettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
}

// MARK: - Sons

enum Sounds {
    /// Sons doux generes par l'app : une variante montante au debut, descendante a la fin.
    static let custom: [(id: String, name: String)] = [("bulle", "Bulle"), ("clic", "Clic"), ("cloche", "Cloche")]
    static let system = ["Tink", "Pop", "Morse", "Purr", "Bottle", "Frog", "Glass", "Ping", "Hero",
                         "Submarine", "Basso", "Blow", "Funk", "Sosumi"]

    private static var cache: [String: NSSound] = [:]

    static func play(start: Bool, preview: Bool = false) {
        let defaults = UserDefaults.standard
        if !preview {
            guard defaults.bool(forKey: Pref.soundOn) else { return }
            guard start || defaults.bool(forKey: Pref.soundAtEnd) else { return }
        }
        let id = defaults.string(forKey: Pref.soundName) ?? "bulle"
        let key = "\(id)-\(start)"
        if cache[key] == nil {
            if let data = synthesize(id, start: start) {
                cache[key] = NSSound(data: data)
            } else {
                cache[key] = NSSound(contentsOfFile: "/System/Library/Sounds/\(id).aiff", byReference: true)
            }
        }
        guard let sound = cache[key] else { return }
        sound.stop()
        sound.volume = Float(defaults.double(forKey: Pref.soundVolume))
        sound.play()
    }

    private static func synthesize(_ id: String, start: Bool) -> Data? {
        let rate = 44100.0
        let duration: Double
        switch id {
        case "bulle": duration = 0.14
        case "clic": duration = 0.04
        case "cloche": duration = 0.45
        default: return nil
        }
        func envelope(_ t: Double, attack: Double, decay: Double) -> Double {
            let shape = t < attack ? t / attack : exp(-(t - attack) / decay)
            let fadeOut = min(1, (duration - t) / 0.005)
            return shape * max(0, fadeOut)
        }
        var samples: [Int16] = []
        var phase = 0.0
        for i in 0..<Int(duration * rate) {
            let t = Double(i) / rate
            var value = 0.0
            switch id {
            case "bulle":
                let (from, to) = start ? (520.0, 820.0) : (760.0, 480.0)
                phase += 2 * .pi * (from + (to - from) * t / duration) / rate
                value = sin(phase) * envelope(t, attack: 0.006, decay: 0.035)
            case "clic":
                let frequency = start ? 1900.0 : 1400.0
                value = sin(2 * .pi * frequency * t) * envelope(t, attack: 0.001, decay: 0.006)
            default:
                let frequency = start ? 1318.5 : 987.8
                value = (sin(2 * .pi * frequency * t) + 0.4 * sin(4 * .pi * frequency * t)) / 1.4
                    * envelope(t, attack: 0.002, decay: 0.09)
            }
            samples.append(Int16(max(-1, min(1, value * 0.8)) * 32767))
        }
        return wavData(from: samples, sampleRate: 44100)
    }
}
