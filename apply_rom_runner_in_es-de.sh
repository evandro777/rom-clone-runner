#!/bin/bash

# Function to display script usage
# Arguments: None
# Returns: None
usage() {
    echo "Usage: $0 <path_to_es_systems.xml>"
    echo ""
    echo "This script modifies the es_systems.xml file to prepend 'rom_runner_wrapper ' to specific command lines"
    echo "and also adjusts the 'MAME - Current' command for specific systems."
    echo "System names and command labels are predefined within the script."
    echo ""
    echo "Arguments:"
    echo "  <path_to_es_systems.xml> : The absolute or relative path to the es_systems.xml file."
    echo ""
    echo "Example:"
    echo "  $0 /etc/emulationstation/es_systems.xml"
    exit 1
}

# --- Default Configuration Constants ---
# Comma-separated list of system names to target for 'rom_runner_wrapper' addition.
DEFAULT_SYSTEM_NAMES="gamegear,megadrive,mastersystem,gba,n64,nes,satellaview,sega32x,sega32xjp,sega32xna,sfc,snes,snesna,sufami"

# Comma-separated list of command labels to target for 'rom_runner_wrapper' addition.
DEFAULT_COMMAND_LABELS="Genesis Plus GX,Genesis Plus GX Wide,mGBA,Mupen64Plus-Next,Mesen,Snes9x - Current,PicoDrive"

# Wrapper string to be prepended
WRAPPER="rom_runner_wrapper "

# MAME specific command old and new strings
OLD_MAME_CMD='<command label="MAME - Current">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/mame_libretro.so %ROM%</command>'
NEW_MAME_CMD='<command label="MAME - Current">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/mame_libretro.so %GAMEDIR%/%BASENAME%</command>'
# --- End Default Configuration Constants ---


# Initialize variables
ES_SYSTEMS_FILE=""

# Parse command line arguments - expecting only the file path
if [ "$#" -ne 1 ]; then
    usage
fi
ES_SYSTEMS_FILE="$1"


# Check if the provided XML file exists
if [ ! -f "$ES_SYSTEMS_FILE" ]; then
    echo "Error: File '$ES_SYSTEMS_FILE' not found."
    exit 1
fi

sudo cp rom_runner_wrapper.sh /bin/rom_runner_wrapper
sudo cp rom_manager.sh /bin/rom_manager

# --- Create a backup of the original file ---
BACKUP_FILE="${ES_SYSTEMS_FILE}.bak"
cp "$ES_SYSTEMS_FILE" "$BACKUP_FILE"
echo "Backup created: '$BACKUP_FILE'"

# Create arrays from default comma-separated strings
IFS=',' read -r -a TARGET_SYSTEMS <<< "$DEFAULT_SYSTEM_NAMES"
IFS=',' read -r -a TARGET_LABELS <<< "$DEFAULT_COMMAND_LABELS"

# Create a temporary file for modifications
TEMP_FILE=$(mktemp)
# Copy original to temp for modification. Operations will be performed on TEMP_FILE.
cp "$ES_SYSTEMS_FILE" "$TEMP_FILE" 

SYSTEM_START_LINE=0
SYSTEM_NAME="" # Initialize system name
IS_TARGET_SYSTEM=false # Initialize flag

# Loop through the file to find system blocks
# `cat -n` is used to number lines so we can process them sequentially
while IFS= read -r line; do
    CURRENT_LINE_NUM=$(echo "$line" | awk '{print $1}')
    LINE_CONTENT=$(echo "$line" | cut -d' ' -f2-) # Extract content without line number

    # 1. Find the start of a system block
    if [[ "$LINE_CONTENT" =~ \<system\> ]]; then
        SYSTEM_START_LINE=$CURRENT_LINE_NUM
        SYSTEM_NAME="" # Reset system name for new block
        IS_TARGET_SYSTEM=false # Reset target system flag
        continue # Move to next line to find name
    fi

    # If we are inside a system block (SYSTEM_START_LINE > 0)
    if [[ "$SYSTEM_START_LINE" -gt 0 ]]; then
        # 2. Find the system name within this block
        if [[ "$LINE_CONTENT" =~ \<name\>([^\<]+)\<\/name\> ]]; then
            SYSTEM_NAME="${BASH_REMATCH[1]}" # Capture the name
            # Check if this system name is in our target list for wrapper addition
            for target_sys in "${TARGET_SYSTEMS[@]}"; do
                if [[ "$SYSTEM_NAME" == "$target_sys" ]]; then
                    IS_TARGET_SYSTEM=true
                    break
                fi
            done
        fi

        # 3. Find the end of the system block
        if [[ "$LINE_CONTENT" =~ \<\/system\> ]]; then
            # If we found an end tag, we finished processing this block.
            SYSTEM_START_LINE=0 # Reset for the next system block
            SYSTEM_NAME="" # Reset system name
            IS_TARGET_SYSTEM=false # Reset target system flag
            continue
        fi

        # 4. If it's a target system, check for command labels and modify for rom_runner_wrapper
        if [[ "$IS_TARGET_SYSTEM" == true ]]; then
            # Regex to find command lines that match target labels AND start with %EMULATOR_RETROARCH%
            if [[ "$LINE_CONTENT" =~ \<command\ label=\"([^\"]+)\"\>(%EMULATOR_RETROARCH%.*)\<\/command\> ]]; then
                COMMAND_LABEL="${BASH_REMATCH[1]}" # Capture the label

                # Check if this command label is in our target list
                IS_TARGET_LABEL=false
                for target_lbl in "${TARGET_LABELS[@]}"; do
                    if [[ "$COMMAND_LABEL" == "$target_lbl" ]]; then
                        IS_TARGET_LABEL=true
                        break
                    fi
                done

                # If both system and label match, and the line starts with %EMULATOR_RETROARCH%
                if [[ "$IS_TARGET_LABEL" == true ]]; then
                    # Escape special characters in the WRAPPER for sed
                    ESCAPED_WRAPPER=$(printf '%s\n' "$WRAPPER" | sed -e 's/[\/&]/\\&/g')

                    # Use sed to replace %EMULATOR_RETROARCH% with "rom_runner_wrapper %EMULATOR_RETROARCH%"
                    sed -i "${CURRENT_LINE_NUM}s|%EMULATOR_RETROARCH%|$ESCAPED_WRAPPER%EMULATOR_RETROARCH%|" "$TEMP_FILE"
                    echo "Modified line $CURRENT_LINE_NUM for system '$SYSTEM_NAME', label '$COMMAND_LABEL' (added rom_runner_wrapper)"
                fi
            fi
        fi
    fi

    # --- Additional specific modification for MAME - Current command ---
    # This modification applies regardless of the system name,
    # it's a direct find-and-replace for this specific line structure.
    # Check if the line matches the exact MAME - Current pattern to be changed
    # Using `*` to allow for potential leading/trailing whitespace
    if [[ "$LINE_CONTENT" == *"$OLD_MAME_CMD"* ]]; then
        # Escape special characters for sed from the constants
        ESCAPED_OLD_MAME_CMD=$(printf '%s\n' "$OLD_MAME_CMD" | sed -e 's/[\/&]/\\&/g')
        ESCAPED_NEW_MAME_CMD=$(printf '%s\n' "$NEW_MAME_CMD" | sed -e 's/[\/&]/\\&/g')

        # Use sed to replace the specific MAME line at its current line number
        sed -i "${CURRENT_LINE_NUM}s|${ESCAPED_OLD_MAME_CMD}|${ESCAPED_NEW_MAME_CMD}|" "$TEMP_FILE"
        echo "Modified line $CURRENT_LINE_NUM for 'MAME - Current' (changed %ROM% to %GAMEDIR%/%BASENAME%)"
    fi

done < <(cat -n "$TEMP_FILE") # Read from TEMP_FILE to ensure all changes apply sequentially

# Replace the original file with the modified temporary file
mv "$TEMP_FILE" "$ES_SYSTEMS_FILE"

echo "File '$ES_SYSTEMS_FILE' updated successfully!"

exit 0
