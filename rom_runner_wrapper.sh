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

# === Handle .scummvm special case ===
if [[ "$ROM_INPUT" == *.scummvm ]]; then
    echo "[INFO] Detected .scummvm file"

    ARCHIVE_PATH="$ROM_DIR/$ROM_BASENAME.7z"
    TARGET_DIR="$CACHE_DIR/scummvm/$ROM_BASENAME"

    if [[ ! -f "$ARCHIVE_PATH" ]]; then
        echo "[ERROR] Required archive not found: $ARCHIVE_PATH" >&2
        exit 1
    fi

    if [[ -d "$TARGET_DIR" && -n "$(ls -A "$TARGET_DIR")" ]]; then
        echo "[INFO] Archive already extracted, skipping extraction."
    else
        echo "[INFO] Extracting full archive to: $TARGET_DIR"
        mkdir -p "$TARGET_DIR"

        7z x -y "$ARCHIVE_PATH" -o"$TARGET_DIR" || {
            echo "[ERROR] Failed to extract archive." >&2
            exit 1
        }
    fi

    echo "[INFO] Copying .scummvm file to extracted folder"
    cp -u "$ROM_INPUT" "$TARGET_DIR/" || {
        echo "[ERROR] Failed to copy .scummvm file." >&2
        exit 1
    }

    ROM_INPUT="$TARGET_DIR/$ROM_FILENAME"

    # === Apply .ini game config if exists ===
    GAME_INI="$ROM_DIR/$ROM_BASENAME.ini"
    if [[ -f "$GAME_INI" ]]; then
        echo "[INFO] Found custom game .ini: $GAME_INI"

        # Extract gameid from .scummvm (first line should contain it)
        GAME_ID=$(head -n 1 "$ROM_INPUT" | tr -d '[]')
        echo "[INFO] Detected gameid section: [$GAME_ID]"

        # Paths to check for scummvm.ini
        declare -a scummvm_paths=(
            "$HOME/.config/retroarch/system/scummvm.ini"
            "$HOME/.var/app/org.libretro.RetroArch/config/retroarch/system/scummvm.ini"
            "$HOME/.var/app/org.scummvm.ScummVM/config/scummvm/scummvm.ini"
            "$HOME/.config/scummvm/scummvm.ini"
            "$HOME/snap/scummvm/current/.config/scummvm/scummvm.ini"
        )

        SCUMMVM_INI_PATH=""
        for p in "${scummvm_paths[@]}"; do
            if [[ -f "$p" ]]; then
                SCUMMVM_INI_PATH="$p"
                break
            fi
        done

        if [[ -n "$SCUMMVM_INI_PATH" ]]; then
            echo "[INFO] Found scummvm.ini at: $SCUMMVM_INI_PATH"

            # Ensure correct path in GAME_INI before merge
            crudini --set "$GAME_INI" "$GAME_ID" path "$TARGET_DIR"

            # Read all keys from GAME_INI for the gameid
            mapfile -t keys < <(crudini --get "$GAME_INI" "$GAME_ID")

            # Apply all keys to SCUMMVM_INI_PATH
            for key in "${keys[@]}"; do
                value=$(crudini --get "$GAME_INI" "$GAME_ID" "$key")
                crudini --set "$SCUMMVM_INI_PATH" "$GAME_ID" "$key" "$value"
            done

            echo "[INFO] Game settings for [$GAME_ID] applied via crudini."
        else
            echo "[WARN] No scummvm.ini found to apply settings."
        fi
    fi

# === Handle .7z compressed ROMs (regular case) ===
elif [[ "$ROM_INPUT" == *.7z ]]; then
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
