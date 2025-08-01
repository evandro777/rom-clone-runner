#!/usr/bin/env bash

# === SETUP ===
CORE="$1"
ARCHIVE="$2"
INSIDE="$3"
CACHE_DIR="/tmp/rom_extract"

# === VALIDATIONS ===
if [[ -z "$CORE" || -z "$ARCHIVE" ]]; then
    echo "Usage: $0 <core.so> <rom.7z> [internal_file.sfc]"
    exit 1
fi

if [[ ! -f "$ARCHIVE" ]]; then
    echo "[ERROR] File not found: $ARCHIVE"
    exit 1
fi

mkdir -p "$CACHE_DIR"

# === Auto-detect function (simplificada) ===
auto_detect_inside() {
    ARCHIVE_BASE=$(basename "$ARCHIVE" .7z)

    # Lista limpa com nomes dos arquivos internos
    FILES=$(7z l -ba "$ARCHIVE" | sed -E 's/^.{53}//' | sed 's/^[ ]*//')

    while IFS= read -r file; do
        base_name="${file%.*}"
        if [[ "$base_name" == "$ARCHIVE_BASE" ]]; then
            echo "$file"
            return 0
        fi
    done <<< "$FILES"

    echo "[ERROR] No exact match found for '$ARCHIVE_BASE' inside archive." >&2
    return 1
}

# === Detect or use specified internal file ===
if [[ -z "$INSIDE" ]]; then
    echo "[INFO] No internal file specified, attempting auto-detection..."
    INSIDE=$(auto_detect_inside) || exit 1
    echo "[INFO] Detected internal file: $INSIDE"
else
    echo "[INFO] Using specified internal file: $INSIDE"
fi

# === Extraction ===
EXTRACTED="$CACHE_DIR/$(basename "$INSIDE")"

# Extrai somente o arquivo desejado
7z e -y -so "$ARCHIVE" "$INSIDE" > "$EXTRACTED" || {
    echo "[ERROR] Failed to extract '$INSIDE' from archive." >&2
    exit 1
}

# === Run in RetroArch ===
echo "[INFO] Launching RetroArch..."
flatpak run org.libretro.RetroArch --verbose -L "$CORE" "$EXTRACTED"

