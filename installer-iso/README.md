# CentOS 7 + Tencent Linux 内核安装 ISO

本仓库将
[`260808-incus-bbiz-tx-centos7`](https://github.com/lwmacct/260808-incus-bbiz-tx-centos7)
发布的安装 rootfs 封装为 BIOS/UEFI hybrid 安装 ISO。系统固定为 CentOS Linux `7.9.2009`
AMD64，运行内核固定为 Tencent Linux `5.4.119-19-0006`。

安装 ISO 只包含基础系统和安装工具，不包含 `m-netctl`、`suprce`、Docker、固定
密码、自动登录或参考项目中的业务服务。

## 安装合同

- 同一 ISO 支持 Legacy BIOS 和 UEFI；Secure Boot 必须关闭。
- 目标磁盘最小 `100 GiB`。
- 第 1 分区：`2 MiB` GPT BIOS Boot，无文件系统。
- 第 2 分区：`256 MiB` FAT32 EFI System Partition。
- 第 3 分区：固定 `60 GiB` XFS，GPT `PARTLABEL=pcdn_index_data`，文件系统标签 `pcdn_data`。
- 第 4 分区：剩余空间，ext4 根分区。
- 数据分区挂载到 `/pcdn_data/pcdn_index_data`。
- 交互安装要求二次确认目标磁盘，并现场设置 root 密码。
- 自动 CI 安装锁定 root，不写入任何固定凭据。

安装会完全擦除选中的目标磁盘。安装器会同时写入 BIOS GRUB 和 UEFI fallback
loader，因此同一块安装盘可分别由 Legacy BIOS 或 UEFI 启动。

## 构建输入

上游 payload 包含：

```text
rootfs.squashfs
rootfs-manifest.json
SHA256SUMS
```

可发布构建只接受固定 OCI digest：

```text
ghcr.io/lwmacct/260808-incus-bbiz-tx-centos7@sha256:<digest>
```

`latest` 标签只用于发现版本，不能作为 ISO 构建输入。

## CI 构建和测试

手动触发：

```bash
gh workflow run build-installer-iso.yml \
  --ref main \
  -f payload_ref=ghcr.io/lwmacct/260808-incus-bbiz-tx-centos7@sha256:<digest>
```

workflow 将执行：

1. 校验 payload digest、manifest、SHA-256、内核和安装合同。
2. 使用 Ubuntu 24.04 Live 环境构建 BIOS/UEFI hybrid ISO。
3. 检查 BIOS 和 UEFI El Torito 启动项及 ISO 文件结构。
4. 分别使用 QEMU SeaBIOS 和 OVMF 验证 ISO 能启动。
5. 使用 SeaBIOS 安装到空白 `100 GiB` qcow2。
6. 移除 ISO 后，让同一安装盘分别由 SeaBIOS 和 OVMF 启动，验证内核、四分区、XFS、fstab、DHCP 和 machine-id。
7. 确认 BIOS GRUB、UEFI fallback loader 均可用，Incus agent 未启用，且不存在被排除的软件。
8. 所有测试通过后才上传 Actions artifact 并发布到 GHCR。

## GHCR 产物

```text
artifact-standard-iso-<iso-commit12>-source-<payload-commit12>
artifact-standard-iso-latest
artifact-standard-iso-stable
```

OCI artifact 包含：

```text
installer.iso
iso-manifest.json
SHA256SUMS
```

`stable` 只通过独立 workflow 从已经完整测试的版本手动提升。

## 本地检查

本地只运行语法和纯逻辑检查：

```bash
task ci:lint
# 或
bash scripts/lint.sh
```

完整 Live rootfs 构建、ISO 打包、自动安装和启动测试应在 GitHub Actions 中执行。
