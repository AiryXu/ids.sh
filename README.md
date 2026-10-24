# ids.sh

> 一台主机，一条命令，一份可读的取证报告。
> 只读取证，不改系统、不联网、不重启、不杀进程 —— 跑在产线上也安心。

作者：Airy Xu
许可：BSD 3-Clause
版本：v1.5.3-open


## 一句话简介

ids.sh 是一个零依赖倾向的 Linux 单机入侵检测脚本。它把账号与提权面、
SSH 密钥逐条认领、反弹 shell、异常监听端口、持久化（cron / rc.local / 服务管理器）、
SUID/SGID、临时文件、共享内存、WebShell、登录审计、强制访问控制和内核崩溃信号
全部扫一遍，证据落盘，红绿分明，退出码可以直接喂给 CI 或告警平台。


## 支持矩阵

  类别        支持情况
  ---------------------------------------------------------
  RHEL 系     RHEL / CentOS 5-9、Rocky、Alma、Oracle Linux、
              Anolis 龙蜥、TencentOS、Amazon Linux
  Debian 系   Ubuntu 12-04-24-04、Debian 7+、Kali、Proxmox VE、Mint
  国产系统     统信 UOS、麒麟 V10/V15、中科方德、openEuler 欧拉
  云厂商镜像   阿里云 Linux、腾讯云 TencentOS、AWS Linux、GCE、Azure、OCI
               （自动识别 guest agent，不误报）
  轻量/容器    Alpine（musl + BusyBox + OpenRC）、ubi-minimal、
               distroless、Docker、k8s 容器、WSL1/2、OpenWrt
  init 系统    systemd、SysVinit、Upstart、OpenRC、runit、busybox-init
  架构         x86_64、aarch64、armhf、loongarch64、riscv64

没有 procps-ng、ss、ipcs、last、find 也能跑。缺什么降级什么，
报告里会明确标注「该项降级运行」，绝不会把「没查到」当成「没有」。


## 安装与运行

  方式一：从发布页下载（推荐，带签名）

    curl -fsSL https://airy.ltd/php_cve_fix/ids.sh -o /root/ids.sh
    curl -fsSL https://airy.ltd/php_cve_fix/ids.sh.minisig -o /root/ids.sh.minisig
    minisign -Vm /root/ids.sh -P "$(cat /root/minisign.pub)"
    chmod +x /root/ids.sh
    bash /root/ids.sh --version

  方式二：一行跑完就删（不落盘）

    curl -fsSL https://airy.ltd/php_cve_fix/ids.sh | sudo bash -s -- --fast

  常用姿势

    bash /root/ids.sh                 # 完整检查
    bash /root/ids.sh --fast          # 只跑高危项（跳板机、容器友好）
    WEB_ROOT=/data/www bash /root/ids.sh            # 加扫 WebShell
    IDS_WL=$HOME/.ids-whitelist bash /root/ids.sh   # 指定跳板白名单
    bash /root/ids.sh --json          # 机器可读输出
    bash /root/ids.sh --update        # 拉取 + 验签后原地升级
    bash /root/ids.sh --update-key    # 显示内置发布公钥，核对有没有被掉包
    bash /root/ids.sh whitelist add 1.2.3.4
    bash /root/ids.sh whitelist add SHA256:xxxxxxxx

报告落在 /root/ids-<主机名>-<时间戳>/，并额外打包一份 /root/ids-<主机名>.tgz。


## 退出码

  0   全绿，无 CRIT 也无 WARN（升级成功也走 0）
  1   有 WARN（需人工过一眼，不等于入侵证据）
  2   有 CRIT，或 --update 验签失败
  3   参数错误，或依赖缺失到无法安全执行

    bash /root/ids.sh --fast
    echo "exit=$?"   # 接进 CI、监控、定时告警都很顺


## 白名单

文件：~/.ids-whitelist，一行一条，# 开头是注释。

  1.2.3.4                              # 放行这个跳板 IP
  SHA256:JC8gnE2WH8pa8tca8FfYwn5GbOh54crs6X0iMa2CPB4   # 放行这枚密钥
  /root/smartping/bin/smartping        # 按镜像路径放行（inode 同源判定优先）

命中白名单后，登录记录和进程扫描都会静音，不再刷 WARN。


## 签名与升级（信任模型）

发布物用 minisign（ed25519）签名：

  ids.sh          脚本本体
  ids.sh.minisig  签名
  minisign.pub    发布公钥（Base64，写死在脚本顶部，也可由 IDS_MINISIGN_PUB 覆盖）

信任链是这样的：

  你手里的 minisign.pub（带外固化，比如随系统镜像下发）
        │
        │   就算 airy.ltd 的 DNS 被劫持、HTTPS 证书被恶意签发
        │   攻击者没有私钥 minisign.sec，也签不出能通过的包
        ▼
  curl 拉 ids.sh + ids.sh.minisig
        └──► minisign -Vm ids.sh -P <公钥>
                  │ 通过 → 覆盖 /root/ids.sh
                  │ 失败 → 拒绝写入，退出 2

--update 只做升级、不跑检测，并且拒绝版本回退（防降级攻击）。
机器上没装 minisign 时自动降级到 SHA256，此时只能防传输损坏，
防不住 DNS/CA 劫持 —— 脚本会明确提示你，别当真当成安全升级。

    bash /root/ids.sh --update-key      # 打印内置公钥，和发布页公布的比对一致才可信


## 自己发版

  # 1) 生成密钥对（只做一次，.sec 离线保存，别进 webroot）
  minisign -G -p minisign.pub -s minisign.sec -c 'ids.sh release key'

  # 2) 把公钥填进脚本顶部 IDS_BUILTIN_PUB，或部署时设环境变量
  export IDS_MINISIGN_PUB="$(head -1 minisign.pub)"

  # 3) 每次发布都签名
  minisign -S -s minisign.sec -m ids.sh -t "v1.5.3-open" -x ids.sh.minisig

  # 4) 连同公钥、签名一起发布
  cp ids.sh ids.sh.minisig minisign.pub 到你的发布目录

  # 5) 本地自证一把
  minisign -Vm ids.sh -P "$(head -1 minisign.pub)"
  # 期望看到：Signature and comment signature verified. Trusted comment: v1.5.3-open


## 设计原则

  * 只读取证    —— 只读 /proc、/etc、/var/log 和文件元数据，不写不改不删
  * 默认不联网  —— --update 是唯一会联网的子命令
  * 不杀进程、不重启 —— 取证第一铁律，内存里的东西留着才有价值
  * POSIX 优先  —— #!/usr/bin/env sh，dash / busybox sh / bash 都能跑
  * 假阳性可解释 —— 每条规则都有降级路径和白名单出口，WARN 不等于入侵


## 许可

BSD 3-Clause，版权所有 (c) 2026 Airy Xu。
可以在遵守许可证条款（保留版权声明与免责声明）的前提下自由使用、复制、
修改、再分发，含商业用途。许可证全文见同目录的 LICENSE 文件。

本脚本按「原样」提供，不附带任何明示或暗示的担保。作者不对因使用本脚本
所产生的任何损失或误判承担责任；安全结论请以多源交叉验证为准。


## 路线图

  [ ] ids-watch.sh 基线模式：首次快照白名单，之后 cron 小时级 diff，只报新增
  [ ] --update 支持 cosign / Sigstore 双签
  [ ] JSON 报告追加 rule_id，方便 SIEM 去重
