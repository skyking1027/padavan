#!/bin/sh

# 基础配置
PROG="$(nvram get zerotier_bin)"
config_path="/etc/storage/zerotier-one"
user_agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
github_proxys="$(nvram get github_proxy)"
[ -z "$github_proxys" ] && github_proxys=""
scriptfilepath=$(cd "$(dirname "$0")"; pwd)/$(basename "$0")
zerotier_renum=$(nvram get zerotier_renum)
zerotier_renum=${zerotier_renum:-0}

# 先定义目录和软链接工具
if [ -z "$PROG" ]; then
  if [ -d "/etc/storage" ] && df -k /etc/storage | awk 'NR==2 {print $4}' | grep -q '^[0-9]'; then
    PROG="/etc/storage/bin/zerotier-one"
  else
    PROG="/tmp/var/zerotier-one"
  fi
  nvram set zerotier_bin="$PROG"
  nvram commit
fi

zt_dir=$(dirname "$PROG")
PROGCLI="${zt_dir}/zerotier-cli"
PROGIDT="${zt_dir}/zerotier-idtool"

mkdir -p /tmp/script /tmp/zero "$zt_dir" "$config_path"

# 重启防卡死
zt_restart() {
  relock="/var/lock/zerotier_restart.lock"
  if [ "$1" = "o" ]; then
    nvram set zerotier_renum="0"
    rm -f "$relock"
    return 0
  fi

  if [ "$1" = "x" ]; then
    zerotier_renum=$((zerotier_renum + 1))
    nvram set zerotier_renum="$zerotier_renum"
    if [ "$zerotier_renum" -gt 3 ]; then
      I=19
      echo "$I" > "$relock"
      logger -t "【zerotier】" "多次启动失败，等待 $I 分钟后重试"
      while [ "$I" -gt 0 ]; do
        I=$((I - 1))
        echo "$I" > "$relock"
        sleep 60
        [ "$(nvram get zerotier_renum)" = "0" ] && break
        [ "$I" -lt 0 ] && break
      done
      nvram set zerotier_renum="1"
    fi
    rm -f "$relock"
  fi
  start_zero
}

# 清理规则
del_rules() {
  zt0=$(ifconfig | grep -m1 '^zt' | awk '{print $1}')
  [ -z "$zt0" ] && return
  ip_segment=$(ip route | grep -m1 "dev $zt0 proto kernel" | awk '{print $1}')

  iptables -D INPUT -i "$zt0" -j ACCEPT 2>/dev/null
  iptables -D FORWARD -i "$zt0" -o "$zt0" -j ACCEPT 2>/dev/null
  iptables -D FORWARD -i "$zt0" -j ACCEPT 2>/dev/null
  iptables -t nat -D POSTROUTING -o "$zt0" -j MASQUERADE 2>/dev/null
  iptables -t nat -D POSTROUTING -s "$ip_segment" -j MASQUERADE 2>/dev/null
}

# 静态路由
zero_route() {
  rulesnum=$(nvram get zero_staticnum_x)
  [ -z "$rulesnum" ] && rulesnum=0
  for i in $(seq 1 "$rulesnum"); do
    j=$((i - 1))
    route_enable=$(nvram get zero_enable_x$j)
    zero_ip=$(nvram get zero_ip_x$j)
    zero_route=$(nvram get zero_route_x$j)
    zt0=$(ifconfig | grep -m1 '^zt' | awk '{print $1}')

    if [ "$1" = "add" ] && [ "$route_enable" -ne 0 ]; then
      ip route add "$zero_ip" via "$zero_route" dev "$zt0" 2>/dev/null
    elif [ "$1" = "del" ]; then
      ip route del "$zero_ip" via "$zero_route" dev "$zt0" 2>/dev/null
    fi
  done
}

# 启动实例
start_instance() {
  port=$(nvram get zerotier_port)
  args=$(nvram get zerotier_args)
  nwid=$(nvram get zerotier_id)
  moonid=$(nvram get zerotier_moonid)
  secret=$(nvram get zerotier_secret)

  mkdir -p "$config_path/networks.d" "$config_path/moons.d"
  [ -n "$port" ] && args="$args -p$port"

  if [ -n "$nwid" ]; then
    touch "$config_path/networks.d/$nwid.conf"
  else
    logger -t "【zerotier】" "网络ID为空"
  fi

  # 密钥处理
  if [ ! -s "$config_path/identity.secret" ]; then
    if [ -n "$secret" ]; then
      echo "$secret" > "$config_path/identity.secret"
      logger -t "【zerotier】" "写入密钥成功"
    else
      logger -t "【zerotier】" "生成新密钥"
      "$PROGIDT" generate "$config_path/identity.secret" "$config_path/identity.public" >/dev/null 2>&1
      secret=$(cat "$config_path/identity.secret")
      nvram set zerotier_secret="$secret"
      nvram commit
    fi
  fi

  if [ ! -s "$config_path/identity.public" ]; then
    "$PROGIDT" getpublic "$config_path/identity.secret" > "$config_path/identity.public"
  fi

  # 临时目录软链接（防止闪存写爆）
  mkdir -p /tmp/zero/peers.d /tmp/zero/controller.d
  ln -sf /tmp/zero/peers.d "$config_path/peers.d"
  ln -sf /tmp/zero/controller.d "$config_path/controller.d"
  touch /tmp/zero/zerotier-one.port /tmp/zero/zerotier-one.pid /tmp/zero/metrics.prom
  ln -sf /tmp/zero/zerotier-one.port "$config_path/zerotier-one.port"
  ln -sf /tmp/zero/zerotier-one.pid "$config_path/zerotier-one.pid"
  ln -sf /tmp/zero/metrics.prom "$config_path/metrics.prom"

  # 启动
  logger -t "【zerotier】" "启动: $PROG $args $config_path"
  "$PROG" $args "$config_path" >/dev/null 2>&1 &

  # 等待端口文件
  while [ ! -f "$config_path/zerotier-one.port" ]; do
    sleep 1
  done

  [ -n "$moonid" ] && "$PROGCLI" orbit "$moonid" "$moonid" && logger -t "【zerotier】" "已加入moon"
  [ -n "$nwid" ] && "$PROGCLI" join "$nwid" && logger -t "【zerotier】" "已加入网络"

  # 防火墙
  nat_enable=$(nvram get zerotier_nat)
  zt0=$(ifconfig | grep -m1 '^zt' | awk '{print $1}')
  [ -z "$zt0" ] && sleep 2 && zt0=$(ifconfig | grep -m1 '^zt' | awk '{print $1}')

  del_rules
  iptables -I INPUT -i "$zt0" -j ACCEPT
  iptables -I FORWARD -i "$zt0" -o "$zt0" -j ACCEPT
  iptables -I FORWARD -i "$zt0" -j ACCEPT

  if [ "$nat_enable" -eq 1 ]; then
    iptables -t nat -I POSTROUTING -o "$zt0" -j MASQUERADE
    while [ -z "$ip_segment" ]; do
      ip_segment=$(ip route | grep -m1 "dev $zt0 proto kernel" | awk '{print $1}')
      sleep 1
    done
    iptables -t nat -I POSTROUTING -s "$ip_segment" -j MASQUERADE
    zero_route add
  fi

  # 状态
  zt_ver=$("$PROG" -version 2>/dev/null | head -n1)
  pid=$(pidof zerotier-one)
  if [ -n "$pid" ]; then
    mem=$(awk '/VmRSS/ {printf "%.1f MB", $2/1024}' /proc/$pid/status)
    logger -t "【zerotier】" "启动成功 $zt_ver 内存:$mem"
    zt_restart o
  else
    logger -t "【zerotier】" "启动失败，10秒后重试"
    sleep 10
    zt_restart x
  fi

  # 在线检测
  count=0
  while [ $count -lt 5 ]; do
    ztstatus=$("$PROGCLI" info 2>/dev/null | awk '{print $5}')
    if [ "$ztstatus" = "ONLINE" ]; then
      ztid=$("$PROGCLI" info | awk '{print $3}')
      nvram set zerotierdev_id="$ztid"
      nvram set zerotier_status="ONLINE 在线"
      break
    elif [ "$ztstatus" = "OFFLINE" ]; then
      sleep 2
    fi
    count=$((count + 1))
  done

  if [ "$ztstatus" != "ONLINE" ]; then
    nvram set zerotier_status="OFFLINE 离线"
  fi

  zt_keep
}

# 守护进程
zt_keep() {
  logger -t "【zerotier】" "守护已启动"
  sed -i '/【zerotier】/d' /tmp/script/_opt_script_check 2>/dev/null
  zt0=$(ifconfig | grep -m1 '^zt' | awk '{print $1}')
  cat >> /tmp/script/_opt_script_check <<EOF
[ -z "\$(pidof zerotier-one)" ] && logger -t "进程守护" "zerotier 掉线" && $scriptfilepath start &
[ -n "$zt0" ] && [ -z "\$(iptables -L -n | grep -w "$zt0")" ] && logger -t "进程守护" "防火墙失效" && $scriptfilepath start &
EOF
}

# 杀进程
kill_z() {
  killall zerotier-one 2>/dev/null
  pid=$(pidof zerotier-one)
  [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
}

# 停止
stop_zero() {
  logger -t "【zerotier】" "正在关闭"
  sed -i '/【zerotier】/d' /tmp/script/_opt_script_check 2>/dev/null
  del_rules
  zero_route del
  kill_z
  logger -t "【zerotier】" "已关闭"
}

# 获取版本
get_zttag() {
  tag=""
  if command -v curl >/dev/null; then
    tag=$(curl -ksL --max-time 5 --user-agent "$user_agent" https://api.github.com/repos/lmq8267/ZeroTierOne/releases/latest | grep tag_name | cut -d'"' -f4)
  else
    tag=$(wget -q --no-check-certificate -T 5 --user-agent "$user_agent" -O - https://api.github.com/repos/lmq8267/ZeroTierOne/releases/latest | grep tag_name | cut -d'"' -f4)
  fi
  [ -z "$tag" ] && tag="1.16.0"
  nvram set zerotier_ver_n="$tag"

  if [ -x "$PROG" ]; then
    zt_ver=$("$PROG" -version 2>/dev/null | head -n1)
    nvram set zerotier_ver="$zt_ver"
  fi
}

# 下载
dowload_zero() {
  tag="$1"
  logger -t "【zerotier】" "开始下载 $tag"
  for proxy in $github_proxys; do
    url="${proxy}https://github.com/lmq8267/ZeroTierOne/releases/download/${tag}/zerotier-one"
    if curl -Lko "$PROG" "$url" || wget --no-check-certificate -O "$PROG" "$url"; then
      chmod +x "$PROG"
      logger -t "【zerotier】" "下载成功"
      break
    else
      logger -t "【zerotier】" "下载失败，尝试CDN"
      curl -Lkso "$PROG" "https://fastly.jsdelivr.net/gh/lmq8267/ZeroTierOne@master/install/${tag}/zerotier-one"
      chmod +x "$PROG"
      break
    fi
  done
}

# 更新
update_zero() {
  get_zttag
  [ -z "$tag" ] && logger -t "【zerotier】" "获取版本失败" && exit 1
  zt_ver=$("$PROG" -version 2>/dev/null | head -n1)
  if [ "$tag" != "$zt_ver" ]; then
    logger -t "【zerotier】" "更新: $zt_ver -> $tag"
    dowload_zero "$tag"
  else
    logger -t "【zerotier】" "已是最新"
  fi
}

# 主启动
start_zero() {
  zt_enable=$(nvram get zerotier_enable)
  [ "$zt_enable" != "1" ] && exit 0
  logger -t "【zerotier】" "启动中"

  # 软链接 cli idtool
  ln -sf "$PROG" "$PROGCLI"
  ln -sf "$PROG" "$PROGIDT"
  chmod +x "$PROG" "$PROGCLI" "$PROGIDT" 2>/dev/null

  if [ ! -x "$PROG" ]; then
    logger -t "【zerotier】" "程序不存在，开始下载"
    get_zttag
    dowload_zero "$tag"
  fi

  kill_z
  start_instance
}

# 入口
case "$1" in
  start) start_zero & ;;
  stop) stop_zero ;;
  update) update_zero & ;;
  *) echo "Usage: $0 {start|stop|update}" ;;
esac
