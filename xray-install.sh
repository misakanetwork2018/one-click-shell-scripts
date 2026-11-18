#!/usr/bin/env bash
#
# xray-install.sh - Xray 一键安装脚本
#
# 功能：
#   - 指定 / 自动解析 Xray 版本
#   - 可选配置 VLESS（含 Reality / TLS）、VMess、Shadowsocks 入站
#   - 可选开启本地 API
#   - 可选生成默认账号并输出分享链接
#   - 支持纯参数（静默）与命令行交互两种模式
#
# 支持系统：Debian / Ubuntu / CentOS / RHEL / Rocky / Alma / Fedora（systemd）
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_ETC="${XRAY_ETC:-/usr/local/etc/xray}"
XRAY_CONFIG="$XRAY_ETC/config.json"
XRAY_LOG="${XRAY_LOG:-/var/log/xray}"
SYSTEMD_UNIT="${SYSTEMD_UNIT:-/etc/systemd/system/xray.service}"
GITHUB_REPO="XTLS/Xray-core"

# 直连 GitHub 失败时依次尝试的加速镜像（仅在未显式指定 --mirror 时启用）
DEFAULT_MIRRORS=(
    "https://gh-proxy.com"
    "https://ghproxy.net"
    "https://ghfast.top"
)

# ---------------------------------------------------------------------------
# 默认值
# ---------------------------------------------------------------------------
SILENT=0
VERSION="latest"
FORCE=0
MIRROR=""
MODE="install"      # install | upgrade | uninstall
TMP_DIR=""          # install_binary 的临时目录，EXIT 时清理
PURGE=0             # 仅 --uninstall 时有效：连配置与日志一起删除
# 本次运行中已成功使用的镜像，后续资产优先复用，避免每个文件都重新探测
USED_MIRROR=""
VERIFY=1
PUBLIC_ADDR=""
RUN_USER="nobody"

API_ON=1
API_LISTEN="127.0.0.1"
API_PORT=10085
API_ALLOW_REMOTE=0

VLESS_ON=1
VLESS_PORT=443
VLESS_UUID=""
VLESS_SECURITY="reality"
VLESS_FLOW="xtls-rprx-vision"
VLESS_TRANSPORT="tcp"
VLESS_PATH="/vless"
VLESS_SERVICE="vless"
VLESS_CERT=""
VLESS_KEY=""
VLESS_REALITY_DEST="www.cloudflare.com:443"
VLESS_REALITY_SNI=""
VLESS_REALITY_SHORT_ID=""
VLESS_REALITY_PRIVATE_KEY=""
VLESS_REALITY_PUBLIC_KEY=""

VMESS_ON=0
VMESS_PORT=10001
VMESS_UUID=""
VMESS_CIPHER="auto"
VMESS_TRANSPORT="tcp"
VMESS_PATH="/vmess"
VMESS_SERVICE="vmess"
VMESS_SECURITY="none"
VMESS_CERT=""
VMESS_KEY=""

SS_ON=0
SS_PORT=10002
SS_METHOD="aes-256-gcm"
SS_PASSWORD=""
SS_NETWORK="tcp,udp"

ACCOUNT_ON=1

# 记录通过命令行显式指定的项，交互模式据此跳过提问
EXPLICIT=""

# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_CYAN=$'\033[36m'
    C_BOLD=$'\033[1m'
    C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_BOLD=""; C_RESET=""
fi

info()  { printf '%s[信息]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%s[警告]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()   { printf '%s[错误]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()   { err "$*"; exit 1; }
step()  { printf '\n%s==> %s%s\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET"; }

# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------
is_set() { [[ " $EXPLICIT " == *" $1 "* ]]; }

json_escape() {
    local s=${1-}
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/}
    s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

validate_port() {
    local p=${1-}
    if [[ ! $p =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
        die "端口无效：'$p'（应为 1-65535 的整数）"
    fi
}

validate_uuid() {
    local u=${1-}
    if [[ ! $u =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        die "UUID 格式无效：'$u'"
    fi
}

gen_uuid() {
    if [[ -x $XRAY_BIN ]]; then
        "$XRAY_BIN" uuid
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        local hex
        hex=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
        printf '%s-%s-%s-%s-%s\n' \
            "${hex:0:8}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}" "${hex:20:12}"
    fi
}

gen_hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }

gen_b64() {
    local n=$1
    if command -v base64 >/dev/null 2>&1; then
        head -c "$n" /dev/urandom | base64 | tr -d '\n'
    else
        od -An -N"$n" -tx1 /dev/urandom | tr -d ' \n'
    fi
}

gen_ss_password() {
    case $SS_METHOD in
        2022-blake3-aes-128-gcm) gen_b64 16 ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) gen_b64 32 ;;
        *) gen_b64 16 ;;
    esac
}

# 从 xray x25519 输出中提取私钥 / 公钥，兼容新旧两种输出格式：
#   PrivateKey: xxx / Password: xxx   (新)
#   Private key: xxx / Public key: xxx (旧)
reality_keypair() {
    local out priv pub
    out=$("$XRAY_BIN" x25519 2>/dev/null) || die "执行 xray x25519 失败"
    priv=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*Private[[:space:]]*[Kk]ey:[[:space:]]*//p' | head -1)
    # 新版输出 `Password (PublicKey): xxx`，旧版为 `Public key: xxx` / `Password: xxx`
    pub=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\(Public[[:space:]]*[Kk]ey\|Password[^:]*\):[[:space:]]*//p' | head -1)
    [[ -n $priv ]] || die "无法从 xray x25519 输出中解析私钥：$out"
    [[ -n $pub ]] || die "无法从 xray x25519 输出中解析公钥：$out"
    VLESS_REALITY_PRIVATE_KEY=$priv
    VLESS_REALITY_PUBLIC_KEY=$pub
}

detect_public_addr() {
    local ip=""
    if command -v ip >/dev/null 2>&1; then
        ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}') || true
    fi
    if [[ -z $ip ]] && command -v hostname >/dev/null 2>&1; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
    fi
    printf '%s' "${ip:-127.0.0.1}"
}

# 判断目标用户能否读取文件（TLS 证书常见坑：/root 下 0600）
can_read_as_user() {
    local f=$1 user=$2
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$user" -- test -r "$f" 2>/dev/null
        return $?
    fi
    if command -v su >/dev/null 2>&1; then
        su -s /bin/sh "$user" -c "test -r '$f'" 2>/dev/null
        return $?
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 帮助
# ---------------------------------------------------------------------------
usage() {
    cat <<'EOF'
Xray 一键安装脚本

用法：xray-install.sh [选项]

通用：
  -h, --help                    显示帮助
  -q, --silent                  静默模式：全程不提问，未指定项使用默认值
  -v, --version <版本>          Xray 版本，例如 26.11.9 / v26.11.9 / latest（默认 latest）
      --force                   已安装时直接覆盖
      --mirror <前缀>           下载镜像前缀，例如 https://ghfast.top/
      --no-verify               跳过 SHA256 校验（不推荐）
      --public-addr <地址>      分享链接中使用的服务器地址（默认自动检测）
      --run-user <用户>         服务运行用户（默认 nobody）

API（默认仅监听本地）：
      --api | --no-api          是否启用 API（默认启用）
      --api-listen <地址>       API 监听地址（默认 127.0.0.1）
      --api-port <端口>         API 端口（默认 10085）
      --api-allow-remote        允许 API 监听非本地地址（默认拒绝）

VLESS（默认启用）：
      --vless | --no-vless
      --vless-port <端口>            默认 443
      --vless-uuid <uuid>            默认自动生成
      --vless-security <模式>        none | tls | reality（默认 reality）
      --vless-flow <流控>            xtls-rprx-vision 或 none（默认 xtls-rprx-vision）
      --vless-transport <传输>       tcp | ws | grpc（默认 tcp）
      --vless-path <路径>            ws 路径（默认 /vless）
      --vless-service-name <名称>    grpc 服务名（默认 vless）
      --vless-cert <路径>            TLS 证书文件
      --vless-key <路径>             TLS 私钥文件
      --vless-reality-dest <目标>    Reality 回落目标（默认 www.cloudflare.com:443）
      --vless-reality-sni <列表>     Reality SNI，逗号分隔（默认取 dest 主机名）
      --vless-reality-short-id <id>  Reality shortId（默认自动生成）
      --vless-reality-private-key <私钥>
                                     复用已有 Reality 私钥（默认自动生成）

VMess（默认关闭）：
      --vmess | --no-vmess
      --vmess-port <端口>            默认 10001
      --vmess-uuid <uuid>            默认自动生成
      --vmess-cipher <加密>          auto | aes-128-gcm | chacha20-poly1305 | none | zero
      --vmess-transport <传输>       tcp | ws | grpc（默认 tcp）
      --vmess-path <路径>            ws 路径（默认 /vmess）
      --vmess-service-name <名称>    grpc 服务名（默认 vmess）
      --vmess-security <模式>        none | tls（默认 none）
      --vmess-cert <路径>            TLS 证书文件
      --vmess-key <路径>             TLS 私钥文件

Shadowsocks（默认关闭）：
      --ss | --no-ss
      --ss-port <端口>               默认 10002
      --ss-method <方法>             默认 aes-256-gcm
      --ss-password <密码>           默认自动生成
      --ss-network <网络>            默认 tcp,udp

账号：
      --account | --no-account       是否生成默认凭据并输出分享链接（默认启用）

升级与卸载：
      --upgrade, -u                  升级已安装的 Xray（可用 -v 指定目标版本，默认 latest）
      --uninstall                    卸载 Xray：停止并删除服务与二进制，保留配置与日志
      --purge                        与 --uninstall 连用：同时删除配置与日志

示例：
  # 全默认静默安装（VLESS + Reality + API + 默认账号）
  ./xray-install.sh --silent

  # 指定版本，开 VLESS(TLS) + VMess + SS，不开 API
  ./xray-install.sh -v 26.11.9 --vless-security tls \
      --vless-cert /etc/ssl/fullchain.pem --vless-key /etc/ssl/privkey.pem \
      --vmess --ss --no-api -q

  # 纯交互
  ./xray-install.sh

  # 升级到最新版本（保留现有配置）
  ./xray-install.sh --upgrade -q

  # 卸载但保留配置与日志
  ./xray-install.sh --uninstall -q

  # 连配置与日志一起删除
  ./xray-install.sh --uninstall --purge -q
EOF
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
need_val() {
    if [[ $# -lt 2 || -z ${2-} ]]; then
        die "选项 ${1} 需要一个值"
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage; exit 0 ;;
            -q|--silent|--non-interactive)
                SILENT=1; shift ;;
            -v|--version)
                need_val "$1" "${2-}"; VERSION=${2#v}; EXPLICIT="$EXPLICIT version"; shift 2 ;;
            --force)
                FORCE=1; shift ;;
            --upgrade|-u)
                MODE="upgrade"; shift ;;
            --uninstall)
                MODE="uninstall"; shift ;;
            --purge)
                PURGE=1; shift ;;
            --mirror)
                need_val "$1" "${2-}"; MIRROR=$2; shift 2 ;;
            --no-verify)
                VERIFY=0; shift ;;
            --public-addr)
                need_val "$1" "${2-}"; PUBLIC_ADDR=$2; shift 2 ;;
            --run-user)
                need_val "$1" "${2-}"; RUN_USER=$2; shift 2 ;;

            --api)      API_ON=1; EXPLICIT="$EXPLICIT api"; shift ;;
            --no-api)   API_ON=0; EXPLICIT="$EXPLICIT api"; shift ;;
            --api-listen)
                need_val "$1" "${2-}"; API_LISTEN=$2; EXPLICIT="$EXPLICIT api_listen"; shift 2 ;;
            --api-port)
                need_val "$1" "${2-}"; API_PORT=$2; EXPLICIT="$EXPLICIT api_port"; shift 2 ;;
            --api-allow-remote)
                API_ALLOW_REMOTE=1; shift ;;

            --vless)     VLESS_ON=1; EXPLICIT="$EXPLICIT vless"; shift ;;
            --no-vless)  VLESS_ON=0; EXPLICIT="$EXPLICIT vless"; shift ;;
            --vless-port)
                need_val "$1" "${2-}"; VLESS_PORT=$2; EXPLICIT="$EXPLICIT vless_port"; shift 2 ;;
            --vless-uuid)
                need_val "$1" "${2-}"; VLESS_UUID=$2; EXPLICIT="$EXPLICIT vless_uuid"; shift 2 ;;
            --vless-security)
                need_val "$1" "${2-}"; VLESS_SECURITY=$2; EXPLICIT="$EXPLICIT vless_security"; shift 2 ;;
            --vless-flow)
                need_val "$1" "${2-}"; VLESS_FLOW=$2; EXPLICIT="$EXPLICIT vless_flow"; shift 2 ;;
            --vless-transport)
                need_val "$1" "${2-}"; VLESS_TRANSPORT=$2; EXPLICIT="$EXPLICIT vless_transport"; shift 2 ;;
            --vless-path)
                need_val "$1" "${2-}"; VLESS_PATH=$2; EXPLICIT="$EXPLICIT vless_path"; shift 2 ;;
            --vless-service-name)
                need_val "$1" "${2-}"; VLESS_SERVICE=$2; EXPLICIT="$EXPLICIT vless_service"; shift 2 ;;
            --vless-cert)
                need_val "$1" "${2-}"; VLESS_CERT=$2; EXPLICIT="$EXPLICIT vless_cert"; shift 2 ;;
            --vless-key)
                need_val "$1" "${2-}"; VLESS_KEY=$2; EXPLICIT="$EXPLICIT vless_key"; shift 2 ;;
            --vless-reality-dest)
                need_val "$1" "${2-}"; VLESS_REALITY_DEST=$2; EXPLICIT="$EXPLICIT vless_reality_dest"; shift 2 ;;
            --vless-reality-sni)
                need_val "$1" "${2-}"; VLESS_REALITY_SNI=$2; EXPLICIT="$EXPLICIT vless_reality_sni"; shift 2 ;;
            --vless-reality-short-id)
                need_val "$1" "${2-}"; VLESS_REALITY_SHORT_ID=$2; EXPLICIT="$EXPLICIT vless_reality_sid"; shift 2 ;;
            --vless-reality-private-key)
                need_val "$1" "${2-}"; VLESS_REALITY_PRIVATE_KEY=$2; EXPLICIT="$EXPLICIT vless_reality_priv"; shift 2 ;;

            --vmess)     VMESS_ON=1; EXPLICIT="$EXPLICIT vmess"; shift ;;
            --no-vmess)  VMESS_ON=0; EXPLICIT="$EXPLICIT vmess"; shift ;;
            --vmess-port)
                need_val "$1" "${2-}"; VMESS_PORT=$2; EXPLICIT="$EXPLICIT vmess_port"; shift 2 ;;
            --vmess-uuid)
                need_val "$1" "${2-}"; VMESS_UUID=$2; EXPLICIT="$EXPLICIT vmess_uuid"; shift 2 ;;
            --vmess-cipher)
                need_val "$1" "${2-}"; VMESS_CIPHER=$2; EXPLICIT="$EXPLICIT vmess_cipher"; shift 2 ;;
            --vmess-transport)
                need_val "$1" "${2-}"; VMESS_TRANSPORT=$2; EXPLICIT="$EXPLICIT vmess_transport"; shift 2 ;;
            --vmess-path)
                need_val "$1" "${2-}"; VMESS_PATH=$2; EXPLICIT="$EXPLICIT vmess_path"; shift 2 ;;
            --vmess-service-name)
                need_val "$1" "${2-}"; VMESS_SERVICE=$2; EXPLICIT="$EXPLICIT vmess_service"; shift 2 ;;
            --vmess-security)
                need_val "$1" "${2-}"; VMESS_SECURITY=$2; EXPLICIT="$EXPLICIT vmess_security"; shift 2 ;;
            --vmess-cert)
                need_val "$1" "${2-}"; VMESS_CERT=$2; EXPLICIT="$EXPLICIT vmess_cert"; shift 2 ;;
            --vmess-key)
                need_val "$1" "${2-}"; VMESS_KEY=$2; EXPLICIT="$EXPLICIT vmess_key"; shift 2 ;;

            --ss)        SS_ON=1; EXPLICIT="$EXPLICIT ss"; shift ;;
            --no-ss)     SS_ON=0; EXPLICIT="$EXPLICIT ss"; shift ;;
            --ss-port)
                need_val "$1" "${2-}"; SS_PORT=$2; EXPLICIT="$EXPLICIT ss_port"; shift 2 ;;
            --ss-method)
                need_val "$1" "${2-}"; SS_METHOD=$2; EXPLICIT="$EXPLICIT ss_method"; shift 2 ;;
            --ss-password)
                need_val "$1" "${2-}"; SS_PASSWORD=$2; EXPLICIT="$EXPLICIT ss_password"; shift 2 ;;
            --ss-network)
                need_val "$1" "${2-}"; SS_NETWORK=$2; EXPLICIT="$EXPLICIT ss_network"; shift 2 ;;

            --account)    ACCOUNT_ON=1; EXPLICIT="$EXPLICIT account"; shift ;;
            --no-account) ACCOUNT_ON=0; EXPLICIT="$EXPLICIT account"; shift ;;

            --)
                shift; break ;;
            -*)
                die "未知选项：$1（使用 --help 查看用法）" ;;
            *)
                die "未知参数：$1（使用 --help 查看用法）" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# 交互
# ---------------------------------------------------------------------------
ask() {
    local var=$1 prompt=$2 def=${3-} ans
    if [[ $SILENT == 1 ]]; then
        printf -v "$var" '%s' "$def"
        return 0
    fi
    read -r -p "$prompt [$def]: " ans || true
    ans=${ans:-$def}
    printf -v "$var" '%s' "$ans"
}

ask_yn() {
    local var=$1 prompt=$2 def=$3 ans def_disp
    if [[ $SILENT == 1 ]]; then
        printf -v "$var" '%s' "$def"
        return 0
    fi
    [[ $def == 1 ]] && def_disp=y || def_disp=n
    while :; do
        read -r -p "$prompt [y/n，默认 $def_disp]: " ans || true
        ans=${ans:-$def}
        case $ans in
            [Yy]|[Yy][Ee][Ss]|1) printf -v "$var" '%s' 1; return 0 ;;
            [Nn]|[Nn][Oo]|0)     printf -v "$var" '%s' 0; return 0 ;;
            *) warn "请输入 y 或 n" ;;
        esac
    done
}

interactive_fill() {
    local _ans=""
    if [[ $SILENT == 1 ]]; then
        return 0
    fi

    printf '\n%s\n' "$C_BOLD===== Xray 安装配置向导（回车使用默认值）=====$C_RESET"

    if ! is_set version; then
        ask VERSION "Xray 版本（latest 或具体版本号）" "$VERSION"
    fi

    if ! is_set api; then
        ask_yn API_ON "是否启用 API" "$API_ON"
    fi
    if [[ $API_ON == 1 ]]; then
        if ! is_set api_listen; then
            ask API_LISTEN "API 监听地址" "$API_LISTEN"
        fi
        if ! is_set api_port; then
            ask API_PORT "API 端口" "$API_PORT"
        fi
    fi

    if ! is_set vless; then
        ask_yn VLESS_ON "是否启用 VLESS 入站" "$VLESS_ON"
    fi
    if [[ $VLESS_ON == 1 ]]; then
        if ! is_set vless_port; then ask VLESS_PORT "VLESS 端口" "$VLESS_PORT"; fi
        if ! is_set vless_security; then
            ask VLESS_SECURITY "VLESS 安全模式（none/tls/reality）" "$VLESS_SECURITY"
        fi
        case $VLESS_SECURITY in
            tls)
                if ! is_set vless_cert; then ask VLESS_CERT "TLS 证书路径" "$VLESS_CERT"; fi
                if ! is_set vless_key;  then ask VLESS_KEY  "TLS 私钥路径" "$VLESS_KEY"; fi
                ;;
            reality)
                if ! is_set vless_reality_dest; then
                    ask VLESS_REALITY_DEST "Reality 回落目标 host:port" "$VLESS_REALITY_DEST"
                fi
                if ! is_set vless_reality_sni; then
                    ask VLESS_REALITY_SNI "Reality SNI（逗号分隔，留空取 dest 主机名）" "$VLESS_REALITY_SNI"
                fi
                if ! is_set vless_reality_sid; then
                    ask VLESS_REALITY_SHORT_ID "Reality shortId（留空自动生成）" "$VLESS_REALITY_SHORT_ID"
                fi
                ;;
        esac
        if ! is_set vless_transport; then
            ask VLESS_TRANSPORT "VLESS 传输（tcp/ws/grpc）" "$VLESS_TRANSPORT"
        fi
        case $VLESS_TRANSPORT in
            ws)
                if ! is_set vless_path; then ask VLESS_PATH "WebSocket 路径" "$VLESS_PATH"; fi ;;
            grpc)
                if ! is_set vless_service; then ask VLESS_SERVICE "gRPC 服务名" "$VLESS_SERVICE"; fi ;;
        esac
        if ! is_set vless_uuid; then
            read -r -p "VLESS UUID（留空自动生成）: " _ans || true
            if [[ -n ${_ans-} ]]; then
                VLESS_UUID=$_ans
            fi
        fi
    fi

    if ! is_set vmess; then
        ask_yn VMESS_ON "是否启用 VMess 入站" "$VMESS_ON"
    fi
    if [[ $VMESS_ON == 1 ]]; then
        if ! is_set vmess_port; then ask VMESS_PORT "VMess 端口" "$VMESS_PORT"; fi
        if ! is_set vmess_security; then
            ask VMESS_SECURITY "VMess 安全模式（none/tls）" "$VMESS_SECURITY"
        fi
        if [[ $VMESS_SECURITY == tls ]]; then
            if ! is_set vmess_cert; then ask VMESS_CERT "VMess TLS 证书路径" "$VMESS_CERT"; fi
            if ! is_set vmess_key;  then ask VMESS_KEY  "VMess TLS 私钥路径" "$VMESS_KEY"; fi
        fi
        if ! is_set vmess_transport; then
            ask VMESS_TRANSPORT "VMess 传输（tcp/ws/grpc）" "$VMESS_TRANSPORT"
        fi
        case $VMESS_TRANSPORT in
            ws)
                if ! is_set vmess_path; then ask VMESS_PATH "VMess WebSocket 路径" "$VMESS_PATH"; fi ;;
            grpc)
                if ! is_set vmess_service; then ask VMESS_SERVICE "VMess gRPC 服务名" "$VMESS_SERVICE"; fi ;;
        esac
        if ! is_set vmess_uuid; then
            read -r -p "VMess UUID（留空自动生成）: " _ans || true
            if [[ -n ${_ans-} ]]; then
                VMESS_UUID=$_ans
            fi
        fi
        if ! is_set vmess_cipher; then
            ask VMESS_CIPHER "VMess 加密方式（auto/aes-128-gcm/chacha20-poly1305/none/zero）" "$VMESS_CIPHER"
        fi
    fi

    if ! is_set ss; then
        ask_yn SS_ON "是否启用 Shadowsocks 入站" "$SS_ON"
    fi
    if [[ $SS_ON == 1 ]]; then
        if ! is_set ss_port; then ask SS_PORT "Shadowsocks 端口" "$SS_PORT"; fi
        if ! is_set ss_method; then
            ask SS_METHOD "Shadowsocks 加密方式" "$SS_METHOD"
        fi
        if ! is_set ss_network; then ask SS_NETWORK "Shadowsocks 网络（tcp,udp）" "$SS_NETWORK"; fi
        if ! is_set ss_password; then
            read -r -p "Shadowsocks 密码（留空自动生成）: " _ans || true
            if [[ -n ${_ans-} ]]; then
                SS_PASSWORD=$_ans
            fi
        fi
    fi

    if ! is_set account; then
        ask_yn ACCOUNT_ON "是否创建默认账号并输出分享链接" "$ACCOUNT_ON"
    fi
}

# ---------------------------------------------------------------------------
# 校验
# ---------------------------------------------------------------------------
normalize_and_validate() {
    # 传输名归一化：raw 视为 tcp
    if [[ $VLESS_TRANSPORT == raw ]]; then VLESS_TRANSPORT="tcp"; fi
    if [[ $VMESS_TRANSPORT == raw ]]; then VMESS_TRANSPORT="tcp"; fi

    # API
    if [[ $API_ON == 1 ]]; then
        validate_port "$API_PORT"
    fi
    if [[ $API_LISTEN != "127.0.0.1" && $API_LISTEN != "::1" && $API_LISTEN != "localhost" ]]; then
        if [[ $API_ALLOW_REMOTE != 1 ]]; then
            die "API 仅允许监听本地地址；确认要暴露到 '$API_LISTEN' 请加 --api-allow-remote"
        fi
    fi

    # VLESS
    if [[ $VLESS_ON == 1 ]]; then
        validate_port "$VLESS_PORT"
        case $VLESS_SECURITY in
            none|tls|reality) ;;
            *) die "VLESS 安全模式无效：'$VLESS_SECURITY'（可选 none/tls/reality）" ;;
        esac
        case $VLESS_TRANSPORT in
            tcp|ws|grpc) ;;
            *) die "VLESS 传输方式无效：'$VLESS_TRANSPORT'（可选 tcp/ws/grpc）" ;;
        esac
        if [[ $VLESS_SECURITY == reality && $VLESS_TRANSPORT == ws ]]; then
            die "Reality 不支持 WebSocket 传输，请改用 tcp 或 grpc，或将 --vless-security 设为 tls/none"
        fi
        if [[ $VLESS_SECURITY == tls ]]; then
            [[ -n $VLESS_CERT ]] || die "security=tls 需要 --vless-cert"
            [[ -n $VLESS_KEY ]]  || die "security=tls 需要 --vless-key"
            [[ -r $VLESS_CERT ]] || die "证书不可读：$VLESS_CERT"
            [[ -r $VLESS_KEY ]]  || die "私钥不可读：$VLESS_KEY"
        fi
        if [[ $VLESS_SECURITY == reality ]]; then
            if [[ $VLESS_REALITY_DEST != *:* ]]; then
                VLESS_REALITY_DEST="$VLESS_REALITY_DEST:443"
            fi
            if [[ -z $VLESS_REALITY_SNI ]]; then
                VLESS_REALITY_SNI=${VLESS_REALITY_DEST%:*}
            fi
            if [[ -n $VLESS_REALITY_SHORT_ID ]]; then
                VLESS_REALITY_SHORT_ID=$(printf '%s' "$VLESS_REALITY_SHORT_ID" | tr 'A-F' 'a-f' | tr -d ' ')
                if [[ ! $VLESS_REALITY_SHORT_ID =~ ^[0-9a-f]+$ ]]; then
                    die "Reality shortId 必须是十六进制字符串：'$VLESS_REALITY_SHORT_ID'"
                fi
                if (( ${#VLESS_REALITY_SHORT_ID} > 16 )); then
                    die "Reality shortId 最长 16 个字符"
                fi
                if (( ${#VLESS_REALITY_SHORT_ID} % 2 == 1 )); then
                    VLESS_REALITY_SHORT_ID="${VLESS_REALITY_SHORT_ID}0"
                fi
            fi
        fi
        if [[ $VLESS_FLOW == none ]]; then VLESS_FLOW=""; fi
        if [[ -n $VLESS_FLOW && $VLESS_SECURITY == none ]]; then
            warn "security=none 时 flow 无意义，已忽略"
            VLESS_FLOW=""
        fi
        if [[ -n $VLESS_FLOW && $VLESS_TRANSPORT != tcp ]]; then
            warn "flow '$VLESS_FLOW' 仅适用于 tcp 传输，已忽略"
            VLESS_FLOW=""
        fi
        if [[ -n $VLESS_UUID ]]; then
            validate_uuid "$VLESS_UUID"
        fi
    fi

    # VMess
    if [[ $VMESS_ON == 1 ]]; then
        validate_port "$VMESS_PORT"
        case $VMESS_SECURITY in
            none|tls) ;;
            *) die "VMess 安全模式无效：'$VMESS_SECURITY'（可选 none/tls）" ;;
        esac
        case $VMESS_TRANSPORT in
            tcp|ws|grpc) ;;
            *) die "VMess 传输方式无效：'$VMESS_TRANSPORT'（可选 tcp/ws/grpc）" ;;
        esac
        case $VMESS_CIPHER in
            auto|aes-128-gcm|chacha20-poly1305|none|zero) ;;
            *) die "VMess 加密方式无效：'$VMESS_CIPHER'" ;;
        esac
        if [[ $VMESS_SECURITY == tls ]]; then
            [[ -n $VMESS_CERT ]] || die "VMess security=tls 需要 --vmess-cert"
            [[ -n $VMESS_KEY ]]  || die "VMess security=tls 需要 --vmess-key"
            [[ -r $VMESS_CERT ]] || die "证书不可读：$VMESS_CERT"
            [[ -r $VMESS_KEY ]]  || die "私钥不可读：$VMESS_KEY"
        fi
        if [[ -n $VMESS_UUID ]]; then
            validate_uuid "$VMESS_UUID"
        fi
    fi

    # Shadowsocks
    if [[ $SS_ON == 1 ]]; then
        validate_port "$SS_PORT"
        case $SS_METHOD in
            2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305|\
            aes-128-gcm|aes-256-gcm|chacha20-poly1305|chacha20-ietf-poly1305|none)
                ;;
            *) die "Shadowsocks 加密方式无效：'$SS_METHOD'" ;;
        esac
    fi

    # 端口冲突
    local ports="" p
    if [[ $API_ON == 1 ]]; then ports="$ports $API_PORT"; fi
    if [[ $VLESS_ON == 1 ]]; then ports="$ports $VLESS_PORT"; fi
    if [[ $VMESS_ON == 1 ]]; then ports="$ports $VMESS_PORT"; fi
    if [[ $SS_ON == 1 ]]; then ports="$ports $SS_PORT"; fi
    for p in $ports; do
        local n=0 q
        for q in $ports; do
            if [[ $p == "$q" ]]; then n=$((n + 1)); fi
        done
        if (( n > 1 )); then
            die "端口冲突：$p 被多个入站使用"
        fi
    done

    if [[ $ACCOUNT_ON == 1 && $VLESS_ON == 0 && $VMESS_ON == 0 && $SS_ON == 0 ]]; then
        warn "没有启用任何入站，账号将不会生成"
    fi

    if ! id -u "$RUN_USER" >/dev/null 2>&1; then
        die "运行用户不存在：$RUN_USER"
    fi
}

# ---------------------------------------------------------------------------
# 环境
# ---------------------------------------------------------------------------
check_env() {
    if [[ -z ${BASH_VERSINFO-} || ${BASH_VERSINFO[0]} -lt 4 ]]; then
        die "需要 bash 4.0 或更高版本"
    fi
    if [[ $(id -u) -ne 0 ]]; then
        die "请使用 root 权限运行（sudo bash $0 ...）"
    fi
    if [[ $(uname -s) != "Linux" ]]; then
        die "本脚本仅支持 Linux"
    fi
    if [[ ! -d /run/systemd/system ]] || ! command -v systemctl >/dev/null 2>&1; then
        die "未检测到 systemd，本脚本仅支持 systemd 系统"
    fi

    # 交互模式必须有终端，否则 read 会读走脚本内容（curl | bash 场景）
    if [[ $SILENT != 1 && ! -t 0 ]]; then
        die "标准输入不是终端，无法交互。请使用 --silent，或下载脚本后执行"
    fi

    case $(uname -m) in
        x86_64|amd64)   ARCH="64" ;;
        aarch64|arm64)  ARCH="arm64-v8a" ;;
        armv7l)         ARCH="arm32-v7a" ;;
        armv6l)         ARCH="arm32-v6" ;;
        armv5tel)       ARCH="arm32-v5" ;;
        i386|i686)      ARCH="32" ;;
        loongarch64)    ARCH="loong64" ;;
        *) die "不支持的架构：$(uname -m)" ;;
    esac

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        die "需要 curl 或 wget"
    fi
}

ensure_unzip() {
    if command -v unzip >/dev/null 2>&1; then
        return 0
    fi
    info "未找到 unzip，尝试自动安装..."
    export DEBIAN_FRONTEND=noninteractive
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y -qq unzip >/dev/null
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q unzip >/dev/null
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q unzip >/dev/null
    elif command -v zypper >/dev/null 2>&1; then
        zypper -q install -y unzip >/dev/null
    elif command -v pacman >/dev/null 2>&1; then
        pacman -S --noconfirm unzip >/dev/null
    else
        die "无法自动安装 unzip，请手动安装后重试"
    fi
    command -v unzip >/dev/null 2>&1 || die "unzip 安装失败"
}

resolve_version() {
    if [[ $VERSION == "latest" ]]; then
        info "正在获取 Xray 最新版本..."
        local tag=""
        tag=$(curl -fsSL --max-time 30 \
            "https://api.github.com/repos/$GITHUB_REPO/releases/latest" 2>/dev/null \
            | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1) || true
        if [[ -z $tag ]]; then
            local loc=""
            loc=$(curl -fsSI --max-time 30 \
                "https://github.com/$GITHUB_REPO/releases/latest" 2>/dev/null \
                | sed -n 's/^[Ll]ocation:[[:space:]]*//p' | tr -d '\r' | head -1) || true
            if [[ -n $loc ]]; then
                tag=${loc##*/}
            fi
        fi
        [[ -n $tag ]] || die "无法获取最新版本，请用 --version 指定版本号，或检查网络"
        VERSION=${tag#v}
    else
        VERSION=${VERSION#v}
    fi
    info "使用 Xray 版本：$VERSION"
}

# ---------------------------------------------------------------------------
# 下载与安装二进制
# ---------------------------------------------------------------------------
download_file() {
    local url=$1 out=$2 tries=${3:-3}
    local full="$url"
    if [[ -n $MIRROR ]]; then
        full="${MIRROR%/}/$url"
    fi

    # 静默模式不输出进度；交互模式用单行进度条，避免日志被刷屏
    local progress=()
    if [[ $SILENT == 1 ]]; then
        progress=(-sS)
    else
        progress=(--progress-bar)
    fi

    local attempt rc=1
    for ((attempt = 1; attempt <= tries; attempt++)); do
        if command -v curl >/dev/null 2>&1; then
            # 不依赖 --retry-all-errors（CentOS 7 的 curl 7.29 不支持），
            # 由外层循环兜底；--speed-limit/--speed-time 防止卡在慢速连接上。
            curl "${progress[@]}" -fL --retry 2 --retry-delay 2 \
                --connect-timeout 15 --max-time 600 \
                --speed-limit 2048 --speed-time 60 \
                -o "$out" "$full" && rc=0 && break
        else
            wget -q -T 15 -t 2 -O "$out" "$full" && rc=0 && break
        fi
        if (( attempt < tries )); then
            warn "下载中断（第 $attempt 次），3 秒后重试..."
            sleep 3
        fi
    done
    if (( rc != 0 )); then
        rm -f "$out" 2>/dev/null || true
    fi
    return $rc
}

# 下载 release 资产：显式 --mirror 时只用该镜像；否则先试 GitHub，
# 失败后依次尝试 DEFAULT_MIRRORS。用到的镜像会打印警告。
download_asset() {
    local url=$1 out=$2

    if [[ -n $MIRROR ]]; then
        download_file "$url" "$out" 3
        return $?
    fi

    if [[ -n $USED_MIRROR ]]; then
        MIRROR=$USED_MIRROR download_file "$url" "$out" 2 && return 0
    fi

    if download_file "$url" "$out" 2; then
        return 0
    fi

    local m
    for m in "${DEFAULT_MIRRORS[@]}"; do
        [[ $m == "$USED_MIRROR" ]] && continue
        warn "GitHub 直连失败，尝试镜像 $m ..."
        if MIRROR=$m download_file "$url" "$out" 1; then
            USED_MIRROR=$m
            warn "已通过第三方镜像下载：$m（内容依赖 SHA256 校验保证完整性）"
            return 0
        fi
    done
    return 1
}

install_binary() {
    ensure_unzip
    local zip_url="https://github.com/$GITHUB_REPO/releases/download/v${VERSION}/Xray-linux-${ARCH}.zip"

    # 已安装同版本时直接复用，避免重复下载数十 MB；需要强制重装可先删除二进制
    if [[ -x $XRAY_BIN ]]; then
        local cur_ver=""
        cur_ver=$("$XRAY_BIN" version 2>/dev/null \
            | sed -n 's/^Xray[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p' | head -1) || true
        if [[ $cur_ver == "$VERSION" ]]; then
            info "已安装 Xray $VERSION，跳过下载"
            return 0
        fi
    fi

    TMP_DIR=$(mktemp -d)
    trap 'if [[ -n ${TMP_DIR:-} ]]; then rm -rf "$TMP_DIR"; fi' EXIT

    step "下载 Xray $VERSION（linux-$ARCH）"
    download_asset "$zip_url" "$TMP_DIR/xray.zip" \
        || die "下载失败。可用 --mirror <镜像> 指定加速地址（例：--mirror https://gh-proxy.com）"

    if [[ $VERIFY == 1 ]]; then
        step "校验文件完整性"
        if download_asset "$zip_url.dgst" "$TMP_DIR/xray.zip.dgst"; then
            local expected actual
            expected=$(sed -n 's/^SHA2-256=[[:space:]]*//p' "$TMP_DIR/xray.zip.dgst" | tr -d '\r' | head -1)
            actual=$(sha256sum "$TMP_DIR/xray.zip" | awk '{print $1}')
            if [[ -z $expected ]]; then
                warn "校验文件中没有 SHA2-256，跳过校验"
            elif [[ $expected != "$actual" ]]; then
                die "SHA256 校验失败：期望 $expected，实际 $actual"
            else
                info "SHA256 校验通过"
            fi
        else
            warn "无法下载校验文件，跳过校验（可用 --no-verify 消除此警告）"
        fi
    fi

    step "解压并安装二进制"
    unzip -o -q "$TMP_DIR/xray.zip" -d "$TMP_DIR" || die "解压失败"
    [[ -f $TMP_DIR/xray ]] || die "压缩包中未找到 xray 二进制"
    install -m 0755 "$TMP_DIR/xray" "$XRAY_BIN"
    local ver
    ver=$("$XRAY_BIN" version 2>/dev/null | head -1) || true
    info "已安装：${ver:-$XRAY_BIN}"
}

# ---------------------------------------------------------------------------
# 升级与卸载
# ---------------------------------------------------------------------------
do_upgrade() {
    if [[ ! -x $XRAY_BIN ]]; then
        die "未检测到已安装的 Xray（$XRAY_BIN 不存在），请先执行安装"
    fi

    local oldver=""
    oldver=$("$XRAY_BIN" version 2>/dev/null \
        | sed -n 's/^Xray[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p' | head -1) || true

    resolve_version
    if [[ -n $oldver && $oldver == "$VERSION" ]]; then
        info "当前已是最新版本：$VERSION"
        return 0
    fi

    step "升级 Xray"
    info "版本：${oldver:-未知} -> $VERSION"
    local bak="$XRAY_BIN.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$XRAY_BIN" "$bak"
    info "已备份旧二进制：$bak"

    # 子 shell 隔离 install_binary 内部的 die，失败时据此回滚
    if ! ( install_binary ); then
        mv -f "$bak" "$XRAY_BIN"
        die "升级失败，已恢复旧版本（${oldver:-未知}）"
    fi

    if [[ -f $XRAY_CONFIG ]] && ! test_config "$XRAY_CONFIG"; then
        mv -f "$bak" "$XRAY_BIN"
        warn "新版本无法通过现有配置校验，已回滚到 ${oldver:-旧版本}"
        die "升级中止"
    fi

    if ! start_service; then
        mv -f "$bak" "$XRAY_BIN"
        systemctl restart xray >/dev/null 2>&1 || true
        die "新版本启动失败，已回滚到 ${oldver:-旧版本}"
    fi

    step "完成"
    info "已升级到 Xray $VERSION（旧版本备份：$bak）"
    info "确认无误后可删除备份：rm -f $bak"
}

do_uninstall() {
    local installed=0
    [[ -e $XRAY_BIN || -f $SYSTEMD_UNIT ]] && installed=1

    if [[ $installed == 0 && $PURGE == 0 ]]; then
        info "未检测到 Xray 安装，无需卸载"
        return 0
    fi

    if [[ $SILENT != 1 ]]; then
        local ok=0
        if [[ $installed == 1 ]]; then
            ask_yn ok "确认卸载 Xray？服务与二进制将被删除" 0
            [[ $ok == 1 ]] || { info "已取消"; return 0; }
        fi
        if [[ $PURGE == 1 ]]; then
            ok=0
            ask_yn ok "同时删除配置目录 $XRAY_ETC 与日志目录 $XRAY_LOG？" 0
            [[ $ok == 1 ]] || PURGE=0
        fi
    fi

    step "卸载 Xray"
    systemctl stop xray >/dev/null 2>&1 || true
    systemctl disable xray >/dev/null 2>&1 || true

    if [[ -f $SYSTEMD_UNIT ]]; then
        rm -f "$SYSTEMD_UNIT"
        systemctl daemon-reload >/dev/null 2>&1 || true
        info "已删除 systemd 服务"
    fi
    if [[ -e $XRAY_BIN ]]; then
        rm -f "$XRAY_BIN"
        info "已删除二进制：$XRAY_BIN"
    fi

    if [[ $PURGE == 1 ]]; then
        rm -rf "$XRAY_ETC" "$XRAY_LOG"
        info "已删除配置与日志"
    else
        info "配置保留在：$XRAY_ETC"
        info "日志保留在：$XRAY_LOG"
        info "如需一并删除，加 --purge"
    fi

    local f
    for f in "$XRAY_BIN".bak.*; do
        [[ -e $f ]] || continue
        rm -f "$f"
        info "已删除备份：$f"
    done

    info "Xray 已卸载"
}

# ---------------------------------------------------------------------------
# 配置生成
# ---------------------------------------------------------------------------
join_json() {
    local first=1 item
    for item in "$@"; do
        if [[ $first == 1 ]]; then first=0; else printf ',\n'; fi
        printf '%s' "$item"
    done
}

reality_sni_list() {
    local list=${VLESS_REALITY_SNI:-${VLESS_REALITY_DEST%:*}}
    local out="" item
    local IFS=,
    for item in $list; do
        item=$(printf '%s' "$item" | tr -d ' ')
        [[ -n $item ]] || continue
        out="$out${out:+,}\"$(json_escape "$item")\""
    done
    printf '%s' "$out"
}

build_api_inbound() {
    cat <<EOF
    {
      "tag": "api",
      "listen": "$(json_escape "$API_LISTEN")",
      "port": $API_PORT,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "$(json_escape "$API_LISTEN")"
      }
    }
EOF
}

vless_clients_json() {
    if [[ $ACCOUNT_ON == 0 ]]; then
        printf '"clients": [],\n    "decryption": "none"'
        return 0
    fi
    local flow_field=""
    if [[ -n $VLESS_FLOW ]]; then
        flow_field=",
        \"flow\": \"$(json_escape "$VLESS_FLOW")\""
    fi
    cat <<EOF
"clients": [
      {
        "id": "$(json_escape "$VLESS_UUID")",
        "email": "default@xray"$flow_field
      }
    ],
    "decryption": "none"
EOF
}

vmess_clients_json() {
    if [[ $ACCOUNT_ON == 0 ]]; then
        printf '"clients": []'
        return 0
    fi
    cat <<EOF
"clients": [
      {
        "id": "$(json_escape "$VMESS_UUID")",
        "alterId": 0,
        "security": "$(json_escape "$VMESS_CIPHER")",
        "email": "default@xray"
      }
    ]
EOF
}

vless_stream_json() {
    local net=$VLESS_TRANSPORT sec=$VLESS_SECURITY
    local net_block="" sec_block=""

    case $net in
        tcp)
            net_block='    "network": "tcp"'
            ;;
        ws)
            net_block=$(cat <<EOF
    "network": "ws",
    "wsSettings": {
      "path": "$(json_escape "$VLESS_PATH")"
    }
EOF
)
            ;;
        grpc)
            net_block=$(cat <<EOF
    "network": "grpc",
    "grpcSettings": {
      "serviceName": "$(json_escape "$VLESS_SERVICE")"
    }
EOF
)
            ;;
    esac

    case $sec in
        none)
            sec_block='    "security": "none"'
            ;;
        tls)
            sec_block=$(cat <<EOF
    "security": "tls",
    "tlsSettings": {
      "certificates": [
        {
          "certificateFile": "$(json_escape "$VLESS_CERT")",
          "keyFile": "$(json_escape "$VLESS_KEY")"
        }
      ]
    }
EOF
)
            ;;
        reality)
            sec_block=$(cat <<EOF
    "security": "reality",
    "realitySettings": {
      "show": false,
      "dest": "$(json_escape "$VLESS_REALITY_DEST")",
      "xver": 0,
      "serverNames": [$(reality_sni_list)],
      "privateKey": "$(json_escape "$VLESS_REALITY_PRIVATE_KEY")",
      "shortIds": ["$(json_escape "$VLESS_REALITY_SHORT_ID")"]
    }
EOF
)
            ;;
    esac

    printf '%s,\n%s' "$net_block" "$sec_block"
}

vmess_stream_json() {
    local net=$VMESS_TRANSPORT sec=$VMESS_SECURITY
    local net_block="" sec_block=""

    case $net in
        tcp)
            net_block='    "network": "tcp"'
            ;;
        ws)
            net_block=$(cat <<EOF
    "network": "ws",
    "wsSettings": {
      "path": "$(json_escape "$VMESS_PATH")"
    }
EOF
)
            ;;
        grpc)
            net_block=$(cat <<EOF
    "network": "grpc",
    "grpcSettings": {
      "serviceName": "$(json_escape "$VMESS_SERVICE")"
    }
EOF
)
            ;;
    esac

    case $sec in
        none)
            sec_block='    "security": "none"'
            ;;
        tls)
            sec_block=$(cat <<EOF
    "security": "tls",
    "tlsSettings": {
      "certificates": [
        {
          "certificateFile": "$(json_escape "$VMESS_CERT")",
          "keyFile": "$(json_escape "$VMESS_KEY")"
        }
      ]
    }
EOF
)
            ;;
    esac

    printf '%s,\n%s' "$net_block" "$sec_block"
}

build_vless_inbound() {
    cat <<EOF
    {
      "tag": "vless-in",
      "listen": "0.0.0.0",
      "port": $VLESS_PORT,
      "protocol": "vless",
      "settings": {
    $(vless_clients_json)
      },
      "streamSettings": {
$(vless_stream_json)
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
EOF
}

build_vmess_inbound() {
    cat <<EOF
    {
      "tag": "vmess-in",
      "listen": "0.0.0.0",
      "port": $VMESS_PORT,
      "protocol": "vmess",
      "settings": {
    $(vmess_clients_json)
      },
      "streamSettings": {
$(vmess_stream_json)
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
EOF
}

build_ss_inbound() {
    cat <<EOF
    {
      "tag": "ss-in",
      "listen": "0.0.0.0",
      "port": $SS_PORT,
      "protocol": "shadowsocks",
      "settings": {
        "method": "$(json_escape "$SS_METHOD")",
        "password": "$(json_escape "$SS_PASSWORD")",
        "network": "$(json_escape "$SS_NETWORK")"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
EOF
}

build_config() {
    local out=$1
    local inbounds=()

    if [[ $API_ON == 1 ]]; then inbounds+=("$(build_api_inbound)"); fi
    if [[ $VLESS_ON == 1 ]]; then inbounds+=("$(build_vless_inbound)"); fi
    if [[ $VMESS_ON == 1 ]]; then inbounds+=("$(build_vmess_inbound)"); fi
    if [[ $SS_ON == 1 ]]; then inbounds+=("$(build_ss_inbound)"); fi

    {
        printf '{\n'
        printf '  "log": {\n'
        printf '    "access": "%s",\n' "$(json_escape "$XRAY_LOG/access.log")"
        printf '    "error": "%s",\n' "$(json_escape "$XRAY_LOG/error.log")"
        printf '    "loglevel": "warning"\n'
        printf '  },\n'

        if [[ $API_ON == 1 ]]; then
            cat <<'EOF'
  "api": {
    "tag": "api",
    "services": ["HandlerService", "LoggerService", "StatsService"]
  },
  "stats": {},
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  },
EOF
        fi

        printf '  "inbounds": [\n'
        if (( ${#inbounds[@]} > 0 )); then
            join_json "${inbounds[@]}"
            printf '\n'
        fi
        printf '  ],\n'

        cat <<'EOF'
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ],
EOF

        if [[ $API_ON == 1 ]]; then
            cat <<'EOF'
  "routing": {
    "rules": [
      {
        "type": "field",
        "inboundTag": ["api"],
        "outboundTag": "api"
      }
    ]
  }
EOF
        else
            cat <<'EOF'
  "routing": {
    "rules": []
  }
EOF
        fi
        printf '}\n'
    } > "$out"
}

# ---------------------------------------------------------------------------
# 账号与分享链接
# ---------------------------------------------------------------------------
build_vless_link() {
    local addr=$1
    local q="encryption=none&security=${VLESS_SECURITY}&type=${VLESS_TRANSPORT}"
    case $VLESS_SECURITY in
        reality)
            local sni
            sni=$(reality_sni_list | tr -d '"' | cut -d, -f1)
            q="$q&sni=$sni"
            q="$q&fp=chrome&pbk=${VLESS_REALITY_PUBLIC_KEY}&sid=${VLESS_REALITY_SHORT_ID}"
            ;;
        tls)
            local tls_sni=${VLESS_REALITY_SNI:-${VLESS_REALITY_DEST%:*}}
            q="$q&sni=$tls_sni"
            ;;
    esac
    if [[ -n $VLESS_FLOW ]]; then
        q="$q&flow=${VLESS_FLOW}"
    fi
    if [[ $VLESS_TRANSPORT == ws ]]; then
        q="$q&path=${VLESS_PATH}"
    elif [[ $VLESS_TRANSPORT == grpc ]]; then
        q="$q&serviceName=${VLESS_SERVICE}"
    fi
    printf 'vless://%s@%s:%s?%s#Xray-VLESS-%s' \
        "$VLESS_UUID" "$addr" "$VLESS_PORT" "$q" "$VLESS_PORT"
}

build_vmess_link() {
    local addr=$1
    local json tls_flag=""
    if [[ $VMESS_SECURITY == tls ]]; then
        tls_flag="tls"
    fi
    json=$(printf '{"v":"2","ps":"Xray-VMess-%s","add":"%s","port":"%s","id":"%s","aid":"0","scy":"%s","net":"%s","type":"none","host":"","path":"%s","tls":"%s","sni":""}' \
        "$VMESS_PORT" "$addr" "$VMESS_PORT" "$VMESS_UUID" "$VMESS_CIPHER" \
        "$VMESS_TRANSPORT" "$VMESS_PATH" "$tls_flag")
    printf 'vmess://%s' "$(printf '%s' "$json" | base64 | tr -d '\n')"
}

build_ss_link() {
    local addr=$1
    local userinfo
    userinfo=$(printf '%s:%s' "$SS_METHOD" "$SS_PASSWORD" | base64 | tr -d '\n')
    printf 'ss://%s@%s:%s#Xray-SS-%s' "$userinfo" "$addr" "$SS_PORT" "$SS_PORT"
}

print_accounts() {
    local addr=$1
    local outfile="$XRAY_ETC/account.txt"

    {
        printf '# Xray 账号信息，生成时间：%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf '# 服务器地址：%s\n\n' "$addr"

        if [[ $VLESS_ON == 1 && $ACCOUNT_ON == 1 ]]; then
            printf '[VLESS]\n'
            printf '端口: %s\n' "$VLESS_PORT"
            printf 'UUID: %s\n' "$VLESS_UUID"
            printf '安全: %s\n' "$VLESS_SECURITY"
            if [[ $VLESS_SECURITY == reality ]]; then
                printf 'SNI: %s\n' "$VLESS_REALITY_SNI"
                printf '公钥: %s\n' "$VLESS_REALITY_PUBLIC_KEY"
                printf 'shortId: %s\n' "$VLESS_REALITY_SHORT_ID"
                printf '回落目标: %s\n' "$VLESS_REALITY_DEST"
            fi
            if [[ -n $VLESS_FLOW ]]; then printf '流控: %s\n' "$VLESS_FLOW"; fi
            printf '链接: %s\n\n' "$(build_vless_link "$addr")"
        fi

        if [[ $VMESS_ON == 1 && $ACCOUNT_ON == 1 ]]; then
            printf '[VMess]\n'
            printf '端口: %s\n' "$VMESS_PORT"
            printf 'UUID: %s\n' "$VMESS_UUID"
            printf '加密: %s\n' "$VMESS_CIPHER"
            printf '链接: %s\n\n' "$(build_vmess_link "$addr")"
        fi

        if [[ $SS_ON == 1 ]]; then
            printf '[Shadowsocks]\n'
            printf '端口: %s\n' "$SS_PORT"
            printf '加密: %s\n' "$SS_METHOD"
            printf '密码: %s\n' "$SS_PASSWORD"
            printf '链接: %s\n\n' "$(build_ss_link "$addr")"
        fi

        if [[ $API_ON == 1 ]]; then
            local api_scope="仅本机"
            if [[ $API_ALLOW_REMOTE == 1 ]]; then api_scope="已允许远程访问"; fi
            printf '[API]\n'
            printf '地址: %s:%s（%s）\n' "$API_LISTEN" "$API_PORT" "$api_scope"
            printf '查看流量: xray api statsquery --server=%s:%s\n' "$API_LISTEN" "$API_PORT"
            printf '重置流量: xray api statsquery --server=%s:%s -reset\n' "$API_LISTEN" "$API_PORT"
        fi
    } > "$outfile"

    chmod 600 "$outfile" 2>/dev/null || true
    info "账号信息已写入：$outfile"
}

show_accounts() {
    step "账号信息"
    if [[ $ACCOUNT_ON == 1 && $VLESS_ON == 1 ]]; then
        printf '\n%sVLESS%s\n' "$C_BOLD" "$C_RESET"
        printf '  端口   : %s\n' "$VLESS_PORT"
        printf '  UUID   : %s\n' "$VLESS_UUID"
        printf '  安全   : %s\n' "$VLESS_SECURITY"
        if [[ $VLESS_SECURITY == reality ]]; then
            printf '  SNI    : %s\n' "$VLESS_REALITY_SNI"
            printf '  公钥   : %s\n' "$VLESS_REALITY_PUBLIC_KEY"
            printf '  shortId: %s\n' "$VLESS_REALITY_SHORT_ID"
        fi
        printf '  链接   : %s\n' "$(build_vless_link "$1")"
    fi

    if [[ $ACCOUNT_ON == 1 && $VMESS_ON == 1 ]]; then
        printf '\n%sVMess%s\n' "$C_BOLD" "$C_RESET"
        printf '  端口   : %s\n' "$VMESS_PORT"
        printf '  UUID   : %s\n' "$VMESS_UUID"
        printf '  链接   : %s\n' "$(build_vmess_link "$1")"
    fi

    if [[ $SS_ON == 1 ]]; then
        printf '\n%sShadowsocks%s\n' "$C_BOLD" "$C_RESET"
        printf '  端口   : %s\n' "$SS_PORT"
        printf '  加密   : %s\n' "$SS_METHOD"
        printf '  密码   : %s\n' "$SS_PASSWORD"
        printf '  链接   : %s\n' "$(build_ss_link "$1")"
    fi

    if [[ $API_ON == 1 ]]; then
        local api_scope="仅本机"
        if [[ $API_ALLOW_REMOTE == 1 ]]; then api_scope="已允许远程访问"; fi
        printf '\n%sAPI%s\n' "$C_BOLD" "$C_RESET"
        printf '  地址   : %s:%s（%s）\n' "$API_LISTEN" "$API_PORT" "$api_scope"
    fi

    if [[ $ACCOUNT_ON == 0 ]]; then
        printf '\n（已按 --no-account 跳过默认账号生成，请自行在配置中添加 clients）\n'
    fi
}

# ---------------------------------------------------------------------------
# 服务
# ---------------------------------------------------------------------------
install_service() {
    local tmp_unit
    tmp_unit=$(mktemp)
    cat > "$tmp_unit" <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=$RUN_USER
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=$XRAY_BIN run -config $XRAY_CONFIG
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    install -m 0644 "$tmp_unit" "$SYSTEMD_UNIT"
    rm -f "$tmp_unit"
}

test_config() {
    local cfg=$1
    if "$XRAY_BIN" run -test -config "$cfg" >/dev/null 2>&1; then
        return 0
    fi
    if "$XRAY_BIN" -test -config "$cfg" >/dev/null 2>&1; then
        return 0
    fi
    err "配置校验失败，输出："
    "$XRAY_BIN" run -test -config "$cfg" 2>&1 || true
    return 1
}

start_service() {
    step "启动服务"
    mkdir -p "$XRAY_LOG"
    chown "$RUN_USER" "$XRAY_LOG" 2>/dev/null || true

    systemctl daemon-reload
    systemctl enable xray >/dev/null 2>&1 || true
    systemctl restart xray || true

    # 只看 is-active 会被 Restart=on-failure 的瞬时 active 骗过，
    # 必须同时确认 SubState 为 running，并让 failed/dead 立即跳出
    local i state
    for i in 1 2 3 4 5 6; do
        sleep 1
        state=$(systemctl show -p ActiveState,SubState --value xray 2>/dev/null | tr '\n' ' ') || true
        case $state in
            "active running"*) info "Xray 服务已启动"; return 0 ;;
            *failed*|*dead*) break ;;
        esac
    done

    err "Xray 启动失败，最近日志："
    journalctl -u xray -n 40 --no-pager 2>/dev/null || true
    return 1
}

# 证书复制到配置目录：Xray 以 $RUN_USER 运行，读不到 /root 下的文件
prepare_tls_certs() {
    local dir="$XRAY_ETC/tls" grp
    mkdir -p "$dir"
    chmod 755 "$dir"
    grp=$(id -gn "$RUN_USER")

    if [[ $VLESS_ON == 1 && $VLESS_SECURITY == tls ]]; then
        case $VLESS_CERT in
            "$dir"/*) : ;;
            *)
                install -m 0644 -o root -g root "$VLESS_CERT" "$dir/vless-cert.pem" \
                    || die "无法复制证书：$VLESS_CERT"
                install -m 0640 -o root -g "$grp" "$VLESS_KEY" "$dir/vless-key.pem" \
                    || die "无法复制私钥：$VLESS_KEY"
                VLESS_CERT="$dir/vless-cert.pem"
                VLESS_KEY="$dir/vless-key.pem"
                info "证书已复制到 $dir（运行用户 $RUN_USER 可读）"
                ;;
        esac
    fi
    if [[ $VMESS_ON == 1 && $VMESS_SECURITY == tls ]]; then
        case $VMESS_CERT in
            "$dir"/*) : ;;
            *)
                install -m 0644 -o root -g root "$VMESS_CERT" "$dir/vmess-cert.pem" \
                    || die "无法复制证书：$VMESS_CERT"
                install -m 0640 -o root -g "$grp" "$VMESS_KEY" "$dir/vmess-key.pem" \
                    || die "无法复制私钥：$VMESS_KEY"
                VMESS_CERT="$dir/vmess-cert.pem"
                VMESS_KEY="$dir/vmess-key.pem"
                info "证书已复制到 $dir（运行用户 $RUN_USER 可读）"
                ;;
        esac
    fi
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    check_env

    case $MODE in
        upgrade)   do_upgrade; return 0 ;;
        uninstall) do_uninstall; return 0 ;;
    esac

    interactive_fill
    normalize_and_validate
    resolve_version

    if [[ -x $XRAY_BIN ]] || [[ -f $SYSTEMD_UNIT ]]; then
        if [[ $FORCE != 1 ]]; then
            if [[ $SILENT == 1 ]]; then
                die "检测到已有 Xray 安装，如需覆盖请加 --force"
            fi
            local ow=0
            ask_yn ow "检测到已有 Xray 安装，是否覆盖？" 0
            if [[ $ow != 1 ]]; then
                info "已取消"
                exit 0
            fi
        fi
        info "停止已有服务"
        systemctl stop xray >/dev/null 2>&1 || true
    fi

    install_binary

    step "生成凭据"
    if [[ $VLESS_ON == 1 && $ACCOUNT_ON == 1 && -z $VLESS_UUID ]]; then
        VLESS_UUID=$(gen_uuid)
    fi
    if [[ $VMESS_ON == 1 && $ACCOUNT_ON == 1 && -z $VMESS_UUID ]]; then
        VMESS_UUID=$(gen_uuid)
    fi
    if [[ $SS_ON == 1 && -z $SS_PASSWORD ]]; then
        SS_PASSWORD=$(gen_ss_password)
    fi
    if [[ $VLESS_ON == 1 && $VLESS_SECURITY == reality ]]; then
        if [[ -z $VLESS_REALITY_PRIVATE_KEY ]]; then
            reality_keypair
        else
            VLESS_REALITY_PUBLIC_KEY=$("$XRAY_BIN" x25519 -i "$VLESS_REALITY_PRIVATE_KEY" 2>/dev/null \
                | sed -n 's/^[[:space:]]*\(Public[[:space:]]*[Kk]ey\|Password[^:]*\):[[:space:]]*//p' | head -1) || true
            [[ -n $VLESS_REALITY_PUBLIC_KEY ]] || warn "无法从私钥推导公钥，分享链接中的 pbk 可能为空"
        fi
        if [[ -z $VLESS_REALITY_SHORT_ID ]]; then
            VLESS_REALITY_SHORT_ID=$(gen_hex 8)
        fi
        info "Reality 私钥：$VLESS_REALITY_PRIVATE_KEY"
        info "Reality 公钥：$VLESS_REALITY_PUBLIC_KEY"
        info "Reality shortId：$VLESS_REALITY_SHORT_ID"
    fi
    if [[ $VLESS_ON == 1 && $ACCOUNT_ON == 1 ]]; then info "VLESS UUID：$VLESS_UUID"; fi
    if [[ $VMESS_ON == 1 && $ACCOUNT_ON == 1 ]]; then info "VMess UUID：$VMESS_UUID"; fi
    if [[ $SS_ON == 1 ]]; then info "Shadowsocks 密码：$SS_PASSWORD"; fi

    step "生成配置"
    mkdir -p "$XRAY_ETC" "$XRAY_LOG"
    chmod 755 "$XRAY_ETC"
    chown "$RUN_USER" "$XRAY_LOG" 2>/dev/null || true
    prepare_tls_certs
    # Xray 按扩展名判断配置格式，临时文件必须以 .json 结尾
    local tmpcfg="$XRAY_ETC/.config.new.json"
    build_config "$tmpcfg"
    if ! test_config "$tmpcfg"; then
        rm -f "$tmpcfg"
        die "配置无效，未做任何替换"
    fi
    info "配置校验通过"
    # -test 以 root 运行会创建日志文件，改回运行用户避免服务启动后无写权限
    chown -R "$RUN_USER" "$XRAY_LOG" 2>/dev/null || true

    if [[ -f $XRAY_CONFIG ]]; then
        local bak="$XRAY_CONFIG.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "$XRAY_CONFIG" "$bak"
        info "已备份旧配置：$bak"
    fi
    install -m 0644 "$tmpcfg" "$XRAY_CONFIG"
    rm -f "$tmpcfg"

    install_service

    if [[ $ACCOUNT_ON == 1 ]]; then
        local addr=${PUBLIC_ADDR:-$(detect_public_addr)}
        print_accounts "$addr"
    fi

    if ! start_service; then
        die "服务启动失败，请根据上方日志排查"
    fi

    if [[ $ACCOUNT_ON == 1 ]]; then
        show_accounts "${PUBLIC_ADDR:-$(detect_public_addr)}"
    fi

    printf '\n%s安装完成%s\n' "$C_GREEN$C_BOLD" "$C_RESET"
    printf '配置：%s\n' "$XRAY_CONFIG"
    printf '管理：systemctl {status|restart|stop} xray\n'
    printf '日志：journalctl -u xray -f\n'
}

main "$@"