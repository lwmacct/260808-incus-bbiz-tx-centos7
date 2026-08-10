# CentOS 7 ext4 构建兼容性

本文说明本仓库为什么需要
[`images/mke2fs-centos7.conf`](../images/mke2fs-centos7.conf)，它如何影响
`mkfs.ext4`，以及升级 runner、e2fsprogs、distrobuilder、GRUB 或内核时应如何验证。

## 结论

Incus VM 的初始根文件系统不是由 CentOS 7 自己创建，而是由 GitHub Actions
`ubuntu-26.04` runner 上的 distrobuilder 调用宿主 `mkfs.ext4` 创建。文件系统的
默认特性因此取决于 runner 的 e2fsprogs 版本，而不是镜像内的 CentOS 版本。

2026-08-10 的 runner 使用 `mke2fs 1.47.2`，其默认配置会启用
`metadata_csum_seed` 和 `orphan_file` 等比 CentOS 7 更新的特性。这个默认值曾导致
镜像内的 CentOS 7 GRUB 报 `unknown filesystem`，在根分区移动后又表现为无法按
文件系统 UUID 找到根分区。

当前方案在运行 distrobuilder 时通过 `MKE2FS_CONFIG` 指定 CentOS 7 兼容配置，
并在磁盘重排前检查实际根文件系统不包含超出项目兼容基线的特性。

## 两条 mkfs.ext4 路径

仓库中存在两条相互独立的 `mkfs.ext4` 调用路径，不能混为同一配置所有者。

| 路径 | 执行环境 | 用途 | 当前兼容措施 |
| --- | --- | --- | --- |
| distrobuilder VM | Ubuntu 26.04 runner | 创建 Incus VM 初始根分区 | 使用 `images/mke2fs-centos7.conf` |
| ISO 安装器 | ISO 内的 Ubuntu 24.04 live 系统 | 格式化用户目标盘根分区 | 使用 Noble e2fsprogs 默认值，并做 BIOS/UEFI 实机测试 |

Ubuntu 24.04 的 `e2fsprogs 1.47.0` 默认启用 `metadata_csum`，但不启用
`metadata_csum_seed` 和 `orphan_file`。当前 ISO CI 已证明该组合可以由目标系统的
Legacy BIOS 和 UEFI GRUB 启动。`images/mke2fs-centos7.conf` 因此只属于 VM 镜像
生产链，不属于 `isobuild/`。

如果将来升级 ISO live 系统后出现同类问题，应为 ISO 安装器单独固定格式化特性，
而不是假设 runner 上的 `MKE2FS_CONFIG` 会被打包进 ISO。

## 故障过程

原始失败由以下步骤共同触发：

1. Ubuntu 26.04 的 `mkfs.ext4` 使用宿主默认特性创建约 `40 GiB` 根文件系统。
2. distrobuilder 把 CentOS 7 文件复制进去，并在 chroot 中生成 GRUB 配置。
3. CentOS 7 的 `grub2-probe` 无法识别该文件系统，输出：

   ```text
   /usr/sbin/grub2-probe: error: unknown filesystem.
   ```

4. 后处理把根分区从 GPT 第 2 分区移动到第 3 分区，并把第 2 分区改为 XFS 数据盘。
5. UEFI GRUB 需要按文件系统 UUID 重新定位根分区，但无法解析根 ext4，最终输出：

   ```text
   error: no such device: <root-filesystem-uuid>.
   error: file `/boot/vmlinuz-5.4.119-19-0006' not found.
   Failed to boot both default and fallback entries.
   ```

只把 GRUB 的 `root` 硬编码为 `(hd0,gpt3)` 不能完整解决问题。GRUB 即使定位到正确
分区，仍必须解析 ext4 才能读取 `/boot/vmlinuz-*` 和 initramfs；内核启动后也必须
能够挂载同一个根文件系统。

## 配置如何生效

workflow 只为 distrobuilder 进程及其子进程设置环境变量：

```bash
sudo env \
  MKE2FS_CONFIG="${GITHUB_WORKSPACE}/images/mke2fs-centos7.conf" \
  distrobuilder build-incus ...
```

这不会覆盖 runner 的 `/etc/mke2fs.conf`，也不会影响 workflow 中其他
`mkfs.ext4` 调用。distrobuilder v3.3.1 随后执行自身固定的 `mkfs.ext4` 命令，
e2fsprogs 从 `MKE2FS_CONFIG` 指定的文件读取默认特性。

当前配置基于 CentOS 7.9.2009 官方
`e2fsprogs-1.42.9-19.el7.x86_64` 包中的 `mke2fs.conf`，核心 ext4 特性集为：

```text
has_journal extent huge_file flex_bg uninit_bg dir_nlink extra_isize 64bit
```

配置中的 `small`、`floppy`、`big`、`huge`、`largefile` 和 `largefile4` 只定义不同
容量下的 inode 和 block 默认值，避免现代 e2fsprogs 在自动选择文件系统类型时回退
到宿主配置。它们不会重新加入被排除的新 ext4 特性。

## 特性基线

以下表格描述本项目的策略，而不是断言每个单独特性在所有 CentOS 7 GRUB 补丁版本
上都必然失败。

| 特性 | Ubuntu 26.04 默认 | 当前 VM 根分区 | 处理理由 |
| --- | --- | --- | --- |
| `metadata_csum` | 启用 | 禁用 | 回到 CentOS 7 原生格式基线，减少旧 GRUB 差异 |
| `metadata_csum_seed` | 启用 | 禁用 | 不属于 CentOS 7 原生格式基线 |
| `orphan_file` | 启用 | 禁用 | 新于固定的 5.4 内核和 CentOS 7 用户态基线 |
| `uninit_bg` | 未显式启用 | 启用 | CentOS 7 官方 ext4 默认特性 |
| `64bit` | 启用 | 启用 | CentOS 7 官方配置已启用，当前 GRUB 和内核测试通过 |

已观察到的故障来自 Ubuntu 26.04 默认特性的组合。当前策略选择完整复用 CentOS 7
原生特性集，而不是只删除当时最可疑的单个 feature。这样更容易审计，也避免下次
e2fsprogs 默认值改变时重新猜测兼容边界。

## CI 门禁

[`scripts/prepare-vm-data-partition.sh`](../scripts/prepare-vm-data-partition.sh) 在移动根
分区前会只读连接实际根文件系统，使用 `tune2fs -l` 读取 `Filesystem features`，
并拒绝以下特性：

```text
metadata_csum
metadata_csum_seed
orphan_file
```

这道检查验证的是 distrobuilder 的实际输出，不只是配置文件文本。即使环境变量失效、
路径写错或未来 distrobuilder 改变调用方式，workflow 也会在发布前失败。

后续 CI 还会：

1. 把根分区迁移到 GPT 第 3 分区；
2. 生成按文件系统 UUID 搜索根分区的 GRUB 配置；
3. 将 qcow2 导入 Incus 并通过 UEFI 启动；
4. 验证固定内核、根分区号、数据分区、agent 和网络；
5. 使用安装 ISO 分别完成 Legacy BIOS 与 UEFI 启动测试。

只有这些检查全部通过后才会发布 GHCR 标签。

## 本地逻辑验证

本地不需要构建完整 VM。可以创建一个小型文件系统，确认配置没有产生被禁止的特性：

```bash
_test_dir=$(mktemp -d)
truncate -s 128M "${_test_dir}/root.ext4"
MKE2FS_CONFIG="$PWD/images/mke2fs-centos7.conf" \
  mkfs.ext4 -F "${_test_dir}/root.ext4"
tune2fs -l "${_test_dir}/root.ext4" \
  | sed -n 's/^Filesystem features:[[:space:]]*//p'
```

预期包含 `uninit_bg` 和 `64bit`，不包含：

```text
metadata_csum metadata_csum_seed orphan_file
```

完整的 GRUB、固定内核和 Incus 启动兼容性仍以 GitHub Actions KVM 测试为准。

## 排障

先检查 workflow 是否确实传入配置：

```bash
rg -n 'MKE2FS_CONFIG|mke2fs-centos7.conf' \
  .github/workflows/build-images-standard.yml
```

再检查配置与门禁是否一致：

```bash
rg -n 'metadata_csum|metadata_csum_seed|orphan_file|uninit_bg' \
  images/mke2fs-centos7.conf scripts/prepare-vm-data-partition.sh
```

常见现象及判断：

| 现象 | 优先检查 |
| --- | --- |
| `grub2-probe: unknown filesystem` | 实际 ext4 features、`MKE2FS_CONFIG` 路径 |
| `error: no such device: <uuid>` | GRUB 是否能解析 ext4、UUID 是否来自实际根文件系统 |
| `/boot/vmlinuz-* not found` | GRUB `root` 是否指向移动后的根分区 |
| 根分区门禁输出 `Unsupported CentOS 7 ext4 feature` | distrobuilder 是否使用了宿主默认配置 |
| Incus agent 等待超时 | 先看串口中的 GRUB、initramfs 或 kernel panic，不要先归因于 agent |

## 其他方案

| 方案 | 优点 | 问题 |
| --- | --- | --- |
| 给 distrobuilder 增加 `mkfs.ext4 -O ...` | 参数最直观 | v3.3.1 没有暴露该配置，需要维护 fork 或补丁 |
| 在 `PATH` 前放置 `mkfs.ext4` 包装器 | 不修改 distrobuilder 源码 | 命令劫持隐蔽，容易漏传参数或递归调用 |
| 固定旧版 e2fsprogs 或旧构建容器 | 默认行为接近 CentOS 7 | 增加软件供应链和运行环境维护成本 |
| 构建后用 `tune2fs` 删除特性 | 不影响 mkfs 阶段 | 需要卸载文件系统并运行 e2fsck，部分特性不适合事后切换 |
| 使用独立兼容 `/boot` 分区 | GRUB 不必读取现代根 ext4 | 增加分区和安装逻辑，固定 5.4 内核仍需支持根 ext4 |
| 升级 GRUB 和内核 | 可以扩大 ext4 特性范围 | 改变当前 CentOS 7/TKernel 固定成品合同 |

当前 `MKE2FS_CONFIG + 实际特性门禁 + KVM 启动测试` 的组合改动最小，且能同时防止
配置漂移和运行时回归。

## 升级检查清单

以下任一项变化时，都应重新执行完整 CI：

- GitHub runner 从 `ubuntu-26.04` 升级到新镜像；
- e2fsprogs 或其 `/etc/mke2fs.conf` 默认值变化；
- distrobuilder 版本或 VM 文件系统创建逻辑变化；
- CentOS GRUB、shim 或 TKernel 版本变化；
- 根分区布局、移动方式或 GRUB UUID 搜索逻辑变化；
- ISO live 系统从 Ubuntu 24.04 升级。

不要只根据 `mkfs.ext4` 命令成功或 `tune2fs` 输出就删除兼容配置。至少应确认 Incus
UEFI 启动、Legacy BIOS 安装启动、UEFI 安装启动和固定内核根挂载均通过。
