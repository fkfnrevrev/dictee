// Ce que veulent dire les appuis sur fn : dictee maintenue, mains libres (double appui) ou reunion (fn + Commande droite).
// Separe du reste pour pouvoir etre teste sans clavier.

import Foundation

struct HotkeyMachine {
    enum Input {
        case fnDown, fnUp
        /// fn et Commande droite tenues ensemble, dans n'importe quel ordre.
        case meetingCombo
        case escape
        /// Autre touche ou clic.
        case other
    }

    enum Action: Equatable {
        case none
        /// Demarre une dictee tenue : elle finit au relachement de fn.
        case begin
        /// Demarre une dictee mains libres : elle finit au prochain appui sur fn.
        case beginHandsFree
        case finish
        case cancel
        case toggleMeeting
    }

    /// Delai maximal entre le relachement du premier appui et le deuxieme appui.
    static let doubleTapWindow: TimeInterval = 0.4
    /// Un appui plus court que ca compte comme une tape, pas comme une dictee.
    static let tapLength: TimeInterval = 0.3

    private(set) var handsFree = false
    private var swallowRelease = false
    private var fnDownAt: Date?
    private var lastTapUp: Date?

    /// `idle` : Emile est pret a dicter. `recording` : une dictee est en cours.
    mutating func handle(_ input: Input, at now: Date, idle: Bool, recording: Bool) -> Action {
        switch input {
        case .meetingCombo:
            handsFree = false
            lastTapUp = nil
            // Relacher fn ensuite ne doit pas finir une dictee.
            swallowRelease = true
            return .toggleMeeting

        case .fnDown:
            if handsFree {
                // Appui pendant le mode mains libres : on termine et on colle le texte.
                handsFree = false
                swallowRelease = true
                return .finish
            }
            if let lastTapUp, now.timeIntervalSince(lastTapUp) < Self.doubleTapWindow, idle {
                self.lastTapUp = nil
                handsFree = true
                return .beginHandsFree
            }
            lastTapUp = nil
            fnDownAt = now
            return .begin

        case .fnUp:
            if swallowRelease {
                swallowRelease = false
                return .none
            }
            // Relachement du deuxieme appui : on continue d'ecouter.
            if handsFree { return .none }
            let short = fnDownAt.map { now.timeIntervalSince($0) < Self.tapLength } ?? false
            lastTapUp = short ? now : nil
            fnDownAt = nil
            return .finish

        case .escape:
            lastTapUp = nil
            fnDownAt = nil
            if handsFree {
                handsFree = false
                return .cancel
            }
            return recording ? .cancel : .none

        case .other:
            lastTapUp = nil
            // fn a servi a un raccourci : son relachement ne compte pas comme une tape.
            fnDownAt = nil
            // En mains libres, on peut taper ou cliquer ailleurs sans couper la dictee.
            if handsFree { return .none }
            // fn + autre touche (fleches, F1...) : c'est un raccourci, pas une dictee.
            return recording ? .cancel : .none
        }
    }

    /// La dictee s'est arretee d'elle-meme (limite de duree, micro indisponible...).
    mutating func recordingEnded() {
        handsFree = false
    }
}
