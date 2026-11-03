# 2BRobust BBRv1 模块安装器

推荐在 **Debian 12** 上使用本仓库。它提供一个针对正在运行内核且 BBRv1 可编译为模块的安装脚本：脚本会自动检测 `uname -r`，下载并校验对应的上游 Linux 源码，再下载、校验并应用 [2BRobust 作者官方仓库](https://github.com/sys-uos/bbr-cpu-contention) 的 BBRv1 补丁，最后在本机编译 `tcp_bbr.ko`，以可回退的模块更新方式安装、加载和验证。

它使用论文《2BRobust — Mitigating TCP BBR Performance Degradation in Virtual Machines under CPU Contention》提供的官方 BBRv1 补丁。

## 使用方式

在 Debian 12 目标主机上克隆本仓库后运行：

```bash
chmod +x install-2brobust.sh
sudo ./install-2brobust.sh
```

安装脚本会：

1. 检查正在运行的内核，并检查 `/lib/modules/$(uname -r)/build` 里有对应的配置和符号版本信息。
2. 安装所需的构建依赖；若缺少 `/lib/modules/$(uname -r)/build`，会自动安装精确匹配的 `linux-headers-$(uname -r)`（默认使用 `apt-get`；其他发行版可自行准备依赖后加 `--skip-deps`）。
3. 从作者官方仓库下载固定提交 `8055052d8d7770fd20f4e0db1182c9ea975398c4` 的 `patches/bbr1.patch`，并用内置 SHA-256 校验其内容。
4. 从 `uname -r` 自动提取数字内核版本并从 kernel.org 下载相应源码；先取得 kernel.org 的官方 SHA-256 清单，再校验下载内容。
5. 对源码先做补丁 dry-run，再应用补丁；复用正在运行内核的 `.config` 和 `Module.symvers`，将 `CONFIG_TCP_CONG_BBR=m` 编译为模块。
6. 将新的模块安装到 `/lib/modules/$(uname -r)/updates/2brobust/net/ipv4/tcp_bbr.ko`，不覆盖发行版原始模块；随后执行 `depmod`。`updates/` 目录会优先于原始 `kernel/` 目录被 `modprobe` 选中。
7. 配置 `fq` 和 `bbr` 为持久默认值，并尝试在当前会话卸载旧模块、加载新模块，最后验证模块路径、加载状态、可用拥塞控制、默认拥塞控制和默认 qdisc。

构建缓存默认位于 `/usr/local/src/2brobust`；成功后临时构建目录会清理，下载的两个已校验文件保留以便下次运行使用。若需要保留完整构建树：

```bash
sudo ./install-2brobust.sh --keep-workdir
```

仅验证已安装状态：

```bash
sudo ./install-2brobust.sh --verify
```

## 前置条件与限制

- 必须在要安装的 **正在运行的** 内核上执行。脚本从 `uname -r` 自动提取上游版本，例如 `6.12.94-amd64` 会使用 `6.12.94` 源码。非标准版本可明确指定：`sudo env KERNEL_VERSION=6.12.94 ./install-2brobust.sh`。
- 对于发行版内核的 ABI 后缀，例如 `6.12.95+deb12-amd64`，脚本会使用 `6.12.95` 上游源码，并自动将 `+deb12-amd64` 写入构建配置，以确保生成模块的 vermagic 与正在运行的内核完全一致。
- `/lib/modules/$(uname -r)/build` 必须是与当前内核精确匹配的、已配置的 build tree，至少包含 `.config`；若启用了 `CONFIG_MODVERSIONS`，还必须包含 `Module.symvers`。默认流程会尝试通过 APT 安装 `linux-headers-$(uname -r)`；若你的内核来自自定义仓库，须先在该仓库提供相同版本的 headers。这正是模块 ABI 匹配所需的信息。
- 补丁先做 dry-run：只要目标内核的 BBRv1 源码与官方补丁不兼容，脚本就会在编译或安装前停止，不会生成或加载不匹配的模块。
- Linux 源码大小取决于当前版本；编译还需要额外磁盘空间和内存。
- 如果当前有 BBR TCP 连接（包括使用 BBR 的 SSH 会话），`tcp_bbr` 可能无法卸载。脚本会恢复原来的运行时默认拥塞控制、保留已安装的新模块而不会覆盖原模块，并以退出码 `2` 结束；关闭相关连接后重跑，或重启后执行 `sudo ./install-2brobust.sh --verify`。
- 启用 Secure Boot 时，内核可能拒绝未签名的自编译模块。请按本机的 MOK/模块签名策略给模块签名后再加载。

## 回退

恢复系统自带模块不会删除任何文件：删除更新模块、重新生成依赖并重启或重新加载模块即可。

```bash
sudo rm -f /lib/modules/$(uname -r)/updates/2brobust/net/ipv4/tcp_bbr.ko
sudo depmod -a $(uname -r)
sudo reboot
```

如不再希望默认启用 BBR/FQ，还应删除 `/etc/sysctl.d/99-2brobust.conf`，然后执行 `sudo sysctl --system`。

## 来源与完整性

- 官方补丁仓库：<https://github.com/sys-uos/bbr-cpu-contention>
- 固定官方提交：`8055052d8d7770fd20f4e0db1182c9ea975398c4`
- 官方 BBRv1 补丁 SHA-256：`07714e80b8b6af314361b2d1bdcaae02aa38004a15d0e954929cb50abe2fc163`
- Linux 源码与 SHA-256 清单均从对应的 <https://cdn.kernel.org/pub/linux/kernel/> 版本目录获取。

上述补丁固定提交和 hash 是刻意设计：官方仓库更新时，脚本不会在没有审核的情况下自动改用新补丁。

本仓库中的自动化脚本以 [MIT License](LICENSE) 发布；2BRobust 官方仓库中的代码许可请以其仓库中的声明为准。
