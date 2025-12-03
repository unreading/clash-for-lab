#!/bin/bash
# shellcheck disable=SC2148
# shellcheck disable=SC1091

# 加载依赖
. script/common.sh >/dev/null 2>&1
. script/clashctl.sh >/dev/null 2>&1

# ==================== 1. 自定义路径解析逻辑 ====================
usage() {
    echo "用法: $0 [-d <安装路径>]"
    echo "  -d <path>   指定要卸载的目录"
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

# 互动逻辑：确保用户输入的是 Y/N，如果选 N 则输入路径
if [ "$SKIP_INTERACTIVE" = false ]; then
    _okcat '📍' "默认安装目录: $MIHOMO_BASE_DIR"
    
    # 循环直到获得有效输入
    while true; do
        echo -n "$(_okcat '🤔' '是否卸载该目录? [Y/n]: ')"
        read -r choice
        case "$choice" in
            [yY]|[yY][eE][sS]|"")
                break # 使用默认
                ;;
            [nN]|[nN][oO])
                echo -n "$(_okcat '📂' '请输入实际安装路径: ')"
                read -r input_path
                [ -z "$input_path" ] && _error_quit "未输入有效路径"
                CUSTOM_INSTALL_DIR="$input_path"
                break
                ;;
            *)
                echo "❌ 无效输入，请输入 y 或 n"
                ;;
        esac
    done
fi

# 应用自定义路径
if [ -n "$CUSTOM_INSTALL_DIR" ]; then
    [[ "$CUSTOM_INSTALL_DIR" == ~* ]] && CUSTOM_INSTALL_DIR="${HOME}${CUSTOM_INSTALL_DIR:1}"
    case "$CUSTOM_INSTALL_DIR" in
        /*) MIHOMO_BASE_DIR="$CUSTOM_INSTALL_DIR" ;;
        *)  MIHOMO_BASE_DIR="$(pwd)/$CUSTOM_INSTALL_DIR" ;;
    esac
    MIHOMO_SCRIPT_DIR="${MIHOMO_BASE_DIR}/script"
    _okcat '🎯' "目标卸载目录: $MIHOMO_BASE_DIR"
fi

_valid_env

# 1. 停止进程
echo "🔄 正在停止服务..."
# 尝试使用该目录下的配置停止
if [ -f "$MIHOMO_BASE_DIR/config/mihomo.pid" ]; then
    pkill -F "$MIHOMO_BASE_DIR/config/mihomo.pid" >/dev/null 2>&1
fi
# 再次强制匹配路径停止
pkill -f "$MIHOMO_BASE_DIR" >/dev/null 2>&1

# 2. 清理定时任务
crontab -l 2>/dev/null | grep -v 'mihomoctl.*update.*auto' | crontab - 2>/dev/null

# 3. [核心] 安全删除文件 (精准匹配)
if [ -d "$MIHOMO_BASE_DIR" ]; then
    echo "🗑️  正在清理 Mihomo 文件..."
    
    # A. 尝试读取 mixin.yaml 里的 external-ui 路径，以便精准删除 UI 文件夹
    UI_DIR_NAME=$(grep '^external-ui:' "$MIHOMO_BASE_DIR/mixin.yaml" 2>/dev/null | awk '{print $2}' | tr -d '"' | tr -d "'")
    
    # B. 删除安装脚本创建的标准子目录
    rm -rf "$MIHOMO_BASE_DIR/bin"
    rm -rf "$MIHOMO_BASE_DIR/config"
    rm -rf "$MIHOMO_BASE_DIR/logs"
    rm -rf "$MIHOMO_BASE_DIR/subscribes"
    rm -rf "$MIHOMO_BASE_DIR/script"
    
    # C. 删除 Web UI 目录
    # 1. 删除配置文件里指定的目录
    [ -n "$UI_DIR_NAME" ] && rm -rf "$MIHOMO_BASE_DIR/$UI_DIR_NAME"
    # 2. 删除常见的 UI 目录名 (兜底，防止配置被改过或读取失败)
    rm -rf "$MIHOMO_BASE_DIR/public"
    rm -rf "$MIHOMO_BASE_DIR/dist"
    rm -rf "$MIHOMO_BASE_DIR/metacubexd"
    rm -rf "$MIHOMO_BASE_DIR/ui"
    rm -rf "$MIHOMO_BASE_DIR/yacd"
    
    # D. 删除根目录下的特定文件
    rm -f "$MIHOMO_BASE_DIR/config.yaml"
    rm -f "$MIHOMO_BASE_DIR/mixin.yaml"
    rm -f "$MIHOMO_BASE_DIR/runtime.yaml"
    rm -f "$MIHOMO_BASE_DIR/runtime.yaml.bak"
    rm -f "$MIHOMO_BASE_DIR/url"
    rm -f "$MIHOMO_BASE_DIR/uninstall.sh"
    rm -f "$MIHOMO_BASE_DIR/mihomoctl.log"
    rm -f "$MIHOMO_BASE_DIR/"*.mmdb
    rm -f "$MIHOMO_BASE_DIR/"*.dat
    rm -f "$MIHOMO_BASE_DIR/"*.bak
    
    # E. 只有当目录为空时，才尝试删除根目录
    # 这样如果里面还有 rust 或其他文件，目录会被保留，避免误删
    if rmdir "$MIHOMO_BASE_DIR" 2>/dev/null; then
        _okcat '✨' "已移除空安装目录"
    else
        _okcat '⚠️' "保留了安装目录 (因为其中包含其他非 Mihomo 文件)"
        echo "   您可以手动检查剩余文件：$MIHOMO_BASE_DIR"
    fi
else
    echo "⚠️  目录不存在: $MIHOMO_BASE_DIR"
fi

# 4. 清理环境变量
_set_rc unset

_okcat '✨' '卸载完成'
_okcat '📝' '注意：请执行 [ source ~/.bashrc ] 或重新登录以彻底清除环境变量'

_quit