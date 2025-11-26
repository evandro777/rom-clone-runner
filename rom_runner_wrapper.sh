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
function link_related_files() {
    echo "[INFO] Linking companion files..."
    while IFS= read -r f; do
        target="$CACHE_DIR/$(basename "$f")"
        [[ -e "$target" ]] || ln -s "$(realpath "$f")" "$target"
    done < <(find "$ROM_DIR" -maxdepth 1 -type f -name "$ROM_BASENAME.*" ! -name "$ROM_FILENAME")
}

handle_n64_hires_texture() {
    local rom_dir="$1"         # directory containing the .7z archive
    local rom_basename="$2"    # ROM base name without extension
    local hires_dir_src="$rom_dir/hires_texture"

    echo "[INFO] Nintendo 64 ROM detected. Checking texture packs..."

    # Check if hires_texture directory exists
    if [[ ! -d "$hires_dir_src" ]]; then
        echo "[INFO] No 'hires_texture' directory found. Skipping N64 texture mount."
        return
    fi

    # Find .erofs file
    local erofs_file
    erofs_file=$(find "$hires_dir_src" -maxdepth 1 -type f -iname "*.erofs" | head -n 1)

    if [[ -z "$erofs_file" ]]; then
        echo "[INFO] No .erofs texture file found. Skipping N64 mount."
        return
    fi

    local erofs_name
    erofs_name=$(basename "$erofs_file" .erofs)

    # RetroArch flatpak
    local ra_flatpak="$HOME/.var/app/org.libretro.RetroArch/config/retroarch/system/Mupen64plus"

    # RetroArch local
    local ra_local="$HOME/.config/retroarch/system/Mupen64plus"

    local target_base=""

    # Priority check — but **only if folder exists**
    if [[ -d "$ra_flatpak" ]]; then
        target_base="$ra_flatpak"
    elif [[ -d "$ra_local" ]]; then
        target_base="$ra_local"
    else
        echo "[INFO] No RetroArch Mupen64plus folder found. Skipping N64 texture mount."
        return
    fi

    local target_mount="$target_base/hires_texture/$erofs_name"
    mkdir -p "$target_mount"

    # Check sudo availability
    if sudo -n true 2>/dev/null; then
        CAN_SUDO=true
        echo "[INFO] sudo available for mount."
    else
        CAN_SUDO=false
        echo "[INFO] sudo NOT available for mount."
    fi

    # === Prepare cache BEFORE mount ===
    local mupen_cache_dir="$target_base/cache"
    mkdir -p /tmp/Mupen64plusCache

    if [[ -e "$mupen_cache_dir" ]]; then
        if [[ -L "$mupen_cache_dir" ]]; then
            local real_target
            real_target=$(readlink -f "$mupen_cache_dir")

            if [[ "$real_target" != "/tmp/Mupen64plusCache" ]]; then
                echo "[INFO] Updating incorrect cache symlink..."
                rm -f "$mupen_cache_dir"
                ln -s /tmp/Mupen64plusCache "$mupen_cache_dir"
            else
                echo "[INFO] Cache already using /tmp/Mupen64plusCache."
            fi
        else
            echo "[INFO] Replacing existing cache directory with symlink..."
            rm -rf "$mupen_cache_dir"
            ln -s /tmp/Mupen64plusCache "$mupen_cache_dir"
        fi
    else
        echo "[INFO] Creating cache symlink to /tmp."
        ln -s /tmp/Mupen64plusCache "$mupen_cache_dir"
    fi

    # === Unmount old mount if needed ===
    if mountpoint -q "$target_mount"; then
        echo "[INFO] Unmounting previous mount at $target_mount..."

        if $CAN_SUDO; then
            sudo umount "$target_mount" 2>/dev/null || fusermount -u "$target_mount"
        else
            fusermount -u "$target_mount" 2>/dev/null
        fi
    fi

    echo "[INFO] Attempting to mount EROFS texture: $erofs_file"

    # === Attempt kernel mount ===
    if $CAN_SUDO; then
        echo sudo mount -t erofs "$erofs_file" "$target_mount"
        if sudo mount -t erofs "$erofs_file" "$target_mount" 2>/dev/null; then
            echo "[INFO] Mounted via kernel EROFS driver."
            return
        fi
    fi

    # === Attempt FUSE mount ===
    if command -v erofs-fuse >/dev/null; then
        if erofs-fuse "$erofs_file" "$target_mount" 2>/dev/null; then
            echo "[INFO] Mounted via erofs-fuse."
            return
        fi
    fi

    echo "[ERROR] Failed to mount EROFS texture file: $erofs_file"
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

    # List archive contents
    FILES=$(7z l -ba "$ARCHIVE_PATH" | sed -E 's/^.{53}//' | sed 's/^[ ]*//')

    # Try exact match (folder)
    MATCHED=""
    while IFS= read -r file; do
        [[ "$file" == "$ROM_BASENAME/"* ]] && MATCHED="$ROM_BASENAME" && break
    done <<< "$FILES"

    # Fallback with "__"
    if [[ -z "$MATCHED" && "$ROM_BASENAME" == *"__"* ]]; then
        BASE_PREFIX="${ROM_BASENAME%%__*}"
        while IFS= read -r file; do
            [[ "$file" == "$BASE_PREFIX/"* ]] && MATCHED="$BASE_PREFIX" && break
        done <<< "$FILES"
    fi

    if [[ -z "$MATCHED" ]]; then
        echo "[ERROR] No matching folder found inside archive." >&2
        exit 1
    fi

    TARGET_DIR="$CACHE_DIR/scummvm/$MATCHED"

    if [[ -d "$TARGET_DIR" && -n "$(ls -A "$TARGET_DIR")" ]]; then
        echo "[INFO] Archive already extracted, skipping extraction."
    else
        echo "[INFO] Extracting folder '$MATCHED/' to: $TARGET_DIR"
        mkdir -p "$TARGET_DIR"
        7z x -y "$ARCHIVE_PATH" -o"$CACHE_DIR/scummvm" "$MATCHED/*" || {
            echo "[ERROR] Failed to extract folder." >&2
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

            # Read all keys from GAME_INI for the gameid, but reversed
            mapfile -t keys < <(crudini --get "$GAME_INI" "$GAME_ID")

            # Apply all keys to SCUMMVM_INI_PATH
            for key in "${keys[@]}"; do
                value=$(crudini --get "$GAME_INI" "$GAME_ID" "$key")
                crudini --set "$SCUMMVM_INI_PATH" "$GAME_ID" "$key" "$value"
            done

            # Ensure correct path in GAME_INI before merge
            crudini --set "$SCUMMVM_INI_PATH" "$GAME_ID" path "$TARGET_DIR"

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

    # Check if ROM is Nintendo 64 by looking at the extension inside the archive
    FIRST_FILE=$(echo "$FILES" | grep -Ei '\.(z64|n64|v64)$' | head -n 1)
    IS_N64=false
    [[ -n "$FIRST_FILE" ]] && IS_N64=true

    # Isolated Nintendo 64 handler
    if $IS_N64; then
        handle_n64_hires_texture "$ROM_DIR" "$ARCHIVE_BASE"
    fi

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
