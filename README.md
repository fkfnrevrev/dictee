# Dictée

Dictée vocale 100 % locale pour Mac : maintiens **Commande droite**, parle, relâche, et le texte s'écrit au curseur, dans n'importe quelle app.

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
2. **Accessibilité** : Réglages Système → Confidentialité et sécurité → Accessibilité, puis active **Dictee**.

## Utilisation

| Icône dans la barre de menus | État |
|---|---|
| Sablier | Le modèle charge |
| Micro | Prêt |
| Micro rouge | Écoute |
| Bulle de texte | Transcription |
| Triangle | Autorisation manquante ou erreur |

Commande droite + une autre touche (comme `Cmd` + `C`) annule la dictée, donc tes raccourcis continuent de marcher.

Le menu de l'icône permet de choisir la langue, de recopier la dernière dictée et de lancer l'app au démarrage du Mac.

## Mettre à jour

```bash
git pull && ./build.sh
```

Après une recompilation, macOS peut redemander l'Accessibilité. Si la touche ne réagit plus, retire **Dictee** de la liste puis ajoute-la de nouveau.

## Tester sans micro

```bash
/Applications/Dictee.app/Contents/MacOS/Dictee --transcribe fichier.wav fr
```

Le fichier doit être un WAV 16 kHz mono en 16 bits.
