#!/bin/bash
MODS_DIR="/Users/lincolncarlton/Library/Application Support/Steam/steamapps/common/Transport Fever 2/mods"
SOURCE_DIR="/Users/lincolncarlton/Dev/tf2_AI_mod"
TARGET_DIR="$MODS_DIR/AI_Optimizer_1"

echo "Installing mod to $TARGET_DIR"

if [ -L "$TARGET_DIR" ]; then
    echo "Removing existing symlink..."
    rm "$TARGET_DIR"
elif [ -d "$TARGET_DIR" ]; then
    echo "Backing up existing mod..."
    mv "$TARGET_DIR" "${TARGET_DIR}_bak_$(date +%s)"
fi

echo "Creating symlink..."
ln -s "$SOURCE_DIR" "$TARGET_DIR"

ls -l "$MODS_DIR" | grep AI_Optimizer
echo "Done."
