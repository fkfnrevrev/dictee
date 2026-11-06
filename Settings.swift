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

            Section("Dictée") {
                LabeledContent("Raccourci") { Text("Maintenir ⌘ droite").foregroundStyle(.secondary) }
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
        .frame(width: 460, height: 720)
        .onChange(of: soundName) { _ in Sounds.play(start: true, preview: true) }
    }
}

final class SettingsWindow {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: appModel)))
            window.title = "Emile"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
