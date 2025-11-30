#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# === CONFIG ===
CACHE_DIR="/tmp/rom_runner_wrapper"
TMP_MUPEN_CACHE="/tmp/Mupen64plusCache"
mkdir -p "$CACHE_DIR"

# === Logging helpers ===
log()   { printf '[INFO] %s\n' "$*"; }
warn()  { printf '[WARN] %s\n' "$*" >&2; }
error() { printf '[ERROR] %s\n' "$*" >&2; }
die()   { error "$*"; exit 1; }

# === Dependency check ===
check_deps() {
    command -v 7z >/dev/null 2>&1 || die "7z (p7zip) is required but not found."
    if command -v crudini >/dev/null 2>&1; then
        HAVE_CRUDINI=true
    else
        HAVE_CRUDINI=false
        warn "crudini not found — scummvm INI merging will be skipped."
    fi
    if command -v erofsfuse >/dev/null 2>&1; then
        HAVE_EROFSFUSE=true
    else
        HAVE_EROFSFUSE=false
    fi
}
check_deps

# === Utility wrappers for archive and extraction ===

# Trim 7z listing to filename column (works with p7zip output)
list_archive_files() {
    local archive="$1"
    7z l -ba "$archive" | sed -E 's/^.{53}//' | sed 's/^[ ]*//'
}

# Extract a single file from archive to destination (stream extract)
extract_file_from_archive() {
    local archive="$1"
    local file_in_archive="$2"
    local dest="$3"
    7z e -y -so "$archive" "$file_in_archive" > "$dest"
}

# Extract a folder from archive into a parent dir (creates parent_dir/folder...)
extract_folder_from_archive() {
    local archive="$1"
    local folder_in_archive="$2"   # folder name inside archive (no trailing slash)
    local parent_dir="$3"
    mkdir -p "$parent_dir"
    7z x -y "$archive" "$folder_in_archive/*" -o"$parent_dir"
}

# Link companion files (create symlinks in cache dir)
link_related_files() {
    # depends on ROM_DIR, ROM_BASENAME, ROM_FILENAME existing in caller scope
    log "Linking companion files..."
    while IFS= read -r f; do
        local target="$CACHE_DIR/$(basename "$f")"
        [[ -e "$target" ]] || ln -s "$(realpath "$f")" "$target"
    done < <(find "$ROM_DIR" -maxdepth 1 -type f -name "$ROM_BASENAME.*" ! -name "$ROM_FILENAME")
}

# === Helpers for sudo / mounts ===

# Return 0 if sudo is available non-interactively
can_use_sudo() {
    if sudo -n true 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Generic EROFS mount handler
# mount_erofs_texture <erofs_file> <target_mount>
# returns 0 on success, 1 on failure
mount_erofs_texture() {
    local erofs_file="$1"
    local target_mount="$2"

    [[ -f "$erofs_file" ]] || { error "erofs file not found: $erofs_file"; return 1; }

    log "Mount handler: $erofs_file -> $target_mount"
    mkdir -p "$target_mount"

    local CAN_SUDO=false
    if can_use_sudo; then
        CAN_SUDO=true
        log "sudo available for kernel mount."
    else
        log "sudo NOT available for kernel mount."
    fi

    # If something is mounted at target, unmount it (simpler behaviour you requested)
    if mountpoint -q "$target_mount"; then
        log "Mountpoint exists at $target_mount — unmounting first."
        if $CAN_SUDO; then
            sudo umount "$target_mount" 2>/dev/null || fusermount -u "$target_mount" 2>/dev/null || warn "Failed to unmount previous mount (tried sudo then fusermount)."
        else
            fusermount -u "$target_mount" 2>/dev/null || warn "Failed to unmount previous mount (no sudo)."
        fi
    fi

    # Try kernel mount if possible
    if $CAN_SUDO; then
        if sudo mount -t erofs "$erofs_file" "$target_mount" 2>/dev/null; then
            log "Mounted via kernel erofs driver at $target_mount"
            return 0
        else
            warn "Kernel erofs mount failed or unsupported."
        fi
    fi

    # Try erofsfuse (FUSE) fallback
    if [[ "$HAVE_EROFSFUSE" == true ]]; then
        if erofsfuse "$erofs_file" "$target_mount" 2>/dev/null; then
            log "Mounted via erofsfuse at $target_mount"
            return 0
        else
            warn "erofsfuse mount failed."
        fi
    else
        warn "erofsfuse not installed; skipping FUSE fallback."
    fi

    error "Failed to mount erofs file: $erofs_file"
    return 1
}

# Prepare mupen cache symlink safely
prepare_mupen_cache() {
    local target_base="$1"   # Mupen64plus parent dir (not including hires_texture)
    local mupen_cache_dir="$target_base/cache"

    mkdir -p "$TMP_MUPEN_CACHE"

    if [[ -e "$mupen_cache_dir" ]]; then
        if [[ -L "$mupen_cache_dir" ]]; then
            local real_target
            real_target=$(readlink -f "$mupen_cache_dir" 2>/dev/null || true)
            if [[ "$real_target" != "$TMP_MUPEN_CACHE" ]]; then
                log "Cache symlink points elsewhere — updating to $TMP_MUPEN_CACHE"
                rm -f "$mupen_cache_dir"
                ln -s "$TMP_MUPEN_CACHE" "$mupen_cache_dir"
            else
                log "Cache already redirected to $TMP_MUPEN_CACHE"
            fi
        else
            log "Replacing existing real cache dir with symlink to $TMP_MUPEN_CACHE"
            rm -rf "$mupen_cache_dir"
            ln -s "$TMP_MUPEN_CACHE" "$mupen_cache_dir"
        fi
    else
        log "Creating cache symlink to $TMP_MUPEN_CACHE"
        ln -s "$TMP_MUPEN_CACHE" "$mupen_cache_dir"
    fi
}

# === N64 detection helper ===
# is_n64_archive <archive>
# returns 0 if a .z64|.n64|.v64 file is present
is_n64_archive() {
    local archive="$1"
    list_archive_files "$archive" | grep -Ei '\.(z64|n64|v64)$' >/dev/null 2>&1
}

# === N64 hires texture handler (orchestrator) ===
handle_n64_hires_texture() {
    local rom_dir="$1"
    local rom_basename="$2"
    local hires_dir_src="$rom_dir/hires_texture"

    log "Nintendo 64 ROM detected. Checking texture packs..."

    [[ -d "$hires_dir_src" ]] || { log "No hires_texture folder found. Skipping."; return; }

    local erofs_file
    erofs_file=$(find "$hires_dir_src" -maxdepth 1 -type f -iname "*.erofs" | head -n 1 || true)
    [[ -n "$erofs_file" ]] || { log "No .erofs file found in hires_texture. Skipping."; return; }

    local erofs_name
    erofs_name=$(basename "$erofs_file" .erofs)

    local ra_flatpak="$HOME/.var/app/org.libretro.RetroArch/config/retroarch/system/Mupen64plus"
    local ra_local="$HOME/.config/retroarch/system/Mupen64plus"
    local target_base=""

    if [[ -d "$ra_flatpak" ]]; then
        target_base="$ra_flatpak"
    elif [[ -d "$ra_local" ]]; then
        target_base="$ra_local"
    else
        log "No Mupen64plus folder found in RetroArch config. Skipping textures."
        return
    fi

    local target_mount="$target_base/hires_texture/$erofs_name"
    mkdir -p "$(dirname "$target_mount")"   # ensure hires_texture parent exists (but do not create Mupen64plus root if it didn't exist)

    # prepare cache BEFORE mount
    prepare_mupen_cache "$target_base"

    # perform mount using generic function
    if mount_erofs_texture "$erofs_file" "$target_mount"; then
        log "Texture mounted successfully."
    else
        warn "Texture mount failed — continuing without hires textures."
    fi
}

# === MAIN ===

# Get args and ROM info
CMD_ARGS=("${@:1:$(($#-1))}")
ROM_INPUT="${!#}"
ROM_DIR=$(dirname "$ROM_INPUT")
ROM_FILENAME=$(basename "$ROM_INPUT")
ROM_BASENAME="${ROM_FILENAME%.*}"
ROM_EXT="${ROM_FILENAME##*.}"
EXTRACTED=""

# === scummvm special case ===
if [[ "$ROM_INPUT" == *.scummvm ]]; then
    log "Detected .scummvm file"

    ARCHIVE_PATH="$ROM_DIR/$ROM_BASENAME.7z"
    TARGET_DIR="$CACHE_DIR/scummvm/$ROM_BASENAME"

    [[ -f "$ARCHIVE_PATH" ]] || die "Required archive not found: $ARCHIVE_PATH"

    FILES=$(list_archive_files "$ARCHIVE_PATH")

    # exact folder match
    MATCHED=""
    while IFS= read -r file; do
        [[ "$file" == "$ROM_BASENAME/"* ]] && { MATCHED="$ROM_BASENAME"; break; }
    done <<< "$FILES"

    # fallback with __ prefix
    if [[ -z "$MATCHED" && "$ROM_BASENAME" == *"__"* ]]; then
        BASE_PREFIX="${ROM_BASENAME%%__*}"
        while IFS= read -r file; do
            [[ "$file" == "$BASE_PREFIX/"* ]] && { MATCHED="$BASE_PREFIX"; break; }
        done <<< "$FILES"
    fi

    [[ -n "$MATCHED" ]] || die "No matching folder found inside archive."

    TARGET_DIR="$CACHE_DIR/scummvm/$MATCHED"

    if [[ -d "$TARGET_DIR" && -n "$(ls -A "$TARGET_DIR")" ]]; then
        log "Archive folder already extracted, skipping extraction."
    else
        log "Extracting folder '$MATCHED/' to: $TARGET_DIR"
        extract_folder_from_archive "$ARCHIVE_PATH" "$MATCHED" "$CACHE_DIR/scummvm" || die "Failed to extract folder."
    fi

    log "Copying .scummvm file to extracted folder"
    cp -u "$ROM_INPUT" "$TARGET_DIR/" || die "Failed to copy .scummvm file."

    ROM_INPUT="$TARGET_DIR/$ROM_FILENAME"

    # apply game ini via crudini (if available)
    GAME_INI="$ROM_DIR/$ROM_BASENAME.ini"
    if [[ -f "$GAME_INI" && "$HAVE_CRUDINI" == true ]]; then
        log "Found custom game .ini: $GAME_INI"
        GAME_ID=$(head -n 1 "$ROM_INPUT" | tr -d '[]')
        log "Detected gameid section: [$GAME_ID]"

        declare -a scummvm_paths=(
            "$HOME/.config/retroarch/system/scummvm.ini"
            "$HOME/.var/app/org.libretro.RetroArch/config/retroarch/system/scummvm.ini"
            "$HOME/.var/app/org.scummvm.ScummVM/config/scummvm/scummvm.ini"
            "$HOME/.config/scummvm/scummvm.ini"
            "$HOME/snap/scummvm/current/.config/scummvm/scummvm.ini"
        )

        SCUMMVM_INI_PATH=""
        for p in "${scummvm_paths[@]}"; do
            [[ -f "$p" ]] && { SCUMMVM_INI_PATH="$p"; break; }
        done

        if [[ -n "$SCUMMVM_INI_PATH" ]]; then
            log "Found scummvm.ini at: $SCUMMVM_INI_PATH"

            # ensure path is correct in the local game ini first
            crudini --set "$GAME_INI" "$GAME_ID" path "$TARGET_DIR"

            # merge keys (order preservation not strict; crudini handles overwrite)
            mapfile -t keys < <(crudini --get "$GAME_INI" "$GAME_ID" || true)
            for key in "${keys[@]}"; do
                value=$(crudini --get "$GAME_INI" "$GAME_ID" "$key" 2>/dev/null || true)
                crudini --set "$SCUMMVM_INI_PATH" "$GAME_ID" "$key" "$value"
            done

            # normalize spacing to scummvm style
            sed -i 's/ = /=/g' "$SCUMMVM_INI_PATH"

            log "Game settings for [$GAME_ID] applied via crudini."
        else
            warn "No scummvm.ini found to apply settings."
        fi
    else
        [[ -f "$GAME_INI" ]] && warn "crudini not available; skipping INI merge."
    fi

# === Handle plain .7z archives ===
elif [[ "$ROM_INPUT" == *.7z ]]; then
    ARCHIVE="$ROM_INPUT"
    ARCHIVE_BASE="${ROM_BASENAME}"

    log "Detected archive: $ARCHIVE"

    FILES=$(list_archive_files "$ARCHIVE")

    # Try exact match file inside archive
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

    [[ -n "$MATCHED" ]] || die "No match found inside archive."

    log "Extracting '$MATCHED' to '$EXTRACTED'..."
    extract_file_from_archive "$ARCHIVE" "$MATCHED" "$EXTRACTED" || die "Extraction failed."

    link_related_files
    ROM_INPUT="$EXTRACTED"

    # Detect N64 ROM inside archive (function)
    if is_n64_archive "$ARCHIVE"; then
        handle_n64_hires_texture "$ROM_DIR" "$ARCHIVE_BASE"
    fi

# === non-archives (copy to cache) ===
else
    cp "$ROM_INPUT" "$CACHE_DIR/" || die "Failed to copy ROM."
    ROM_INPUT="$CACHE_DIR/$(basename "$ROM_INPUT")"
    link_related_files
fi

# === Launch emulator ===
log "Launching emulator..."
exec "${CMD_ARGS[@]}" "$ROM_INPUT"
