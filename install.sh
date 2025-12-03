#!/bin/bash
# shellcheck disable=SC2148
# shellcheck disable=SC1091

# 加载依赖
. script/common.sh >/dev/null 2>&1
. script/clashctl.sh >/dev/null 2>&1

# ==================== [新增] 重写环境变量写入函数 ====================
# 覆盖 common.sh 中的默认函数，以支持写入中文注释
_set_rc() {
    local cmd="source $MIHOMO_SCRIPT_DIR/common.sh && source $MIHOMO_SCRIPT_DIR/clashctl.sh && watch_proxy"
    local comment="# ====== Mihomo 代理 ======"
    
    # 遍历 Bash 和 Zsh 的配置文件
    for rc_file in "$SHELL_RC_BASH" "$SHELL_RC_ZSH"; do
        [ -f "$rc_file" ] || continue
        
        # 1. 清理旧配置 (防止重复堆积)
        # 删除包含脚本路径的 source 行
        sed -i "\|$MIHOMO_SCRIPT_DIR|d" "$rc_file" 2>/dev/null
        # 删除旧的注释行 (精确匹配)
        sed -i "/^# ====== Mihomo 代理 ======$/d" "$rc_file" 2>/dev/null
        
        # 2. 写入新配置
        echo "" >> "$rc_file"
        echo "$comment" >> "$rc_file"
        echo "$cmd" >> "$rc_file"
        
        # 3. 反馈
        # echo "已更新: $rc_file"
    done
}
# =================================================================

# ==================== 自定义路径解析逻辑 ====================
usage() {
    echo "用法: $0 [-d <安装路径>]"
    echo "  -d <path>   直接指定安装目录 (跳过互动询问)"
    exit 1
}

CUSTOM_INSTALL_DIR=""
SKIP_INTERACTIVE=false

# 解析命令行参数
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

# 如果没有通过 -d 指定，进入互动模式
if [ "$SKIP_INTERACTIVE" = false ]; then
    _okcat '📍' "默认安装目录: $MIHOMO_BASE_DIR"
    echo -n "$(_okcat '🤔' '是否安装到默认目录? [Y/n]: ')"
    read -r choice
    case "$choice" in
        [nN]|[nN][oO])
            echo -n "$(_okcat '📂' '请输入自定义安装路径: ')"
            read -r input_path
            [ -z "$input_path" ] && _error_quit "未输入有效路径"
            CUSTOM_INSTALL_DIR="$input_path"
            ;;
        *) _okcat '👌' "使用默认目录..." ;;
    esac
fi

# 应用自定义路径并更新相关变量
if [ -n "$CUSTOM_INSTALL_DIR" ]; then
    [[ "$CUSTOM_INSTALL_DIR" == ~* ]] && CUSTOM_INSTALL_DIR="${HOME}${CUSTOM_INSTALL_DIR:1}"
    
    # 解析绝对路径
    case "$CUSTOM_INSTALL_DIR" in
        /*) TEMP_BASE_DIR="$CUSTOM_INSTALL_DIR" ;;
        *)  TEMP_BASE_DIR="$(pwd)/$CUSTOM_INSTALL_DIR" ;;
    esac
    
    # 智能路径确认逻辑
    if [[ "$TEMP_BASE_DIR" != *"mihomo"* ]]; then
        echo
        _okcat '🧐' "检测到路径中未包含 'mihomo'，请选择安装方式:"
        echo "   [1] 在该目录下新建 mihomo 子目录 (推荐): $TEMP_BASE_DIR/mihomo"
        echo "   [2] 直接安装到该目录:                   $TEMP_BASE_DIR"
        echo
        printf "   👉 请输入 [1/2] (默认 1): "
        read -r path_mode
        
        case "$path_mode" in
            2) 
                MIHOMO_BASE_DIR="$TEMP_BASE_DIR" 
                _okcat '👌' "选择直接安装到: $MIHOMO_BASE_DIR"
                ;;
            *) 
                MIHOMO_BASE_DIR="${TEMP_BASE_DIR}/mihomo" 
                _okcat '👌' "选择安装到子目录: $MIHOMO_BASE_DIR"
                ;;
        esac
    else
        MIHOMO_BASE_DIR="$TEMP_BASE_DIR"
    fi
    
    # 手动更新所有衍生变量
    MIHOMO_SCRIPT_DIR="${MIHOMO_BASE_DIR}/script"
    MIHOMO_CONFIG_URL="${MIHOMO_BASE_DIR}/url"
    MIHOMO_CONFIG_RAW="${MIHOMO_BASE_DIR}/config.yaml"
    MIHOMO_SUBSCRIBES_DIR="${MIHOMO_BASE_DIR}/subscribes"
    CURRENT_SUBSCRIBE_FILE="${MIHOMO_BASE_DIR}/config/current_sub"
    MIHOMO_CONFIG_MIXIN="${MIHOMO_BASE_DIR}/mixin.yaml"
    MIHOMO_CONFIG_RUNTIME="${MIHOMO_BASE_DIR}/runtime.yaml"
    MIHOMO_CONFIG_RAW_BAK="${MIHOMO_CONFIG_RAW}.bak"
    MIHOMO_UPDATE_LOG="${MIHOMO_BASE_DIR}/mihomoctl.log"
    MIHOMO_PORT_STATE="${MIHOMO_BASE_DIR}/config/ports.conf"
    MIHOMO_PORT_PREF="${MIHOMO_BASE_DIR}/config/port.pref"
    
    _set_bin
    
    _okcat '🎯' "最终目标目录: $MIHOMO_BASE_DIR"
fi

# ==========================================================

# 检查目录是否存在 (覆盖安装逻辑)
if [ -d "$MIHOMO_BASE_DIR" ]; then
    echo "⚠️ 检测到目录已存在：$MIHOMO_BASE_DIR"
    
    # 尝试停止该目录下可能正在运行的服务
    if [ -f "$MIHOMO_BASE_DIR/config/mihomo.pid" ]; then
        echo "🔄 正在停止旧服务以解除文件锁定..."
        stop_mihomo >/dev/null 2>&1 || pkill -F "$MIHOMO_BASE_DIR/config/mihomo.pid" >/dev/null 2>&1
        sleep 1
    fi
    
    echo "📦 开始覆盖安装..."
fi

_get_kernel

# 创建基础目录
mkdir -p "$MIHOMO_BASE_DIR"/{bin,config,logs,subscribes}

# ==================== 2. 安装二进制文件 ====================
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

# 重命名 yq
for yq_file in "${MIHOMO_BASE_DIR}/bin"/yq_*; do
    if [ -f "$yq_file" ]; then
        mv "$yq_file" "${MIHOMO_BASE_DIR}/bin/yq"
        break
    fi
done
chmod +x "${MIHOMO_BASE_DIR}/bin/yq"

_set_bin

# 复制资源文件
cp -rf "$SCRIPT_BASE_DIR" "$MIHOMO_BASE_DIR/"
cp "$RESOURCES_BASE_DIR"/*.yaml "$MIHOMO_BASE_DIR/" 2>/dev/null || true
cp "$RESOURCES_BASE_DIR"/*.mmdb "$MIHOMO_BASE_DIR/" 2>/dev/null || true
cp "$RESOURCES_BASE_DIR"/*.dat "$MIHOMO_BASE_DIR/" 2>/dev/null || true

# 安装卸载脚本
if [ -f "uninstall.sh" ]; then
    cp "uninstall.sh" "$MIHOMO_BASE_DIR/"
    chmod +x "$MIHOMO_BASE_DIR/uninstall.sh"
fi

# ==================== 3. 订阅配置 (跳过验证版) ====================

echo -n "$(_okcat '🔗' '是否现在配置订阅链接? [Y/n]: ')"
read -r sub_choice

HAS_VALID_CONFIG=false

if [[ ! "$sub_choice" =~ ^[nN] ]]; then
    while true; do
        echo -n "$(_okcat '🌍' '请输入订阅链接 (http/https): ')"
        read -r input_url
        
        if [ -z "$input_url" ]; then
            _okcat '⏭️' "跳过订阅配置，使用默认空配置"
            break
        fi
        
        if [[ "$input_url" != http* ]]; then
            _failcat "链接格式错误，必须以 http 或 https 开头"
            continue
        fi

        echo -n "$(_okcat '🏷️' '请命名该订阅 [默认: default]: ')"
        read -r input_name
        [ -z "$input_name" ] && input_name="default"
        
        if [[ "$input_name" =~ [^a-zA-Z0-9_.-] ]]; then
            _failcat "名称包含非法字符，建议使用英文、数字、下划线"
            continue
        fi

        SUB_DIR="${MIHOMO_BASE_DIR}/subscribes/${input_name}"
        mkdir -p "$SUB_DIR"
        
        echo "$input_url" > "$SUB_DIR/url"
        
        _okcat '⏳' "正在下载订阅配置 (已启用快速模式，跳过内核验证)..."
        
        if _download_raw_config "$SUB_DIR/config.yaml" "$input_url"; then
             _okcat '⚠️' "订阅 [$input_name] 下载成功 (已跳过验证)"
             _okcat 'ℹ️' "提示：若订阅格式非 YAML（如 Base64），启动可能失败，请使用 mihomo update 修复。"
             
             ln -sf "$SUB_DIR/config.yaml" "$MIHOMO_BASE_DIR/config.yaml"
             mkdir -p "$(dirname "$MIHOMO_BASE_DIR/config/current_sub")"
             echo "$input_name" > "$MIHOMO_BASE_DIR/config/current_sub"
             mkdir -p "$(dirname "$MIHOMO_CONFIG_URL")"
             echo "$input_url" > "$MIHOMO_CONFIG_URL"
             
             HAS_VALID_CONFIG=true
             break
        else
             _failcat "下载失败，清理残留文件..."
             rm -rf "$SUB_DIR"
             
             echo -n "$(_okcat '🔄' '是否重试? [Y/n]: ')"
             read -r retry_choice
             [[ "$retry_choice" =~ ^[nN] ]] && break
        fi
    done
fi

if [ "$HAS_VALID_CONFIG" = false ] && ! _valid_config "$MIHOMO_CONFIG_RAW"; then
    DEFAULT_SUB_DIR="${MIHOMO_BASE_DIR}/subscribes/default"
    mkdir -p "$DEFAULT_SUB_DIR"
    cp "$RESOURCES_CONFIG" "$DEFAULT_SUB_DIR/config.yaml"
    ln -sf "$DEFAULT_SUB_DIR/config.yaml" "$MIHOMO_BASE_DIR/config.yaml"
    echo "default" > "$MIHOMO_BASE_DIR/config/current_sub"
    _okcat '⚠️' "使用默认模板配置 (default) 继续安装"
fi

# ===========================================================

# 修正安装路径配置
if [ -n "$CUSTOM_INSTALL_DIR" ]; then
    sed -i "s|^MIHOMO_BASE_DIR=.*|MIHOMO_BASE_DIR=\"$MIHOMO_BASE_DIR\"|g" "$MIHOMO_BASE_DIR/script/common.sh"
fi

# 安装 UI
if ! tar -xf "$ZIP_UI" -C "$MIHOMO_BASE_DIR"; then
    _error_quit "解压 UI 文件失败: $ZIP_UI"
fi

# 设置 shell 配置 (调用开头定义的重写函数)
_set_rc

# 启动服务
mihomoctl on
clashui

_okcat '🎉' 'mihomo 用户空间代理已安装完成！'
_okcat '📝' '使用说明：'
_okcat '💡' '命令前缀: clash | mihomo | mihomoctl'
_okcat '  • 开启/关闭: clash on/off'
_okcat '  • Web控制台: clash ui'
_okcat '  • 更新订阅: clash update' 
_okcat '  • 切换订阅: clash sub list / clash sub ch <name>'
_okcat ''
_okcat '🏠' "安装目录: $MIHOMO_BASE_DIR"

_quit