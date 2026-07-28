#!/bin/sh

BASE_DIR="extra-packages"
TEMP_DIR="$BASE_DIR/temp-unpack"
TARGET_DIR="packages"

# 清理旧的目录
rm -rf "$TEMP_DIR" "$TARGET_DIR"
mkdir -p "$TEMP_DIR" "$TARGET_DIR"

# 解压 .run 文件
for run_file in "$BASE_DIR"/*.run; do
    [ -e "$run_file" ] || continue
    echo "🧩 解压 $run_file -> $TEMP_DIR"
    sh "$run_file" --target "$TEMP_DIR" --noexec
done

# 1. 收集 run 解压出的 .apk 文件
find "$TEMP_DIR" -type f -name "*.apk" -exec cp -v {} "$TARGET_DIR"/ \;

# 2. 收集 extra-packages/*/ 下的 .apk 文件（只查一级子目录）

find "$BASE_DIR" -mindepth 2 -maxdepth 2 -type f -name "*.apk" ! -path "$TEMP_DIR/*" \
  -exec echo "👉 Found:" {} \; \
  -exec cp -v {} "$TARGET_DIR"/ \;

echo "✅ 所有 .apk 文件已整理至 $TARGET_DIR/"

# 生成 apk 索引文件 (APKINDEX.tar.gz),确保 ImageBuilder 能正确识别 packages 目录中的 .apk 文件
# apk index 通过读取 .apk 文件内部元数据识别包,不依赖文件名
if command -v apk >/dev/null 2>&1; then
    echo "📦 正在生成 APKINDEX 索引..."
    cd "$TARGET_DIR" && apk index -o APKINDEX.tar.gz *.apk 2>/dev/null && cd ..
    echo "✅ APKINDEX 索引已生成"
else
    echo "⚠️ apk 命令不可用,跳过索引生成 (ImageBuilder 会自动处理)"
fi
