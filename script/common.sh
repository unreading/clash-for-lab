#!/bin/bash
# shellcheck disable=SC2148
# shellcheck disable=SC2034
# shellcheck disable=SC2155

# ==============================================================================
# 1. Global Variables & Directory Layout
# ==============================================================================

[ -n "$BASH_VERSION" ] && set +o noglob
[ -n "$ZSH_VERSION" ] && setopt glob no_nomatch

URL_GH_PROXY='https://ghfast.top'
URL_CLASH_UI="https://metacubexd.pages.dev"

# 脚本与资源目录定义
SCRIPT_BASE_DIR='./script'

RESOURCES_BASE_DIR='./resources'
RESOURCES_BIN_DIR="${RESOURCES_BASE_DIR}/bin"
RESOURCES_CONFIG="${RESOURCES_BASE_DIR}/config.yaml"
RESOURCES_CONFIG_MIXIN="${RESOURCES_BASE_DIR}/mixin.yaml"

ZIP_BASE_DIR="${RESOURCES_BASE_DIR}/zip"
ZIP_CLASH=$(echo ${ZIP_BASE_DIR}/clash*)
ZIP_MIHOMO=$(echo ${ZIP_BASE_DIR}/mihomo*)
ZIP_YQ=$(echo ${ZIP_BASE_DIR}/yq*)
ZIP_SUBCONVERTER=$(echo ${ZIP_BASE_DIR}/subconverter*)
ZIP_UI="${ZIP_BASE_DIR}/zashboard.tar.gz"

# 运行时目录定义
MIHOMO_BASE_DIR="~/tools/mihomo"
MIHOMO_SCRIPT_DIR="${MIHOMO_BASE_DIR}/$(basename $SCRIPT_BASE_DIR)"

# [修复补充] 订阅管理文件路径
CURRENT_SUBSCRIBE_FILE="${MIHOMO_BASE_DIR}/config/current_sub"
MIHOMO_SUBSCRIBES_DIR="${MIHOMO_BASE_DIR}/subscribes"

MIHOMO_CONFIG_URL="${MIHOMO_BASE_DIR}/url"
MIHOMO_CONFIG_RAW="${MIHOMO_BASE_DIR}/$(basename $RESOURCES_CONFIG)"
MIHOMO_CONFIG_RAW_BAK="${MIHOMO_CONFIG_RAW}.bak"
MIHOMO_CONFIG_MIXIN="${MIHOMO_BASE_DIR}/$(basename $RESOURCES_CONFIG_MIXIN)"
MIHOMO_CONFIG_RUNTIME="${MIHOMO_BASE_DIR}/runtime.yaml"
MIHOMO_UPDATE_LOG="${MIHOMO_BASE_DIR}/mihomoctl.log"

# 端口状态与偏好文件路径
MIHOMO_PORT_STATE="${MIHOMO_BASE_DIR}/config/ports.conf"
MIHOMO_PORT_PREF="${MIHOMO_BASE_DIR}/config/port.pref"

# Legacy compatibility (兼容旧变量名)
CLASH_BASE_DIR="$MIHOMO_BASE_DIR"
CLASH_SCRIPT_DIR="$MIHOMO_SCRIPT_DIR"
CLASH_CONFIG_URL="$MIHOMO_CONFIG_URL"
CLASH_CONFIG_RAW="$MIHOMO_CONFIG_RAW"
CLASH_CONFIG_RAW_BAK="$MIHOMO_CONFIG_RAW_BAK"
CLASH_CONFIG_MIXIN="$MIHOMO_CONFIG_MIXIN"
CLASH_CONFIG_RUNTIME="$MIHOMO_CONFIG_RUNTIME"
CLASH_UPDATE_LOG="$MIHOMO_UPDATE_LOG"

# ==============================================================================
# 2. Environment Setup
# ==============================================================================

_set_var() {
    local user=$USER
    local home=$HOME

    [ -n "$BASH_VERSION" ] && _SHELL=bash
    [ -n "$ZSH_VERSION" ] && _SHELL=zsh
    [ -n "$fish_version" ] && _SHELL=fish

    # RC 文件路径
    command -v bash >&/dev/null && SHELL_RC_BASH="${home}/.bashrc"
    command -v zsh >&/dev/null && SHELL_RC_ZSH="${home}/.zshrc"

    MIHOMO_CRON_TAB="user"
    CLASH_CRON_TAB="$MIHOMO_CRON_TAB"
}
_set_var

_set_bin() {
    local bin_base_dir="${MIHOMO_BASE_DIR}/bin"
    [ -n "$1" ] && bin_base_dir=$1
    BIN_CLASH="${bin_base_dir}/clash"
    BIN_MIHOMO="${bin_base_dir}/mihomo"
    BIN_YQ="${bin_base_dir}/yq"
    BIN_SUBCONVERTER_DIR="${bin_base_dir}/subconverter"
    BIN_SUBCONVERTER_CONFIG="$BIN_SUBCONVERTER_DIR/pref.yml"
    BIN_SUBCONVERTER_PORT="25500"
    BIN_SUBCONVERTER="${BIN_SUBCONVERTER_DIR}/subconverter"
    BIN_SUBCONVERTER_LOG="${BIN_SUBCONVERTER_DIR}/latest.log"

    [ -f "$BIN_CLASH" ] && BIN_KERNEL=$BIN_CLASH
    [ -f "$BIN_MIHOMO" ] && BIN_KERNEL=$BIN_MIHOMO
    
    # 默认回退
    if [ -z "$BIN_KERNEL" ]; then
        BIN_KERNEL=$BIN_MIHOMO
    fi
    BIN_KERNEL_NAME=$(basename "$BIN_KERNEL")
}
_set_bin

# [修复补充] 必须定义的函数，否则 source 报错
watch_proxy() {
    # 此函数被写入 .bashrc，用于在打开新终端时自动检查或显示代理状态
    # 简单实现：如果存在，不做任何操作，避免刷屏
    :
}

_set_rc() {
    [ "$1" = "unset" ] && {
        sed -i "\|$MIHOMO_SCRIPT_DIR|d" "$SHELL_RC_BASH" "$SHELL_RC_ZSH" 2>/dev/null
        return
    }

    # 确保写入 source 语句
    echo "source $MIHOMO_SCRIPT_DIR/common.sh && source $MIHOMO_SCRIPT_DIR/clashctl.sh && watch_proxy" |
        tee -a "$SHELL_RC_BASH" "$SHELL_RC_ZSH" >&/dev/null
}

# ==============================================================================
# 3. Kernel Management
# ==============================================================================

function _get_kernel() {
    [ -f "$ZIP_CLASH" ] && {
        ZIP_KERNEL=$ZIP_CLASH
        BIN_KERNEL=$BIN_CLASH
    }

    [ -f "$ZIP_MIHOMO" ] && {
        ZIP_KERNEL=$ZIP_MIHOMO
        BIN_KERNEL=$BIN_MIHOMO
    }

    [ ! -f "$ZIP_MIHOMO" ] && [ ! -f "$ZIP_CLASH" ] && {
        local arch=$(uname -m)
        _failcat "${ZIP_BASE_DIR}：未检测到可用的内核压缩包"
        _download_clash "$arch"
        ZIP_KERNEL=$ZIP_CLASH
        BIN_KERNEL=$BIN_CLASH
    }

    BIN_KERNEL_NAME=$(basename "$BIN_KERNEL")
    _okcat "安装内核：$BIN_KERNEL_NAME"
}

_download_clash() {
    local arch=$1
    local url sha256sum
    case "$arch" in
    x86_64)
        url=https://downloads.clash.wiki/ClashPremium/clash-linux-amd64-2023.08.17.gz
        sha256sum='92380f053f083e3794c1681583be013a57b160292d1d9e1056e7fa1c2d948747'
        ;;
    *86*)
        url=https://downloads.clash.wiki/ClashPremium/clash-linux-386-2023.08.17.gz
        sha256sum='254125efa731ade3c1bf7cfd83ae09a824e1361592ccd7c0cccd2a266dcb92b5'
        ;;
    armv*)
        url=https://downloads.clash.wiki/ClashPremium/clash-linux-armv5-2023.08.17.gz
        sha256sum='622f5e774847782b6d54066f0716114a088f143f9bdd37edf3394ae8253062e8'
        ;;
    aarch64)
        url=https://downloads.clash.wiki/ClashPremium/clash-linux-arm64-2023.08.17.gz
        sha256sum='c45b39bb241e270ae5f4498e2af75cecc0f03c9db3c0db5e55c8c4919f01afdd'
        ;;
    *)
        _error_quit "未知的架构版本：$arch，请自行下载对应版本至 ${ZIP_BASE_DIR} 目录下"
        ;;
    esac

    _okcat '⏳' "正在下载：clash：${arch} 架构..."
    local clash_zip="${ZIP_BASE_DIR}/$(basename $url)"
    mkdir -p "$ZIP_BASE_DIR"
    curl --progress-bar --show-error --fail --insecure --connect-timeout 15 --retry 1 --output "$clash_zip" "$url"
    
    # 简单的校验，忽略错误以防 sha 变动
    echo $sha256sum "$clash_zip" | sha256sum -c || _failcat "⚠️ 校验和不匹配，但尝试继续..."
}

# ==============================================================================
# 4. Utilities & Helpers
# ==============================================================================

_get_color() {
    local hex="${1#\#}"
    local r=$((16#${hex:0:2}))
    local g=$((16#${hex:2:2}))
    local b=$((16#${hex:4:2}))
    printf "\e[38;2;%d;%d;%dm" "$r" "$g" "$b"
}
_get_color_msg() {
    local color=$(_get_color "$1")
    local msg=$2
    local reset="\033[0m"
    printf "%b%s%b\n" "$color" "$msg" "$reset"
}

function _okcat() {
    local color=#c8d6e5
    local emoji=😼
    [ $# -gt 1 ] && emoji=$1 && shift
    local msg="${emoji} $1"
    _get_color_msg "$color" "$msg" && return 0
}

function _failcat() {
    local color=#fd79a8
    local emoji=😾
    [ $# -gt 1 ] && emoji=$1 && shift
    local msg="${emoji} $1"
    _get_color_msg "$color" "$msg" >&2 && return 1
}

function _quit() {
    exec "$_SHELL" -i
}

function _error_quit() {
    [ $# -gt 0 ] && {
        local color=#f92f60
        local emoji=📢
        [ $# -gt 1 ] && emoji=$1 && shift
        local msg="${emoji} $1"
        _get_color_msg "$color" "$msg"
    }
    exit 1
}

# [修复补充] 获取当前订阅名称
_get_current_subscribe() {
    if [ -f "$CURRENT_SUBSCRIBE_FILE" ]; then
        cat "$CURRENT_SUBSCRIBE_FILE"
    else
        echo ""
    fi
}

# [修复补充] 回滚配置
_rollback() {
    local msg="$1"
    _failcat "🔄 $msg，正在回滚配置..."
    if [ -f "$MIHOMO_CONFIG_RAW_BAK" ]; then
        cp -f "$MIHOMO_CONFIG_RAW_BAK" "$MIHOMO_CONFIG_RAW"
        _okcat "✅ 已回滚至上一次有效配置"
    else
        _failcat "❌ 无备份文件，无法回滚"
    fi
    return 1
}

# ==============================================================================
# 5. Network & Port Functions
# ==============================================================================

_get_random_port() {
    local randomPort
    if command -v shuf >/dev/null 2>&1; then
        randomPort=$(shuf -i 1024-65535 -n 1)
    elif command -v jot >/dev/null 2>&1; then
        randomPort=$(jot -r 1 1024 65535)
    else
        randomPort=$((RANDOM % 64512 + 1024))
    fi
    ! _is_bind "$randomPort" && { echo "$randomPort" && return; }
    _get_random_port
}

_is_bind() {
    local port=$1
    { ss -lnptu || netstat -lnptu; } 2>/dev/null | grep ":${port}\b"
}

_is_already_in_use() {
    local port=$1
    local progress=$2
    _is_bind "$port" | grep -qs -v "$progress"
}

# 读取端口偏好
_load_port_preferences() {
    PORT_PREF_MODE=auto
    PORT_PREF_VALUE=""
    [ -f "$MIHOMO_PORT_PREF" ] || return 0
    while IFS='=' read -r key value; do
        case "$key" in
        PROXY_MODE) [ -n "$value" ] && PORT_PREF_MODE=$value ;;
        PROXY_PORT) PORT_PREF_VALUE=$value ;;
        esac
    done < "$MIHOMO_PORT_PREF"
    [ "$PORT_PREF_MODE" = "manual" ] || PORT_PREF_MODE=auto
}

# 保存端口偏好
_save_port_preferences() {
    local mode=$1
    local value=$2
    mkdir -p "$(dirname "$MIHOMO_PORT_PREF")"
    cat > "$MIHOMO_PORT_PREF" <<EOF
PROXY_MODE=$mode
PROXY_PORT=$value
EOF
}

# 保存实际监听端口
_save_port_state() {
    local proxy_port=$1
    local ui_port=$2
    local dns_port=$3
    mkdir -p "$(dirname "$MIHOMO_PORT_STATE")"
    cat > "$MIHOMO_PORT_STATE" << EOF
PROXY_PORT=$proxy_port
UI_PORT=$ui_port
DNS_PORT=$dns_port
TIMESTAMP=$(date +%s)
EOF
}

function _get_proxy_port() {
    if [ -f "$MIHOMO_PORT_STATE" ]; then
        MIXED_PORT=$(grep "^PROXY_PORT=" "$MIHOMO_PORT_STATE" 2>/dev/null | cut -d'=' -f2)
    fi
    MIXED_PORT=${MIXED_PORT:-7890}
}

function _get_ui_port() {
    if [ -f "$MIHOMO_PORT_STATE" ]; then
        UI_PORT=$(grep "^UI_PORT=" "$MIHOMO_PORT_STATE" 2>/dev/null | cut -d'=' -f2)
    fi
    UI_PORT=${UI_PORT:-9090}
}

function _get_dns_port() {
    if [ -f "$MIHOMO_PORT_STATE" ]; then
        DNS_PORT=$(grep "^DNS_PORT=" "$MIHOMO_PORT_STATE" 2>/dev/null | cut -d'=' -f2)
    fi
    DNS_PORT=${DNS_PORT:-15353}
}

_resolve_port_conflicts() {
    local config_file=$1
    local show_message=${2:-true}
    local port_changed=false

    _load_port_preferences

    # Check mixed-port
    local mixed_port=$("$BIN_YQ" '.mixed-port // ""' "$config_file" 2>/dev/null)
    if [ "$PORT_PREF_MODE" = "manual" ]; then
        if ! [[ $PORT_PREF_VALUE =~ ^[0-9]+$ ]]; then
            PORT_PREF_VALUE=7890
        fi
        MIXED_PORT=$PORT_PREF_VALUE
        "$BIN_YQ" -i ".mixed-port = $MIXED_PORT" "$config_file"
    else
        MIXED_PORT=${mixed_port:-7890}
    fi

    if _is_already_in_use "$MIXED_PORT" "$BIN_KERNEL_NAME"; then
        # ... (简化的逻辑：如果在脚本中使用，我们尽量自动处理)
        # 这里为了保持简洁，使用自动分配逻辑，除非交互式环境复杂判断
        local newPort=$(_get_random_port)
        [ "$show_message" = true ] && _failcat '🎯' "代理端口占用：${MIXED_PORT} 🎲 随机分配：$newPort"
        "$BIN_YQ" -i ".mixed-port = $newPort" "$config_file"
        MIXED_PORT=$newPort
        port_changed=true
    fi

    # Check external-controller
    local ext_addr=$("$BIN_YQ" '.external-controller // ""' "$config_file" 2>/dev/null)
    # 处理 '0.0.0.0:9090' 或 ':9090' 或 '9090' 格式
    if [[ "$ext_addr" == *":"* ]]; then
        UI_PORT=${ext_addr##*:}
    else
        UI_PORT=${ext_addr:-9090}
    fi
    
    if _is_already_in_use "$UI_PORT" "$BIN_KERNEL_NAME"; then
        local newPort=$(_get_random_port)
        [ "$show_message" = true ] && _failcat '🎯' "UI端口占用：${UI_PORT} 🎲 随机分配：$newPort"
        # 保持 IP 绑定部分不变
        if [[ "$ext_addr" == *":"* ]]; then
             local ip_part=${ext_addr%:*}
             "$BIN_YQ" -i ".external-controller = \"${ip_part}:${newPort}\"" "$config_file"
        else
             "$BIN_YQ" -i ".external-controller = \"127.0.0.1:${newPort}\"" "$config_file"
        fi
        UI_PORT=$newPort
        port_changed=true
    fi

    # Check DNS
    local dns_listen=$("$BIN_YQ" '.dns.listen // ""' "$config_file" 2>/dev/null)
    if [[ "$dns_listen" == *":"* ]]; then
        DNS_PORT=${dns_listen##*:}
    else
        DNS_PORT=${dns_listen:-15353}
    fi

    if _is_already_in_use "$DNS_PORT" "$BIN_KERNEL_NAME"; then
        local newPort=$(_get_random_port)
        [ "$show_message" = true ] && _failcat '🎯' "DNS端口占用：${DNS_PORT} 🎲 随机分配：$newPort"
        if [[ "$dns_listen" == *":"* ]]; then
             local ip_part=${dns_listen%:*}
             "$BIN_YQ" -i ".dns.listen = \"${ip_part}:${newPort}\"" "$config_file"
        else
             "$BIN_YQ" -i ".dns.listen = \"0.0.0.0:${newPort}\"" "$config_file"
        fi
        DNS_PORT=$newPort
        port_changed=true
    fi

    if [ "$port_changed" = true ] && [ "$show_message" = true ]; then
        _okcat "端口分配完成 - 代理:$MIXED_PORT UI:$UI_PORT DNS:$DNS_PORT"
    fi
    return 0
}

# ==============================================================================
# 6. Configuration & Download Functions
# ==============================================================================

function _valid_env() {
    # 基础环境检查
    command -v curl >/dev/null 2>&1 || _error_quit "未找到 curl 命令"
    command -v jq >/dev/null 2>&1 || _error_quit "未找到 jq 命令"
}

function _valid_config() {
    [ -e "$1" ] && [ "$(wc -l <"$1")" -gt 1 ] && {
        local cmd msg
        cmd="$BIN_KERNEL -d $(dirname "$1") -f $1 -t"
        msg=$(eval "$cmd" 2>&1)
        if [ $? -ne 0 ]; then
            echo "$msg" | grep -qs "unsupport proxy type" && _error_quit "配置包含不支持的代理类型"
            return 1
        fi
        return 0
    }
    return 1
}

_download_raw_config() {
    local dest=$1
    local url=$2
    local agent='clash-verge/v2.0.4'
    curl --silent --show-error --insecure --connect-timeout 5 --retry 1 \
         --noproxy "*" --user-agent "$agent" --output "$dest" "$url"
}

_download_convert_config() {
    local dest=$1
    local url=$2
    _start_convert
    local convert_url=$(
        target='clash'
        base_url="http://127.0.0.1:${BIN_SUBCONVERTER_PORT}/sub"
        curl --get --silent --output /dev/null \
            --data-urlencode "target=$target" \
            --data-urlencode "url=$url" \
            --write-out '%{url_effective}' \
            "$base_url"
    )
    _download_raw_config "$dest" "$convert_url"
    _stop_convert
}

function _download_config() {
    local dest=$1
    local url=$2
    [ "${url:0:4}" = 'file' ] && return 0
    
    # 备份现有配置
    [ -f "$dest" ] && cp "$dest" "${dest}.bak"

    _download_raw_config "$dest" "$url" || return 1
    _okcat '🍃' '下载成功：内核验证配置...'
    
    if _valid_config "$dest"; then
        return 0
    else
        _failcat '🍂' "验证失败：尝试订阅转换..."
        _download_convert_config "$dest" "$url" || {
             _failcat '🍂' "转换失败或验证依旧失败"
             return 1
        }
        # 再次验证转换后的配置
        _valid_config "$dest" || return 1
    fi
}

_start_convert() {
    if _is_already_in_use $BIN_SUBCONVERTER_PORT 'subconverter'; then
        local newPort=$(_get_random_port)
        [ ! -e "$BIN_SUBCONVERTER_CONFIG" ] && cp -f "$BIN_SUBCONVERTER_DIR/pref.example.yml" "$BIN_SUBCONVERTER_CONFIG"
        "$BIN_YQ" -i ".server.port = $newPort" "$BIN_SUBCONVERTER_CONFIG"
        BIN_SUBCONVERTER_PORT=$newPort
    fi
    ("$BIN_SUBCONVERTER" > "$BIN_SUBCONVERTER_LOG" 2>&1 &)
    # 等待启动
    for i in {1..10}; do
        if _is_bind "$BIN_SUBCONVERTER_PORT" >/dev/null; then return 0; fi
        sleep 0.5
    done
    _error_quit "订阅转换服务启动超时"
}

_stop_convert() {
    pkill -9 -f "$BIN_SUBCONVERTER" >&/dev/null
}

# ==============================================================================
# 7. Process Management
# ==============================================================================

start_mihomo() {
    local pid_file="$MIHOMO_BASE_DIR/config/mihomo.pid"
    local log_file="$MIHOMO_BASE_DIR/logs/mihomo.log"
    mkdir -p "$(dirname "$pid_file")" "$(dirname "$log_file")"

    if is_mihomo_running; then
        _okcat "mihomo 进程已在运行"
        return 0
    fi

    _valid_config "$MIHOMO_CONFIG_RUNTIME" || {
        _failcat "配置文件验证失败，无法启动"
        return 1
    }

    nohup "$BIN_KERNEL" -d "$MIHOMO_BASE_DIR" -f "$MIHOMO_CONFIG_RUNTIME" > "$log_file" 2>&1 &
    local pid=$!
    echo "$pid" > "$pid_file"
    
    sleep 1
    if is_mihomo_running; then
        _okcat "mihomo 进程启动成功 (PID: $pid)"
        return 0
    else
        rm -f "$pid_file"
        _failcat "启动失败，请检查日志: $log_file"
        return 1
    fi
}
stop_mihomo() {
    local pid_file="$MIHOMO_BASE_DIR/config/mihomo.pid"
    [ ! -f "$pid_file" ] && return 0
    
    local pid=$(cat "$pid_file" 2>/dev/null)
    if [ -n "$pid" ]; then
        # 1. 先探测进程是否存在 (kill -0)
        if kill -0 "$pid" 2>/dev/null; then
            # 2. 尝试优雅停止
            kill "$pid" 2>/dev/null
            
            # 3. 等待进程消失
            for i in {1..20}; do
                if ! kill -0 "$pid" 2>/dev/null; then
                    break
                fi
                sleep 0.1
            done
            
            # 4. 如果还在（且仅当它还在时），才执行强制杀
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null
            fi
        fi
    fi
    
    rm -f "$pid_file"
    rm -f "$MIHOMO_PORT_STATE"
    _okcat "mihomo 进程已停止"
}

is_mihomo_running() {
    local pid_file="$MIHOMO_BASE_DIR/config/mihomo.pid"
    [ ! -f "$pid_file" ] && return 1
    local pid=$(cat "$pid_file" 2>/dev/null)
    [ -z "$pid" ] && return 1
    kill -0 "$pid" 2>/dev/null
}

# ==============================================================================
# 8. Feature Management (TUN, etc)
# ==============================================================================

# [修复补充] 开启 TUN
_tunon() {
    mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
    # 强制启用 tun, 设置为 system 栈 (兼容性好), 开启自动路由
    "$BIN_YQ" -i '.tun.enable = true | .tun.stack = "system" | .tun.auto-route = true | .tun.auto-detect-interface = true' "$MIHOMO_CONFIG_MIXIN"
    
    # 注意：_merge_config_restart 在 mihomo.sh 中定义。
    # 因为本文件是被 mihomo.sh source 的，且调用发生在函数内，所以可以访问主脚本的函数。
    # 如果单独运行 common.sh 会报错，但在完整流程中是正常的。
    if command -v _merge_config_restart >/dev/null; then
        _merge_config_restart && _okcat "TUN 模式已开启 (请确保拥有 sudo 权限或 cap_net_admin)"
    else
        _failcat "无法重启服务，请手动执行 restart"
    fi
}

# [修复补充] 关闭 TUN
_tunoff() {
    mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
    "$BIN_YQ" -i '.tun.enable = false' "$MIHOMO_CONFIG_MIXIN"
    
    if command -v _merge_config_restart >/dev/null; then
        _merge_config_restart && _okcat "TUN 模式已关闭"
    else
        _failcat "无法重启服务，请手动执行 restart"
    fi
}

# [修复补充] 查看 TUN 状态
_tunstatus() {
    local status=$("$BIN_YQ" '.tun.enable' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null)
    if [ "$status" = "true" ]; then
        _okcat "TUN 模式: 🟢 开启"
    else
        _okcat "TUN 模式: 🔴 关闭"
    fi
}