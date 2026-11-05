#!/bin/zsh
# Installe tout ce qu'il faut : le moteur whisper.cpp, le modele (574 Mo), puis l'app.
set -euo pipefail
cd "$(dirname "$0")"

MODEL_NAME=ggml-large-v3-turbo-q5_0.bin
MODEL_SHA256=394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL_NAME"
MODEL_DIR="$HOME/Library/Application Support/Dictee/models"
MODEL_PATH="$MODEL_DIR/$MODEL_NAME"

command -v swiftc >/dev/null || { echo "Installe d'abord les outils Apple : xcode-select --install"; exit 1; }
command -v brew >/dev/null || { echo "Installe d'abord Homebrew : https://brew.sh"; exit 1; }

brew install whisper.cpp

mkdir -p "$MODEL_DIR"
checksum() { shasum -a 256 "$MODEL_PATH" | awk '{print $1}'; }
if [[ ! -f "$MODEL_PATH" || "$(checksum)" != "$MODEL_SHA256" ]]; then
    echo "Telechargement du modele (574 Mo)..."
    curl -L --fail --progress-bar -C - -o "$MODEL_PATH" "$MODEL_URL"
    if [[ "$(checksum)" != "$MODEL_SHA256" ]]; then
        rm -f "$MODEL_PATH"
        echo "Modele corrompu, relance le script."
        exit 1
    fi
fi

./build.sh
open /Applications/Emile.app
echo "Emile est lancee. Autorise le micro et l'Accessibilite (voir README)."
