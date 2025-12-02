#!/bin/bash
# shellcheck disable=SC2148
# shellcheck disable=SC2155

# ==============================================================================
# 0. 环境初始化与路径检测 (兼容 Zsh/Bash)
# ==============================================================================
if [ -n "$ZSH_VERSION" ]; then
    SCRIPT_PATH="${(%):-%x}"
elif [ -n "$BASH_VERSION" ]; then
    SCRIPT_PATH="${BASH_SOURCE[0]}"
else
    SCRIPT_PATH="$0"
fi
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

# 加载依赖库
if [ -f "$SCRIPT_DIR/common.sh" ]; then
    . "$SCRIPT_DIR/common.sh" >&/dev/null
else
    echo "Error: common.sh not found in $SCRIPT_DIR"
    return 1
fi

# ==============================================================================
# 1. 全局通用函数 (API & Helpers)
# ==============================================================================

# [核心修复] 统一 API 请求函数
curl_api() {
    local api_path="$1" 
    shift
    
    # 动态获取端口
    _get_ui_port
    local controller="127.0.0.1:${UI_PORT:-9090}"
    local secret=$("$BIN_YQ" '.secret // ""' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
    local CURL_BIN="/usr/bin/curl"
    [ ! -x "$CURL_BIN" ] && CURL_BIN=$(which curl)

    if [ -z "$CURL_BIN" ]; then
        _failcat "❌ curl command not found"
        return 1
    fi

    if [ -n "$secret" ]; then
        "$CURL_BIN" -s -H "Authorization: Bearer $secret" "http://$controller$api_path" "$@"
    else
        "$CURL_BIN" -s "http://$controller$api_path" "$@"
    fi
}

urlencode() {
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$1" 2>/dev/null
}

# 内部函数：显示节点列表并处理选择
_interactive_node_select() {
    local group_name="$1"
    local direct_target="$2"
    local group_enc=$(urlencode "$group_name")
    local group_resp=$(curl_api "/proxies/$group_enc")

    if [[ "$group_resp" != \{* ]]; then echo "❌ 无法获取节点列表 (API 异常)"; return 1; fi

    # 解析节点列表
    local nodes=()
    while IFS= read -r node; do nodes+=("$node"); done < <(echo "$group_resp" | jq -r '.all[]')

    # Mode A: 直接切换 (带参数)
    if [ -n "$direct_target" ]; then
        local target_node=""
        if [[ "$direct_target" =~ ^[0-9]+$ ]]; then
            if [ "$direct_target" -ge 1 ] && [ "$direct_target" -le "${#nodes[@]}" ]; then
                if [ -n "$ZSH_VERSION" ]; then target_node="${nodes[$direct_target]}"; else target_node="${nodes[$((direct_target - 1))]}"; fi
            else
                echo "❌ 无效编号: $direct_target"
                return 1
            fi
        else
            target_node="$direct_target"
        fi

        echo "🔍 主分组: $group_name"
        echo "🔄 正在切换到: $target_node"

        local payload=$(jq -n --arg name "$target_node" '{name: $name}')
        curl_api "/proxies/$group_enc" -X PUT -H "Content-Type: application/json" -d "$payload" >/dev/null
        local now=$(curl_api "/proxies/$group_enc" | jq -r .now)
        if [ "$now" = "$target_node" ]; then echo "✅ 切换成功！当前: $now"; else
            echo "❌ 切换失败，当前: $now"
        fi
        return 0
    fi

    # Mode B: 智能表格显示
    echo "📋 [$group_name] 可选节点 (自适应表格显示):"
    local current_node=$(echo "$group_resp" | jq -r '.now')
    local items=()
    local j=1

    # Format all nodes
    for node in "${nodes[@]}"; do
        local mark=" "
        [ "$node" = "$current_node" ] && mark="*"
        items+=("$(printf "%s[%2d] %s" "$mark" "$j" "$node")")
        ((j++))
    done

    # Calculate columns
    local term_cols=$(tput cols)
    local max_col_width=45
    local col_count=$((term_cols / max_col_width))
    if [ "$col_count" -lt 1 ]; then col_count=1; fi
    if [ "$col_count" -gt 5 ]; then col_count=5; fi

    # Build table data stream
    (
        local total=${#items[@]}
        local k=0
        while [ $k -lt $total ]; do
            local line=""
            for ((c = 0; c < col_count; c++)); do
                local idx=$((k + c))
                if [ $idx -lt $total ]; then
                    line+="${items[$idx]}|"
                fi
            done
            echo "${line%|}"
            ((k += col_count))
        done
    ) | column -t -s '|'

    printf "\n👉 请输入节点编号: "
    read -r n_idx

    if ! [[ "$n_idx" =~ ^[0-9]+$ ]] || [ "$n_idx" -lt 1 ] || [ "$n_idx" -gt "${#nodes[@]}" ]; then echo "❌ 无效编号"; return 1; fi

    local selected_node=""
    if [ -n "$ZSH_VERSION" ]; then selected_node="${nodes[$n_idx]}"; else selected_node="${nodes[$((n_idx - 1))]}"; fi

    echo "🔄 正在切换到: $selected_node"
    local payload=$(jq -n --arg name "$selected_node" '{name: $name}')
    curl_api "/proxies/$group_enc" -X PUT -H "Content-Type: application/json" -d "$payload" >/dev/null
    local new_now=$(curl_api "/proxies/$group_enc" | jq -r .now)
    [ "$new_now" = "$selected_node" ] && echo "✅ 切换成功" || echo "❌ 切换可能失败"
}

_set_system_proxy() {
    [ ! -f "$MIHOMO_CONFIG_RUNTIME" ] && return 1
    local auth=$("$BIN_YQ" '.authentication[0] // ""' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
    [ -n "$auth" ] && auth=$auth@

    export http_proxy="http://${auth}127.0.0.1:${MIXED_PORT}"
    export https_proxy=$http_proxy
    export HTTP_PROXY=$http_proxy
    export HTTPS_PROXY=$http_proxy
    export all_proxy="socks5h://${auth}127.0.0.1:${MIXED_PORT}"
    export ALL_PROXY=$all_proxy
    export no_proxy="localhost,127.0.0.1,::1"
    export NO_PROXY=$no_proxy

    mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
    "$BIN_YQ" -i '.system-proxy.enable = true' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null
}

_unset_system_proxy() {
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
    mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
    "$BIN_YQ" -i '.system-proxy.enable = false' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null
}

_verify_actual_ports() {
    local log_file="$MIHOMO_BASE_DIR/logs/mihomo.log"
    [ ! -f "$log_file" ] && return 0
    local actual_proxy_port actual_ui_port actual_dns_port
    actual_proxy_port=$(grep "Mixed(http+socks) proxy listening at:" "$log_file" | tail -1 | awk -F: '{print $NF}' | tr -d '[:space:]\r"')
    [ -z "$actual_proxy_port" ] && actual_proxy_port=$(grep "HTTP proxy listening at:" "$log_file" | tail -1 | awk -F: '{print $NF}' | tr -d '[:space:]\r"')
    actual_ui_port=$(grep "RESTful API listening at:" "$log_file" | tail -1 | awk -F: '{print $NF}' | tr -d '[:space:]\r"')
    actual_dns_port=$(grep "DNS server(UDP) listening at:" "$log_file" | tail -1 | awk -F: '{print $NF}' | tr -d '[:space:]\r"')

    local port_changed=false
    if [ -n "$actual_proxy_port" ] && [ "$actual_proxy_port" != "$MIXED_PORT" ]; then
        _failcat "🔄" "mihomo自动调整代理端口: $MIXED_PORT → $actual_proxy_port"
        MIXED_PORT=$actual_proxy_port
        port_changed=true
    fi
    if [ -n "$actual_ui_port" ] && [ "$actual_ui_port" != "$UI_PORT" ]; then
        if [[ "$actual_ui_port" =~ ^[0-9]+$ ]]; then
            _failcat "🔄" "mihomo自动调整UI端口: $UI_PORT → $actual_ui_port"
            UI_PORT=$actual_ui_port
            port_changed=true
        fi
    fi
    if [ -n "$actual_dns_port" ] && [ "$actual_dns_port" != "$DNS_PORT" ]; then
        if [[ "$actual_dns_port" =~ ^[0-9]+$ ]]; then
            _failcat "🔄" "mihomo自动调整DNS端口: $DNS_PORT → $actual_dns_port"
            DNS_PORT=$actual_dns_port
            port_changed=true
        fi
    fi
}

watch_proxy() {
    [ -z "$http_proxy" ] && [[ $- == *i* ]] && {
        if is_mihomo_running; then
            _get_proxy_port
            _set_system_proxy
        fi
    }
}

_update_specific_sub() {
    local name="$1"; local url="$2"
    local sub_dir="$MIHOMO_SUBSCRIBES_DIR/$name"
    local config_file="$sub_dir/config.yaml"
    _okcat "正在更新订阅: $name"
    mkdir -p "$sub_dir"
    
    if _download_raw_config "$config_file" "$url"; then
        _okcat "⚠️  已跳过内核验证 (环境未就绪)，依赖 mihomo on 时的最终验证。" 
        echo "$url" >"$sub_dir/url"
        _okcat "正在应用配置..."
        echo "$name" >"$CURRENT_SUBSCRIBE_FILE"
        ln -sf "$config_file" "$MIHOMO_CONFIG_RAW"
        mkdir -p "$(dirname "$MIHOMO_CONFIG_URL")"
        echo "$url" >"$MIHOMO_CONFIG_URL"
        _merge_config_restart && _okcat "✅ 订阅 [$name] 更新并激活成功"
    else
        _failcat "❌ 下载失败"; return 1
    fi
}

_merge_config_restart() {
    local backup="${MIHOMO_BASE_DIR}/config/runtime.backup"
    mkdir -p "$(dirname "$backup")"
    cat "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null > "$backup"
    "$BIN_YQ" eval-all '. as $item ireduce ({}; . *+ $item) | (.. | select(tag == "!!seq")) |= unique' \
        "$MIHOMO_CONFIG_MIXIN" "$MIHOMO_CONFIG_RAW" "$MIHOMO_CONFIG_MIXIN" > "$MIHOMO_CONFIG_RUNTIME"
    
    if ! _valid_config "$MIHOMO_CONFIG_RUNTIME"; then
        cat "$backup" > "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null
        rm -f "$backup"
        _failcat "配置合并验证失败，已回滚"
        return 1
    fi
    rm -f "$backup"
    clashrestart
}

# ==============================================================================
# 2. 功能模块 (Functions)
# ==============================================================================

# ----------------- Service Control -----------------
clashon() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        echo "用法: mihomo on"
        echo "功能: 启动 mihomo 代理服务，合并配置，解析端口并设置系统代理。"
        return 0
    fi
    mkdir -p "$(dirname "$MIHOMO_CONFIG_RUNTIME")"
    "$BIN_YQ" eval-all '. as $item ireduce ({}; . *+ $item) | (.. | select(tag == "!!seq")) |= unique' \
        "$MIHOMO_CONFIG_MIXIN" "$MIHOMO_CONFIG_RAW" "$MIHOMO_CONFIG_MIXIN" >"$MIHOMO_CONFIG_RUNTIME"
    _resolve_port_conflicts "$MIHOMO_CONFIG_RUNTIME" false
    if start_mihomo; then
        sleep 2
        _verify_actual_ports
        _save_port_state "$MIXED_PORT" "$UI_PORT" "$DNS_PORT"
        _set_system_proxy
        _okcat "最终端口分配 - 代理:$MIXED_PORT UI:$UI_PORT DNS:$DNS_PORT"
        _okcat '已开启代理环境'
    else
        _failcat '代理启动失败'; return 1
    fi
}

clashoff() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        echo "用法: mihomo off"
        echo "功能: 停止 mihomo 代理服务，并移除系统代理环境变量。"
        return 0
    fi
    stop_mihomo
    _unset_system_proxy
    _okcat '已关闭代理环境'
}

clashrestart() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        echo "用法: mihomo restart"
        echo "功能: 重启 mihomo 代理服务。"
        return 0
    fi
    _okcat "正在重启代理服务..."
    { clashoff && clashon; } >&/dev/null && _okcat "代理服务重启成功"
}

# ----------------- Subscription -----------------
clashsubscribe() {
    mkdir -p "$MIHOMO_SUBSCRIBES_DIR"
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        cat <<EOF
用法: mihomo subscribe [COMMAND] [URL/NAME]

功能: 订阅管理（多订阅支持），用于添加、查看、切换订阅。

COMMANDS:
  (无参数)      显示当前激活的订阅信息。
  list          列出所有已保存的订阅链接，并标记当前使用项 (*)。
  rm <NAME>     删除指定名称的订阅。
  ch <NAME>     切换到已下载的指定订阅 (无需 -n 参数)。
  <URL>         新增或更新订阅 (URL 必须以 http/https 开头)。
  -n <NAME> <URL> 指定名称新增或更新订阅。
EOF
        return 0
    fi

    case "$1" in
    "")
        local current_name="$(_get_current_subscribe)"
        if [ -n "$current_name" ] && [ -f "$MIHOMO_SUBSCRIBES_DIR/$current_name/url" ]; then
            _okcat "当前订阅名称: $current_name"
            _okcat "当前订阅地址: $(cat "$MIHOMO_SUBSCRIBES_DIR/$current_name/url")"
        else
            local legacy_url=$(cat "$MIHOMO_CONFIG_URL" 2>/dev/null)
            [ -n "$legacy_url" ] && _okcat "当前订阅地址(Legacy): $legacy_url" || _failcat "未配置订阅"
        fi
        ;;
    list)
        _okcat "订阅列表："
        printf " %-2s %-16s %s\n" "St" "Name" "URL"
        local current_name="$(_get_current_subscribe)"
        for d in "$MIHOMO_SUBSCRIBES_DIR"/*; do
            [ -d "$d" ] || continue
            local name=$(basename "$d"); local url=$(cat "$d/url" 2>/dev/null)
            local mark=" "; [ "$name" = "$current_name" ] && mark="*"
            local display_url="${url:-<无URL>}"
            [ ${#display_url} -gt 60 ] && display_url="${display_url:0:57}..."
            printf " %s  %-16s %s\n" "$mark" "$name" "$display_url"
        done
        ;;
    rm|del|delete)
        shift 
        local name="$1"
        [ -z "$name" ] && { _failcat "❌ 请指定要删除的订阅名称。"; clashsubscribe -h; return 1; }
        local sub_dir="$MIHOMO_SUBSCRIBES_DIR/$name"
        [ ! -d "$sub_dir" ] && { _failcat "❌ 找不到订阅: $name"; return 1; }
        local current_name="$(_get_current_subscribe)"
        if [ "$name" = "$current_name" ]; then
            _failcat "⚠️ 警告: [$name] 是当前正在使用的订阅！"
            printf "删除后将无法自动更新，确定删除吗？[y/N]: "; read -r confirm
            case "$confirm" in [yY]*) rm -f "$CURRENT_SUBSCRIBE_FILE" ;; *) _okcat "已取消操作"; return 0 ;; esac
        fi
        rm -rf "$sub_dir"; _okcat "✅ 已删除订阅: $name"
        ;;
    ch)
        shift
        # 兼容性处理：如果用户还是输入了 -n，自动跳过
        if [ "$1" = "-n" ]; then shift; fi
        
        local name="$1"
        if [ -z "$name" ]; then 
            _failcat "❌ 请指定要切换的订阅名称 (用法: mihomo sub ch <name>)"
            clashsubscribe list # 自动列出列表方便用户
            return 1
        fi

        local sub_dir="$MIHOMO_SUBSCRIBES_DIR/$name"
        [ ! -f "$sub_dir/config.yaml" ] && { _failcat "❌ 订阅 '$name' 不存在或尚未下载配置。"; return 1; }
        
        echo "$name" >"$CURRENT_SUBSCRIBE_FILE"
        ln -sf "$sub_dir/config.yaml" "$MIHOMO_CONFIG_RAW"
        [ -f "$sub_dir/url" ] && { mkdir -p "$(dirname "$MIHOMO_CONFIG_URL")"; cat "$sub_dir/url" >"$MIHOMO_CONFIG_URL"; }
        _merge_config_restart; _okcat "✅ 已切换并激活订阅: $name"
        ;;
    *)
        local name=""; local url=""
        if [ "$1" = "-n" ]; then name="$2"; url="$3"; else url="$1"; fi
        if [ -z "$url" ] || [ "${url:0:4}" != "http" ]; then _failcat "❌ 无效的订阅地址。"; clashsubscribe -h; return 1; fi
        while [ -z "$name" ]; do printf "请输入订阅名称: "; read -r name; done
        _update_specific_sub "$name" "$url"
        ;;
    esac
}

clashupdate() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        echo "用法: mihomo update"
        echo "功能: 重新下载并应用当前激活的订阅配置文件。"
        return 0
    fi
    local current_name="$(_get_current_subscribe)"
    local url=$(cat "$MIHOMO_SUBSCRIBES_DIR/$current_name/url" 2>/dev/null)
    [ -z "$url" ] && url=$(cat "$MIHOMO_CONFIG_URL" 2>/dev/null)
    [ "${url:0:4}" != "http" ] && { _failcat "无效的更新链接"; return 1; }
    _okcat '👌' "正在下载更新..."
    if _download_raw_config "$MIHOMO_CONFIG_RAW" "$url"; then
        _okcat "正在执行内核验证..."
        _valid_config "$MIHOMO_CONFIG_RAW" || _rollback "验证失败"
        _merge_config_restart && _okcat '🍃' '更新成功'
    else
        _failcat "❌ 下载失败"
    fi
}

# ----------------- Node / Group -----------------
clashnow() {
    # 1. 帮助信息优先处理
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        echo "用法: mihomo now"
        echo "功能: 显示当前订阅名称、主策略组、当前选中节点、延迟和核心模式。"
        return 0
    fi

    # 2. [新增] 检查服务状态
    if ! is_mihomo_running; then
        _failcat "当前没有开启代理 (mihomo 未运行)"
        return 1
    fi

    # 3. 原有逻辑
    local current_sub="$(_get_current_subscribe)"
    [ -n "$current_sub" ] && printf "📂 当前订阅: %s\n" "$current_sub"
    
    local resp=$(curl_api "/proxies"); [ -z "$resp" ] && return 1
    
    local group=""
    if [ -f "$MIHOMO_CONFIG_RUNTIME" ]; then
        group=$("$BIN_YQ" '.proxy-groups[] | select(.type == "select") | .name' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null | head -n 1)
    fi
    if [ -z "$group" ]; then
        group=$(echo "$resp" | jq -r '.proxies | to_entries[] | select(.value.type=="Selector" and .key!="GLOBAL" and .key!="Global") | .key' | head -n 1)
    fi
    
    [ -z "$group" ] && { echo "❌ 无法识别主分组"; return 1; }
    
    local group_enc=$(urlencode "$group")
    local node=$(curl_api "/proxies/$group_enc" | jq -r .now)
    local node_enc=$(urlencode "$node")
    local delay=$(curl_api "/proxies/$node_enc/delay?timeout=2000&url=http://www.gstatic.com/generate_204" | jq -r '.delay // "N/A"')
    local mode=$(curl_api "/configs" | jq -r .mode)
    
    printf "🎯 主分组: %s\n🚀 节点:   %s\n📶 延迟:   %s ms\n🛡️  模式:   %s\n" "$group" "$node" "$delay" "$mode"
}

clashgroup() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        cat <<EOF
用法: mihomo group [options] [<group_name_or_index>]
功能: 查看策略分组列表，或查看指定分组的详细节点状态/进行测速。
 (无参数)         列出所有策略分组及当前选中节点/延迟。
 -n/--node        查看指定分组的节点状态 (交互式或指定)。
 -t/--test        对指定分组所有节点进行延迟测试。
EOF
        return 0
    fi

    local target_input=""; local show_nodes=false; local do_test=false
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--name|--node) show_nodes=true; shift ;;
            -t|--test) do_test=true; shift ;;
            -*) echo "❌ 未知选项: $1"; return 1 ;;
            *) [ -z "$target_input" ] && target_input="$1"; shift ;;
        esac
    done

    if [ "$show_nodes" = true ]; then
        # 交互逻辑
        if [ -z "$target_input" ]; then
            local all_groups=()
            while IFS= read -r g; do all_groups+=("$g"); done < <("$BIN_YQ" '.proxy-groups[] | select(.type == "select" or .type == "url-test" or .type == "fallback" or .type == "load-balance") | .name' "$MIHOMO_CONFIG_RUNTIME")
            if [ ${#all_groups[@]} -eq 0 ]; then echo "❌ 未找到策略组"; return 1; fi
            echo "📋 请选择要查看的策略组:"
            local k=1; for g in "${all_groups[@]}"; do printf " [%2d] %s\n" "$k" "$g"; ((k++)); done
            printf "👉 输入编号: "; read -r input_idx
            if [[ "$input_idx" =~ ^[0-9]+$ ]] && [ "$input_idx" -ge 1 ] && [ "$input_idx" -le "${#all_groups[@]}" ]; then
                target_input="$input_idx"
            else echo "❌ 无效编号"; return 1; fi
        fi

        local target_group="$target_input"
        if [[ "$target_input" =~ ^[0-9]+$ ]]; then
            local groups=(); while IFS= read -r group_name; do groups+=("$group_name"); done < <("$BIN_YQ" '.proxy-groups[] | select(.type == "select" or .type == "url-test" or .type == "fallback" or .type == "load-balance") | .name' "$MIHOMO_CONFIG_RUNTIME")
            if [ "$target_input" -ge 1 ] && [ "$target_input" -le "${#groups[@]}" ]; then
                if [ -n "$ZSH_VERSION" ]; then target_group="${groups[$target_input]}"; else target_group="${groups[$((target_input-1))]}"; fi
                echo "✅ 选中序号 [$target_input]: $target_group"
            else echo "❌ 无效序号"; return 1; fi
        fi

        local resp=$(curl_api "/proxies"); [ -z "$resp" ] && { echo "❌ API 异常"; return 1; }
        local chk=$(echo "$resp" | jq -r --arg g "$target_group" '.proxies[$g].all')
        if [ "$chk" = "null" ] || [ "$chk" = "" ]; then echo "❌ 策略组 '$target_group' 不存在"; return 1; fi

        if [ "$do_test" = true ]; then
            echo "⚡️ 测速中..."
            local n_list=(); while IFS= read -r n; do n_list+=("$n"); done < <(echo "$resp" | jq -r --arg g "$target_group" '.proxies[$g].all[]')
            set +m
            for n in "${n_list[@]}"; do
                local nenc=$(urlencode "$n")
                curl_api "/proxies/$nenc/delay?timeout=2000&url=http://www.gstatic.com/generate_204" >/dev/null 2>&1 &
            done
            local spin='-\|/'; local i=0; while kill -0 $! 2>/dev/null; do i=$(( (i+1) %4 )); printf "\r⏳ %s" "${spin:$i:1}"; sleep 0.1; done; wait; set -m
            echo -e "\r✅ 完成        "
            resp=$(curl_api "/proxies")
        fi

        echo "📂 策略组: $target_group"
        echo "🏆 延迟最低 Top 5 (智能去重):"
        echo "$resp" | jq -r --arg g "$target_group" '.proxies as $root | [ $root[$g].all[] | {name: ., delay: ($root[.].history[-1].delay // 99999)} ] | map(select(.name | test("自动|直连|流量|到期|剩余|重置|官网|故障|群组|DIRECT|REJECT"; "i") | not)) | map(select(.delay > 0 and .delay < 99999)) | sort_by(.delay) | unique_by(if .name | test("[\\x{1F1E6}-\\x{1F1FF}]{2}") then (.name | match("[\\x{1F1E6}-\\x{1F1FF}]{2}").string) else (.name | gsub("\\d+|\\s+|-|_"; "") | ascii_upcase) end) | sort_by(.delay) | .[:5] | .[] | "   🚀 \(.name) (\(.delay)ms)"'
        echo "----------------------------------------"
        echo "📋 节点状态 (自适应列):"
        local items_str=$(echo "$resp" | jq -r --arg g "$target_group" '.proxies as $root | $root[$g].now as $cur | $root[$g].all[] | . as $name | $root[$name].history[-1].delay as $d | ($d // 0) as $dd | (if $name == $cur then "* " else "  " end) + $name + " (" + (if $dd == 0 then "N/A" else ($dd | tostring) + "ms" end) + ")"')
        [ -n "$items_str" ] && { echo "$items_str" | column -c $(tput cols) 2>/dev/null || echo "$items_str"; }
        echo ""
    else
        # 默认：列出所有组
        local resp=$(curl_api "/proxies"); [ -z "$resp" ] && return 1
        echo "📋 策略分组列表 (按配置顺序)："
        (
            echo "🆔 编号|📂 分组名称|👉 当前选中|⚡ 延迟"
            echo "---|---|---|---"
            local i=1
            "$BIN_YQ" '.proxy-groups[] | select(.type == "select" or .type == "url-test" or .type == "fallback" or .type == "load-balance") | .name' "$MIHOMO_CONFIG_RUNTIME" | while read -r n; do
                local info=$(echo "$resp" | jq -r --arg g "$n" '.proxies as $p | $p[$g].now as $cur | ($p[$cur].history[-1].delay // 0) as $d1 | ($p[$cur].now // "") as $next1 | (if $d1 > 0 then $d1 elif $next1 != "" then $p[$next1] as $n2 | ($n2.history[-1].delay // 0) as $d2 | ($n2.now // "") as $next2 | (if $d2 > 0 then $d2 elif $next2 != "" then $p[$next2].history[-1].delay // 0 else 0 end) else 0 end) as $final_delay | $cur + "|" + (if $final_delay == 0 then "N/A" else ($final_delay | tostring) + "ms" end)')
                local now="${info%|*}"; local delay="${info#*|}"
                if [ "$now" != "null" ] && [ -n "$now" ]; then echo "$i|$n|$now|$delay"; ((i++)); fi
            done
        ) | column -t -s '|'
        echo ""
    fi
}

clashch() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        cat <<EOF
用法: mihomo ch [COMMAND]
功能: 快速切换节点或策略组，或切换订阅。
 -n [<node_name_or_index>]  交互式切换主策略组的节点，或直接指定节点名称/序号。
 -g [<group_name_or_index>] 交互式选择策略组，并进入其节点切换界面。
 -s                         进入订阅切换界面 (等同于 mihomo subscribe ch)。
 --library <path> 修改 Mihomo 的安装/数据目录路径 (需重启终端生效)。
EOF
        return 0
    fi
    local cmd="$1"; shift
    case "$cmd" in
    # 修改默认的地址
    -lib|--library)
        local new_path="$1"
        [ -z "$new_path" ] && { _failcat "❌ 请指定新的安装路径"; return 1; }
        if [[ "$new_path" != /* ]]; then
            if [ -d "$new_path" ]; then
                new_path="$(cd "$new_path" && pwd)"
            else
                local parent="$(cd "$(dirname "$new_path")" 2>/dev/null && pwd)"
                [ -z "$parent" ] && parent="$PWD"
                new_path="${parent}/$(basename "$new_path")"
            fi
        fi
        local common_file="$SCRIPT_DIR/common.sh"
        [ ! -f "$common_file" ] && { _failcat "❌ 找不到 common.sh"; return 1; }
        
        _okcat "新路径: $new_path"
        if sed -i "s|^MIHOMO_BASE_DIR=.*|MIHOMO_BASE_DIR=\"$new_path\"|" "$common_file"; then
            _okcat "✅ 修改成功，请手动移动旧数据并重启终端。"
        else
            _failcat "❌ 修改失败"
            return 1
        fi
        ;;
    
    -g|-group)
        local target_idx="$1"
        local groups=(); while IFS= read -r group_name; do groups+=("$group_name"); done < <("$BIN_YQ" '.proxy-groups[] | select(.type == "select" or .type == "url-test" or .type == "fallback" or .type == "load-balance") | .name' "$MIHOMO_CONFIG_RUNTIME")
        [ ${#groups[@]} -eq 0 ] && { echo "❌ 无分组"; return 1; }
        local selected_group=""
        if [[ "$target_idx" =~ ^[0-9]+$ ]]; then
            if [ "$target_idx" -ge 1 ] && [ "$target_idx" -le "${#groups[@]}" ]; then
                if [ -n "$ZSH_VERSION" ]; then selected_group="${groups[$target_idx]}"; else selected_group="${groups[$((target_idx-1))]}"; fi
                echo "✅ 选中: $selected_group"
            else echo "❌ 无效编号"; return 1; fi
        else
            echo "📋 可用策略组:"
            echo "----------------------------------------"
            local k=1; for g in "${groups[@]}"; do printf " [%2d] %s\n" "$k" "$g"; ((k++)); done
            echo "----------------------------------------"
            printf "👉 分组编号: "; read -r input_idx
            if [[ "$input_idx" =~ ^[0-9]+$ ]] && [ "$input_idx" -ge 1 ] && [ "$input_idx" -le "${#groups[@]}" ]; then
                if [ -n "$ZSH_VERSION" ]; then selected_group="${groups[$input_idx]}"; else selected_group="${groups[$((input_idx-1))]}"; fi
            else echo "❌ 无效"; return 1; fi
        fi
        _interactive_node_select "$selected_group" ""
        ;;
    -s|-subscribe) clashsubscribe ch ;;
    -n|-node)
        local target="$1"
        local resp=$(curl_api "/proxies"); [ -z "$resp" ] && return 1
        local grp=$("$BIN_YQ" '.proxy-groups[] | select(.type == "select") | .name' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null | head -n 1)
        [ -z "$grp" ] && grp=$(echo "$resp" | jq -r '.proxies | to_entries[] | select(.value.type=="Selector" and .key!="GLOBAL" and .key!="Global") | .key' | head -n 1)
        [ -z "$grp" ] && { echo "❌ 无法识别主分组"; return 1; }
        [ -z "$target" ] && { _interactive_node_select "$grp" ""; return 0; }
        echo "🔍 主分组: $grp"; _interactive_node_select "$grp" "$target"
        ;;
    *)
        # 默认
        local direct_target="$cmd"
        local resp=$(curl_api "/proxies"); [ -z "$resp" ] && return 1
        local grp=$("$BIN_YQ" '.proxy-groups[] | select(.type == "select") | .name' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null | head -n 1)
        [ -z "$grp" ] && grp=$(echo "$resp" | jq -r '.proxies | to_entries[] | select(.value.type=="Selector" and .key!="GLOBAL" and .key!="Global") | .key' | head -n 1)
        [ -z "$grp" ] && { echo "❌ 无法识别主分组"; return 1; }
        _interactive_node_select "$grp" "$direct_target"
        ;;
    esac
}

# ----------------- Status / UI -----------------
clashstatus() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        echo "用法: mihomo status"
        echo "功能: 查看 mihomo 进程状态、运行时间、端口信息和当前订阅地址。"
        return 0
    fi
    local pid_file="$MIHOMO_BASE_DIR/config/mihomo.pid"
    local log_file="$MIHOMO_BASE_DIR/logs/mihomo.log"
    local subscription_url=$(cat "$MIHOMO_CONFIG_URL" 2>/dev/null)
    if [ -n "$subscription_url" ]; then _okcat "订阅地址: $subscription_url"; else _failcat "订阅地址: 未设置"; fi
    if is_mihomo_running; then
        local pid=$(cat "$pid_file" 2>/dev/null)
        local uptime=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
        _okcat "mihomo 进程状态: 运行中"
        _okcat "进程 PID: $pid"
        _okcat "运行时间: ${uptime:-未知}"
        _get_proxy_port; _get_ui_port; _get_dns_port
        _okcat "代理端口: $MIXED_PORT"
        _okcat "管理端口: $UI_PORT"
        _okcat "DNS端口: $DNS_PORT"
        clashproxy status
    else
        _failcat "mihomo 进程状态: 未运行"
        [ -f "$pid_file" ] && { _failcat "发现残留 PID 文件，已清理"; rm -f "$pid_file"; }
        return 1
    fi
}

clashui() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        echo "用法: mihomo ui"
        echo "功能: 显示 Web 控制台访问地址和当前节点信息 (节点名/延迟)。"
        return 0
    fi
    _get_ui_port
    local query_url='api64.ipify.org'
    local public_ip=$(curl -s --noproxy "*" --connect-timeout 2 "$query_url")
    local public_address="http://${public_ip:-公网}:${UI_PORT}/ui"
    local local_ip=$(hostname -I | awk '{print $1}')
    local local_address="http://${local_ip}:${UI_PORT}/ui"

    # 自动识别分组
    local resp=$(curl_api "/proxies")
    local group=$(echo "$resp" | jq -r '.proxies | to_entries[] | select(.value.type=="Selector" and .key!="GLOBAL" and .key!="Global") | .key' | head -n 1)
    [ -z "$group" ] && group="Proxy"
    local group_enc=$(urlencode "$group")
    local node_name=$(curl_api "/proxies/$group_enc" | jq -r .now)
    local delay="N/A"
    if [[ -n "$node_name" && "$node_name" != "null" ]]; then
        local node_enc=$(urlencode "$node_name")
        local delay_val=$(curl_api "/proxies/$node_enc/delay?timeout=2000&url=http://www.gstatic.com/generate_204" | jq -r '.delay // "null"')
        [ "$delay_val" != "null" ] && delay="${delay_val}ms"
    else node_name="无法获取"; fi

    printf "\n"
    printf "╔═══════════════════════════════════════════════╗\n"
    printf "║                 %s                   ║\n" "$(_okcat 'Web 控制台')"
    printf "║═══════════════════════════════════════════════║\n"
    printf "║     🔓 注意放行端口：%-5s                   ║\n" "$UI_PORT"
    printf "║     🏠 内网：%-31s  ║\n" "$local_address"
    printf "║     🌏 公网：%-31s  ║\n" "$public_address"
    printf "║     ☁️  公共：%-31s  ║\n" "$URL_CLASH_UI"
    printf "║                                               ║\n"
    printf "║     📡 当前节点：%-30s ║\n" "$node_name"
    printf "║     ⏱️  延迟：%-33s ║\n" "$delay"
    printf "╚═══════════════════════════════════════════════╝\n\n"
}

# ----------------- Proxy / Tun -----------------
clashproxy() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        cat <<EOF
用法: mihomo proxy [on|off|status]
功能: 管理系统代理环境变量的设置。
 on      开启系统代理 (需 mihomo 运行中)
 off     关闭系统代理
 status  查看系统代理状态
EOF
        return 0
    fi
    case "$1" in
    on)
        if is_mihomo_running; then _set_system_proxy; _okcat '已开启系统代理'; else _failcat '无法开启系统代理：mihomo 进程未运行'; return 1; fi
        ;;
    off)
        _unset_system_proxy; _okcat '已关闭系统代理'
        ;;
    status)
        local system_proxy_status=$("$BIN_YQ" '.system-proxy.enable' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null)
        [ "$system_proxy_status" = "false" ] && { _failcat "系统代理：关闭"; return 1; }
        if is_mihomo_running; then _okcat "系统代理：开启\nhttp_proxy： $http_proxy\nsocks_proxy：$all_proxy"; else _failcat "系统代理：配置为开启，但 mihomo 进程未运行"; return 1; fi
        ;;
    *) clashproxy -h ;;
    esac
}

clashtun() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        cat <<EOF
用法: mihomo tun [on|off|status]
功能: 管理 mihomo 的 TUN 模式 (透明代理)。
 on      开启 TUN 模式
 off     关闭 TUN 模式
 status  查看 TUN 模式状态
EOF
        return 0
    fi
    case "$1" in
    on) _tunon ;;
    off) _tunoff ;;
    *) _tunstatus ;;
    esac
}

# ----------------- Other Settings -----------------
clashport() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        cat <<EOF
用法: mihomo port [status|auto|set <port>]
功能: 管理 mihomo 的代理端口配置。
 status   查看当前代理端口模式与端口
 auto     切换为自动分配代理端口 (需要重启生效)
 set <port> 固定代理端口 (需要重启生效)
EOF
        return 0
    fi
    local action=$1; shift || true
    case "$action" in
    ""|status)
        _load_port_preferences; _get_proxy_port
        local mode_msg="自动"; [ "$PORT_PREF_MODE" = "manual" ] && [ -n "$PORT_PREF_VALUE" ] && mode_msg="固定(${PORT_PREF_VALUE})"
        _okcat "端口模式：$mode_msg"; _okcat "当前代理端口：$MIXED_PORT"
        ;;
    auto)
        _save_port_preferences auto ""; _okcat "已切换为自动分配代理端口"
        is_mihomo_running && { _okcat "正在重新应用配置..."; clashrestart; }
        ;;
    set|manual)
        local manual_port=$1
        while true; do
            [ -z "$manual_port" ] && { printf "请输入想要固定的代理端口 [1024-65535]: "; read -r manual_port; }
            [ -z "$manual_port" ] && { _failcat "未输入端口"; continue; }
            if ! [[ $manual_port =~ ^[0-9]+$ ]] || [ "$manual_port" -lt 1024 ] || [ "$manual_port" -gt 65535 ]; then
                _failcat "端口号无效，请输入 1024-65535 之间的数字"; manual_port=""; continue
            fi
            if _is_already_in_use "$manual_port" "$BIN_KERNEL_NAME"; then
                _failcat '🎯' "端口 $manual_port 已被占用"
                printf "选择操作 [r]重新输入/[a]自动分配: "; read -r choice
                case "$choice" in
                    [aA]) _save_port_preferences auto ""; _okcat "已切换为自动分配代理端口"; break ;;
                    *) manual_port=""; continue ;;
                esac
            else
                _save_port_preferences manual "$manual_port"; _okcat "已固定代理端口：$manual_port"; break
            fi
        done
        is_mihomo_running && { _okcat "正在重新应用配置..."; clashrestart; }
        ;;
    *) clashport -h ;;
    esac
}

clashsecret() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        echo "用法: mihomo secret [<new_secret>]"
        echo "功能: 查看或设置 Web API 认证密钥。"
        echo " <new_secret>   设置新的认证密钥 (需要重启生效)"
        echo " (无参数)       查看当前的认证密钥"
        return 0
    fi
    case "$#" in
    0) [ -f "$MIHOMO_CONFIG_RUNTIME" ] && _okcat "当前密钥：$("$BIN_YQ" '.secret // ""' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)" ;;
    1) mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"; "$BIN_YQ" -i ".secret = \"$1\"" "$MIHOMO_CONFIG_MIXIN" 2>/dev/null || { _failcat "密钥更新失败"; return 1; }; _merge_config_restart; _okcat "密钥更新成功，已重启生效" ;;
    *) _failcat "密钥不要包含空格" ;;
    esac
}

clashmixin() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        cat <<EOF
用法: mihomo mixin [-e|-r]
功能: 管理/查看 Mixin 配置 (用户自定义配置片段)。
 -e     编辑 Mixin 配置文件 (使用 vim, 成功保存并验证后自动重启生效)
 -r     只读查看当前的运行时配置 (runtime.yaml)
 (默认) 只读查看 Mixin 配置文件
EOF
        return 0
    fi
    case "$1" in
    -e) vim "$MIHOMO_CONFIG_MIXIN" && { _merge_config_restart && _okcat "配置更新成功"; };;
    -r) less -f "$MIHOMO_CONFIG_RUNTIME" ;;
    *) less -f "$MIHOMO_CONFIG_MIXIN" ;;
    esac
}

clashnode() { clashnow "$@"; }

# ==============================================================================
# 3. 主控制入口
# ==============================================================================

clashctl() {
    local cmd="$1"
    shift || true

    case "$cmd" in
    # --- 订阅功能 ---
    sub|subscribe) clashsubscribe "$@" ;;
    update)        clashupdate "$@" ;;

    # --- 节点查看与切换 ---
    now)           clashnow "$@" ;;
    group)         clashgroup "$@" ;;
    ch)            clashch "$@" ;;
    node)          clashnode "$@" ;; # Alias

    # --- 服务启动 ---
    on)            clashon "$@" ;;
    off)           clashoff "$@" ;;
    restart)       clashrestart "$@" ;;

    # --- 状态面板与Web ---
    status)        clashstatus "$@" ;;
    ui)            clashui "$@" ;;

    # --- 代理与模式设置 ---
    proxy)         clashproxy "$@" ;;
    tun)           clashtun "$@" ;;

    # --- 其他设置 ---
    
    port)          clashport "$@" ;;
    secret)        clashsecret "$@" ;;
    mixin)         clashmixin "$@" ;;

    # --- 帮助 ---
    -h|--help)
        cat <<EOF
用法: mihomo <command> [arguments]

✅ 订阅功能:
 subscribe (sub) 管理订阅 [list|rm|ch|update]。
 update          更新当前订阅配置。

🚀 节点查看与切换:
 now             查看当前选中节点和模式。
 group           查看策略分组及节点状态 [status|test <group>]。
 ch              快速切换节点/策略组/订阅 [ch -n <node> | ch -g <group> | ch -s]。

⚙️ 服务启动:
 on              启动 mihomo 代理服务。
 off             停止 mihomo 代理服务。
 restart         重启 mihomo 代理服务。

📋 状态面板与Web:
 status          查看 mihomo 进程和端口状态。
 ui              显示 Web 控制台地址。

🛡️ 代理与模式设置:
 proxy           管理系统代理环境变量 [on|off|status]。
 tun             管理 TUN 模式 [on|off|status]。

🔧 其他设置:
 port            管理代理端口设置 [status|auto|set <port>]。
 secret          查看或设置 Web API 密钥。
 mixin           查看或编辑用户自定义 Mixin 配置。

使用 'mihomo <command> -h' 查看特定命令的详细用法。
EOF
        ;;
    *)
        if [ -z "$cmd" ]; then
            clashctl -h
        else
            _failcat "❌ 未知的命令: $cmd"
            echo "尝试 'mihomo -h' 查看帮助。"
        fi
        ;;
    esac
}

# ==============================================================================
# 4. 别名设置
# ==============================================================================
function mihomoctl() { clashctl "$@"; }
function clash() { clashctl "$@"; }
function mihomo() { clashctl "$@"; }
