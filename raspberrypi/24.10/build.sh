#!/bin/bash
source shell/custom-packages.sh
source shell/switch_repository.sh
echo "第三方软件包: $CUSTOM_PACKAGES"
# yml 传入的路由器型号 PROFILE
echo "Building for profile: $PROFILE"
echo "Include Docker: $INCLUDE_DOCKER"
# yml 传入的固件大小 ROOTFS_PARTSIZE
echo "Building for ROOTFS_PARTSIZE: $ROOTSIZE"
if [ -z "$CUSTOM_PACKAGES" ]; then
  echo "⚪️ 未选择 任何第三方软件包"
else
  # 配置我们的 RunFilesBuilder 仓库
  RFB_REPO="Shaw-fung/RunFilesBuilder"
  ARCH_KEYWORDS="aarch64 arm64 _all"

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
fi


LUCI_VERSION="${LUCI_VERSION:-24.10.4}"  # workflow 传入的luci版本，默认为24.10.4
# 根据 PROFILE 选择 CPU_ARCH
case "$PROFILE" in
  rpi-3)
    CPU_ARCH="aarch64_cortex-a53"
    ;;
  rpi-4)
    CPU_ARCH="aarch64_cortex-a72"
    ;;
  rpi-5)
    CPU_ARCH="aarch64_cortex-a76"
    ;;
  *)
    CPU_ARCH="aarch64_generic"
    ;;
esac

# 插入架构优先级 (aarch64_cortex-a53 作为回退架构,用于安装 .run 包中的第三方插件)
sed -i "1i\
arch aarch64_generic 10\n\
arch $CPU_ARCH 15\n\
arch aarch64_cortex-a53 5" repositories.conf

# 修改树莓派 repositories.conf 仓库路径，使通用包使用 aarch64_generic，并动态填 LUCI_VERSION
sed -i -E "s|(src/gz immortalwrt_base .*aarch64_cortex-a[0-9]+)/base|src/gz immortalwrt_base https://downloads.immortalwrt.org/releases/$LUCI_VERSION/packages/aarch64_generic/base|" repositories.conf
sed -i -E "s|(src/gz immortalwrt_luci .*aarch64_cortex-a[0-9]+)/luci|src/gz immortalwrt_luci https://downloads.immortalwrt.org/releases/$LUCI_VERSION/packages/aarch64_generic/luci|" repositories.conf
sed -i -E "s|(src/gz immortalwrt_packages .*aarch64_cortex-a[0-9]+)/packages|src/gz immortalwrt_packages https://downloads.immortalwrt.org/releases/$LUCI_VERSION/packages/aarch64_generic/packages|" repositories.conf
sed -i -E "s|(src/gz immortalwrt_routing .*aarch64_cortex-a[0-9]+)/routing|src/gz immortalwrt_routing https://downloads.immortalwrt.org/releases/$LUCI_VERSION/packages/aarch64_generic/routing|" repositories.conf
sed -i -E "s|(src/gz immortalwrt_telephony .*aarch64_cortex-a[0-9]+)/telephony|src/gz immortalwrt_telephony https://downloads.immortalwrt.org/releases/$LUCI_VERSION/packages/aarch64_generic/telephony|" repositories.conf
echo "✅ repositories.conf updated for $PROFILE with generic fallback and LUCI_VERSION=$LUCI_VERSION"
echo "Current repositories.conf content:"
cat repositories.conf

# passwall2 依赖的 shadowsocks-libev-ss-local 和 ss-redir 不在 .run 包中
# 从 dl.openwrt.ai 的 kiddin9 仓库补充下载
SS_ARCH="aarch64_cortex-a53"
SS_BASE_URL="https://dl.openwrt.ai/packages-24.10/${SS_ARCH}/kiddin9/"
for ss_pkg in shadowsocks-libev-ss-local shadowsocks-libev-ss-redir shadowsocksr-libev-ssr-local shadowsocksr-libev-ssr-redir; do
    SS_PAGE=$(curl -s "$SS_BASE_URL")
    SS_FILE=$(echo "$SS_PAGE" | grep -oP "href=\"\K[^\"]*${ss_pkg}[^\"]*\.ipk" | head -n1)
    if [ -n "$SS_FILE" ]; then
        echo "📥 补充下载依赖: $ss_pkg -> $SS_FILE"
        wget -q "${SS_BASE_URL}${SS_FILE}" -P /home/build/immortalwrt/packages/
    else
        echo "⚠️ 未找到 $ss_pkg (可从 passwall2 的 CUSTOM_PACKAGES 中移除以跳过)"
    fi
done

# 输出调试信息
echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting build process..."


# 定义所需安装的包列表
PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
# 服务——FileBrowser 用户名admin 密码admin
PACKAGES="$PACKAGES luci-i18n-filebrowser-go-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"

#24.10
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"
# ======== shell/custom-packages.sh =======
# 合并imm仓库以外的第三方插件
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

if echo "$PACKAGES" | grep -q "luci-app-ssr-plus"; then
    echo "✅ 已选择 luci-app-ssr-plus，添加 mihomo core"
    mkdir -p files/usr/bin
    # Download mihomo
    MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.24/mihomo-linux-arm64-v1.19.24.gz"
    mkdir -p files/usr/bin
    wget -qO- "$MIHOMO_URL" | gzip -dc > files/usr/bin/mihomo
    chmod +x files/usr/bin/mihomo
    echo "✅ 已下载 mihomo core"
    ls -lah files/usr/bin
else
    echo "⚪️ 未选择 luci-app-ssr-plus"
fi



# 构建镜像
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

make image PROFILE=$PROFILE PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=$ROOTSIZE

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
