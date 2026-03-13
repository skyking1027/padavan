#!/bin/sh

# ==================== 配置区 ====================
PROG="$(nvram get zerotier_bin)"
[ -z "$PROG" ] && PROG="/usr/bin/zerotier-one"
PROGCLI="$PROG"               # ZeroTier 单二进制：cli 就是主程序
PROGIDT="$PROG"               # idtool 也是同一个二进制
config_path="/etc/storage/zerotier-one"
user_agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
github_proxys="$(nvram get github_proxy)"
[ -z "$github_proxys" ] && github_proxys=" "  # 空格表示无代理
scriptfilepath=$(cd "$(dirname "$0")"; pwd)/$(basename $0)
zerotier_renum=$(nvram get zerotier_renum)

# ==================== 工具函数 ====================
check_disk_size() {
    local path="$1"
    local avail_kb
    avail_kb=$(df "$path" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -z "$avail_kb" ] || ! echo "$avail_kb" | grep -qE '^[0-9]+$'; then
        echo "0"
    else
        echo $((avail_kb / 1024))  # 转为 MB
    fi
}

zt_restart() {
    relock="/var/lock/zerotier_restart.lock"
    if [ "$1" = "o" ]; then
        nvram set zerotier_renum="0"
        [ -f "$relock" ] && rm -f "$relock"
        return 0
    fi

    if [ "$1" = "x" ]; then
        zerotier_renum=${zerotier_renum:-"0"}
        zerotier_renum=$((zerotier_renum + 1))
        nvram set zerotier_renum="$zerotier_renum"
        nvram commit

        if [ "$zerotier_renum" -gt "3" ]; then
            I=19
            echo "$I" > "$relock"
            logger -t "【zerotier】" "多次尝试启动失败，等待【$(cat $relock)分钟】后自动尝试重新启动"
            while [ $I -gt 0 ]; do
                I=$((I - 1))
                echo "$I" > "$relock"
                sleep 60
                [ "$(nvram get zerotier_renum)" = "0" ] && break
                [ $I -lt 0 ] && break
            done
            nvram set zerotier_renum="1"
            nvram commit
        fi
        [ -f "$relock" ] && rm -f "$relock"
    fi
    start_zero
}

kill_z() {
    local pids
    pids=$(pidof zerotier-one)
    if [ -n "$pids" ]; then
        logger -t "【zerotier】" "关闭 zerotier-one 进程..."
        killall zerotier-one >/dev/null 2>&1
        sleep 1
        kill -9 $pids >/dev/null 2>&1
    fi
}

stop_zero() {
    del_rules
    zero_route "del"
    kill_z
    # 注意：不删除 config_path，保留配置
}

start_zero() {
    logger -t "【zerotier】" "正在启动 ZeroTier 服务..."
    kill_z
    mkdir -p "$config_path"
    start_instance
}

# ==================== 核心功能 ====================
start_instance() {
    port="$(nvram get zerotier_port)"
    args="$(nvram get zerotier_args)"
    nwid="$(nvram get zerotier_id)"
    moonid="$(nvram get zerotier_moonid)"
    secret="$(nvram get zerotier_secret)"

    mkdir -p "$config_path/networks.d" "$config_path/moons.d"

    if [ -n "$port" ]; then
        args="$args -p$port"
    fi

    if [ -z "$nwid" ]; then
        logger -t "【zerotier】" "ZeroTier 网络ID为空，请正确填写！"
        return 1
    fi
    [ ! -f "$config_path/networks.d/$nwid.conf" ] && touch "$config_path/networks.d/$nwid.conf"

    # 处理密钥
    if [ ! -s "$config_path/identity.secret" ]; then
        if [ -n "$secret" ]; then
            logger -t "【zerotier】" "找到密钥，正在写入文件..."
            echo "$secret" > "$config_path/identity.secret"
        else
            logger -t "【zerotier】" "密钥为空，正在生成新密钥..."
            sf="$config_path/identity.secret"
            pf="$config_path/identity.public"
            $PROGIDT generate "$sf" "$pf" >/dev/null
            [ $? -ne 0 ] && { logger -t "【zerotier】" "密钥生成失败！"; return 1; }
            secret="$(cat "$sf")"
            nvram set zerotier_secret="$secret"
            nvram commit
        fi
    fi

    if [ ! -s "$config_path/identity.public" ]; then
        logger -t "【zerotier】" "生成公钥文件..."
        $PROGIDT getpublic "$config_path/identity.secret" > "$config_path/identity.public"
    fi

    # 符号链接到内存盘（减少闪存写入）
    tmpdir="/tmp/zero"
    mkdir -p "$tmpdir"
    for file in peers.d controller.d zerotier-one.port zerotier-one.pid metrics.prom; do
        src="$tmpdir/$file"
        dst="$config_path/$file"
        if [ ! -L "$dst" ]; then
            rm -rf "$dst"
            case "$file" in
                *.d) mkdir -p "$src";;
                *) touch "$src";;
            esac
            ln -sf "$src" "$dst"
        fi
    done

    # 启动主进程
    logger -t "【zerotier】" "启动 $PROG $args $config_path"
    $PROG $args "$config_path" >/dev/null 2>&1 &

    # 等待端口文件生成（表示启动成功）
    timeout=30
    while [ ! -f "$config_path/zerotier-one.port" ] && [ $timeout -gt 0 ]; do
        sleep 1
        timeout=$((timeout - 1))
    done

    if [ ! -f "$config_path/zerotier-one.port" ]; then
        logger -t "【zerotier】" "启动超时，未检测到端口文件"
        return 1
    fi

    # 加入 Moon
    if [ -n "$moonid" ]; then
        $PROGCLI orbit "$moonid" "$moonid"
        logger -t "【zerotier】" "加入 Moon: $moonid 成功!"
    fi

    # 加入网络
    if [ -n "$nwid" ]; then
        $PROGCLI join "$nwid"
        logger -t "【zerotier】" "加入网络: $nwid 成功!"
        rules
    fi
}

rules() {
    while [ -z "$(ifconfig | grep '^zt' | awk '{print $1}')" ]; do
        sleep 1
    done

    nat_enable=$(nvram get zerotier_nat)
    zt0=$(ifconfig | grep '^zt' | awk '{print $1}')
    del_rules

    logger -t "【zerotier】" "添加 ${zt0} 防火墙规则..."
    iptables -I INPUT -i "$zt0" -j ACCEPT
    iptables -I FORWARD -i "$zt0" -o "$zt0" -j ACCEPT
    iptables -I FORWARD -i "$zt0" -j ACCEPT

    if [ "$nat_enable" = "1" ]; then
        iptables -t nat -I POSTROUTING -o "$zt0" -j MASQUERADE
        timeout=30
        while [ -z "$(ip route | grep -E "dev\\s+$zt0\\s+proto\\s+kernel" | awk '{print $1}')" ] && [ $timeout -gt 0 ]; do
            sleep 1
            timeout=$((timeout - 1))
        done
        ip_segment=$(ip route | grep -E "dev\\s+$zt0\\s+proto\\s+kernel" | awk '{print $1}')
        if [ -n "$ip_segment" ]; then
            logger -t "【zerotier】" "将网段 $ip_segment 添加进 NAT 规则..."
            iptables -t nat -I POSTROUTING -s "$ip_segment" -j MASQUERADE
            zero_route "add"
        fi
    fi

    # 检查进程状态
    if pidof zerotier-one >/dev/null; then
        mem=$(awk '/VmRSS/{printf "%.1f MB", $2/1024}' /proc/$(pidof zerotier-one)/status 2>/dev/null || echo "N/A")
        cpui=$(top -b -n1 2>/dev/null | awk -v pid=$(pidof zerotier-one) '$1==pid{print $9}' || echo "N/A")
        zt_ver=$($PROG -version 2>/dev/null | head -n1 || echo "unknown")
        logger -t "【zerotier】" "zerotier-one ${zt_ver} 启动成功! 内存: ${mem}, CPU: ${cpui}%"
        zt_restart o
    else
        logger -t "【zerotier】" "启动失败，10 秒后重试..."
        sleep 10
        zt_restart x
        return
    fi

    # 检查 ONLINE 状态
    count=0
    while [ $count -lt 5 ]; do
        ztstatus=$($PROGCLI info 2>/dev/null | awk '{print $5}')
        if [ "$ztstatus" = "ONLINE" ]; then
            ztid=$($PROGCLI info | awk '{print $3}')
            nvram set zerotierdev_id="$ztid"
            nvram set zerotier_status="ONLINE 在线"
            nvram commit
            zt_keep
            return 0
        elif [ "$ztstatus" = "OFFLINE" ]; then
            sleep 2
        fi
        count=$((count + 1))
    done

    logger -t "【zerotier】" "当前 ZeroTier 未上线，可能无法连接官方服务器！"
    nvram set zerotier_status="OFFLINE 离线"
    nvram commit
    exit 1
}

del_rules() {
    zt0=$(ifconfig | grep '^zt' | awk '{print $1}') || return 0
    ip_segment=$(ip route | grep -E "dev\\s+$zt0\\s+proto\\s+kernel" | awk '{print $1}') || return 0

    iptables -D INPUT -i "$zt0" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i "$zt0" -o "$zt0" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i "$zt0" -j ACCEPT 2>/dev/null
    iptables -t nat -D POSTROUTING -o "$zt0" -j MASQUERADE 2>/dev/null
    iptables -t nat -D POSTROUTING -s "$ip_segment" -j MASQUERADE 2>/dev/null
}

zero_route() {
    rulesnum=$(nvram get zero_staticnum_x)
    [ -z "$rulesnum" ] && rulesnum=0

    for i in $(seq 1 $rulesnum); do
        j=$((i - 1))
        route_enable=$(nvram get zero_enable_x$j)
        zero_ip=$(nvram get zero_ip_x$j)
        zero_route=$(nvram get zero_route_x$j)
        zt0=$(ifconfig | grep '^zt' | awk '{print $1}') || continue

        if [ "$1" = "add" ]; then
            if [ "$route_enable" = "1" ] && [ -n "$zero_ip" ] && [ -n "$zero_route" ]; then
                ip route add "$zero_ip" via "$zero_route" dev "$zt0" 2>/dev/null
            fi
        else
            ip route del "$zero_ip" via "$zero_route" dev "$zt0" 2>/dev/null
        fi
    done
}

zt_keep() {
    logger -t "【zerotier】" "注册守护进程..."
    if [ -s /tmp/script/_opt_script_check ]; then
        sed -Ei '/【zerotier】|^$/d' /tmp/script/_opt_script_check
        zt0=$(ifconfig | grep '^zt' | awk '{print $1}') || zt0="zt+"
        cat >> "/tmp/script/_opt_script_check" <<-OSC
	[ -z "\$(pidof zerotier-one)" ] && logger -t "进程守护" "zerotier-one 进程掉线" && eval "$scriptfilepath start &" && sed -Ei '/【zerotier】|^$/d' /tmp/script/_opt_script_check #【zerotier】
	[ -z "\$(iptables -L -n -v | grep '$zt0')" ] && logger -t "进程守护" "zerotier-one 防火墙规则失效" && eval "$scriptfilepath start &" && sed -Ei '/【zerotier】|^$/d' /tmp/script/_opt_script_check #【zerotier】
	OSC
    fi
    exit 0
}

# ==================== 版本管理 ====================
get_zttag() {
    logger -t "【zerotier】" "开始获取最新版本..."
    tag=""
    if command -v curl >/dev/null; then
        tag=$(curl -k --connect-timeout 5 --max-time 10 --user-agent "$user_agent" \
            https://api.github.com/repos/lmq8267/ZeroTierOne/releases/latest 2>/dev/null | grep '"tag_name"' | cut -d'"' -f4)
    elif command -v wget >/dev/null; then
        tag=$(wget --no-check-certificate -T 5 -t 2 --user-agent "$user_agent" -qO- \
            https://api.github.com/repos/lmq8267/ZeroTierOne/releases/latest 2>/dev/null | grep '"tag_name"' | cut -d'"' -f4)
    fi

    if [ -z "$tag" ]; then
        logger -t "【zerotier】" "无法获取最新版本"
        nvram set zerotier_ver_n=""
    else
        nvram set zerotier_ver_n="$tag"
    fi
    nvram commit

    # 更新当前版本信息
    if [ -f "$PROG" ]; then
        chmod +x "$PROG"
        zt_ver=$($PROG -version 2>/dev/null | head -n1)
        nvram set zerotier_ver="${zt_ver:-unknown}"
        # 确保 cli 链接存在
        [ ! -e "$PROGCLI" ] && ln -sf "$PROG" "$PROGCLI"
        ztstatus=$($PROGCLI info 2>/dev/null | awk '{print $5}') || ztstatus="OFFLINE"
        ztid=$($PROGCLI info 2>/dev/null | awk '{print $3}') || ztid="unknown"
        nvram set zerotierdev_id="$ztid"
        if [ "$ztstatus" = "ONLINE" ]; then
            nvram set zerotier_status="ONLINE 在线"
        else
            nvram set zerotier_status="OFFLINE 离线"
        fi
        nvram commit
    fi
}

dowload_zero() {
    tag="$1"
    [ -z "$tag" ] && { logger -t "【zerotier】" "未指定下载版本"; return 1; }

    logger -t "【zerotier】" "开始下载 zerotier-one $tag ..."
    bin_path=$(dirname "$PROG")
    [ ! -d "$bin_path" ] && mkdir -p "$bin_path"

    # 获取文件大小（估算）
    file_url="https://github.com/lmq8267/ZeroTierOne/releases/download/${tag}/zerotier-one"
    length=0
    for proxy in $github_proxys; do
        url="${proxy}${file_url}"
        if command -v curl >/dev/null; then
            length=$(curl -I -k --connect-timeout 5 "$url" 2>/dev/null | grep -i "content-length" | awk '{print $2}' | tr -d '\r')
        elif command -v wget >/dev/null; then
            length=$(wget --spider -S "$url" 2>&1 | grep -i "content-length" | awk '{print $2}')
        fi
        [ -n "$length" ] && break
    done

    if [ -n "$length" ]; then
        need_mb=$(( (length + 1048575) / 1048576 + 1 ))  # 向上取整 + 1MB 缓冲
        avail_mb=$(check_disk_size "$bin_path")
        if [ "$avail_mb" -lt "$need_mb" ]; then
            logger -t "【zerotier】" "磁盘空间不足：需要 ${need_mb}MB，可用 ${avail_mb}MB"
            return 1
        fi
        logger -t "【zerotier】" "文件大小约 ${length} 字节（${need_mb}MB），磁盘空间充足"
    fi

    # 下载
    success=0
    for proxy in $github_proxys; do
        url="${proxy}${file_url}"
        logger -t "【zerotier】" "尝试从 $url 下载..."
        if command -v curl >/dev/null; then
            if curl -k --connect-timeout 15 --max-time 60 --user-agent "$user_agent" -L -o "$PROG.tmp" "$url"; then
                success=1
                break
            fi
        elif command -v wget >/dev/null; then
            if wget --no-check-certificate -T 20 -t 2 --user-agent "$user_agent" -O "$PROG.tmp" "$url"; then
                success=1
                break
            fi
        fi
    done

    if [ "$success" = "1" ]; then
        mv "$PROG.tmp" "$PROG"
        chmod +x "$PROG"
        logger -t "【zerotier】" "下载成功！"
        nvram set zerotier_ver_downloaded="$tag"
        nvram commit
        return 0
    else
        logger -t "【zerotier】" "所有代理下载失败！"
        rm -f "$PROG.tmp"
        return 1
    fi
}

# ==================== 主入口 ====================
case "$1" in
    start)
        start_zero
        sleep 2
        echo 3 > /proc/sys/vm/drop_caches
        ;;
    stop)
        stop_zero
        sleep 2
        echo 3 > /proc/sys/vm/drop_caches
        ;;
    restart)
        stop_zero
        sleep 2
        start_zero
        ;;
    update)
        get_zttag
        latest=$(nvram get zerotier_ver_n)
        current=$(nvram get zerotier_ver_downloaded)
        if [ -n "$latest" ] && [ "$latest" != "$current" ]; then
            dowload_zero "$latest"
        else
            logger -t "【zerotier】" "已是最新版本：$latest"
        fi
        ;;
    version)
        get_zttag
        ;;
    *)
        echo "用法: $0 {start|stop|restart|update|version}"
        exit 1
        ;;
esac
