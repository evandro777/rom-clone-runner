#!/usr/bin/env bash
set -euo pipefail

# --- Initial Validation and Setup ---

# Function to display usage help and exit
usage() {
    echo "Usage: $(basename "$0") <roms_directory> <media_directory> <xml_file>"
    echo
    echo "This script restructures ROMs to prioritize USA versions."
    echo
    echo "Arguments:"
    echo "  <roms_directory>    Path to the main ROMs folder."
    echo "  <media_directory>   Path to the media folder (images, videos)."
    echo "  <xml_file>          Path to the gamelist.xml file to be updated."
    exit 1
}

# 1) Validate that all three parameters were provided
if [ "$#" -ne 3 ]; then
    echo "❌ Error: All three parameters are required." >&2
    usage
fi

# Assign parameters to clearly named variables
ROMS_DIR="$1"
MEDIA_DIR="$2"
XML_FILE="$3"

# 2) Validate that the paths and file exist
if [ ! -d "$ROMS_DIR" ]; then
    echo "❌ Error: ROMs directory not found at: $ROMS_DIR" >&2
    exit 1
fi

if [ ! -d "$MEDIA_DIR" ]; then
    echo "❌ Error: Media directory not found at: $MEDIA_DIR" >&2
    exit 1
fi

if [ ! -f "$XML_FILE" ]; then
    echo "❌ Error: XML file not found at: $XML_FILE" >&2
    exit 1
fi

for dir in "$ROMS_DIR"/*; do
    [ -d "$dir" ] || continue
    old_folder="$(basename "$dir")"

    # 1) Skip folders that are already (USA)
    if [[ "$old_folder" =~ (\(USA|USA\)|, USA|USA,) ]]; then
        continue
    fi

    parent_archive="$dir/${old_folder}.7z"
    if [ ! -f "$parent_archive" ]; then
        echo "⚠️  Archive not found: $parent_archive"
        continue
    fi

    # 2) List internal files (ROBUST METHOD)
    mapfile -t internal_items < <(7z l "$parent_archive" \
        | grep --fixed-strings -e " ....A " -e " ..... " \
        | awk '{ print substr($0, 54) }' \
        | grep -v '/')

    # 3) Choose the best USA ROM
    best_usa=""
    best_score=-1 # Start with -1 to ensure any valid ROM with score >= 0 is chosen

    for item in "${internal_items[@]}"; do
        # Only considers files that contain '(USA' or 'USA)' or ', USA' or 'USA, '
        echo "$item"
        if [[ ! "$item" =~ (\(USA|USA\)|, USA|USA,) ]]; then
            continue
        fi

        current_score=100 # Base score for any USA ROM

        # --- SCORE ADJUSTMENT ---

        # PRIORITIZE: Major revisions (adds points)
        # "Mega Man X (USA) (Rev 1)" > "Mega Man X (USA)"
        if [[ "$item" =~ \(Rev[[:space:]]*([0-9]+)\) ]]; then
            rev_number="${BASH_REMATCH[1]}"
            # Adiciona um valor base + o número da revisão
            current_score=$((current_score + 50 + rev_number))
        fi

        # DEPRIORITIZE: Unwanted tags (subtracts A LOT of points)
        # "X Zone (Japan, USA) (En)" > "X Zone (Japan, USA) (En) (Beta)"
        if [[ "$item" =~ \((Beta|Proto|Sample|Demo) ]]; then
        # if [[ "$item" =~ \((Beta|Proto|Sample|Demo)\) ]]; then
            current_score=$((current_score - 200))
        fi

        # DEPRIORITIZE: Virtual Console Releases (subtracts points)
        # "Super Metroid (Japan, USA)" > "Super Metroid (USA, Europe) (Switch Online)"
        if [[ "$item" =~ (Switch[[:space:]]Online|Wii|Arcade|Virtual[[:space:]]Console|Classic[[:space:]]Mini) ]]; then
            current_score=$((current_score - 100))
        fi

        # SUBTLE BONUS: Prefer ROMs that are exclusively USA or USA+Languages ​​vs. multi-region
        # "Mega Man X (USA)" > "Mega Man X (USA, Japan)"
        if [[ "$item" =~ \((USA)\) ]] || [[ "$item" =~ \((USA)\)\ \([A-Za-z,]+\) ]]; then
            current_score=$((current_score + 5))
        fi

        # SUBTLE BONUS: Prefer ROMs that are exclusively USA or USA+Languages ​​vs. multi-region
        # echo "  - Score [$current_score] for: $item"

        # Select the highest score
        if (( current_score > best_score )); then
            best_score=$current_score
            best_usa="$item"
        fi
    done

    if [[ -z "$best_usa" ]]; then
        echo "✘ skipping $old_folder: no internal USA ROM found"
        continue
    fi
    
    # 4) define new names
    new_base="${best_usa%.*}"
    new_folder="$new_base"
    old_parent="$parent_archive"
    new_parent="$dir/${new_base}.7z"

    echo "✔ found best USA: '$best_usa' → promoting to '$new_base'"

    # 5) renomeia pasta/arquivo se necessário
    if [[ "$old_folder" != "$new_folder" ]]; then
        mv "$old_parent" "$new_parent"
        mv "$dir" "$ROMS_DIR/$new_folder"
        dir="$ROMS_DIR/$new_folder"
    fi

    # 6) (re)create all symlinks into clones/
    clone_dir="$dir/clones"
    mkdir -p "$clone_dir"
    rm -f "$clone_dir"/*.7z

    for item in "${internal_items[@]}"; do
        [ "$item" == "$best_usa" ] && continue
        clone_name="${item%.*}.7z"
        ln -s "../${new_base}.7z" "$clone_dir/$clone_name"
    done

    # 7) updates patches-soft
    if [ -d "$dir/patches-soft" ]; then
        for link in "$dir/patches-soft/"*.7z; do
            [ -L "$link" ] || continue
            fname="$(basename "$link")"
            base="${fname%%__*}"
            suffix="${fname#*__}"
            new_link="${base}__${suffix}"
            rm "$link"
            ln -s "../${new_base}.7z" "$dir/patches-soft/$new_link"
        done
    fi

    # 8) Rename media files recursively
    while IFS= read -r -d '' media_file; do
        media_dir="$(dirname "$media_file")"
        media_ext="${media_file##*.}"
        new_media_file="${media_dir}/${new_base}.${media_ext}"
        mv "$media_file" "$new_media_file"
    done < <(find "$MEDIA_DIR" -type f -name "${old_folder}.*" -print0)

    # 9) Update XML <path> tag
    old_path_xml="./$old_folder"
    new_path_xml="./$new_base"

    # Prepares variables for XML format, escaping the '&' to '&amp;'
    old_path_xml_escaped="${old_path_xml//&/&amp;}"
    new_path_xml_escaped="${new_path_xml//&/&amp;}"

    # Use escaped variables to find and replace text correctly
    sed -i "s|<path>${old_path_xml_escaped}</path>|<path>${new_path_xml_escaped}</path>|g" "$XML_FILE"


    echo "✅ done: ${old_folder} → ${new_base}"
done

