#!/bin/bash
source shell/custom-packages.sh
source shell/switch_repository.sh
# 该文件实际为imagebuilder容器内的build.sh

# 检测 ipq40xx 平台设备（ARM 32位）
is_ipq40xx=false
case "$PROFILE" in
    glinet_gl-b2200|p2w_r619ac-128m|p2w_r619ac-64m)
        is_ipq40xx=true
        ;;
esac

# 根据架构确定 run 包匹配关键词和 arch 优先级
if [ "$is_ipq40xx" = "true" ]; then
    ARCH_KEYWORDS=("arm_cortex-a7" "aarch32" "_all")
    ARCH_LINE="arch arm_cortex-a7_neon-vfpv4 20"
    echo "📦 设备:$PROFILE 架构: ARM 32位 (ipq40xx)"
else
    ARCH_KEYWORDS=("aarch64" "arm64" "_all")
    ARCH_LINE="arch aarch64_generic 10\narch aarch64_cortex-a53 15"
    echo "📦 设备:$PROFILE 架构: ARM 64位"
fi

# 从本仓库 Release 下载对应架构的第三方插件 run 包
echo "🔄 正在从本仓库 Release 下载第三方插件 run 包..."
mkdir -p /home/build/immortalwrt/extra-packages

GITHUB_REPO="${GITHUB_REPOSITORY:-Shaw-fung/ImmortalWrt-ImageBuilder}"
RELEASES_API="https://api.github.com/repos/${GITHUB_REPO}/releases"
TEMP_ASSETS="/tmp/assets_list.txt"

# 遍历所有 release 找匹配架构的 run 文件
curl -s "${RELEASES_API}?per_page=30" 2>/dev/null \
    | jq -r '.[].assets[] | "\(.name)|\(.browser_download_url)"' 2>/dev/null > "$TEMP_ASSETS"

DOWNLOAD_COUNT=0
if [ -s "$TEMP_ASSETS" ]; then
    while IFS='|' read -r name url; do
        [ -z "$name" ] && continue
        # 只处理 .run 文件
        [[ "$name" != *.run ]] && continue

        # 检查文件名是否匹配当前架构
        matched=false
        for kw in "${ARCH_KEYWORDS[@]}"; do
            if [[ "$name" == *"$kw"* ]]; then
                matched=true
                break
            fi
        done

        if [ "$matched" = true ]; then
            echo "⬇️ 下载: $name"
            if curl -fsL -o "/home/build/immortalwrt/extra-packages/$name" "$url" 2>/dev/null; then
                DOWNLOAD_COUNT=$((DOWNLOAD_COUNT + 1))
            fi
        fi
    done < "$TEMP_ASSETS"
fi
rm -f "$TEMP_ASSETS"

echo "✅ 已下载 $DOWNLOAD_COUNT 个 run 包"
ls -lh /home/build/immortalwrt/extra-packages/*.run 2>/dev/null || echo "⚠️ 没有下载到 run 包（可能是首次运行，release 还未生成）"

# 解压 run 包并拷贝 ipk 到 packages 目录
if [ "$DOWNLOAD_COUNT" -gt 0 ]; then
    sh shell/prepare-packages.sh
    ls -lah /home/build/immortalwrt/packages/
fi

# 添加架构优先级信息
sed -i "1i\\$ARCH_LINE" repositories.conf



# yml 传入的路由器型号 PROFILE
echo "Building for profile: $PROFILE"

echo "Include Docker: $INCLUDE_DOCKER"
echo "Create pppoe-settings"
mkdir -p  /home/build/immortalwrt/files/etc/config

# 创建pppoe配置文件 yml传入pppoe变量————>pppoe-settings文件
cat << EOF > /home/build/immortalwrt/files/etc/config/pppoe-settings
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT}
pppoe_password=${PPPOE_PASSWORD}
EOF

echo "cat pppoe-settings"
cat /home/build/immortalwrt/files/etc/config/pppoe-settings

# 输出调试信息
echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting build process..."


# 定义所需安装的包列表 下列插件你都可以自行删减
PACKAGES=""
PACKAGES="$PACKAGES curl luci luci-i18n-base-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
#24.10.0
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"
# 文件管理器
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"


# 第三方软件包 合并
# ======== shell/custom-packages.sh =======
if [ "$PROFILE" = "glinet_gl-axt1800" ] || [ "$PROFILE" = "glinet_gl-ax1800" ]; then
    # 这2款 暂时不支持第三方插件的集成 snapshot版本太高 opkg换成apk包管理器 6.12内核 
    echo "Model:$PROFILE not support third-parted packages"
    PACKAGES="$PACKAGES -luci-i18n-diskman-zh-cn luci-i18n-homeproxy-zh-cn"
else
    echo "Other Model:$PROFILE"
    PACKAGES="$PACKAGES $CUSTOM_PACKAGES"
fi

# 判断是否需要编译 Docker 插件
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "Adding package: luci-i18n-dockerman-zh-cn"
fi

# 若构建openclash 则添加内核
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，添加 openclash core"
    mkdir -p files/etc/openclash/core
    # Download clash_meta (根据架构选择 arm 或 arm64 版本)
    if [ "$is_ipq40xx" = "true" ]; then
        META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm.tar.gz"
    else
        META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz"
    fi
    wget -qO- $META_URL | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta
    # Download GeoIP and GeoSite
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat
    # Download latest openclash Client
    URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases/latest \
      | grep "browser_download_url.*ipk" \
      | head -n1 \
      | cut -d '"' -f 4)
    echo "OpenClash latest ipk: $URL"
    wget "$URL" -P /home/build/immortalwrt/packages/
else
    echo "⚪️ 未选择 luci-app-openclash"
fi


# 构建镜像
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

make image PROFILE=$PROFILE PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files"

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
