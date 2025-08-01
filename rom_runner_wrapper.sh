#!/usr/bin/env bash

# === CONFIG ===
CACHE_DIR="/tmp/rom_runner_wrapper"
mkdir -p "$CACHE_DIR"

# Get all arguments except the last (emulator command and options)
CMD_ARGS=("${@:1:$(($#-1))}")
ROM_INPUT="${!#}"  # Last argument is the ROM path
ROM_DIR=$(dirname "$ROM_INPUT")
ROM_FILENAME=$(basename "$ROM_INPUT")
ROM_BASENAME="${ROM_FILENAME%.*}"  # Without extension
ROM_EXT="${ROM_FILENAME##*.}"
EXTRACTED=""

# === Function to link complementary files ===
link_related_files() {
    echo "[INFO] Linking companion files..."
    while IFS= read -r f; do
        target="$CACHE_DIR/$(basename "$f")"
        [[ -e "$target" ]] || ln -s "$(realpath "$f")" "$target"
    done < <(find "$ROM_DIR" -maxdepth 1 -type f -name "$ROM_BASENAME.*" ! -name "$ROM_FILENAME")
}

# === Handle .7z compressed ROMs ===
if [[ "$ROM_INPUT" == *.7z ]]; then
    ARCHIVE="$ROM_INPUT"
    ARCHIVE_BASE="${ROM_BASENAME}"

    echo "[INFO] Detected archive: $ARCHIVE"

    FILES=$(7z l -ba "$ARCHIVE" | sed -E 's/^.{53}//' | sed 's/^[ ]*//')

    # Try exact match
    MATCHED=""
    while IFS= read -r file; do
        base="${file%.*}"
        if [[ "$base" == "$ARCHIVE_BASE" ]]; then
            MATCHED="$file"
            EXTRACTED="$CACHE_DIR/$(basename "$file")"
            break
        fi
    done <<< "$FILES"

    # Fallback with "__"
    if [[ -z "$MATCHED" && "$ARCHIVE_BASE" == *"__"* ]]; then
        BASE_PREFIX="${ARCHIVE_BASE%%__*}"
        while IFS= read -r file; do
            base="${file%.*}"
            if [[ "$base" == "$BASE_PREFIX" ]]; then
                EXT="${file##*.}"
                MATCHED="$file"
                EXTRACTED="$CACHE_DIR/$ARCHIVE_BASE.$EXT"
                break
            fi
        done <<< "$FILES"
    fi

    # No match found
    if [[ -z "$MATCHED" ]]; then
        echo "[ERROR] No match found inside archive." >&2
        exit 1
    fi

    echo "[INFO] Extracting '$MATCHED' to '$EXTRACTED'..."
    7z e -y -so "$ARCHIVE" "$MATCHED" > "$EXTRACTED" || {
        echo "[ERROR] Extraction failed." >&2
        exit 1
    }

    link_related_files
    ROM_INPUT="$EXTRACTED"

# === Handle non-archive ROMs (e.g., .bps passed directly) ===
else
    cp "$ROM_INPUT" "$CACHE_DIR/" || {
        echo "[ERROR] Failed to copy ROM." >&2
        exit 1
    }
    ROM_INPUT="$CACHE_DIR/$(basename "$ROM_INPUT")"
    link_related_files
fi

# === Launch emulator ===
echo "[INFO] Launching emulator..."
exec "${CMD_ARGS[@]}" "$ROM_INPUT"

