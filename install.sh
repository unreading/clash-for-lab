# shellcheck disable=SC2148
# shellcheck disable=SC1091
. script/common.sh >/dev/null 2>&1
. script/clashctl.sh >/dev/null 2>&1

# ==================== [功能] 自定义路径解析逻辑 ====================
usage() {
    echo "用法: $0 [-d <安装路径>]"
    echo "  -d <path>   直接指定安装目录 (跳过互动询问)"
    exit 1
}

CUSTOM_INSTALL_DIR=""
SKIP_INTERACTIVE=false

# 1. 解析命令行参数 (-d)
while getopts ":d:h" opt; do
  case $opt in
    d)
      CUSTOM_INSTALL_DIR="$OPTARG"
      SKIP_INTERACTIVE=true
      ;;
    h)
      usage
      ;;
    \?)
      echo "无效选项: -$OPTARG" >&2
      usage
      ;;
  esac
done

# 2. 如果没有通过 -d 指定，进入互动模式
if [ "$SKIP_INTERACTIVE" = false ]; then
    # 显示默认目录
    _okcat '📍' "默认安装目录: $MIHOMO_BASE_DIR"
    
    # 询问是否使用默认目录
    echo -n "$(_okcat '🤔' '是否安装到默认目录? [Y/n]: ')"
    read -r choice
    
    case "$choice" in
        [nN]|[nN][oO])
            # 用户选择 No，提示输入新路径
            echo -n "$(_okcat '📂' '请输入自定义安装路径: ')"
            read -r input_path
            
            if [ -z "$input_path" ]; then
                _error_quit "未输入有效路径，安装已取消"
            fi
            CUSTOM_INSTALL_DIR="$input_path"
            ;;
        *)
            _okcat '👌' "使用默认目录..."
            ;;
    esac
fi

# 3. 如果设定了自定义路径 (无论是通过 -d 还是互动输入)，进行环境配置更新
if [ -n "$CUSTOM_INSTALL_DIR" ]; then
    # 处理波浪号 ~ (Bash 中 read 不会自动展开 ~)
    if [[ "$CUSTOM_INSTALL_DIR" == ~* ]]; then
        CUSTOM_INSTALL_DIR="${HOME}${CUSTOM_INSTALL_DIR:1}"
    fi

    # 处理相对路径转绝对路径
    case "$CUSTOM_INSTALL_DIR" in
        /*) MIHOMO_BASE_DIR="$CUSTOM_INSTALL_DIR" ;;
        *)  MIHOMO_BASE_DIR="$(pwd)/$CUSTOM_INSTALL_DIR" ;;
    esac

    # 更新依赖 MIHOMO_BASE_DIR 的衍生变量
    MIHOMO_SCRIPT_DIR="${MIHOMO_BASE_DIR}/script"
    MIHOMO_CONFIG_URL="${MIHOMO_BASE_DIR}/url"
    
    # 重新调用 _set_bin 更新二进制文件路径
    _set_bin
    
    _okcat '🎯' "目标安装目录已变更为: $MIHOMO_BASE_DIR"
fi
# ================================================================

# 用于检查环境是否有效
_valid_env

if [ -d "$MIHOMO_BASE_DIR" ]; then
    _error_quit "请先执行卸载脚本,以清除安装路径：$MIHOMO_BASE_DIR"
fi

_get_kernel

# 创建用户目录结构
mkdir -p "$MIHOMO_BASE_DIR"/{bin,config,logs}

# 解压并安装二进制文件到用户目录
if ! gzip -dc "$ZIP_KERNEL" > "${MIHOMO_BASE_DIR}/bin/$BIN_KERNEL_NAME"; then
    _error_quit "解压内核文件失败: $ZIP_KERNEL"
fi
chmod +x "${MIHOMO_BASE_DIR}/bin/$BIN_KERNEL_NAME"

if ! tar -xf "$ZIP_SUBCONVERTER" -C "${MIHOMO_BASE_DIR}/bin"; then
    _error_quit "解压 subconverter 失败: $ZIP_SUBCONVERTER"
fi

if ! tar -xf "$ZIP_YQ" -C "${MIHOMO_BASE_DIR}/bin"; then
    _error_quit "解压 yq 失败: $ZIP_YQ"
fi

# 重命名 yq 二进制文件（yq_linux_amd64 -> yq）
for yq_file in "${MIHOMO_BASE_DIR}/bin"/yq_*; do
    if [ -f "$yq_file" ]; then
        mv "$yq_file" "${MIHOMO_BASE_DIR}/bin/yq"
        break
    fi
done
chmod +x "${MIHOMO_BASE_DIR}/bin/yq"

# 设置二进制文件路径
_set_bin

# 验证或获取配置文件
url=""
if ! _valid_config "$RESOURCES_CONFIG"; then
    echo -n "$(_okcat '✈️ ' '输入订阅：')"
    read -r url
    _okcat '⏳' '正在下载...'

    if ! _download_config "$RESOURCES_CONFIG" "$url"; then
        _error_quit "下载失败: 请将配置内容写入 $RESOURCES_CONFIG 后重新安装"
    fi

    if ! _valid_config "$RESOURCES_CONFIG"; then
        _error_quit "配置无效，请检查配置：$RESOURCES_CONFIG，转换日志：$BIN_SUBCONVERTER_LOG"
    fi
fi
_okcat '✅' '配置可用'

if [ -n "$url" ]; then
    echo "$url" > "$MIHOMO_CONFIG_URL"
fi

cp -rf "$SCRIPT_BASE_DIR" "$MIHOMO_BASE_DIR/"
cp "$RESOURCES_BASE_DIR"/*.yaml "$MIHOMO_BASE_DIR/" 2>/dev/null || true
cp "$RESOURCES_BASE_DIR"/*.mmdb "$MIHOMO_BASE_DIR/" 2>/dev/null || true
cp "$RESOURCES_BASE_DIR"/*.dat "$MIHOMO_BASE_DIR/" 2>/dev/null || true

# ==================== [关键] 固化安装路径 ====================
# 如果使用了自定义路径，必须修改安装好的 common.sh，否则运行时找不到路径
if [ -n "$CUSTOM_INSTALL_DIR" ]; then
    sed -i "s|^MIHOMO_BASE_DIR=.*|MIHOMO_BASE_DIR=\"$MIHOMO_BASE_DIR\"|g" "$MIHOMO_BASE_DIR/script/common.sh"
fi
# ===========================================================

if ! tar -xf "$ZIP_UI" -C "$MIHOMO_BASE_DIR"; then
    _error_quit "解压 UI 文件失败: $ZIP_UI"
fi

# 设置 shell 配置
_set_rc

# 启动代理服务
mihomoctl on

# 显示 Web UI 信息
clashui

_okcat '🎉' 'mihomo 用户空间代理已安装完成！'
_okcat '📝' '使用说明：'
_okcat '💡' '命令前缀: clash | mihomo | mihomoctl'
_okcat '  • 开启/关闭: clash on/off'
_okcat '  • 重启服务: clash restart'
_okcat '  • 查看状态: clash status'
_okcat '  • Web控制台: clash ui'
_okcat '  • 更新订阅: clash update [auto|log]'
_okcat '  • 设置订阅: clash subscribe [URL]'
_okcat '  • 系统代理: clash proxy [on|off|status]'
_okcat '  • 局域网访问: clash lan [on|off|status]'
_okcat ''
_okcat '🏠' "安装目录: $MIHOMO_BASE_DIR"
_okcat '📁' "配置目录: $MIHOMO_BASE_DIR/config/"
_okcat '📋' "日志目录: $MIHOMO_BASE_DIR/logs/"

_quit