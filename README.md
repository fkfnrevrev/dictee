# Emile

Dictée vocale 100 % locale pour Mac : maintiens **fn** (🌐, en bas à gauche du clavier), parle, relâche, et le texte s'écrit au curseur, dans n'importe quelle app.

Emile transcrit aussi tes réunions dans un fichier Word, rangé directement dans un dossier Google Drive partagé.

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

## Réunions

Lance une réunion depuis l'**Accueil** d'Emile (boutons **En ligne** ou **En présentiel**), depuis l'icône de la barre de menus, ou par un **double-appui sur fn**. Un nouveau double-appui l'arrête.

- **En ligne** (Zoom, Meet, Teams…) : Emile capte ton micro et le son de l'ordi séparément. La transcription distingue donc ton prénom et « Interlocuteurs ». Avec des haut-parleurs plutôt qu'un casque, Emile retire les phrases des autres que ton micro a reprises.
- **En présentiel** : un seul micro, tout le monde est noté « Participants ».

Toutes les 30 secondes environ, le morceau écouté est transcrit sur le Mac puis effacé de la mémoire. L'audio n'est jamais enregistré. Le fichier Word est réécrit au fur et à mesure, sous un nom du type `2026-11-06 14h30 – Nom de la réunion – Martin.docx`. Une heure de réunion pèse environ 50 Ko.

### Le dossier partagé

Par défaut, Emile écrit dans **VENTILO DRIVE › 07_TRANSCRIPTIONS**, via Google Drive pour ordinateur :

1. Installe [Google Drive pour ordinateur](https://www.google.com/drive/download/) et connecte ton compte. Dans ses préférences, choisis **Diffuser les fichiers** pour qu'ils ne prennent pas de place sur le Mac.
2. Si le dossier VENTILO DRIVE a été partagé avec toi, ajoute-le à ton Drive : sur drive.google.com, clic droit → **Organiser → Ajouter un raccourci dans Mon Drive**.
3. Relance Emile : la carte **Dossier** de l'Accueil doit afficher « Synchronisé avec Google Drive ».

Tant que le Drive n'est pas relié, les réunions vont dans `Documents/Réunions Emile`. Tu peux aussi choisir un autre dossier dans **Réglages → Réunions**, et y indiquer ton prénom, qui signe tes fichiers.

### Les comptes rendus par Claude

À la fin de chaque réunion, Emile envoie le **texte** de la transcription à Claude, via [Claude Code](https://claude.com/claude-code) installé sur le Mac. Ça passe par ton abonnement Claude, sans frais en plus. Claude écrit un compte rendu en Word, avec résumé, décisions, tâches, chiffres clés, personnes citées et questions en suspens, et le range dans **08_RESUMES** sous le même nom que la transcription.

Emile tient aussi à jour **00_Journal des réunions.docx**, qui rassemble tous les comptes rendus, du plus récent au plus ancien. C'est la mémoire de toutes vos réunions, à donner à Claude pour retrouver une décision ou une tâche.

Les réunions du dossier qui n'ont pas encore de compte rendu, y compris celles enregistrées sur un autre Mac, sont traitées toutes les 10 minutes, une à la fois. L'audio ne quitte jamais le Mac : seul le texte est envoyé à Claude. Tu peux couper les comptes rendus dans **Réglages → Comptes rendus**.

Il faut que Claude Code soit installé et connecté : tape `claude` dans le Terminal une fois pour te connecter.

### Autorisation pour le son des visios

Pour entendre les autres, macOS demande l'autorisation **Enregistrement de l'écran** (Réglages Système → Confidentialité et sécurité). Emile n'utilise pas l'image de l'écran. Après l'avoir donnée, relance Emile. Comme pour l'Accessibilité, il faut parfois la redonner après une mise à jour.

Pense à prévenir les participants que la réunion est transcrite.

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

Pour faire résumer une transcription par Claude :

```bash
/Applications/Emile.app/Contents/MacOS/Emile --summary-test transcription.docx dossier-de-sortie
```

Pour simuler une réunion à partir de deux fichiers (ton micro, puis le son de l'ordi) :

```bash
/Applications/Emile.app/Contents/MacOS/Emile --meeting-test micro.wav ordi.wav dossier-de-sortie
```
