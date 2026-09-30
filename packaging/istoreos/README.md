# OpenCode for iStoreOS（原生版）

基于 `agentx1boss/opencode` fork，在 iStoreOS 裸机上运行 OpenCode musl 二进制，以 procd 管理服务。无需 Docker、Node.js、npm 或另装 Bun。支持 x86_64 和 ARM64（aarch64），x64 使用 baseline 版本兼容没有 AVX2 的 CPU；不支持 MIPS 和 32 位 ARM。

目前交付原生安装脚本及服务文件；尚未上架 iStore、提供 LuCI 管理页或完成真机验收。官方 musl 构建在 iStoreOS 上的实际 ABI/内核兼容性需要验证，脚本会先执行版本检测，不能运行时停止安装服务。

## 一键安装

将完整项目复制到 iStoreOS，在路由器 SSH 终端以 root 执行：

```sh
sh packaging/istoreos/scripts/install.sh --bind 192.168.17.10 --data /mnt/sda1/opencode
```

`--bind` 填设备实际 LAN IPv4；`--data` 填已挂载持久磁盘下的全新目录，父目录必须存在。也可以使用 `/opt/opencode`，但应确认 `/opt` 的持久性及剩余容量。下载及解压在该磁盘进行，不占用 `/tmp` 内存盘。至少要求数据磁盘有 512 MiB 空间，实际项目及缓存需要额外空间；建议使用 2 GiB 以上内存的设备，这不是已测得的最低运行要求。

脚本自动使用固件的 `apk` 或 `opkg` 安装 curl、CA 证书、jsonfilter、libgcc、libstdcpp、ripgrep、git-http、shadow-useradd 和 shadow-groupadd。需要可用的固件软件源及 GitHub 网络访问；不复制 Alpine 运行库，不替换系统 musl。

可选参数：`--port 4096`、`--version <实际存在的官方版本号>`。默认从 `agentx1boss/opencode` 的 Release 下载；不指定版本时，先解析该仓库当前 release，再下载固定版本资产并核对 GitHub SHA256 digest。缺失 digest 时停止。fork 当前尚无 Release，因此默认安装要等首次发布后才能使用。

如需先验证固件兼容性，可显式添加 `--repo anomalyco/opencode` 使用上游 Release；这不会安装 fork 源码构建，也不会自动回退。数据目录的 `SOURCE` 文件记录二进制来源。

安装完成前会检测：二进制版本、服务健康响应、健康接口无密码访问返回 401。通过后才启用开机启动；模型连接与真实项目操作仍需验收。

打开 `http://192.168.17.10:4096`，用户名为 `opencode`。密码自动随机生成，仅写入 root 可读的配置：

```sh
cat /etc/opencode/service.conf
```

随后在 OpenCode Web 中连接模型提供商、设置模型凭据并创建项目会话。

## 原生运行结构

| 路径                         | 用途和权限                              |
| ---------------------------- | --------------------------------------- |
| `/etc/init.d/opencode`       | procd 服务，root 管理                   |
| `/usr/libexec/opencode-run`  | 进入项目目录后启动 Web，root 管理       |
| `/etc/opencode/service.conf` | 路径、地址、端口和密码，root 专用，0600 |
| `<data>/bin/opencode`        | 官方二进制，root 拥有                   |
| `<data>/VERSION`             | 已安装版本记录                          |
| `<data>/SOURCE`              | 发布资产来源仓库                        |
| `<data>/home`                | 独立用户 HOME                           |
| `<data>/state`               | XDG 配置、会话、模型凭据及缓存          |
| `<data>/workspace`           | 默认项目目录                            |

服务由独立的 `opencode` 用户和组运行，该用户禁用登录；只有 home、state 和 workspace 归其所有，权限 0700。安装器不会复用已有同名账户或覆盖已有路径。导入项目时需给 opencode 用户相应读写权限；父磁盘目录也必须允许它穿越。

procd 提供异常重启、开机启动、syslog 日志，以及 LAN 启动/磁盘挂载后的重试。持久磁盘应正确配置在 OpenWrt fstab 中。实际重启和挂载顺序仍需真机验证。

原生服务没有容器或文件系统沙箱：它能读取系统中普通用户可读的文件，能够执行代码和访问网络。独立用户限制权限，但不把访问范围严格限定在 workspace。脚本不修改防火墙或端口转发；仅绑定指定 LAN 地址。密码使用 HTTP Basic Auth，跨不可信网络访问时应通过 HTTPS 或 VPN。

## 管理

```sh
/etc/init.d/opencode status
/etc/init.d/opencode stop
/etc/init.d/opencode start
/etc/init.d/opencode restart
logread -e opencode
```

修改 `/etc/opencode/service.conf` 后重启生效，不要把密码贴到公开日志中。

当前安装器只处理首次安装，拒绝覆盖式升级。升级前停止服务并备份 state/home/workspace 和配置；下载新版本、核对 digest、验证兼容性后，以 root 原子替换二进制，再重启验证。正式 LuCI 版本应实现版本回退和自动升级流程。

安装失败时，下载临时目录会清理，但已安装的软件依赖、创建的账户和服务文件可能保留。健康/认证失败会停止服务且不启用开机启动。不要直接删除整个数据目录后重试；先检查日志和已有路径。

卸载服务、保留账户和所有项目/会话数据：

```sh
/etc/init.d/opencode stop
/etc/init.d/opencode disable
rm /etc/init.d/opencode /usr/libexec/opencode-run
```

此操作保留 `/etc/opencode/service.conf`、数据目录和独立账户。彻底删除或重新安装前应自行备份并处理这些保留项；不自动删除系统账户或共享依赖。

## 验证与 iStore 接入

在 `packaging/istoreos` 目录执行本地检查：

```sh
sh -n scripts/install.sh
sh -n files/opencode.init
python3 -m unittest discover -s tests -v
```

测试覆盖架构/参数拒绝、procd 用户及环境、缺失密码/磁盘拒绝启动，以及启动器的工作目录和参数传递。它们不代替 iStoreOS 运行验收。

真机应覆盖：x64/ARM64 ABI 兼容性、独立用户启动、密码拒绝/成功、真实模型会话、项目文件修改、设备重启、延迟挂载、磁盘空间不足、下载失败、端口冲突、重复安装和卸载保留数据。尚未在用户路由器上执行安装。

iStore 接入下一步为 `luci-app-opencode` 软件包：配置、安装任务、启动/停止、状态/日志、打开 Web、升级回退和保留数据的卸载。使用对应 iStoreOS SDK 构建，再按商店收录规则提交；本地脚本不会自动出现在官方商店中。

## 在这个 fork 上构建与发布

新增 `.github/workflows/istoreos-build.yml`，仅在 `agentx1boss/opencode` 手动触发。已有上游 publish 工作流带有 `github.repository == 'anomalyco/opencode'` 限制，不能直接在 fork 中发布。

新工作流使用现有 Bun 构建脚本，保留其默认完整构建流程，再收集 x64 baseline musl 和 ARM64 musl 两个目标；没有修改 OpenCode 核心源码。它包含嵌入 Web UI，不在路由器上编译。上传的 Actions artifact 包含两个二进制压缩包、原生安装器、SHA256SUMS、SOURCE_COMMIT、SOURCE_REPOSITORY 和 VERSION。工作流只有 read 权限，不会自动发布 Release、推送代码或改上游发行流程。当前尚未实际运行该工作流。

维护者应检查 artifact 并在对应源码提交上创建 fork Release，上传二进制资产及安装器。Release tag 必须是 `v<嵌入版本>`，资产名为 `opencode-linux-x64-baseline-musl.tar.gz` 和 `opencode-linux-arm64-musl.tar.gz`，压缩包根目录必须有 `opencode`。GitHub 发布资产后提供 digest，安装器使用该 digest 校验。Actions artifact 本身不是安装器可用的 Release。

发布后用户可下载 `opencode-istoreos-installer.tar.gz`，解压并在其中运行 `sh scripts/install.sh ...`。正式公网一行安装命令应引用固定版本及已校验的安装器；当前没有已发布 URL，因此不提供虚构下载链接。

## 官方依据

- [OpenCode 安装脚本](https://opencode.ai/install)：官方 release 与 musl/baseline 资产命名。
- [OpenCode 上游 Dockerfile](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/Dockerfile)：参考其 musl 二进制所需 libgcc/libstdc++/ripgrep，项目本身不使用 Docker。
- [OpenCode Web](https://opencode.ai/docs/web/) 与 [Server API](https://opencode.ai/docs/server/)：启动、密码认证和健康接口。
- [OpenWrt procd 源码](https://github.com/openwrt/openwrt/blob/main/package/system/procd/files/procd.sh)：用户切换、环境与重启/挂载触发器。
