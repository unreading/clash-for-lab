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
    # 1. 帮助信息
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        echo "用法: mihomo now"
        echo "功能: 显示当前订阅名称、主策略组、当前选中节点、延迟和核心模式。"
        return 0
    fi

    # 2. 检查服务
    if ! is_mihomo_running; then
        _failcat "当前没有开启代理 (mihomo 未运行)"
        return 1
    fi

    # 3. 显示订阅
    local current_sub="$(_get_current_subscribe)"
    [ -n "$current_sub" ] && printf "📂 当前订阅: %s\n" "$current_sub"
    
    # 4. 获取核心模式
    local mode=$(curl_api "/configs" | jq -r .mode)
    
    # 5. 定义默认变量
    local group_display=""
    local node_display=""
    local delay_display="N/A"
    
    # ==================== [核心逻辑修正] ====================
    if [ "$mode" = "global" ]; then
        # --- Global 模式逻辑 ---
        # 主分组显示为 GLOBAL
        group_display="GLOBAL (全局路由)"
        
        # 直接查询 GLOBAL 策略组的信息
        # 注意：Mihomo API 中 GLOBAL 策略组包含当前选中的节点信息
        local global_info=$(curl_api "/proxies/GLOBAL")
        local global_node=$(echo "$global_info" | jq -r .now)
        
        if [ -n "$global_node" ] && [ "$global_node" != "null" ]; then
            node_display="$global_node"
            # 查询该节点的真实延迟
            local node_enc=$(urlencode "$node_display")
            local d=$(curl_api "/proxies/$node_enc/delay?timeout=2000&url=http://www.gstatic.com/generate_204" | jq -r '.delay // "N/A"')
            [ "$d" != "N/A" ] && delay_display="${d}ms"
        else
            node_display="未知"
        fi
        
    else
        # --- Rule / Direct 模式逻辑 (原有逻辑) ---
        # 从配置文件查找主 Selector
        if [ -f "$MIHOMO_CONFIG_RUNTIME" ]; then
            group_display=$("$BIN_YQ" '.proxy-groups[] | select(.type == "select") | .name' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null | head -n 1)
        fi
        # 兜底查找
        if [ -z "$group_display" ]; then
            local resp=$(curl_api "/proxies")
            group_display=$(echo "$resp" | jq -r '.proxies | to_entries[] | select(.value.type=="Selector" and .key!="GLOBAL" and .key!="Global") | .key' | head -n 1)
        fi
        [ -z "$group_display" ] && group_display="无法识别"
        
        # 查询该 Selector 选中的节点
        local group_enc=$(urlencode "$group_display")
        local node_name=$(curl_api "/proxies/$group_enc" | jq -r .now)
        node_display="$node_name"
        
        # 查询延迟
        if [ -n "$node_name" ] && [ "$node_name" != "null" ]; then
            local node_enc=$(urlencode "$node_name")
            local d=$(curl_api "/proxies/$node_enc/delay?timeout=2000&url=http://www.gstatic.com/generate_204" | jq -r '.delay // "N/A"')
            [ "$d" != "N/A" ] && delay_display="${d}ms"
        fi
    fi
    # =======================================================
    
    printf "🎯 主分组: %s\n🚀 节点:  %s\n📶 延迟:  %s\n🛡️  模式:  %s\n" "$group_display" "$node_display" "$delay_display" "$mode"
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

    # 获取当前核心模式
    local mode=$(curl_api "/configs" | jq -r .mode)

    if [ "$show_nodes" = true ]; then
        # ==================== [交互/详情模式] ====================
        
        # --- 1. Global 模式特殊处理 ---
        if [ "$mode" = "global" ]; then
            # 如果未指定目标，显示简化菜单
            if [ -z "$target_input" ]; then
                echo "📋 请选择要查看的策略组 (Global 模式):"
                echo " [ 1] GLOBAL"
                printf "👉 输入编号: "; read -r input_idx
                if [ "$input_idx" = "1" ]; then
                    target_input="GLOBAL"
                else
                    echo "❌ 无效编号"; return 1
                fi
            # 如果指定了编号 1，映射为 GLOBAL
            elif [ "$target_input" = "1" ]; then
                target_input="GLOBAL"
            fi
            
            # 如果指定了其他名称但不是 GLOBAL
            if [ "$target_input" != "GLOBAL" ] && [ "$target_input" != "1" ]; then
                 echo "⚠️  Global 模式下仅支持查看 GLOBAL 分组"
                 return 1
            fi
            
            echo "🔄 Global 模式：正在获取全局节点列表..."
        
        # --- 2. Rule/Direct 模式常规处理 ---
        else
            if [ -z "$target_input" ]; then
                local all_groups=()
                while IFS= read -r g; do all_groups+=("$g"); done < <("$BIN_YQ" '.proxy-groups[] | select(.type == "select" or .type == "url-test" or .type == "fallback" or .type == "load-balance") | .name' "$MIHOMO_CONFIG_RUNTIME")
                if [ ${#all_groups[@]} -eq 0 ]; then echo "❌ 未找到策略组"; return 1; fi
                
                echo "📋 请选择要查看的策略组:"
                local k=1
                for g in "${all_groups[@]}"; do 
                    printf " [%2d] %s\n" "$k" "$g"
                    ((k++))
                done
                printf "👉 输入编号: "; read -r input_idx
                
                if [[ "$input_idx" =~ ^[0-9]+$ ]] && [ "$input_idx" -ge 1 ] && [ "$input_idx" -le "${#all_groups[@]}" ]; then
                    target_input="$input_idx"
                else 
                    echo "❌ 无效编号"; return 1
                fi
            fi
            
            # 解析数字编号
            if [[ "$target_input" =~ ^[0-9]+$ ]]; then
                local groups=(); while IFS= read -r group_name; do groups+=("$group_name"); done < <("$BIN_YQ" '.proxy-groups[] | select(.type == "select" or .type == "url-test" or .type == "fallback" or .type == "load-balance") | .name' "$MIHOMO_CONFIG_RUNTIME")
                if [ "$target_input" -ge 1 ] && [ "$target_input" -le "${#groups[@]}" ]; then
                    if [ -n "$ZSH_VERSION" ]; then target_input="${groups[$target_input]}"; else target_input="${groups[$((target_input-1))]}"; fi
                else 
                    echo "❌ 无效序号"; return 1
                fi
            fi
        fi

        local target_group="$target_input"
        local resp=$(curl_api "/proxies"); [ -z "$resp" ] && { echo "❌ API 异常"; return 1; }
        
        # 验证组是否存在
        local chk=$(echo "$resp" | jq -r --arg g "$target_group" '.proxies[$g].all')
        if [ "$chk" = "null" ] || [ "$chk" = "" ]; then echo "❌ 策略组 '$target_group' 不存在"; return 1; fi

        # 测速逻辑
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

        # 显示详情
        echo "📂 策略组: $target_group"
        echo "🏆 延迟最低 Top 5 (智能去重):"
        echo "$resp" | jq -r --arg g "$target_group" '.proxies as $root | [ $root[$g].all[] | {name: ., delay: ($root[.].history[-1].delay // 99999)} ] | map(select(.name | test("自动|直连|流量|到期|剩余|重置|官网|故障|群组|DIRECT|REJECT"; "i") | not)) | map(select(.delay > 0 and .delay < 99999)) | sort_by(.delay) | unique_by(if .name | test("[\\x{1F1E6}-\\x{1F1FF}]{2}") then (.name | match("[\\x{1F1E6}-\\x{1F1FF}]{2}").string) else (.name | gsub("\\d+|\\s+|-|_"; "") | ascii_upcase) end) | sort_by(.delay) | .[:5] | .[] | "   🚀 \(.name) (\(.delay)ms)"'
        echo "----------------------------------------"
        echo "📋 节点状态 (自适应列):"
        _interactive_node_select "$target_group" ""
        echo ""
        
    else
        # ==================== [列表模式] ====================
        local resp=$(curl_api "/proxies"); [ -z "$resp" ] && return 1
        echo "📋 策略分组列表 (按配置顺序)："
        (
            echo "🆔 编号|📂 分组名称|👉 当前选中|⚡ 延迟"
            echo "---|---|---|---"
            
            # --- [Global 模式视图] ---
            if [ "$mode" = "global" ]; then
                # 直接获取 GLOBAL 策略组的当前选中节点
                local now=$(echo "$resp" | jq -r '.proxies.GLOBAL.now // "未知"')
                local delay="N/A"
                
                # 获取该节点的延迟
                if [ -n "$now" ] && [ "$now" != "未知" ]; then
                     local d=$(echo "$resp" | jq -r --arg n "$now" '.proxies[$n].history[-1].delay // 0')
                     [ "$d" != "0" ] && delay="${d}ms"
                fi
                
                # 只显示这一行
                echo "1|GLOBAL|$now|$delay"
            
            # --- [Rule/Direct 模式视图] ---
            else
                local i=1
                "$BIN_YQ" '.proxy-groups[] | select(.type == "select" or .type == "url-test" or .type == "fallback" or .type == "load-balance") | .name' "$MIHOMO_CONFIG_RUNTIME" | while read -r n; do
                    # 使用简化的 jq 查询，避免嵌套错误
                    local info=$(echo "$resp" | jq -r --arg g "$n" '
                        .proxies[$g].now as $cur | 
                        (.proxies[$cur].history[-1].delay // 0) as $d |
                        $cur + "|" + (if $d == 0 then "N/A" else ($d | tostring) + "ms" end)
                    ')
                    
                    local now="${info%|*}"; local delay="${info#*|}"
                    if [ "$now" != "null" ] && [ -n "$now" ]; then echo "$i|$n|$now|$delay"; ((i++)); fi
                done
            fi
        ) | column -t -s '|'
        echo ""
    fi
}

clashch() {
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        cat <<EOF
用法: mihomo ch [COMMAND]
功能: 快速切换节点、策略组、订阅或代理模式。

选项:
 -n [<node>]     交互式切换主策略组的节点，或直接指定节点名称/序号。
 -g [<group>]    交互式选择策略组，并进入其节点切换界面。
 -s              进入订阅切换界面 (等同于 mihomo subscribe ch)。
 -m [<mode>]     切换代理模式 [rule|global|direct] (支持交互选择)。
 --library <path> 修改 Mihomo 的安装/数据目录路径。
EOF
        return 0
    fi

    local cmd="$1"
    # [修复] 只有当有参数时才执行 shift，消除 "shift count must be <= $#" 报错
    if [ $# -gt 0 ]; then shift; fi

    case "$cmd" in
    # --- 模式切换 ---
    -m|--mode)
        local target_mode="$1"
        if [ -z "$target_mode" ]; then
            if ! is_mihomo_running; then _failcat "服务未运行"; return 1; fi
            local current_mode=$(curl_api "/configs" | jq -r .mode 2>/dev/null)
            echo "🛡️  当前模式: ${current_mode:-未知}"
            echo "📋 请选择要切换的模式:"
            echo "   [1] Rule   (规则模式 - 推荐)"
            echo "   [2] Global (全局模式)"
            echo "   [3] Direct (直连模式)"
            echo
            printf "👉 请输入编号 [1-3]: "
            read -r choice
            case "$choice" in
                1|[rR]*) target_mode="rule" ;;
                2|[gG]*) target_mode="global" ;;
                3|[dD]*) target_mode="direct" ;;
                *) echo "❌ 取消操作"; return 1 ;;
            esac
        fi
        target_mode=$(echo "$target_mode" | tr '[:upper:]' '[:lower:]')
        if [[ "$target_mode" == "global" || "$target_mode" == "rule" || "$target_mode" == "direct" ]]; then
            local payload=$(jq -n --arg mode "$target_mode" '{mode: $mode}')
            if curl_api "/configs" -X PATCH -d "$payload" >/dev/null; then
                _okcat "✅ 核心模式已切换为: $target_mode"
                if [ "$target_mode" == "global" ]; then
                    _okcat "ℹ️ 提示: 现在使用 [mi ch] 将直接控制全局出口节点。"
                fi
            else
                _failcat "❌ 切换失败 (API请求错误)"; return 1
            fi
        else
            _failcat "❌ 无效模式: $target_mode"; return 1
        fi
        ;;
    
    # --- 修改安装路径 ---
    -lib|--library)
        local new_path="$1"
        [ -z "$new_path" ] && { _failcat "❌ 请指定新的安装路径"; return 1; }
        if [[ "$new_path" != /* ]]; then
            if [ -d "$new_path" ]; then new_path="$(cd "$new_path" && pwd)"; else
                local parent="$(cd "$(dirname "$new_path")" 2>/dev/null && pwd)"
                [ -z "$parent" ] && parent="$PWD"
                new_path="${parent}/$(basename "$new_path")"
            fi
        fi
        local common_file="$SCRIPT_DIR/common.sh"
        [ ! -f "$common_file" ] && { _failcat "❌ 找不到 common.sh"; return 1; }
        _okcat "新路径: $new_path"
        if sed -i "s|^MIHOMO_BASE_DIR=.*|MIHOMO_BASE_DIR=\"$new_path\"|" "$common_file"; then
            _okcat "✅ 修改成功，请手动移动旧数据并重启终端。"; else _failcat "❌ 修改失败"; return 1; fi
        ;;
    
    # --- 切换策略组 ---
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
        # 默认行为：节点切换
        local direct_target="$cmd"
        
        # [优化] 获取当前模式，如果是 global，直接操作 GLOBAL 策略组
        local mode=$(curl_api "/configs" | jq -r .mode 2>/dev/null)
        local grp=""
        
        if [ "$mode" = "global" ]; then
            grp="GLOBAL"
            # 只有当用户没有直接指定目标时，才显示提示，避免干扰脚本调用
            [ -z "$direct_target" ] && _okcat "🛡️  当前为 Global 模式，正在选择全局出口节点..."
        else
            local resp=$(curl_api "/proxies"); [ -z "$resp" ] && return 1
            grp=$("$BIN_YQ" '.proxy-groups[] | select(.type == "select") | .name' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null | head -n 1)
            [ -z "$grp" ] && grp=$(echo "$resp" | jq -r '.proxies | to_entries[] | select(.value.type=="Selector" and .key!="GLOBAL" and .key!="Global") | .key' | head -n 1)
        fi
        
        [ -z "$grp" ] && { echo "❌ 无法识别操作分组"; return 1; }
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

# ----------------- UI Update -----------------
clashui_update() {
    # 1. 检查环境
    if ! command -v curl >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
        _failcat "需要 curl 和 unzip 工具，请先安装: sudo dnf install curl unzip"
        return 1
    fi

    # 2. 获取当前配置的 UI 目录名
    local ui_dir_name=$("$BIN_YQ" '.external-ui // "dist"' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null)
    local target_dir="$MIHOMO_BASE_DIR/$ui_dir_name"
    
    _okcat "🔍 检测到 Web UI 安装目录: $target_dir"
    
    # 3. 准备临时目录
    local tmp_dir=$(mktemp -d)
    local download_url="https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip"
    
    # 4. 下载最新版 Zashboard
    _okcat "⏳ 正在从 GitHub 下载最新版 Zashboard..."
    if curl -L -o "$tmp_dir/dist.zip" --connect-timeout 10 --retry 3 "$download_url"; then
        _okcat "✅ 下载成功，正在解压..."
    else
        _failcat "❌ 下载失败，请检查网络连接"
        rm -rf "$tmp_dir"
        return 1
    fi

    # 5. 解压并替换
    if unzip -q "$tmp_dir/dist.zip" -d "$tmp_dir"; then
        # 备份旧版（可选，防止更新失败）
        if [ -d "$target_dir" ]; then
            mv "$target_dir" "${target_dir}.bak"
        fi
        
        # 移动新版到位
        # 注意：dist.zip 解压后通常包含一个 dist 文件夹
        if [ -d "$tmp_dir/dist" ]; then
            mv "$tmp_dir/dist" "$target_dir"
        else
            # 应对压缩包结构变化的情况，直接移动所有内容
            mkdir -p "$target_dir"
            cp -r "$tmp_dir/"* "$target_dir/" 2>/dev/null
        fi
        
        # 清理
        rm -rf "$tmp_dir"
        rm -rf "${target_dir}.bak" # 更新成功后删除备份
        
        _okcat "🎉 Web UI 更新完成！"
        _okcat "👉 请在浏览器中按 Ctrl+F5 强制刷新页面生效。"
    else
        _failcat "❌ 解压失败"
        rm -rf "$tmp_dir"
        return 1
    fi
}

function clashui() {
    # --- [新增] 子命令处理 ---
    if [[ "$1" == "update" ]]; then
        clashui_update
        return $?
    fi

    # --- 帮助信息 ---
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        echo "用法: mihomo ui [COMMAND]"
        echo "功能: 显示 Web 控制台信息或管理 UI 文件。"
        echo "  (无参数)   显示访问地址和当前节点状态"
        echo "  update     从 GitHub 下载并更新 Web UI 文件"
        return 0
    fi

    # --- 以下是原有的显示逻辑 (保持不变) ---
    _get_ui_port

    # 1. 检查服务状态
    if ! is_mihomo_running; then
        _failcat "当前没有开启代理 (mihomo 未运行)"
        return 1
    fi

    # 2. 获取核心模式
    local mode=$(curl_api "/configs" | jq -r .mode)
    
    # 3. 准备显示变量
    local group_display=""
    local node_display=""
    local delay_display="N/A"

    # 4. 根据模式获取节点信息
    if [ "$mode" = "global" ]; then
        group_display="GLOBAL (全局路由)"
        local global_info=$(curl_api "/proxies/GLOBAL")
        local global_node=$(echo "$global_info" | jq -r .now)
        
        if [ -n "$global_node" ] && [ "$global_node" != "null" ]; then
            node_display="$global_node"
            local node_enc=$(urlencode "$node_display")
            local d=$(curl_api "/proxies/$node_enc/delay?timeout=2000&url=http://www.gstatic.com/generate_204" | jq -r '.delay // "N/A"')
            [ "$d" != "N/A" ] && delay_display="${d}ms"
        else
            node_display="未知"
        fi
    else
        local resp=$(curl_api "/proxies"); 
        [ -z "$resp" ] && { _failcat "❌ API 异常"; return 1; }

        local group=""
        if [ -f "$MIHOMO_CONFIG_RUNTIME" ]; then
            group=$("$BIN_YQ" '.proxy-groups[] | select(.type == "select") | .name' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null | head -n 1)
        fi
        if [ -z "$group" ]; then
            group=$(echo "$resp" | jq -r '.proxies | to_entries[] | select(.value.type=="Selector" and .key!="GLOBAL" and .key!="Global") | .key' | head -n 1)
        fi
        [ -z "$group" ] && group="Proxy"
        
        group_display="$group"
        local group_enc=$(urlencode "$group")
        local node_name=$(curl_api "/proxies/$group_enc" | jq -r .now)
        
        if [[ -n "$node_name" && "$node_name" != "null" ]]; then
            node_display="$node_name"
            local node_enc=$(urlencode "$node_name")
            local d=$(curl_api "/proxies/$node_enc/delay?timeout=2000&url=http://www.gstatic.com/generate_204" | jq -r '.delay // "N/A"')
            [ "$d" != "N/A" ] && delay_display="${d}ms"
        else 
            node_display="无法获取"
        fi
    fi

    # 5. 格式化输出
    local query_url='api64.ipify.org'
    local public_ip=$(curl -s --noproxy "*" --connect-timeout 2 "$query_url")
    local public_address="http://${public_ip:-公网}:${UI_PORT}/ui"
    local local_ip=$(hostname -I | awk '{print $1}')
    local local_address="http://${local_ip}:${UI_PORT}/ui"
    local forward_address="http://127.0.0.1:${UI_PORT}/ui"
    
    # [新增] 获取配置的监听地址
    local listener_addr=$("$BIN_YQ" '.external-controller // "127.0.0.1:9090"' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null)
    local listener_line="🔑 当前内核监听配置："
    
    local max_len=0
    # [修改] 纳入新变量计算宽度
    for text in "$public_address" "$local_address" "$forward_address" "$URL_CLASH_UI" "$node_display" "$group_display" "$listener_addr"; do
        local len=${#text}
        [ $len -gt $max_len ] && max_len=$len
    done

    local TOTAL_WIDTH=$(( max_len + 13 ))
    [ $TOTAL_WIDTH -lt 42 ] && TOTAL_WIDTH=42
    
    local line_inner=""
    for ((i=0; i<TOTAL_WIDTH-2; i++)); do line_inner+="═"; done

    _print_line() {
        local label="$1"
        local value="$2"
        printf "║ %s%s" "$label" "$value"
        printf "\033[${TOTAL_WIDTH}G║\n"
    }

    local header="$(_okcat 'Web 控制台')"

    printf "\n"
    printf "╔%s╗\n" "$line_inner"
    _print_line "$header" ""
    printf "║%s║\n" "$line_inner"
    _print_line "🔓 !!!注意放行端口：" "$UI_PORT"
    _print_line "$listener_line" "$listener_addr" # <--- 新增行
    printf "\033[${TOTAL_WIDTH}G║\n"
    _print_line "🏠 内网：" "$local_address"
    _print_line "🌏 公网：" "$public_address"
    _print_line "🔗 本地：" "$forward_address"
    _print_line "☁️  官方：" "$URL_CLASH_UI"
    printf "║"
    printf "\033[${TOTAL_WIDTH}G║\n"
    _print_line "🎯 当前分组：" "$group_display"
    _print_line "🚀 当前节点：" "$node_display"
    _print_line "⏱️  延迟：" "$delay_display"
    printf "╚%s╝\n\n" "$line_inner"
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
    # 保持原有的帮助信息逻辑
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        cat <<EOF
用法: mihomo mixin [Option]
功能: 管理/查看 Mixin 配置 (用户自定义配置片段)。
 (无参数)    显示交互式管理菜单 (编辑/修改监听地址)
 -e          直接调用 vim 编辑 Mixin 配置文件
 -r          只读查看当前的运行时配置 (runtime.yaml)
EOF
        return 0
    fi

    # 保持原有的快捷参数逻辑
    case "$1" in
    -e) vim "$MIHOMO_CONFIG_MIXIN" && { _merge_config_restart && _okcat "配置更新成功"; }; return ;;
    -r) less -f "$MIHOMO_CONFIG_RUNTIME" ; return ;;
    esac

    # ==================== 新增交互菜单逻辑 ====================
    echo "📋 Mixin 配置管理"
    echo "----------------------------------------"
    echo " [1] 📝 打开设置 (编辑配置文件)"
    echo " [2] 🌐 修改监听地址 (127.0.0.1 / 0.0.0.0)"
    echo "----------------------------------------"
    printf "👉 请输入选项 [1-2]: "
    read -r choice

    case "$choice" in
    1)
        # 选项1：维持原来的打开 (vim 编辑)
        vim "$MIHOMO_CONFIG_MIXIN" && { _merge_config_restart && _okcat "配置更新成功"; }
        ;;
    2)
        # 选项2：修改监听地址 (带密码交互逻辑)
        
        # 1. 获取当前完整配置 (例如 127.0.0.1:9090)
        local current_full=$("$BIN_YQ" '.external-controller // "127.0.0.1:9090"' "$MIHOMO_CONFIG_MIXIN")
        
        # 2. 提取端口号 (保留原端口)
        local current_port="9090"
        if [[ "$current_full" == *":"* ]]; then
            current_port="${current_full##*:}" 
        else
            current_port="$current_full"
        fi

        echo ""
        _okcat "当前监听地址: $current_full"
        echo "👇 请选择新的监听模式 (端口 $current_port 将保持不变):"
        echo " [1] 🏠 127.0.0.1 (仅限本机访问 - 安全)"
        echo " [2] 🌏 0.0.0.0   (允许公网访问 - 需配置密码)"
        printf "👉 请输入 [1/2]: "
        read -r ip_choice

        local new_ip=""
        local pass_action="none" # none, set, clear
        local new_pass=""

        case "$ip_choice" in
            1) 
                new_ip="127.0.0.1" 
                # 切换回本地时，询问是否清除密码
                echo -n "❓ 是否清除 API 访问密码? [y/N]: "
                read -r clear_pass
                if [[ "$clear_pass" =~ ^[yY] ]]; then
                    pass_action="clear"
                fi
                ;;
            2) 
                new_ip="0.0.0.0" 
                # 切换到公网时，询问是否设置密码
                echo -n "❓ 是否立即设置访问密码? (推荐) [Y/n]: "
                read -r set_pass
                # 默认为 Yes
                if [[ ! "$set_pass" =~ ^[nN] ]]; then 
                    pass_action="set"
                    while [ -z "$new_pass" ]; do
                        printf "⌨️  请输入新密码: "
                        read -r new_pass
                        [ -z "$new_pass" ] && _failcat "❌ 密码不能为空，请重新输入"
                    done
                else
                    _okcat "⚠️  警告：您选择了不设置密码，公网访问将处于裸奔状态！"
                    echo "👉 后续请务必使用 'mihomo secret <password>' 进行补设。"
                fi
                ;;
            *) _failcat "❌ 无效选择"; return 1 ;;
        esac

        # 3. 拼接新地址
        local new_val="${new_ip}:${current_port}"

        # 4. 开始应用修改
        _okcat "🔄 正在应用配置..."
        mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"

        # 修改 IP
        "$BIN_YQ" -i ".external-controller = \"$new_val\"" "$MIHOMO_CONFIG_MIXIN" 2>/dev/null
        
        # 处理密码逻辑
        if [ "$pass_action" == "set" ]; then
            "$BIN_YQ" -i ".secret = \"$new_pass\"" "$MIHOMO_CONFIG_MIXIN" 2>/dev/null
            _okcat "🔐 密码已更新"
        elif [ "$pass_action" == "clear" ]; then
             "$BIN_YQ" -i ".secret = \"\"" "$MIHOMO_CONFIG_MIXIN" 2>/dev/null
             _okcat "🔓 密码已清除"
        fi

        # 5. 重启生效
        if [ $? -eq 0 ]; then
            _merge_config_restart && _okcat "✅ 监听地址修改成功 ($new_val)"
        else
            _failcat "❌ 修改失败，请检查 yq 工具"
        fi
        ;;
    *)
        echo "取消操作"
        ;;
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