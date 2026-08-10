# CentOS 7 + Tencent Linux 内核 Incus VM 镜像

本仓库使用 `distrobuilder` 构建 CentOS 7 Incus VM 镜像，并将同一系统 rootfs
封装为支持 Legacy BIOS 和 UEFI 的安装 ISO。构建、安装和启动验证均由 GitHub
Actions 完成。镜像范围如下：

- 系统：CentOS Linux `7.9.2009`
- 架构：`amd64`（内核和 distrobuilder 使用 `x86_64`）
- 内核 RPM：Tencent Linux `5.4.119-19.0006.tl2`
- 运行内核：`5.4.119-19-0006`
- 默认磁盘：`100 GiB`，其中固定 `60 GiB` 独立挂载到 `/pcdn_data/pcdn_index_data`
- 类型：Incus VM，并额外发布供安装 ISO 使用的 rootfs payload
- VM 产物：`incus.tar.xz`、`disk.qcow2`、`SHA256SUMS`
- 安装 payload：`rootfs.squashfs`、`rootfs-manifest.json`、`SHA256SUMS`
- ISO 产物：`installer.iso`、`iso-manifest.json`、`SHA256SUMS`

镜像定义位于 [`images/standard.yaml`](images/standard.yaml)。构建、启动测试和
GHCR 发布由 [Build Incus VM image](.github/workflows/build-images-standard.yml)
workflow 完成。发布后的独立网络验证由
[Test VM network on Incus managed bridge](.github/workflows/test-network-incus-managed.yml)
workflow 完成；复用 Docker 默认 bridge 和 NAT 的对照实验由
[Test VM network on Docker default bridge](.github/workflows/test-network-docker-default.yml)
workflow 完成。

网络设计、DHCP 限制和故障排查经验见 [`docs/network.md`](docs/network.md)。中国大陆
CentOS 7 Vault 镜像的实测结果、取舍和构建限制见
[`docs/centos7-mirrors-cn.md`](docs/centos7-mirrors-cn.md)。

## 中国大陆 yum 源

成品镜像将 CentOS 7.9.2009 的 `base`、`updates`、`extras` 固定到中国大陆
Vault 镜像池，按腾讯云、阿里云、华为云、南京大学和哈尔滨工业大学排列。所有
地址使用 HTTPS，RPM 继续使用 CentOS 官方密钥验证；任一镜像不可用时 yum 可以
尝试后续地址。构建时下载 Minimal ISO 仍受 `distrobuilder v3.3.1` 限制而使用
官方 `vault.centos.org`；构建期间的包安装也使用官方 Vault，只有镜像定制完成前
的最后 `post-files` 阶段才切换成品运行时 yum 到大陆源。

## 固定内核

镜像不会启用 TencentOS 软件源，也不会安装会改变系统身份的 `tlinux-release`。
构建期间只下载以下固定 RPM，并同时验证 SHA-256 和 Tlinux RPM 签名：

| RPM                                            | SHA-256                                                            |
| ---------------------------------------------- | ------------------------------------------------------------------ |
| `kernel-5.4.119-19.0006.tl2.x86_64.rpm`        | `6b3f5af7d3985d81e8bf07e4240b44f47aa1324f5f5b2517e2908091d91107fb` |

Tlinux 签名密钥指纹：

```text
D799 A819 89B1 9BC3 210E 2759 F30E D62F 1DAC 41D4
```

VM 启动后，workflow 会精确验证 `uname -r` 为
`5.4.119-19-0006`，并检查 RPM、默认 grub 内核、virtio 模块、Incus agent、
磁盘布局和网络。

该固定内核支持通用 BPF，但不支持 BPF LSM：包内配置没有 `CONFIG_BPF_LSM`，也
没有对应的 `security/bpf` 实现。因此不能仅通过 `lsm=bpf` 启动参数开启；需要
更换带有回移的内核包，或重建内核后再启用 BPF LSM。详细检查结果见
[`docs/build.md`](docs/build.md#bpf-lsm-支持状态)。

## 默认磁盘布局

成品 `disk.qcow2` 的虚拟容量固定为 `100 GiB`。第 1 分区为 `100 MiB` EFI，
第 2 分区为固定 `60 GiB` XFS 数据分区，第 3 分区为约 `39.9 GiB` 根分区。数据
分区的 GPT 分区标签为 `pcdn_index_data`，XFS 文件系统标签为 `pcdn_data`，通过
`PARTLABEL=pcdn_index_data` 写入 `/etc/fstab`，挂载到
`/pcdn_data/pcdn_index_data`。XFS 标签最多 12 个字符，因此不能直接使用完整
的 15 字符分区标签作为文件系统标签；格式化时关闭 Linux 5.4 不支持的新版 XFS
特性。

该虚拟容量也是 Incus 创建实例时的最小根盘容量；显式配置小于 `100 GiB` 的
实例或存储池 volume size 会被拒绝。根分区位于磁盘末尾，因此把实例根盘扩大到
`100 GiB` 以上后，新增空间与第 3 分区相邻，可用于扩展根分区和根文件系统；镜像
不会自动执行扩容。

独立网络 workflow 会把 runner 的全部可用 CPU 分配给 VM，并把总内存减去
`4 GiB` 后全部设置为 VM 内存上限。它验证 DHCP、默认路由、VM 与宿主的桥接
连通性、DNS，以及 VM 到腾讯 Tlinux 镜像和 CentOS 7 大陆 Vault 镜像的 IPv4
HTTPS。

Docker bridge 对照 workflow 仅手动触发。它将 VM 网卡直接桥接到 `docker0`。
由于 Docker 默认网络不提供 DHCP，它在 `docker0` 上启动仅提供 DHCP 的
`dnsmasq`，并按本次 run 动态生成 MAC 和单一租约；VM 的转发和 NAT 则完全使用
Docker 的默认规则。

## GHCR 标签

CentOS 版本和内核版本由仓库配置固定，不再重复编码到 GHCR 标签中。所有标签使用
`artifact-` 前缀，后接镜像定义文件名；`standard` 对应
[`images/standard.yaml`](images/standard.yaml)。每次成功构建发布一个使用 12 位 Git
提交 ID 的可追溯标签，并更新 `artifact-standard-latest`：

```text
artifact-standard-latest
artifact-standard-sha-<git-commit-id-12>
artifact-standard-stable
artifact-standard-installer-rootfs-latest
artifact-standard-installer-rootfs-sha-<git-commit-id-12>
artifact-standard-installer-rootfs-stable
```

`artifact-standard-stable` 不会随每次构建自动移动。通过
[Publish stable GHCR tag](.github/workflows/publish-stable.yml) 手动指定一个不可变
的 `artifact-standard-sha-*` 标签后，才会将它提升为 stable。

```bash
gh workflow run publish-stable.yml --ref main \
  -f source_tag=artifact-standard-sha-<git-commit-id-12>
```

发布地址：

```text
ghcr.io/lwmacct/260808-incus-bbiz-tx-centos7
```

安装 payload 从磁盘重排前的初始 VM 镜像只读导出。导出时同时挂载根分区和 EFI
分区，因此 `rootfs.squashfs` 包含 `/boot/efi`。v2 manifest 声明 rootfs 支持
`i386-pc` 和 `x86_64-efi` 两套 GRUB platform，不包含消费方的目标盘分区策略。
消费方必须使用 OCI digest 或
`artifact-standard-installer-rootfs-sha-*` 标签固定输入；`latest` 只用于发现新
版本，不能作为可发布 ISO 的构建输入。

## 拉取和导入

```bash
mkdir -p out/centos7-tkernel-vm
oras pull \
  --output out/centos7-tkernel-vm \
  ghcr.io/lwmacct/260808-incus-bbiz-tx-centos7:artifact-standard-latest
cd out/centos7-tkernel-vm
sha256sum --check SHA256SUMS
sudo incus image import \
  incus.tar.xz disk.qcow2 \
  --alias centos-7-tkernel-vm
```

该内核没有 9p，启动 VM 时必须挂载 Incus agent 配置光盘，同时关闭 Secure Boot：

```bash
sudo incus init centos-7-tkernel-vm centos7-tkernel --vm \
  -c security.secureboot=false
sudo incus config device add centos7-tkernel agent disk source=agent:config
sudo incus start centos7-tkernel
sudo incus exec centos7-tkernel -- findmnt /pcdn_data/pcdn_index_data
```

安装 payload 的拉取方式：

```bash
mkdir -p out/centos7-tkernel-installer-rootfs
oras pull \
  --output out/centos7-tkernel-installer-rootfs \
  ghcr.io/lwmacct/260808-incus-bbiz-tx-centos7:artifact-standard-installer-rootfs-sha-<git-commit-id-12>
cd out/centos7-tkernel-installer-rootfs
sha256sum --check SHA256SUMS
jq . rootfs-manifest.json
```

## 安装 ISO

ISO 构建器位于 [`isobuild/`](isobuild)，安装合同位于
[`isobuild/config/install.env`](isobuild/config/install.env)。同一 ISO 支持 Legacy BIOS 和 UEFI；
安装器会写入 `i386-pc` GRUB、`x86_64-efi` GRUB 和 UEFI fallback loader，Secure
Boot 必须关闭。

当前默认合同要求目标盘至少为 `100 GiB`，使用 GPT，包含 BIOS Boot 分区、EFI
System Partition、固定 `60 GiB` XFS 数据分区和使用剩余空间的 ext4 根分区。数据
分区继续使用 `PARTLABEL=pcdn_index_data`、文件系统标签 `pcdn_data`，并挂载到
`/pcdn_data/pcdn_index_data`。交互安装要求二次确认目标盘并现场设置 root 密码；
CI 自动安装会锁定 root，且不写入固定凭据。

[Build and test installer ISO](.github/workflows/build-installer-iso.yml) 在以下场景执行
完整构建和 QEMU 测试：

1. ISO 构建器变更的 pull request 和 `main` push 使用已固定 digest 的基线 payload。
2. [Build Incus VM image](.github/workflows/build-images-standard.yml) 成功后，通过
   `workflow_run` 将对应 `artifact-standard-installer-rootfs-sha-*` 标签解析成 OCI
   digest，再构建 ISO。
3. 手动触发时必须显式传入不可变的 rootfs OCI digest。

workflow 会检查 ISO 的 BIOS/UEFI El Torito 启动项，分别启动 SeaBIOS 和 OVMF，
自动安装到空白 qcow2，然后让同一安装盘分别通过 Legacy BIOS 和 UEFI 启动。pull
request 只构建和测试；可信 `main` 事件通过全部验证后只发布到 GHCR，不创建
GitHub Actions artifact：

```text
artifact-standard-iso-<iso-commit12>-source-<payload-commit12>
artifact-standard-iso-latest
artifact-standard-iso-stable
```

手动构建和稳定版提升：

```bash
gh workflow run build-installer-iso.yml --ref main \
  -f payload_ref=ghcr.io/lwmacct/260808-incus-bbiz-tx-centos7@sha256:<digest>
gh workflow run publish-installer-iso-stable.yml --ref main \
  -f source_tag=artifact-standard-iso-<iso-commit12>-source-<payload-commit12>
```

本地只运行语法和纯逻辑检查，镜像构建及 QEMU 集成测试留在 CI：

```bash
task isobuild:lint
# 或
bash isobuild/scripts/lint.sh
```

## 生命周期和源码

> [!WARNING]
> CentOS 7 已于 2024-06-30 结束维护，Vault 中的软件包不再接收安全更新。
> 腾讯镜像当前也没有提供该内核精确版本对应的 SRPM。公开再分发镜像前，
> 应根据实际分发方式确认对应源码供应要求。

GHCR 中保存的是通用 OCI artifact，不是 SimpleStreams 树，不能直接作为
`incus remote add --protocol=simplestreams` 的地址。完整构建和验证说明见
[`docs/build.md`](docs/build.md)。
