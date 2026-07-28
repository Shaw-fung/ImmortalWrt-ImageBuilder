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

# 修正 apk 文件名: 将版本号中的 .commit_hash-rN 转换为 ~commit_hash-rN
# Alpine apk 内部使用 ~ 作为 pre-release 版本分隔符,但部分上游 release 文件名使用 .
# 若文件名与内部版本不一致,ImageBuilder 自动生成的索引会引用 ~版本号但找不到对应文件,
# 导致 "package mentioned in index not found" 错误 (如 clashoo-2026.07.28.cb8e990-r1.apk)
for apk_file in "$TARGET_DIR"/*.apk; do
    [ -e "$apk_file" ] || continue
    base_name=$(basename "$apk_file")
    new_name=$(echo "$base_name" | sed -E 's/\.([0-9a-f]{7})-r([0-9]+)\.apk/~\1-r\2.apk/')
    if [ "$new_name" != "$base_name" ]; then
        echo "🔧 修正版本号分隔符: $base_name -> $new_name"
        mv "$apk_file" "$TARGET_DIR/$new_name"
    fi
done

# 生成 apk 索引文件 (APKINDEX.tar.gz),确保 ImageBuilder 能正确识别 packages 目录中的 .apk 文件
if command -v apk >/dev/null 2>&1; then
    echo "📦 正在生成 APKINDEX 索引..."
    cd "$TARGET_DIR" && apk index -o APKINDEX.tar.gz *.apk 2>/dev/null && cd ..
    echo "✅ APKINDEX 索引已生成"
else
    echo "⚠️ apk 命令不可用,跳过索引生成 (ImageBuilder 会自动处理)"
fi
