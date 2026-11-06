# Emile

Dictée vocale 100 % locale pour Mac : maintiens **fn** (🌐, en bas à gauche du clavier), parle, relâche, et le texte s'écrit au curseur, dans n'importe quelle app.

La transcription tourne sur le Mac avec [whisper.cpp](https://github.com/ggml-org/whisper.cpp). Le moteur n'écoute que sur `127.0.0.1` et l'audio n'est jamais écrit sur le disque.

## Prérequis

- Mac Apple Silicon, macOS 13 ou plus récent
- [Homebrew](https://brew.sh)
- Outils de développement Apple : `xcode-select --install`
- Environ 600 Mo d'espace disque, et environ 800 Mo de RAM quand l'app tourne

## Installation

```bash
git clone https://github.com/fkfnrevrev/dictee.git
```

```bash
cd dictee && ./install.sh
```

Le script installe whisper.cpp, télécharge le modèle, compile l'app dans `/Applications` et la lance.

Il reste deux autorisations à donner :

1. **Micro** : clique sur Autoriser quand macOS le demande.
2. **Accessibilité** : Réglages Système → Confidentialité et sécurité → Accessibilité, puis active **Emile**.

## Utilisation

| Icône dans la barre de menus | État |
|---|---|
| Sablier | Le modèle charge |
| Micro | Prêt |
| Micro rouge | Écoute |
| Bulle de texte | Transcription |
| Triangle | Autorisation manquante ou erreur |

Une petite barre flottante en bas de l'écran s'agrandit pendant la dictée, et un son discret marque le début et la fin.

La fenêtre de réglages s'ouvre au lancement d'Emile, ou depuis l'icône de la barre de menus → **Réglages…**. Tu peux y régler la barre (couleur, taille, opacité, hauteur), le son, la langue et le lancement au démarrage du Mac.

fn + une autre touche (comme fn + flèche) annule la dictée, donc tes raccourcis continuent de marcher.

Pour que fn ne fasse rien d'autre : Réglages Système → Clavier → « Appuyer sur la touche 🌐 pour » → **Ne rien faire**. Si Wispr Flow est installé, change son raccourci ou quitte-le, car il utilise aussi fn par défaut.

Le menu de l'icône permet aussi de recopier la dernière dictée.

## Mettre à jour

```bash
git pull && ./build.sh
```

Après une recompilation, macOS peut redemander l'Accessibilité. Si la touche ne réagit plus, retire **Emile** de la liste puis ajoute-la de nouveau.

## Tester sans micro

```bash
/Applications/Emile.app/Contents/MacOS/Emile --transcribe fichier.wav fr
```

Le fichier doit être un WAV 16 kHz mono en 16 bits.
