// Fenetre de reglages, ouverte quand on lance Emile.

import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage(Pref.barVisible) private var barVisible = true
    @AppStorage(Pref.barAlways) private var barAlways = true
    @AppStorage(Pref.barStyle) private var barStyle = "orange"
    @AppStorage(Pref.barSize) private var barSize = 1.0
    @AppStorage(Pref.barOpacity) private var barOpacity = 0.92
    @AppStorage(Pref.barOffset) private var barOffset = 14.0
    @AppStorage(Pref.soundOn) private var soundOn = true
    @AppStorage(Pref.soundName) private var soundName = "bulle"
    @AppStorage(Pref.soundAtEnd) private var soundAtEnd = true
    @AppStorage(Pref.soundVolume) private var soundVolume = 0.35
    @AppStorage(Pref.language) private var language = "fr"
    @AppStorage(Pref.userName) private var userName = ""
    @AppStorage(Pref.meetingMode) private var meetingMode = MeetingMode.online.rawValue
    @AppStorage(Pref.meetingFolder) private var meetingFolder = ""
    @ObservedObject private var library = MeetingLibrary.shared

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Emile").font(.title2.weight(.semibold))
                        Text(model.status).foregroundStyle(.secondary)
                    }
                }
                if !model.accessibilityGranted {
                    HStack {
                        Label("Autorise Emile dans Accessibilité pour utiliser la touche.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Ouvrir") { openAccessibilitySettings() }
                    }
                }
            }

            Section("Barre") {
                Toggle("Afficher la barre", isOn: $barVisible)
                Toggle("Toujours visible, pas seulement pendant la dictée", isOn: $barAlways)
                    .disabled(!barVisible)
                Picker("Couleur", selection: $barStyle) {
                    Text("Orange").tag("orange")
                    Text("Noir").tag("noir")
                    Text("Graphite").tag("graphite")
                    Text("Vert").tag("vert")
                }
                .pickerStyle(.segmented)
                LabeledContent("Taille") { Slider(value: $barSize, in: 0.7...1.8) }
                LabeledContent("Opacité") { Slider(value: $barOpacity, in: 0.3...1) }
                LabeledContent("Hauteur") { Slider(value: $barOffset, in: 0...300) }
                HStack {
                    Spacer()
                    Button("Tester la barre") { model.runDemo() }
                }
            }

            Section("Son") {
                Toggle("Jouer un son quand j'appuie", isOn: $soundOn)
                Picker("Son", selection: $soundName) {
                    ForEach(Sounds.custom, id: \.id) { Text($0.name).tag($0.id) }
                    Divider()
                    ForEach(Sounds.system, id: \.self) { Text($0).tag($0) }
                }
                .disabled(!soundOn)
                Toggle("Aussi quand je relâche la touche", isOn: $soundAtEnd)
                    .disabled(!soundOn)
                LabeledContent("Volume") {
                    Slider(value: $soundVolume, in: 0.05...1) { editing in
                        if !editing { Sounds.play(start: true, preview: true) }
                    }
                }
                .disabled(!soundOn)
                HStack {
                    Spacer()
                    Button("Écouter") {
                        Sounds.play(start: true, preview: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Sounds.play(start: false, preview: true) }
                    }
                }
                .disabled(!soundOn)
            }

            Section {
                TextField("Ton prénom", text: $userName, prompt: Text("Martin"))
                Picker("Double-appui sur fn", selection: $meetingMode) {
                    ForEach(MeetingMode.allCases, id: \.self) { Text("Réunion \($0.label.lowercased())").tag($0.rawValue) }
                }
                LabeledContent("Dossier") {
                    HStack {
                        Text(MeetingFolder.shortPath(library.folder)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                        Button("Choisir…") { chooseFolder() }
                        if !meetingFolder.isEmpty {
                            Button("Par défaut") {
                                meetingFolder = ""
                                library.refresh()
                            }
                        }
                    }
                }
                LabeledContent("Son des autres (en ligne)") {
                    if model.screenAudioGranted {
                        Label("Autorisé", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Autoriser l'enregistrement de l'écran") { openScreenRecordingSettings() }
                    }
                }
            } header: {
                Text("Réunions")
            } footer: {
                Text("Le prénom signe tes transcriptions dans le dossier partagé. Emile n'enregistre jamais l'image de l'écran : macOS demande cette autorisation pour laisser capter le son des visios.")
                    .foregroundStyle(.secondary)
            }

            Section("Dictée") {
                LabeledContent("Raccourci") { Text("Maintenir fn 🌐").foregroundStyle(.secondary) }
                LabeledContent("Réunion") { Text("Double-appui sur fn 🌐").foregroundStyle(.secondary) }
                Picker("Langue", selection: $language) {
                    Text("Français").tag("fr")
                    Text("English").tag("en")
                    Text("Détection automatique").tag("auto")
                }
                Toggle("Lancer Emile au démarrage du Mac",
                       isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .onChange(of: soundName) { _ in Sounds.play(start: true, preview: true) }
        .onAppear {
            model.refreshPermissions()
            library.refresh()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choisir"
        panel.message = "Où ranger les transcriptions de réunion ?"
        panel.directoryURL = library.folder
        if panel.runModal() == .OK, let url = panel.url {
            meetingFolder = url.path
            library.refresh()
        }
    }
}

/// Fenetre principale : un menu a gauche, comme Wispr Flow.
struct MainView: View {
    enum Page: Hashable { case home, meetings, stats, settings }

    @ObservedObject var model: AppModel
    @ObservedObject var stats: StatsStore
    @State private var page: Page? = .home

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Label("Accueil", systemImage: "house").tag(Page.home)
                Label("Réunions", systemImage: "waveform").tag(Page.meetings)
                Label("Statistiques", systemImage: "chart.bar.xaxis").tag(Page.stats)
                Label("Réglages", systemImage: "gearshape").tag(Page.settings)
            }
            .safeAreaInset(edge: .top) {
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28)
                    Text("Emile").font(.title3.weight(.semibold))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            switch page ?? .home {
            case .home:
                HomeView(model: model, stats: stats, library: MeetingLibrary.shared, log: MeetingLog.shared,
                         onSeeAll: { page = .meetings })
            case .meetings: MeetingsView(library: MeetingLibrary.shared, model: model)
            case .stats: StatsView(stats: stats)
            case .settings: SettingsView(model: model)
            }
        }
        .frame(minWidth: 860, minHeight: 600)
    }
}

final class MainWindow {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let controller = NSHostingController(rootView: MainView(model: appModel, stats: StatsStore.shared))
            let window = NSWindow(contentViewController: controller)
            window.title = "Emile"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 1000, height: 720))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
