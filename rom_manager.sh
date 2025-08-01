#!/usr/bin/env bash
set -euo pipefail

# Show help message
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

This script processes .7z archives and creates symlinks based on specified modes.
You can choose whether to place links in folders or directly as files, and whether
to include clone references (internal files or folders inside the 7z).

Required options:
  -m MODE          Mode of output:
                   'file'   → do the operation (symlink, copy or move) for the parent rom directly in the root of the destination folder
                   'folder' → creates a subdirectory for each rom, and do the operation (symlink, copy or move) for the parent rom
  -s SRC_DIR       Source directory containing .7z archives
  -d DEST_DIR      Destination base directory for roms

Optional options:
  -c CLONES        Clone handling mode [Always use symlinks]:
                   'file'   → detects clones based on internal files of the archive.
                   'folder' → detects clones based on internal folders of the archive
                   (default: process only the parent archive, ignoring clones)
  -o OPERATION     Operation type for handling files:
                   'symlink' → create symbolic links (default)
                   'copy'    → copy files instead of linking
                   'move'    → move files instead of linking
  -t CHD_SRC_DIR   Directory containing CHD folders to be linked if matching archive names
  -h               Show this help message and exit

Examples:
  # Create folder per archive, only parent links (default behavior)
  $0 -m folder -s /roms -d /output

  # Create folder per archive, including clone links based on internal files
  $0 -m folder -c file -s /roms -d /output

  # Flat symlink structure, with clones based on internal folders
  $0 -m file -c folder -s /roms -d /output -t /chdsource
EOF
    exit 1
}

# Default values
MODE=""
CLONES_MODE="only_parent"
SRC_DIR=""
DEST_BASE=""
OPERATION_TYPE="symlink"
CHD_SRC_DIR=""
DEBUG_ENABLED=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m) MODE="$2"; shift 2 ;;
        -c) CLONES_MODE="$2"; shift 2 ;;
        -s) SRC_DIR="$2"; shift 2 ;;
        -d) DEST_BASE="$2"; shift 2 ;;
        -o) OPERATION_TYPE="$2"; shift 2 ;;
        -t) CHD_SRC_DIR="$2"; shift 2 ;;
        --debug) DEBUG_ENABLED=true; shift ;;
        -h) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

# Validate required arguments
[[ -z "$MODE" || -z "$SRC_DIR" || -z "$DEST_BASE" ]] && {
    echo "Error: Missing required arguments." >&2
    usage
}

# Validate mode
[[ "$MODE" != "file" && "$MODE" != "folder" ]] && {
    echo "Error: Mode must be 'file' or 'folder'" >&2
    usage
}

# Validate clones mode
CLONES_ENABLED=false
CLONES_METHOD=""
if [[ "$CLONES_MODE" == "file" || "$CLONES_MODE" == "folder" ]]; then
    CLONES_ENABLED=true
    CLONES_METHOD="$CLONES_MODE"
elif [[ "$CLONES_MODE" != "only_parent" ]]; then
    echo "Error: Invalid clone mode: $CLONES_MODE" >&2
    usage
fi

# Validate operation type
[[ "$OPERATION_TYPE" != "symlink" && "$OPERATION_TYPE" != "copy" && "$OPERATION_TYPE" != "move" ]] && {
    echo "Error: Invalid operation: $OPERATION_TYPE" >&2
    usage
}

# Resolve paths
SRC_DIR="$(realpath "$SRC_DIR")"
DEST_BASE_ORIGINAL="$DEST_BASE"
DEST_BASE="$(realpath "$DEST_BASE")"
[[ -n "$CHD_SRC_DIR" ]] && CHD_SRC_DIR="$(realpath "$CHD_SRC_DIR")"

shopt -s nullglob

# Debug print function
debug() {
    if [[ "$DEBUG_ENABLED" == true ]]; then
        echo "DEBUG: $*" >&2
    fi
}

# Get file base name
get_base_name() {
    local filename="$1"
    basename "${filename%.*}"
}

# Perform the chosen operation: symlink (default), copy, or move
# This function returns the absolute path of the final destination if the operation was copy/move
handle_file_operation() {
    local src="$1"
    local dest="$2"
    mkdir -p "$(dirname "$dest")"

    case "$OPERATION_TYPE" in
        symlink)
            ln -sf "$src" "$dest"
            echo "$dest" # return symlink path
            ;;
        copy|move)
            if [[ "$src" != /* ]]; then
                local resolved_src="$(realpath -m "$(dirname "$dest")/$src")"
            else
                local resolved_src="$src"
            fi

            if [[ ! -e "$resolved_src" ]]; then
                echo "Warning: Source '$resolved_src' does not exist, skipping." >&2
                return 1
            fi

            if [[ "$OPERATION_TYPE" == "copy" ]]; then
                cp -f "$resolved_src" "$dest"
            else
                mv -f "$resolved_src" "$dest"
            fi
            echo "$dest" # return new location
            ;;
    esac
}

# Utility: compute relative path from a directory to a target
relative_path() {
    local target="$1"
    local base_dir="$2"
    realpath --relative-to="$base_dir" "$target"
}

# Create CHD symlink if folder exists
create_chd_symlink_if_exists() {
    local name="$1"
    local dest_dir="$2"
    [[ -z "$CHD_SRC_DIR" ]] && return
    local chd_path="$CHD_SRC_DIR/$name"
    [[ ! -d "$chd_path" ]] && return
    # Avoid creating symlink to self directory
    if [[ "$(realpath "$chd_path")" == "$(realpath "$dest_dir/$name")" ]]; then
        return
    fi
    local rel_chd=$(relative_path "$chd_path" "$dest_dir")
    handle_file_operation "$rel_chd" "$dest_dir/$name"
}

# This function finds internal files/folders within the 7z that can be considered clones.
# It returns their *base names* (e.g., "Simpsons Trivia (v1.00)" from "Simpsons Trivia (v1.00).sms").
find_internal_clone_base_names() {
    local parent_archive_path="$1" # Full path to the parent .7z archive
    local internal_clone_base_names=()
    local parent_base_name="$(basename "${parent_archive_path%.7z}")"

    if [[ ! -f "$parent_archive_path" ]]; then
        echo "Warning: Parent archive '$parent_archive_path' not found." >&2
        return
    fi

    local internal_items_raw
    if [[ "$CLONES_METHOD" == "file" ]]; then
        mapfile -t internal_items_raw < <(7z l "$parent_archive_path" | grep --fixed-strings -e " ....A " -e " ..... " | awk '{ print substr($0, 54) }' | grep -v '/')
    elif [[ "$CLONES_METHOD" == "folder" ]]; then
        mapfile -t internal_items_raw < <(7z l "$parent_archive_path" | grep --fixed-strings " D.... " | awk '{ print substr($0, 54) }')
    fi

    debug "  DEBUG: Internal items found in '$parent_archive_path':" >&2
    debug "  DEBUG: - %s\n" "${internal_items_raw[@]}" >&2

    for item_path in "${internal_items_raw[@]}"; do
        local item_base_name # This will be the potential clone name base_name
        
        if [[ "$CLONES_METHOD" == "file" ]]; then
            item_base_name="$(basename "${item_path%.*}")" # Get name without internal extension
        elif [[ "$CLONES_METHOD" == "folder" ]]; then
            item_base_name="$(basename "${item_path%/}")" # Get folder name
        fi

        debug "  DEBUG: Processed internal item '$item_path' -> potential clone base_name '$item_base_name'" >&2

        if [[ -n "$item_base_name" ]]; then
            if [[ "$item_base_name" != "$parent_base_name" ]]; then
                internal_clone_base_names+=("$item_base_name")
                debug "  DEBUG: Identified internal clone base_name: '$item_base_name'" >&2
            else
                debug "  DEBUG: Internal item '$item_base_name' matches parent base_name, skipping (not a clone for this purpose)." >&2
            fi
        else
            debug "  DEBUG: Empty item_base_name for '$item_path', skipping." >&2
        fi
    done

    if [[ ${#internal_clone_base_names[@]} -gt 0 ]]; then
        printf "%s\n" "${internal_clone_base_names[@]}"
    else
        debug "  DEBUG: No clone base_names to report for '$parent_archive_path'." >&2
    fi
}

# Process a single archive
process_archive() {
    local archive="$1"
    local ext="${archive##*.}"
    local base_name
    base_name="$(get_base_name "$archive")"
    local current_dest_dir="$DEST_BASE"

    echo "Processing $base_name.$ext"
    [[ "$MODE" == "folder" ]] && current_dest_dir="$DEST_BASE/$base_name" && mkdir -p "$current_dest_dir"

    local rel_main=$(relative_path "$archive" "$current_dest_dir")
    local parent_dest_path="$current_dest_dir/$base_name.$ext"

    resolved_parent_path=$(handle_file_operation "$rel_main" "$parent_dest_path") || {
        echo "  Skipping $archive due to error in parent operation." >&2
        return
    }
    rel_path_to_parent=$(relative_path "$parent_dest_path" "$DEST_BASE")
    echo "  ${OPERATION_TYPE^}ed main archive to $DEST_BASE_ORIGINAL/$rel_path_to_parent"

    create_chd_symlink_if_exists "$base_name" "$current_dest_dir"

    if [[ "$CLONES_ENABLED" == true ]]; then
        debug "Searching for internal clones in $archive"
        local internal_clone_base_names=()
        mapfile -t internal_clone_base_names < <(find_internal_clone_base_names "$resolved_parent_path")

        if [[ ${#internal_clone_base_names[@]} -gt 0 ]]; then
            local clones_dir="$current_dest_dir"
            [[ "$MODE" == "folder" ]] && clones_dir="$current_dest_dir/clones" && mkdir -p "$clones_dir"

            for clone_base in "${internal_clone_base_names[@]}"; do
                local clone_path="$clones_dir/$clone_base.$ext"
                local rel_target=$(relative_path "$resolved_parent_path" "$clones_dir")
                ln -sf "$rel_target" "$clone_path"
                
                echo "  Clone symlink created: $clone_path -> $rel_target"
                
                create_chd_symlink_if_exists "$base_name" "$clones_dir"
            done
        else
            debug "No internal clones found in $archive"
        fi
    fi
    echo "-------------------------------------"
}

# Main loop — agora aceita .7z e .zip
for archive in "$SRC_DIR"/*.7z "$SRC_DIR"/*.zip; do
    process_archive "$archive"
done

echo "Script execution complete."
