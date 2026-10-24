#!/usr/bin/env sh
# ==================================================================
# ids.sh  v1.5.2  —— Linux / 容器 / 轻量系统  单机入侵检测（只读取证版）
#
# 作者  : Airy Xu
# 邮箱  : airy@airy.cn
# 站点  : https://airy.ltd
# 许可  : BSD 3-Clause  https://opensource.org/licenses/BSD-3-Clause
# 版权  : (c) 2026 Airy Xu. 保留所有权利。
#
# 兼容: RHEL/CentOS 5-9 · Rocky/Alma/Anolis · Ubuntu 12-24 · Debian 7+ ·
#       统信UOS · 麒麟 · openEuler · Amazon Linux · Alpine/musl ·
#       容器(distroless,ubi) · WSL1/2 · OpenWrt · SysV / Upstart / OpenRC / runit
#
# 原则: 不联网 · 不改系统 · 不重启 · 不杀进程 · 不删文件 · 不依赖 GNU 扩展
#
# 用法:
#   bash /root/ids.sh                 # 完整检查
#   bash /root/ids.sh --fast          # 只跑高危项
#   WEB_ROOT=/data/www bash /root/ids.sh
#   bash /root/ids.sh --json
#   bash /root/ids.sh --version
# ==================================================================

IDS_VERSION="1.5.2"
IDS_AUTHOR="Airy Xu"
IDS_CONTACT="airy@airy.cn"
IDS_LICENSE="BSD 3-Clause"

show_version(){
  printf '\033[1;36mids.sh\033[0m v%s
  作者  : %s <%s>
  站点  : https://airy.ltd
  许可  : %s
  兼容  : RHEL/CentOS/Rocky/Alma/Anolis · Ubuntu/Debian · 统信/麒麟/openEuler
           · Amazon Linux · Alpine/musl · 容器(distroless,ubi) · WSL · OpenWrt
  原则  : 只读取证 / 不改系统 / 不联网 / 不重启 / 不杀进程
' "$IDS_VERSION" "$IDS_AUTHOR" "$IDS_CONTACT" "$IDS_LICENSE"
  exit 0
}
case " $*" in *" --version"*|*" -v "*) show_version ;; esac

set +e
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# ---------- 能力探测 ----------
H="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo unknown)"
TS="$(date +%F_%H%M%S 2>/dev/null || echo manual)"
OUT="/root/ids-$H-$TS"; mkdir -p "$OUT"
: > "$OUT/crit"; : > "$OUT/warn"

have(){ command -v "$1" >/dev/null 2>&1; }
if have ps; then
  if ps -p 1 -o pid= >/dev/null 2>&1; then PS_LVL=2
  elif ps aux >/dev/null 2>&1; then PS_LVL=1
  else PS_LVL=0; fi
else PS_LVL=0; fi
have journalctl && JCTL=1 || JCTL=0
have systemctl  && SYSCTL=1 || SYSCTL=0
have ss         && SS=1 || SS=0
have ipcs       && IPCS=1 || IPCS=0
have last       && LAST=1 || LAST=0
have stat       && STAT=1 || STAT=0
have readlink   && RLNK=1 || RLNK=0
have awk        && AWK=1 || AWK=0
if have grep && echo a | grep -qE 'a' 2>/dev/null; then GREP_OK=1; else GREP_OK=0; fi

# ---------- init / 发行版 / 环境 ----------
INIT="unknown"
if [ -d /run/systemd/system ] || (have systemctl && systemctl --version >/dev/null 2>&1); then
  INIT="systemd"
elif [ -x /sbin/initctl ] && initctl list >/dev/null 2>&1 2>&1; then
  INIT="upstart"
elif [ -x /sbin/rc-service ] || [ -x /usr/bin/rc-status ]; then
  INIT="openrc"
elif [ -x /usr/bin/sv ] || [ -d /etc/runit ]; then
  INIT="runit"
elif [ -f /etc/inittab ]; then
  INIT="sysv"
elif grep -q 'busybox' /proc/1/comm 2>/dev/null; then
  INIT="busybox-init"
fi
[ "$INIT" = "unknown" ] && [ -n "$(cat /proc/1/comm 2>/dev/null)" ] && INIT="$(cat /proc/1/comm):init"

DISTRO="unknown"; DISTRO_FAM="unknown"
if [ -f /etc/os-release ]; then
  DISTRO="$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-${NAME:-unknown}}")"
  _id="$(. /etc/os-release 2>/dev/null; echo "$ID" | tr A-Z a-z)"
  case "$_id" in
    centos|rhel|rocky|almalinux|alma|ol|oraclelinux|anolis|anolis_os|tencentos|tlinux|amzn|amazon) DISTRO_FAM="rhel" ;;
    ubuntu|debian|kali|linuxmint|proxmox|pve) DISTRO_FAM="debian" ;;
    uos|uniontechos|kylin|kylinos|neokylin|openuler|openeuler|euler) DISTRO_FAM="china" ;;
    alpine) DISTRO_FAM="alpine" ;;
    *) DISTRO_FAM="other" ;;
  esac
elif [ -f /etc/redhat-release ]; then DISTRO="$(cat /etc/redhat-release)"; DISTRO_FAM="rhel"
elif [ -f /etc/debian_version ]; then DISTRO="Debian $(cat /etc/debian_version 2>/dev/null)"; DISTRO_FAM="debian"
elif [ -f /etc/alpine-release ]; then DISTRO="Alpine $(cat /etc/alpine-release 2>/dev/null)"; DISTRO_FAM="alpine"
fi

CT="baremetal"
grep -qE 'docker|containerd|lxc' /proc/1/cgroup 2>/dev/null && CT="container"
[ -f /.dockerenv ] && CT="container"
grep -qiE 'kvm|qemu|google|bhyve|VBOX|vmware|hyper-v|ami:' /sys/class/dmi/id/product_name 2>/dev/null && CT="vm"
grep -qiE 'microsoft|WSL' /proc/version 2>/dev/null && CT="wsl"
grep -qE 'pve|Proxmox' /etc/hostname /proc/1/comm 2>/dev/null && CT="proxmox-lxc"

case "$DISTRO_FAM" in
  rhel)   AUTH_LOG="/var/log/secure"; CRON_LOG="/var/log/cron"; SYSLOG_LOG="/var/log/messages" ;;
  debian) AUTH_LOG="/var/log/auth.log"; CRON_LOG="/var/log/syslog"; SYSLOG_LOG="/var/log/syslog" ;;
  alpine) AUTH_LOG="/var/log/messages"; CRON_LOG="/var/log/messages"; SYSLOG_LOG="/var/log/messages" ;;
  *)      AUTH_LOG=""; CRON_LOG=""; SYSLOG_LOG="" ;;
esac
[ -n "$AUTH_LOG" ] && [ ! -f "$AUTH_LOG" ] && AUTH_LOG=""
[ -n "$CRON_LOG" ] && [ ! -f "$CRON_LOG" ] && CRON_LOG=""

# ---------- 原语 ----------
red(){  printf '\033[1;31m[CRIT] %s\033[0m\n' "$1"; printf '%s\n' "$1" >> "$OUT/crit"; }
yel(){  printf '\033[1;33m[WARN] %s\033[0m\n' "$1"; printf '%s\n' "$1" >> "$OUT/warn"; }
grn(){  printf '\033[1;32m[OK]   %s\033[0m\n' "$1"; }
hdr(){  printf '\n\033[1;36m##### %s #####\033[0m\n' "$1"; }

cnt(){
  local n
  n="$(wc -l < "$1" 2>/dev/null | tr -d ' \t' )"
  case "${n:-0}" in *[!0-9]*) echo 0;; *) echo "${n:-0}";; esac
}
safe_c(){
  if [ "$GREP_OK" = 1 ]; then
    n="$(grep -c '^ssh-' "$1" 2>/dev/null | tr -d ' \t' | tail -1)"
  else
    n="$(while IFS= read -r l; do case "$l" in ssh-*) echo x;; esac; done < "$1" | wc -l | tr -d ' \t')"
  fi
  case "${n:-0}" in *[!0-9]*) echo 0;; *) echo "$n";; esac
}
samefile(){
  [ "$RLNK" != 1 ] && [ "$STAT" != 1 ] && return 1
  [ -z "$1" ] || [ -z "$2" ] && return 1
  [ -e "$1" ] && [ -e "$2" ] || return 1
  a="$(readlink -f "$1" 2>/dev/null || echo "$1")"
  b="$(readlink -f "$2" 2>/dev/null || echo "$2")"
  [ "$a" = "$b" ] && return 0
  if [ "$STAT" = 1 ]; then
    ia="$(stat -c '%d:%i' "$a" 2>/dev/null)"; ib="$(stat -c '%d:%i' "$b" 2>/dev/null)"
    [ -n "$ia" ] && [ "$ia" = "$ib" ] && return 0
  fi
  return 1
}
pid_cmdline(){ tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | sed 's/ *$//'; }
pid_comm(){    cat "/proc/$1/comm" 2>/dev/null; }
pid_exe(){     readlink "/proc/$1/exe" 2>/dev/null; }

# v1.5.2：运维二进制白名单（这些即使用 root/nobody 跑，也绝不判 CRIT）
is_blessed(){
  case "$1" in
    /usr/bin/curl|/usr/bin/wget|/usr/bin/smartping|/root/smartping/*|/sbin/dhclient|/usr/sbin/dhclient|\
    /usr/bin/cloud-init*|/usr/libexec/cloud-init*|/usr/sbin/cron*|/usr/sbin/sshd|/usr/lib/systemd/*|\
    /usr/bin/letsencrypt*|/opt/appnode/*|/var/opt/appnode/*|/usr/bin/php*|/usr/sbin/raid-check|\
    /usr/lib64/sa/*|/usr/bin/perl|/usr/bin/python*|/usr/bin/ruby|/usr/sbin/chkrootkit|/usr/bin/rkhunter|\
    /bin/tar|/usr/bin/zip|/usr/bin/gzip|/usr/bin/gpg*|/usr/bin/openssl|/usr/bin/ssh|/usr/bin/scp) return 0 ;;
  esac
  return 1
}

printf '\033[1;36m== ids.sh v%s · %s ==\033[0m\n' "$IDS_VERSION" "$IDS_AUTHOR"
printf '    系统: %s | %s | 内核 %s | arch %s | init=%s | 环境=%s\n' \
  "$DISTRO" "$(uname -o 2>/dev/null || echo Linux)" "$(uname -r)" "$(uname -m)" "$INIT" "$CT"
[ "$PS_LVL" = 0 ] && yel "本机无 procps-ng，进程扫描改走 /proc 直读（Alpine/容器正常）"

# ==================================================================
hdr "0. 基础信息"
printf '    主机: %s   时间: %s   已开机: ' "$H" "$TS"; uptime -p 2>/dev/null || uptime
case "$INIT" in
  systemd) systemctl is-active crond 2>/dev/null || systemctl is-active cron 2>/dev/null || echo "crond 状态未知" ;;
  openrc)  rc-status -s 2>/dev/null | grep -E 'cron|syslog' | sed 's/^/    /' || echo "rc-status 不可用" ;;
  upstart) initctl list 2>/dev/null | grep -E 'cron|rsyslog' | sed 's/^/    /' || echo "initctl 不可用" ;;
  *)       crontab -l >/dev/null 2>&1 && echo "crond: 运行中(无法精确确认)" ;;
esac
if grep -hE 'init 6|/sbin/reboot|shutdown -r' /etc/crontab /etc/cron.d/* 2>/dev/null | grep -qvE '^#'; then
  yel "⚠ 本机仍配了每日重启，内存型驻留活不过 24h → 先停用，观察 72h"
else
  grn "未发现每日重启类 cron"
fi

# ==================================================================
hdr "1. 账号 / 提权面"
awk -F: '$3==0&&$1!="root"{printf "    [CRIT] 额外 UID=0 账号: %s\n",$1}' /etc/passwd >> "$OUT/crit"
if have sudo; then
  grep -rE 'NOPASSWD|!authenticate' /etc/sudoers /etc/sudoers.d/ 2>/dev/null | sed 's/^/    [sudo] /'
else
  yel "未安装 sudo（容器/最小化系统常见，属正常）"
fi
awk -F: '($7!~/nologin|false/)&&($3>=1000||$3==0){print "    "$1,$3,$7}' /etc/passwd
getent passwd 2>/dev/null | awk -F: '$3>=1000' | cut -d: -f1 | while read -r u; do
  case "$(passwd -S "$u" 2>/dev/null | awk '{print $2}')" in LK|locked)
    printf '    [账号已锁] %s\n' "$u" >> "$OUT/warn" ;; esac
done
[ -s "$OUT/crit" ] || grn "无额外 root 账号"

# ==================================================================
hdr "2. SSH 密钥逐条认领"
for d in /root /home/*; do
  [ -d "$d/.ssh" ] || continue
  f="$d/.ssh/authorized_keys"
  printf '\n    \033[1m%s\033[0m\n' "$d/.ssh"
  ls -l --time-style=+%F\ %T "$d/.ssh" 2>/dev/null | sed 's/^/      /'
  if [ ! -f "$f" ]; then yel "$f 不存在（账号 $(basename "$d") 家目录在，但无 authorized_keys）"; continue; fi
  n=$(safe_c "$f")
  if [ "$n" -gt 1 ]; then
    red "$f 共 $n 条公钥，逐条认领："
    while IFS= read -r k; do
      [ -z "$k" ] && continue
      if have ssh-keygen; then
        fp=$(ssh-keygen -lf <(printf '%s\n' "$k") 2>/dev/null | awk '{print $1" | "$2" | "$3}')
        printf '      %s\n' "${fp:-${k:0:64}…}"
      else
        printf '      %s…（无 ssh-keygen，无法解析指纹）\n' "${k:0:64}"
      fi
    done < "$f"
  else
    if have ssh-keygen; then fp=$(ssh-keygen -lf "$f" 2>/dev/null | awk '{print $1" | "$2" | "$3}')
    else fp=""; fi
    grn "$f 仅 1 条: ${fp:-（无 ssh-keygen）}"
  fi
  u="$(basename "$d")"
  getent passwd "$u" >/dev/null 2>&1 || yel "孤儿 ssh 目录：账号 $u 已不存在，但 $d/.ssh 还在"
done

hdr "2b. 成功直登 root 的外网 IP（IPv4 only，排除 ::1 / 127. / 本机自连）"
> "$OUT/root-ip.txt"
if [ "$LAST" = 1 ]; then
  last -w -F 2>/dev/null | \
    awk '/root +pts|root +tty/{
      ip=$(NF-2);
      if (ip ~ /^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$/ && ip !~ /^(127\.|0\.0\.0\.0)/) print ip
    }' | sort | uniq -c | sort -nr | head -15 | tee "$OUT/root-ip.txt" | sed 's/^/    /'
else
  yel "last 不可用，改从 $AUTH_LOG 提取 Accepted 记录"
  if [ -n "$AUTH_LOG" ] && [ -f "$AUTH_LOG" ]; then
    grep -E 'Accepted (publickey|password|keyboard-interactive) for root' "$AUTH_LOG" 2>/dev/null | \
      grep -oE 'from [0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | awk '{print $2}' | \
      sort | uniq -c | sort -nr | head -15 | tee "$OUT/root-ip.txt" | sed 's/^/    /'
  fi
fi
if [ -s "$OUT/root-ip.txt" ]; then
  yel "上面这些外网 IP 成功直登过 root —— 逐条核对是否你的跳板"
else
  grn "近期无外网 IP 直登 root 记录（或本机无登录审计日志）"
fi

# ==================================================================
# v1.5.2：§3 与 §3b 各自独立文件，命中直接落盘，不经 red()，斩断自污染
hdr "3. 反弹 shell / 派生进程（/proc 直读，BusyBox 安全）"
: > "$OUT/proc-crit.txt"
SELF_PID="$$"
for p in /proc/[0-9]*; do
  pid="${p#/proc/}"; [ -d "$p" ] || continue
  [ "$pid" = "$SELF_PID" ] && continue
  case "$p" in */$$ | */$PPID | */$BASHPID) continue ;; esac
  exe=$(pid_exe "$pid"); cmd=$(pid_cmdline "$pid"); comm=$(pid_comm "$pid")
  case "$cmd" in *"ids.sh"*|*"ir-check"*|*"grep -E"*|*"grep -e "*|*"grep -- "*|*"grep -F"*) continue ;; esac
  [ -z "$exe" ] && continue
  argv0="$(echo "$cmd" | awk '{print $1}')"
  samefile "$exe" "$argv0" && continue
  is_blessed "$exe" && continue
  echo "$cmd" | grep -qE '(/dev/(tcp|udp)|nc .*-e|socat.*(exec|system|pty)|bash -i|sh -i|pty\.spawn|TCPSocket|mkfifo)' || continue
  printf '    pid=%s comm=%s exe=%s  cmd=%s\n' "$pid" "$comm" "$exe" "$cmd" >> "$OUT/proc-crit.txt"
done
if [ -s "$OUT/proc-crit.txt" ]; then
  printf '\033[1;31m[CRIT] 疑似反弹/派生 shell（已另存 %s）:\033[0m\n' "$OUT/proc-crit.txt"
  sed 's/^/    /' "$OUT/proc-crit.txt" >> "$OUT/crit"
else
  grn "未发现反弹 shell 特征"
fi

hdr "3b. 临时区陌生二进制（同源 argv 放行 + 运维白名单）"
: > "$OUT/tmp-crit.txt"
for p in /proc/[0-9]*; do
  pid="${p#/proc/}"; [ -d "$p" ] || continue
  exe=$(pid_exe "$pid"); [ -z "$exe" ] && continue
  case "$exe" in
    /usr/*|/bin/*|/sbin/*|/lib*|/etc/*|/proc/*) continue ;;
    /root/smartping/*|/opt/appnode/*|/var/opt/appnode/*|/data/*|/alidata/*) continue ;;
  esac
  argv0="$(cat "$p/cmdline" 2>/dev/null | tr '\0' ' ' | awk '{print $1}')"
  samefile "$exe" "$argv0" && continue
  is_blessed "$exe" && continue
  case "$exe" in
    */tmp/*|*/var/tmp/*|*/dev/shm/*|*/run/shm/*)
      printf '    pid=%s comm=%s exe=%s\n' "$pid" "$(pid_comm "$pid")" "$exe" >> "$OUT/tmp-crit.txt" ;;
  esac
done
if [ -s "$OUT/tmp-crit.txt" ]; then
  printf '\033[1;31m[CRIT] 临时区落地的陌生进程镜像（已另存 %s）:\033[0m\n' "$OUT/tmp-crit.txt"
  sed 's/^/    /' "$OUT/tmp-crit.txt" >> "$OUT/crit"
else
  grn "无临时区落地的陌生进程镜像"
fi

# ==================================================================
hdr "4. 网络：外连 TOP + 非标准监听"
if [ "$SS" = 1 ]; then
  ss -tnp state established 2>/dev/null | \
    awk 'NR>1&&$5!~/127\.|::1/{split($5,a,":");print a[1]}' | sort | uniq -c | sort -nr | head -12 | \
    while read -r c ip; do printf '    [外连 %3s] %s\n' "$c" "$ip"; done
  ss -lntp 2>/dev/null | awk 'NR>1&&$4~/0\.0\.0\.0/{print $4,$6}' | \
    grep -vE ':(22|80|443|53|25|3306|6379|9000|8080|8443)$' | sed 's/^/    [非标监听] /' | tee "$OUT/listen.txt"
else
  yel "无 ss 命令，改读 /proc/net/tcp（只列监听，不统计外连）"
  awk 'NR>1 && $4=="01" && $2!~/00000000:0000/{
    ip=sprintf("%d.%d.%d.%d", strtonum("0x"substr($2,7,2)), strtonum("0x"substr($2,5,2)), strtonum("0x"substr($2,3,2)), strtonum("0x"substr($2,1,2)))
    printf "    [监听] %s:%d\n", ip, strtonum("0x"substr($2,10,4))
  }' /proc/net/tcp 2>/dev/null | head -20 | tee "$OUT/listen.txt"
fi
[ -s "$OUT/listen.txt" ] && yel "存在非标准监听端口，确认是不是你开的" || grn "无异常监听端口"

# ==================================================================
hdr "5. 持久化：cron / rc.local / 服务管理器"
> "$OUT/cron.raw"
grep -hE '^[^*#[:space:]]' /etc/crontab /etc/cron.d/* 2>/dev/null > "$OUT/cron.raw"
sed 's/^/    [cron] /' "$OUT/cron.raw"
grep -E '\.(configrc|config)|/tmp/|curl |wget |nc |socat |base64 -d|passwd=|password=|enc-passwd=|init 6|reboot|shutdown' "$OUT/cron.raw" | \
  while IFS= read -r line; do
    tgt=$(printf '%s' "$line" | grep -oE '(/[a-z0-9_./-]+)' | head -1)
    if [ -n "$tgt" ] && [ -e "$tgt" ]; then
      printf '    [!CRIT] 可疑命令指向实文件: %s\n' "$line" >> "$OUT/crit"
    else
      printf '    [僵尸cron] 目标已不存在，可清理: %s\n' "$line" >> "$OUT/warn"
    fi
  done
for u in root $(ls /home 2>/dev/null); do
  crontab -l -u "$u" 2>/dev/null | grep -vE '^#|^$' | sed "s/^/    [cron $u] /"
done

if [ -x /etc/rc.d/rc.local ] || [ -x /etc/rc.local ]; then
  if grep -qvE '^[[:space:]]*#|^[[:space:]]*$' /etc/rc.d/rc.local 2>/dev/null; then
    yel "/etc/rc.local 含有效指令（请核对是否为你自己的启动项）:"
    grep -vE '^[[:space:]]*#|^[[:space:]]*$' /etc/rc.d/rc.local 2>/dev/null | sed 's/^/    /'
  fi
fi

# v1.5.2：云镜像 / 出厂服务全部沉底，只留真正需要人眼的
case "$INIT" in
  systemd)
    systemctl list-unit-files --type=service 2>/dev/null | grep -E 'enabled' | \
      grep -vE '^(sshd|network|NetworkManager|rsyslog|auditd|firewalld|crond|systemd-|rhel|centos|appnode|nginx|php|mysql|mariadb|smartping|google-|qemu|iptables|chronyd|postfix|dbus|irqbalance|kdump|lvm2|microcode|cloud-|abrt|fail2ban|acpid|autovt|blk-|dhclient|raid-check|sa2|letsencrypt|agent|dblimiter|smartd|containerd|docker|kubelet|iscsi|initramfs-|dmraid|atd|getty|rpcbind|rpc-statd|tuned|irqbalance|cpupower|numad|libvirtd|virtlogd|virtlockd)-' | \
      sed 's/^/    [自启?] /' | head -20 ;;
  openrc)
    rc-update show -v 2>/dev/null | grep -E '\[ *on *\]' | \
      grep -vE '^(sshd|nginx|php|mysql|mariadb|smartping|appnode|syslog|network|netmount|chronyd|postfix|docker|containerd)' | \
      sed 's/^/    [自启?] /' | head -20 ;;
  upstart)
    initctl list 2>/dev/null | grep -vE 'stop/waiting' | \
      grep -vE 'sshd|nginx|mysql|appnode|smartping|rsyslog|cron|cloud' | sed 's/^/    [upstart] /' | head -20 ;;
  runit)   ls /etc/service/ 2>/dev/null | sed 's/^/    [runit 服务] /' | head -20 ;;
  busybox-init|sysv)
    ls /etc/rc*.d/ 2>/dev/null | sed 's/^/    [SysV 启动链] /' | head -10
    runlevel 2>/dev/null | sed 's/^/    [runlevel] /' ;;
esac

hdr "5b. SUID / SGID（系统路径 / appnode / 国产面板 / 站点目录都放过）"
CHINA_PATH='^/(usr/(bin|sbin|lib|lib64|libexec)|bin|sbin|etc/appnode|var/opt/appnode|opt/appnode|data|alidata|usr/local)'
find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | \
  grep -vE "$CHINA_PATH" | \
  while IFS= read -r f; do printf '    [SUID] %s\n' "$f"; done | tee "$OUT/suid.txt"
[ -s "$OUT/suid.txt" ] && red "非系统路径 SUID/SGID（用 stat 看 mtime）" || grn "无异常 SUID/SGID"

# v1.5.2：把 appnode-phpXX 整段、wp-includes、业务空目录一起排掉
find / -xdev -perm -o+w -type d 2>/dev/null | \
  grep -vE '^/(tmp|var/tmp|dev/shm|run|var/cache|var/spool)(/|$)' | \
  grep -vE 'WordPress|wp-content|wp-includes|/uploads|/cache$|wp-admin|/wwwroot|/htdocs|/voc$|/kk$|appnode-php|/tmp$' | \
  head -20 | while IFS= read -r d; do printf '    [全局可写?] %s\n' "$d"; done

# ==================================================================
hdr "6. 临时文件 / 共享内存"
find /tmp /var/tmp /dev/shm /run/shm -type f \( -perm -111 -o -name '*.php' -o -name '*.sh' -o -name '*.so' \) 2>/dev/null | \
  grep -vE 'php-fpm\.sock|systemd-|ids\.sh|ir-check|smartping' | \
  while IFS= read -r f; do printf '    %s\n' "$f"; done | tee "$OUT/tmpf.txt"
[ -s "$OUT/tmpf.txt" ] && red "临时目录有可执行物（先 cp 出来，别删）" || grn "临时目录无异常可执行物"
if [ "$IPCS" = 1 ]; then
  ipcs -m 2>/dev/null | awk 'NR>3 && NF>5 && $2!="shmid" && $6=="666"' | grep -qE '^[0-9]'
  [ $? = 0 ] && red "存在 666 共享内存段（任意用户可读）" || grn "无 666 共享内存段"
else
  yel "无 ipcs，改读 /proc/sysvipc/shm"
  awk 'NR>1 && $5!~/^0/ && $4~/666/{printf "    [shm 666] id=%s key=%s perms=%s bytes=%s nattch=%s\n",$1,$2,$4,$5,$6}' /proc/sysvipc/shm 2>/dev/null | tee -a "$OUT/tmpf.txt"
  [ -s "$OUT/tmpf.txt" ] || grn "无 666 共享内存段"
fi

# ==================================================================
hdr "7. WebShell 扫描（指定 WEB_ROOT 才跑）"
WEB="${WEB_ROOT:-}"
if [ -n "$WEB" ] && [ -d "$WEB" ]; then
  yel "扫描根: $WEB"
  if [ "$GREP_OK" = 1 ]; then
    grep -rnE --include='*.php' --line-number \
      '@eval|base64_decode\s*\(|gzinflate\s*\(|gzuncompress\s*\(|shell_exec\s*\(|passthru\s*\(|system\s*\(|assert\s*\(|create_function\s*\(' \
      "$WEB" 2>/dev/null | head -80 | sed 's/^/    /' | tee "$OUT/webshell.txt"
  else
    grep -rnE '@eval|shell_exec|passthru|create_function' "$WEB" 2>/dev/null | head -80 | sed 's/^/    /' | tee "$OUT/webshell.txt"
    yel "本机 grep 不支持扩展正则，已降为字符串匹配，建议装 GNU grep 后重跑"
  fi
  find "$WEB" -name '*.php' -mtime -7 2>/dev/null | \
    grep -iE 'upload|cache|tmp|plugins|themes|admin|wp-includes' | \
    while IFS= read -r f; do printf '    [7天内] %s\n' "$f"; done | tee -a "$OUT/webshell.txt"
  [ -s "$OUT/webshell.txt" ] && yel "命中危险函数/近期新增 php，人工看上下文"
else
  grn "未指定 WEB_ROOT，跳过 WebShell 扫描（例: WEB_ROOT=/data/www bash /root/ids.sh）"
fi

# ==================================================================
hdr "8. 登录证据（按发行版选日志源，指纹级去重 + 剔除本机自连）"
> "$OUT/auth.txt"
_log(){ [ -n "$1" ] && [ -f "$1" ] && grep -E 'Accepted (password|publickey|keyboard-interactive)' "$1" >> "$OUT/auth.txt"; }
_log "$AUTH_LOG"; _log "$SYSLOG_LOG"
if [ "$JCTL" = 1 ] && [ "$INIT" = "systemd" ]; then
  journalctl -u sshd --since="2026-10-17" 2>/dev/null | grep -E 'Accepted' >> "$OUT/auth.txt"
fi
if [ -s "$OUT/auth.txt" ]; then
  yel "最近成功登录（已指纹去重并剔除 ::1 / 127.，核对是否你的跳板）:"
  # v1.5.2：先剥 hostname 与端口做指纹，UseDNS 双记只算一次
  awk '{
    if ($0 ~ /::1/ || $0 ~ /127\.0\.0\.1/) next
    k=$0
    sub(/[a-zA-Z0-9.-]+\.airy\.cn? sshd\[[0-9]+\]: /,"sshd: ",k)
    sub(/ port [0-9]+ /," port X ",k)
    if (!(k in seen)) { seen[k]=1; print }
  }' "$OUT/auth.txt" | tail -15 | sed 's/^/    /'
else
  grn "无登录审计记录（容器/最小化系统常见；非 systemd 机请查 $AUTH_LOG）"
fi
find /etc/ssh /etc/passwd /etc/shadow -mtime -1 2>/dev/null | sed 's/^/    [24h内改动] /'
find /root/.ssh /home/*/.ssh -mmin -600 2>/dev/null | sed 's/^/    [10分钟内动过] /'

hdr "8b. 强制访问控制（SELinux / AppArmor）"
if [ -x /usr/sbin/sestatus ] || [ -x /sbin/sestatus ]; then
  sestatus 2>/dev/null | grep -E 'SELinux status|Current mode|Policy' | sed 's/^/    [SELinux] /'
elif [ -e /sys/fs/selinux/enforce ]; then
  printf '    [SELinux] enforcing=%s（sestatus 未装，读内核接口）\n' "$(cat /sys/fs/selinux/enforce 2>/dev/null)"
fi
if have aa-status; then
  aa-status 2>/dev/null | grep -E 'profiles|enforce|complain' | head -5 | sed 's/^/    [AppArmor] /'
elif [ -d /etc/apparmor.d ]; then
  yel "存在 /etc/apparmor.d 但 aa-status 未装，AppArmor 状态未知"
fi
[ "$DISTRO_FAM" = "china" ] && yel "国产系统 $DISTRO：请额外核对厂商加固策略（麒麟 secGear / 统信安全机制）"

# ==================================================================
hdr "9. 崩溃 / OOM / 异常信号"
if [ "$JCTL" = 1 ] && [ "$INIT" = "systemd" ]; then
  journalctl --since="2026-10-17" 2>/dev/null | \
    grep -Ei 'segfault|SIGSEGV|SIGABRT|exited on signal|Out of memory|traps:|denied' | \
    tail -20 | sed 's/^/    /' | tee "$OUT/kern.txt"
elif [ -f /var/log/kern.log ]; then
  grep -Ei 'segfault|oom|traps:|denied' /var/log/kern.log 2>/dev/null | tail -20 | sed 's/^/    /' | tee "$OUT/kern.txt"
else
  dmesg 2>/dev/null | tail -40 | grep -Ei 'segfault|oom|traps:|denied' | sed 's/^/    /' | tee "$OUT/kern.txt"
fi
[ -s "$OUT/kern.txt" ] && yel "有崩溃/OOM/拒绝信号" || grn "近 7 天无异常信号"
ls -1dt /var/spool/abrt/ccpp-* 2>/dev/null | head -3 | while read -r d; do
  printf '    [abrt] %s  %s\n' "$(basename "$d" | sed 's/^ccpp-//')" \
    "$(grep -m1 '^Executable:' "$d/metadata" 2>/dev/null | cut -d' ' -f2-)"
done

# ==================================================================
hdr "===== 结论 ====="
C=$(cnt "$OUT/crit")
W=$(cnt "$OUT/warn")
B="$(wc -c < "$OUT/crit" 2>/dev/null | tr -d ' \t')"
[ "${B:-0}" = "0" ] && C=0
[ -s "$OUT/crit" ] || C=0
printf '主机     : %s\n系统     : %s (%s, %s)\n脚本     : ids.sh v%s (%s)
报告目录 : %s\nCRIT     : %s\nWARN     : %s\n' \
  "$H" "$DISTRO" "$INIT" "$CT" "$IDS_VERSION" "$IDS_AUTHOR" "$OUT" "$C" "$W"
echo "─────────────────────────────────────────────"
if [ "$C" -gt 0 ]; then
  printf '\033[1;31m  ★ CRIT 非空 → 先隔离公网、保现场、别 reboot、换凭据，再分析取证包\033[0m\n'
elif [ -s "$OUT/crit" ]; then
  printf '\033[1;33m  ★ crit 文件异常（计数归零但内容非空），请人工看: %s\033[0m\n' "$OUT/crit"
else
  printf '\033[1;32m  ★ 本轮无 CRIT 命中\033[0m\n'
fi
if grep -hE 'init 6|/sbin/reboot' /etc/crontab /etc/cron.d/* 2>/dev/null | grep -qE '^[^#]'; then
  printf '  ⚠ 但本机仍有每日重启 → 内存驻留查不到，停掉后观察 72h 再下“干净”结论\n'
fi
printf '  检测能力: ps=%s journalctl=%s ss=%s ipcs=%s last=%s stat=%s\n' \
  "$PS_LVL" "$JCTL" "$SS" "$IPCS" "$LAST" "$STAT"
tar czf "/root/ids-$H.tgz" -C "$(dirname "$OUT")" "$(basename "$OUT")" >/dev/null 2>&1 && echo "已打包: /root/ids-$H.tgz"
if [ "$2" = "--json" ] || [ "$1" = "--json" ]; then
  printf '{"host":"%s","distro":"%s","init":"%s","env":"%s","arch":"%s","tool":"ids.sh","version":"%s","author":"%s","ts":"%s","crit":%s,"warn":%s}\n' \
    "$H" "$DISTRO" "$INIT" "$CT" "$(uname -m)" "$IDS_VERSION" "$IDS_AUTHOR" "$TS" "$C" "$W"
fi
