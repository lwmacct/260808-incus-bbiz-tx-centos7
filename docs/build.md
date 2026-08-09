# 镜像构建与发布

本仓库通过 [Build Incus VM image](../.github/workflows/build-images-standard.yml)
workflow 构建、启动验证并发布 CentOS 7.9.2009 AMD64 Incus VM 镜像。成品内核
固定为 Tencent Linux `5.4.119-19-0006`，默认磁盘容量为 `100 GiB`。

网络方案、DHCP 限制和故障排查经验见 [`docs/network.md`](network.md)。

## 触发方式

| 方式 | 条件 |
| --- | --- |
| Push | 向 `main` 推送镜像定义、磁盘处理脚本或 workflow 修改 |
| Manual | 在 Actions 页面运行 workflow，或使用 GitHub CLI |

手动触发并等待结果：

```bash
gh workflow run build-images-standard.yml --ref main
gh run list --workflow build-images-standard.yml --limit 10
gh run watch <run-id> --exit-status
```

构建范围固定为：

```text
CentOS Linux 7.9.2009 / tkernel 5.4.119-19-0006 / amd64 / default / VM
```

## 构建流程

1. 在 GitHub `ubuntu-24.04` AMD64 runner 上配置 Zabbly Incus stable，安装 Incus、QEMU、OVMF 和构建依赖。
2. 编译并缓存固定版本的 `distrobuilder v3.3.1`。
3. 验证 `images/standard.yaml`，从官方 CentOS Vault 下载并校验 Minimal ISO。
4. 使用 `distrobuilder build-incus --vm --type=split` 构建初始 `40 GiB` 镜像；构建期间所有 CentOS 包使用官方 Vault，构建动作从腾讯镜像下载固定的单体 `kernel` RPM；最后的 `post-files` 阶段才把成品 yum 切换到中国大陆镜像池。
5. 校验 RPM 的固定 SHA-256，并使用内嵌 Tlinux 公钥验证 RSA/SHA256 签名。
6. 安装内核，显式运行 `depmod`、`dracut` 和 grub 配置，并把该版本设为默认内核。
7. 输出 Incus 元数据和 qcow2 磁盘文件，再把磁盘扩展到 `100 GiB`，在尾部创建并格式化约 `60 GiB` 的 XFS `pcdn_index_data` 分区。
8. 对 `disk.qcow2` 执行完整性和虚拟容量检查，将镜像导入 Incus，挂载 agent 配置光盘并关闭 Secure Boot 启动。
9. 验证系统身份、架构、RPM、`uname -r`、默认 grub 内核、virtio 模块、数据分区、Incus agent 和 IPv4 网络。
10. 生成 `SHA256SUMS`，通过 ORAS 发布到 GHCR。

## 独立网络实验

[Test VM network on Incus managed bridge](../.github/workflows/test-network-incus-managed.yml)
workflow 在每次镜像构建 workflow 成功后自动运行，也可以手动指定 GHCR 标签：

```bash
gh workflow run test-network-incus-managed.yml --ref main
```

该 workflow 不重新构建镜像，而是从 GHCR 拉取发布产物并验证 `SHA256SUMS` 和
qcow2 完整性，然后导入 Incus。默认测试 `artifact-standard-latest`；复现特定
构建时可传入 `-f image_tag=artifact-standard-sha-<git-commit-id-12>`。VM 使用
runner 的全部 `nproc` CPU，总内存则按 `MemTotal - 4 GiB` 设置，给宿主和
Incus/QEMU 管理进程保留 `4 GiB`。

网络实验依次验证：

1. Incus agent 和固定内核可以正常启动。
2. 总磁盘为 `100 GiB`，数据分区独立挂载、容量约 `60 GiB` 且可以读写。
3. VM 中在线 CPU 数和内存容量符合动态资源分配。
4. VM 通过 DHCP 获得全局 IPv4 地址和默认路由。
5. VM 可以访问桥接网关，runner 宿主也可以访问 VM IPv4。
6. VM 可以通过 DNS 解析腾讯镜像和 CentOS 7 大陆 Vault 镜像。
7. VM 可以通过 IPv4 HTTPS 下载两个仓库的 `repomd.xml`。

### Docker 默认 bridge 对照实验

[Test VM network on Docker default bridge](../.github/workflows/test-network-docker-default.yml)
workflow 仅手动触发。它将 Incus VM 的 tap 设备直接桥接到 `docker0`，不添加额外
的 iptables 转发规则。Docker 默认 bridge 不提供 DHCP，因此该实验在 `docker0`
上启动一个仅提供 DHCP 的 `dnsmasq`，从 Docker IPAM 子网末端选择未占用地址，
并按本次 run 动态生成 MAC 和单一租约。数据转发和 NAT 仍使用 Docker 默认规则。

```bash
gh workflow run test-network-docker-default.yml --ref main
```

该方案适合临时 CI runner。长期共享宿主需要为 Docker IPAM 与 DHCP 配置互不
重叠的地址池，避免 Docker 后续分配与 DHCP lease 冲突。

构建得到：

```text
incus.tar.xz
disk.qcow2
SHA256SUMS
```

## Stable 标签发布

[Publish stable GHCR tag](../.github/workflows/publish-stable.yml) 只允许手动触发。
它从指定的不可变 `artifact-standard-sha-<git-commit-id-12>` 标签提升并覆盖
`artifact-standard-stable`，然后校验两个标签指向相同 digest：

```bash
gh workflow run publish-stable.yml --ref main \
  -f source_tag=artifact-standard-sha-<git-commit-id-12>
```

## 内核信任和固定

运行时需要一个单体内核包：

```text
kernel-5.4.119-19.0006.tl2.x86_64
```

对应 SHA-256：

```text
6b3f5af7d3985d81e8bf07e4240b44f47aa1324f5f5b2517e2908091d91107fb  kernel-5.4.119-19.0006.tl2.x86_64.rpm
```

公钥取自腾讯官方 `tlinux-release-2-13.tl2.3.x86_64.rpm`，指纹为：

```text
D799 A819 89B1 9BC3 210E 2759 F30E D62F 1DAC 41D4
```

镜像不安装 `tlinux-release`，也不保留 Tlinux yum 仓库，从而避免改变
`/etc/os-release` 或把固定内核自动升级到其他小版本。

RPM 的 release 使用点号 `19.0006`，但包内内核 release 和 `uname -r` 使用
连字符 `5.4.119-19-0006`。

## 默认磁盘布局

`distrobuilder v3.3.1` 只能创建 EFI 和单一根分区，因此镜像定义先生成 `40 GiB`
磁盘。构建 workflow 随后通过
[`prepare-vm-data-partition.sh`](../scripts/prepare-vm-data-partition.sh) 将 qcow2 转为
稀疏 raw、扩展到 `100 GiB`、修复 GPT 备用表位置并创建第三分区，最后重新压缩为
qcow2。

第三分区使用全部尾部空间，格式化为 XFS，GPT 分区标签为 `pcdn_index_data`，
XFS 文件系统标签为 `pcdn_data`，并通过 `PARTLABEL=pcdn_index_data` 挂载到
`/pcdn_data/pcdn_index_data`。XFS 文件系统标签最多 12 个字符；扩大实例根盘只会
增加磁盘尾部未分配空间，不会自动扩大该分区。

## Incus 兼容性

该内核内置 virtio block、virtio PCI 和 `virtio_scsi`，并将 `virtio_console`、
`virtio_net`、`virtiofs` 编译为模块。镜像定义通过 dracut 显式加入启动和 agent
设备所需的 `virtio_scsi`、`virtio_console`；网络和 virtiofs 模块在根文件系统
挂载后按需加载。

该内核未启用 9p，而 Incus 默认使用 9p 提供 agent 配置。因此镜像元数据设置
`requirements.cdrom_agent=true`，启动实例前必须添加
`disk source=agent:config` 设备。CI 使用该配置光盘启动 agent，并直接验证
agent 可用性。

CentOS 7 的旧 shim 和该内核不纳入当前 Secure Boot 信任链，因此测试和使用时
必须设置 `security.secureboot=false`。

## 上游和源码边界

CentOS 镜像定义派生自 `lxc/lxc-ci` commit
[`5826c344bfac81dbdef0d54f56ef90d907bd2591`](https://github.com/lxc/lxc-ci/commit/5826c344bfac81dbdef0d54f56ef90d907bd2591)，
并固定到 CentOS Vault `7.9.2009`。构建期间使用官方 Vault，成品的 yum 配置使用
中国大陆镜像池；调查和
`distrobuilder v3.3.1` 对构建 ISO 源的限制见
[`centos7-mirrors-cn.md`](centos7-mirrors-cn.md)。

腾讯 RPM 元数据声明的对应源码包是
`kernel-5.4.119-19.0006.tl2.src.rpm`，但腾讯镜像当前没有提供该文件。
这不影响二进制安装和签名验证，但不能从公开 SRPM 重现该内核。公开再分发前应
根据实际分发方式确认对应源码供应要求。

## 发布和权限

workflow 只申请：

```yaml
permissions:
  contents: read
  packages: write
```

发布使用仓库自带的 `GITHUB_TOKEN`，不需要额外 registry secret。所有成功产物
发布到：

```text
ghcr.io/lwmacct/260808-incus-bbiz-tx-centos7
```

workflow 不创建 GitHub Actions Artifact。ORAS 拉取、校验和 Incus 导入命令见
仓库 [README](../README.md#拉取和导入)。
