# CentOS 7 Tencent Linux kernel Incus VM image

本仓库使用 `distrobuilder` 构建并启动验证一个固定范围的 Incus VM 镜像：

- 系统：CentOS Linux `7.9.2009`
- 架构：`amd64`（内核和 distrobuilder 使用 `x86_64`）
- 内核：Tencent Linux `5.4.119-19.0009.67.3`
- 类型：仅 VM
- 产物：`incus.tar.xz`、`disk.qcow2`、`SHA256SUMS`

镜像定义位于 [`images/standard.yaml`](images/standard.yaml)。构建、启动测试和
GHCR 发布由 [Build Incus VM image](.github/workflows/build-incus-vm.yml)
workflow 完成。发布后的独立网络验证由
[Test VM network on Incus managed bridge](.github/workflows/test-network-incus-managed.yml)
workflow 完成；复用 Docker 默认 bridge 和 NAT 的对照实验由
[Test VM network on Docker default bridge](.github/workflows/test-network-docker-default.yml)
workflow 完成。

## 固定内核

镜像不会启用 TencentOS 软件源，也不会安装会改变系统身份的 `tlinux-release`。
构建期间只下载以下三个固定 RPM，并同时验证 SHA-256 和 Tlinux RPM 签名：

| RPM | SHA-256 |
| --- | --- |
| `kernel-5.4.119-19.0009.67.3.tl2.x86_64.rpm` | `5faa0b0ac3fd74ba3d8357cb3a9a0358c1f2282d2a87288c3faf4b6a43c18581` |
| `kernel-core-5.4.119-19.0009.67.3.tl2.x86_64.rpm` | `5b551268d8de1ae3c6dd0f956131b49ac6a5e968516af0b688095dd1545bc78d` |
| `kernel-modules-5.4.119-19.0009.67.3.tl2.x86_64.rpm` | `18230ae693aa8e6e99e44ae0812fb8704d3cb4401cce0d4e27982841bf721c24` |

Tlinux 签名密钥指纹：

```text
D799 A819 89B1 9BC3 210E 2759 F30E D62F 1DAC 41D4
```

VM 启动后，workflow 会精确验证 `uname -r` 为
`5.4.119-19.0009.67.3`，并检查三个 RPM、默认 grub 内核、virtio 模块、
Incus agent 和网络。

独立网络 workflow 会把 runner 的全部可用 CPU 分配给 VM，并把总内存减去
`4 GiB` 后全部设置为 VM 内存上限。它验证 DHCP、默认路由、VM 与宿主的桥接
连通性、DNS，以及 VM 到腾讯镜像和 CentOS Vault 的 IPv4 HTTPS。

Docker bridge 对照 workflow 仅手动触发。它将 VM 网卡直接桥接到 `docker0`。
由于 Docker 默认网络不提供 DHCP，它在 `docker0` 上启动仅提供 DHCP 的
`dnsmasq`，并按本次 run 动态生成 MAC 和单一租约；VM 的转发和 NAT 则完全使用
Docker 的默认规则。

## GHCR 标签

CentOS 版本和内核版本由仓库配置固定，不再重复编码到 GHCR 标签中。tag 前缀取自
镜像定义文件名，`standard` 对应 [`images/standard.yaml`](images/standard.yaml)。每次
成功构建发布一个使用 12 位 Git 提交 ID 的可追溯标签，并更新 `standard-latest`：

```text
standard-latest
standard-sha-<git-commit-id-12>
```

发布地址：

```text
ghcr.io/lwmacct/260808-incus-bbiz-tx-centos7
```

## 拉取和导入

```bash
mkdir -p out/centos7-tkernel-vm
oras pull \
  --output out/centos7-tkernel-vm \
  ghcr.io/lwmacct/260808-incus-bbiz-tx-centos7:standard-latest
cd out/centos7-tkernel-vm
sha256sum --check SHA256SUMS
sudo incus image import \
  incus.tar.xz disk.qcow2 \
  --alias centos-7-tkernel-vm
```

该内核没有 9p，启动 VM 时必须挂载 Incus agent 配置光盘，同时关闭 Secure Boot：

```bash
sudo incus init centos-7-tkernel-vm centos7-tkernel \
  --vm \
  -c security.secureboot=false
sudo incus config device add centos7-tkernel agent disk source=agent:config
sudo incus start centos7-tkernel
```

## 生命周期和源码

> [!WARNING]
> CentOS 7 已于 2024-06-30 结束维护，Vault 中的软件包不再接收安全更新。
> 腾讯镜像当前也没有提供该内核精确版本对应的 SRPM。公开再分发镜像前，
> 应根据实际分发方式确认对应源码供应要求。

GHCR 中保存的是通用 OCI artifact，不是 SimpleStreams 树，不能直接作为
`incus remote add --protocol=simplestreams` 的地址。完整构建和验证说明见
[`docs/build.md`](docs/build.md)。
