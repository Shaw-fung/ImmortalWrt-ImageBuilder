#!/bin/bash
source shell/apk-custom-packages.sh

# 检测 ipq40xx 平台设备（ARM 32位 与 aarch64 不兼容）
is_ipq40xx=false
case "$PROFILE" in
    glinet_gl-b2200|p2w_r619ac-128m|p2w_r619ac-64m)
        is_ipq40xx=true
        ;;
esac

if [ "$is_ipq40xx" = "true" ]; then
    # ipq40xx 是 ARM 32位平台 跳过 aarch64 预编译第三方apk包 避免兼容性问题
    # 但保留 CUSTOM_PACKAGES 中的插件名称 来自 ImmortalWrt 官方仓库的插件(如 luci-i18n-*-zh-cn)仍可正常安装
    echo "⚠️ 检测到 ipq40xx 设备:$PROFILE 跳过 aarch64 预编译第三方apk包"
    echo "ℹ️ CUSTOM_PACKAGES 中的官方仓库插件仍可正常安装"
else
  #echo "✅ 你选择了第三方软件包：$CUSTOM_PACKAGES"
  if [ -z "$CUSTOM_PACKAGES" ]; then
    echo "⚪️ 未选择 任何第三方软件包"
  else
    # ============= 同步第三方插件库==============
    # 同步第三方软件仓库run/apk
    echo "🔄 正在同步第三方软件仓库 Cloning apk file repo..."
    git clone --depth=1 https://github.com/wukongdaily/apk.git /tmp/store-apk-repo

    # 拷贝 run/arm64 下所有 run 文件和apk文件 到 extra-packages 目录
    mkdir -p /home/build/immortalwrt/extra-packages
    cp -r /tmp/store-apk-repo/run/arm64-a53/* /home/build/immortalwrt/extra-packages/

    echo "✅ Run files copied to extra-packages:"
    # 解压并拷贝apk到packages目录
    sh shell/apk-prepare-packages.sh
    ls -lah /home/build/immortalwrt/packages/
  fi
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
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"
# 文件管理器
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"


# 第三方软件包 合并
# ======== shell/apk-custom-packages.sh =======
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
      | grep "browser_download_url.*apk" \
      | head -n1 \
      | cut -d '"' -f 4)
    echo "OpenClash latest apk: $URL"
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
