#!/bin/bash
set -e

# Đảm bảo script được chạy từ thư mục gốc của project
cd "$(dirname "$0")/.."

echo "Bắt đầu tạo bản build release..."
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
    
    echo "Building cho $TARGET..."
    zig build -Dtarget=$TARGET -Doptimize=ReleaseSafe
    
    # Copy và đóng gói
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
    echo "Đã tạo xong ${OUT_NAME}"
done

echo "Tất cả bản build đã sẵn sàng tại thư mục releases/"
