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

if [ -n "$CUSTOM_PACKAGES" ]; then
  echo "✅ 你选择了第三方软件包：$CUSTOM_PACKAGES"
  if [ "$PROFILE" = "glinet_gl-mt3000" ]; then
    echo "❌ 检查到您集成了第三方软件包 由于mt3000闪存空间较小 不支持此操作"
    echo "✅ 系统将自动帮你注释掉shell/custom-packages.sh中的插件 目前支持第三方插件集成的机型是mt2500/mt6000等大闪存机型"
    CUSTOM_PACKAGES=""
  else
    # 从 RunFilesBuilder 仓库下载第三方插件 .run 包
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
    # 添加架构优先级信息
    sed -i '1i\
    arch aarch64_generic 10\n\
    arch aarch64_cortex-a53 15' repositories.conf
  fi
else
  echo "⚪️ 未选择任何第三方软件包"
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
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-i18n-filebrowser-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
#23.05
PACKAGES="$PACKAGES luci-i18n-opkg-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES luci-i18n-passwall-zh-cn"
PACKAGES="$PACKAGES luci-app-openclash"
PACKAGES="$PACKAGES luci-i18n-homeproxy-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"
# 增加几个必备组件 方便用户安装iStore
PACKAGES="$PACKAGES fdisk"
PACKAGES="$PACKAGES script-utils"
# 第三方软件包 合并
# ======== shell/custom-packages.sh =======
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

# 判断是否需要编译 Docker 插件
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "Adding package: luci-i18n-dockerman-zh-cn"
fi

# 若构建openclash 则添加内核
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，添加 openclash core"
    mkdir -p files/etc/openclash/core
    # Download clash_meta
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz"
    wget -qO- $META_URL | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta
    # Download GeoIP and GeoSite
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat
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
