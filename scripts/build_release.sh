#!/bin/bash
set -e

# Ensure script runs from project root directory
cd "$(dirname "$0")/.."

echo "Starting release build..."
mkdir -p releases

TARGETS=(
    "x86_64-linux-gnu:mini-agent-linux-x86_64"
    "aarch64-linux-gnu:mini-agent-linux-aarch64"
    "x86_64-macos:mini-agent-macos-x86_64"
    "aarch64-macos:mini-agent-macos-aarch64"
    "x86_64-windows:mini-agent-windows-x86_64"
)

for target_info in "${TARGETS[@]}"; do
    TARGET="${target_info%%:*}"
    OUT_NAME="${target_info##*:}"
    
    echo "Building for $TARGET..."
    zig build -Dtarget=$TARGET -Doptimize=ReleaseSafe
    
    # Copy and package
    if [[ "$TARGET" == *"windows"* ]]; then
        mv zig-out/bin/mini.exe releases/${OUT_NAME}.exe
        cd releases
        zip ${OUT_NAME}.zip ${OUT_NAME}.exe
        rm ${OUT_NAME}.exe
        cd ..
    else
        mv zig-out/bin/mini releases/${OUT_NAME}
        cd releases
        chmod +x ${OUT_NAME}
        tar -czf ${OUT_NAME}.tar.gz ${OUT_NAME}
        rm ${OUT_NAME}
        cd ..
    fi
    echo "Completed ${OUT_NAME}"
done

echo "All release builds ready in releases/ directory."
