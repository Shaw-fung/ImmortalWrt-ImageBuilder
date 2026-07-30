#!/bin/bash
source shell/custom-packages.sh
source shell/switch_repository.sh
# 该文件实际为imagebuilder容器内的build.sh

# 检测 ipq40xx 平台设备（ARM 32位 与 aarch64 不兼容）
is_ipq40xx=false
case "$PROFILE" in
    glinet_gl-b2200|p2w_r619ac-128m|p2w_r619ac-64m)
        is_ipq40xx=true
        ;;
esac

# 配置我们的 RunFilesBuilder 仓库
RFB_REPO="Shaw-fung/RunFilesBuilder"

# 根据设备架构确定匹配关键词
if [ "$is_ipq40xx" = "true" ]; then
    ARCH_KEYWORDS="arm_cortex-a7_neon-vfpv4 aarch32 _all"
    echo "📦 设备:$PROFILE 架构: ARM 32位 (ipq40xx)"
else
    ARCH_KEYWORDS="aarch64 arm64 _all"
    echo "📦 设备:$PROFILE 架构: ARM 64位 (aarch64)"
fi

# 从我们的 RunFilesBuilder 仓库下载第三方插件 .run 包
echo "🔄 正在从 $RFB_REPO 下载第三方插件..."
mkdir -p /home/build/immortalwrt/extra-packages

# 通过 GitHub API 获取所有 release 资产链接
GH_AUTH=()
[ -n "$GITHUB_TOKEN" ] && GH_AUTH=(-H "Authorization: token $GITHUB_TOKEN")
RELEASES_JSON=$(curl -s "${GH_AUTH[@]}" "https://api.github.com/repos/${RFB_REPO}/releases")
ASSET_URLS=$(echo "$RELEASES_JSON" | grep '"browser_download_url"' | grep '\.run' | cut -d '"' -f 4)

DOWNLOAD_COUNT=0
for url in $ASSET_URLS; do
    filename=$(basename "$url")
    # 24.10 使用 opkg/ipk 包: 跳过 _apk_ 标识的包 (25.12 专用)
    if echo "$filename" | grep -qi '_apk_'; then
        echo "⏭️ 跳过 apk 包 (25.12 专用): $filename"
        continue
    fi
    # 检查文件名是否匹配当前架构或为 _all 架构（通用）
    for keyword in $ARCH_KEYWORDS; do
        if echo "$filename" | grep -qi "$keyword"; then
            echo "📥 下载: $filename"
            if wget -q --timeout=30 "$url" -P /home/build/immortalwrt/extra-packages/; then
                DOWNLOAD_COUNT=$((DOWNLOAD_COUNT + 1))
            else
                echo "⚠️ 下载失败: $filename"
            fi
            break
        fi
    done
done

if [ "$DOWNLOAD_COUNT" -gt 0 ]; then
    echo "✅ 从 $RFB_REPO 下载了 $DOWNLOAD_COUNT 个插件包"
    echo "📦 文件列表:"
    ls -lh /home/build/immortalwrt/extra-packages/*.run 2>/dev/null
    # 解压 .run 并整理 ipk 到 packages 目录
    sh shell/prepare-packages.sh
    ls -lah /home/build/immortalwrt/packages/ 2>/dev/null
else
    echo "⚠️ 未从 $RFB_REPO 获取到任何插件包"
fi

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
    URL=$(curl -s "${GH_AUTH[@]}" https://api.github.com/repos/vernesong/OpenClash/releases/latest \
      | grep "browser_download_url.*ipk" \
      | head -n1 \
      | cut -d '"' -f 4)
    echo "OpenClash latest ipk: $URL"
    wget "$URL" -P /home/build/immortalwrt/packages/
else
    echo "⚪️ 未选择 luci-app-openclash"
fi


# 修复 daede 依赖：上游未提供 ipq40xx 架构的 vmlinux-btf 和 kmod-xdp-sockets-diag
# 移除 dae/daed ipk 中这些缺失的依赖，使构建能通过
if [ "$is_ipq40xx" = "true" ]; then
    for pkg_file in /home/build/immortalwrt/packages/dae_*.ipk /home/build/immortalwrt/packages/daed_*.ipk; do
        [ -e "$pkg_file" ] || continue
        echo "🔧 移除 $pkg_file 中的缺失依赖 (vmlinux-btf, kmod-xdp-sockets-diag)..."
        mkdir -p /tmp/fix-ipk
        cd /tmp/fix-ipk
        rm -rf *
        tar xzf "$pkg_file"
        tar xzf control.tar.gz
        sed -i 's/vmlinux-btf//g; s/kmod-xdp-sockets-diag//g; s/, ,*/, /g; s/Depends: ,/Depends: /g; s/, $//g; s/  */ /g' control
        tar czf control.tar.gz control postinst prerm 2>/dev/null || tar czf control.tar.gz control
        tar czf "$pkg_file" control.tar.gz data.tar.gz debian-binary
        cd - >/dev/null
    done
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
