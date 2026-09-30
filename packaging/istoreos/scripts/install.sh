#!/bin/sh
# Native OpenWrt/iStoreOS installation. No Node.js or container runtime.
set -eu
fail() { echo "错误: $*" >&2; exit 1; }
usage() { echo "用法: sh scripts/install.sh --bind <LAN IPv4> --data <持久目录> [--version <版本>] [--port <端口>] [--repo agentx1boss/opencode|anomalyco/opencode]"; }
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/platform.sh"
bind= data= version= port=4096 repo=agentx1boss/opencode
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --bind|--data|--version|--port|--repo)
            [ "$#" -ge 2 ] || fail "$1 缺少参数"
            case "$1" in
                --bind) bind=$2 ;; --data) data=$2 ;;
                --version) version=${2#v} ;; --port) port=$2 ;;
                --repo) repo=$2 ;;
            esac
            shift 2 ;;
        *) fail "未知参数 $1" ;;
    esac
done
valid_release_repo "$repo" || fail "仅允许 agentx1boss/opencode 或 anomalyco/opencode"
valid_ipv4 "$bind" || fail "请指定有效 LAN IPv4，不能使用 0.0.0.0"
valid_data_path "$data" || fail "数据目录需位于 /mnt 或 /opt 下，且不含空格、.. 或尾随斜杠"
[ -z "$version" ] || valid_version "$version" || fail "非法版本"
case "$port" in ''|*[!0-9]*|??????*) fail "非法端口" ;; esac
[ "$port" -ge 1024 ] && [ "$port" -le 65535 ] || fail "端口范围为 1024-65535"
[ "$(id -u)" = 0 ] || fail "请在 iStoreOS 上以 root 执行"
[ -f /etc/openwrt_release ] && [ -f /etc/rc.common ] || fail "仅支持使用 procd 的 OpenWrt/iStoreOS"
target=$(detect_target "$(uname -m)") || fail "仅支持 x86_64 和 aarch64"
[ ! -e "$data" ] && [ ! -L "$data" ] || fail "数据目录已存在，拒绝覆盖"
for path in /etc/init.d/opencode /etc/opencode /usr/libexec/opencode-run; do
    [ ! -e "$path" ] && [ ! -L "$path" ] || fail "$path 已存在，拒绝覆盖"
done
# Existing accounts are never repurposed.
! id opencode >/dev/null 2>&1 || fail "opencode 用户已存在，请先核实已有安装"
! awk -F: '$1=="opencode" {found=1} END {exit !found}' /etc/group || fail "opencode 组已存在"
parent=$(dirname "$data")
[ -d "$parent" ] || fail "请先挂载磁盘并创建父目录 $parent"
parent=$(CDPATH= cd -- "$parent" && pwd -P)
data="$parent/$(basename "$data")"
valid_data_path "$data" || fail "真实目录必须位于 /mnt 或 /opt 下"
[ "$(df -Pk "$parent" | awk 'END {print $4}')" -ge 524288 ] || fail "数据磁盘至少需要 512 MiB 可用空间"
[ -f "$script_dir/../files/opencode.init" ] && [ -f "$script_dir/../files/opencode-run" ] || fail "请复制完整项目"
# Firmware packages supply the musl runtime libraries; do not borrow Alpine libraries.
if command -v apk >/dev/null 2>&1; then
    apk update
    apk add curl ca-bundle jsonfilter libgcc libstdcpp ripgrep git-http shadow-useradd shadow-groupadd
elif command -v opkg >/dev/null 2>&1; then
    opkg update
    opkg install curl ca-bundle jsonfilter libgcc libstdcpp ripgrep git-http shadow-useradd shadow-groupadd
else
    fail "没有 apk/opkg"
fi
for tool in curl jsonfilter sha256sum tar useradd groupadd od; do
    command -v "$tool" >/dev/null 2>&1 || fail "依赖安装不完整: $tool"
done
# Stage on the persistent disk, not the router's RAM-backed /tmp.
build_dir=$(mktemp -d "$parent/.opencode-install.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
trap 'exit 1' HUP INT TERM
release=latest
[ -z "$version" ] || release="tags/v$version"
curl -fLsS --retry 3 "https://api.github.com/repos/$repo/releases/$release" -o "$build_dir/release.json" \
    || fail "$repo 没有可用 Release 或网络访问失败；不会自动回退到上游"
tag=$(jsonfilter -i "$build_dir/release.json" -e '@.tag_name')
case "$tag" in v*) ;; *) fail "无法解析官方版本" ;; esac
valid_version "${tag#v}" || fail "不支持的官方版本格式"
asset="opencode-linux-$target.tar.gz"
url=$(jsonfilter -i "$build_dir/release.json" -e "@.assets[@.name=\"$asset\"].browser_download_url")
digest=$(jsonfilter -i "$build_dir/release.json" -e "@.assets[@.name=\"$asset\"].digest")
case "$url" in "https://github.com/$repo/releases/download/"*) ;; *) fail "没有来自 $repo 的受支持资产" ;; esac
case "$digest" in sha256:*) checksum=${digest#sha256:} ;; *) fail "官方资产缺少 SHA256 digest，停止安装" ;; esac
[ "${#checksum}" = 64 ] || fail "非法校验值"
case "$checksum" in *[!a-fA-F0-9]*) fail "非法校验值" ;; esac
curl -fLsS --retry 3 "$url" -o "$build_dir/release.tar.gz"
printf '%s  %s\n' "$checksum" "$build_dir/release.tar.gz" | sha256sum -c -
tar -xzf "$build_dir/release.tar.gz" -C "$build_dir" opencode
[ -f "$build_dir/opencode" ] && [ ! -L "$build_dir/opencode" ] || fail "资产中没有普通二进制文件"
chmod 755 "$build_dir/opencode"
# Fail before creating service/user when the firmware ABI cannot run this release.
actual=$("$build_dir/opencode" --version) || fail "二进制无法运行；请检查 musl/运行库/内核兼容性"
[ "$actual" = "${tag#v}" ] || fail "二进制版本与 release 不一致"
password=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
[ "${#password}" = 48 ] || fail "生成密码失败"
umask 077
mkdir "$data"
mkdir -p "$data/bin" "$data/home" "$data/state" "$data/workspace"
cp "$build_dir/opencode" "$data/bin/opencode"
printf '%s\n' "$tag" > "$data/VERSION"
printf '%s\n' "$repo" > "$data/SOURCE"
groupadd --system opencode
useradd --system --gid opencode --home-dir "$data/home" --no-create-home --shell /bin/false opencode
# Root owns executable and top directory; the agent only owns writable state/workspace.
chmod 755 "$data" "$data/bin" "$data/bin/opencode"
chown opencode:opencode "$data/home" "$data/state" "$data/workspace"
chmod 700 "$data/home" "$data/state" "$data/workspace"
mkdir /etc/opencode
printf "OPENCODE_DATA='%s'\nOPENCODE_BIND='%s'\nOPENCODE_PORT='%s'\nOPENCODE_SERVER_PASSWORD='%s'\n" \
    "$data" "$bind" "$port" "$password" > /etc/opencode/service.conf
chmod 700 /etc/opencode
chmod 600 /etc/opencode/service.conf
mkdir -p /usr/libexec
cp "$script_dir/../files/opencode-run" /usr/libexec/opencode-run
cp "$script_dir/../files/opencode.init" /etc/init.d/opencode
chmod 755 /usr/libexec/opencode-run /etc/init.d/opencode
/etc/init.d/opencode start
# Verify both authentication enforcement and actual server health before enabling boot.
printf 'user = "opencode:%s"\n' "$password" > "$build_dir/curl.conf"
ready=0
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if curl --noproxy '*' -fsS --max-time 2 --config "$build_dir/curl.conf" \
        "http://$bind:$port/global/health" -o "$build_dir/health.json"; then
        healthy=$(jsonfilter -i "$build_dir/health.json" -e '@.healthy')
        server_version=$(jsonfilter -i "$build_dir/health.json" -e '@.version')
        if [ "$healthy" = true ] && [ "$server_version" = "${tag#v}" ]; then
            ready=1
            break
        fi
    fi
    sleep 1
done
code=$(curl --noproxy '*' -sS --max-time 2 -o /dev/null -w '%{http_code}' "http://$bind:$port/global/health" || true)
if [ "$ready" != 1 ] || [ "$code" != 401 ]; then
    /etc/init.d/opencode stop
    fail "启动/认证检查失败，已停止服务且未启用开机启动。文件保留供排查: logread -e opencode"
fi
/etc/init.d/opencode enable
echo "OpenCode $tag（$repo）原生服务启动与认证检查通过。访问 http://$bind:$port，用户名 opencode。"
echo "密码位于 /etc/opencode/service.conf（root 可读）。日志: logread -e opencode"
echo "请继续验证模型连接和项目会话；健康检查不代表业务验收。"
