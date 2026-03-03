# Building a Custom Firecracker Kernel for K3s

This guide walks through building a Linux kernel for Firecracker microVMs with full
support for k3s, Flannel (VXLAN backend), Cilium CNI, kube-proxy (IPVS mode),
nftables, ipset, and all other networking features required by Kubernetes.

## Why a Custom Kernel?

The official Firecracker kernel image is built from a minimal config that lacks:

| Feature | Config Option | k3s Component |
|---|---|---|
| VXLAN tunnel devices | `CONFIG_VXLAN` | Flannel CNI |
| Geneve tunnel devices | `CONFIG_GENEVE` | Cilium CNI |
| nftables framework | `CONFIG_NF_TABLES` | iptables-nft translation layer |
| IP sets | `CONFIG_IP_SET` | kube-router network policy |
| IPVS load balancing | `CONFIG_IP_VS` | kube-proxy |
| nfacct accounting | `CONFIG_NETFILTER_NETLINK_ACCT` | metrics/accounting |
| iptables comment match | `CONFIG_NETFILTER_XT_MATCH_COMMENT` | k3s iptables rules |
| TUN/TAP devices | `CONFIG_TUN` | various CNI plugins |
| BPF JIT compiler | `CONFIG_BPF_JIT` | Cilium eBPF |
| BTF type info | `CONFIG_DEBUG_INFO_BTF` | Cilium CO-RE eBPF |
| Crypto user API | `CONFIG_CRYPTO_USER_API_HASH` | Cilium |
| TPROXY target | `CONFIG_NETFILTER_XT_TARGET_TPROXY` | Cilium L7 policy |

Additionally, `CONFIG_MODULES` is disabled in the Firecracker config, so every
required feature must be compiled directly into the kernel (`=y`), not as a loadable
module (`=m`).

## Prerequisites

### Build Machine Requirements

- **OS**: Linux (x86_64). Ubuntu 22.04+ or Debian 12+ recommended.
- **Disk**: ~3 GB for kernel source, ~2 GB for build artifacts.
- **RAM**: 2 GB minimum, 4+ GB recommended.
- **CPU**: More cores = faster build. A 4-core machine builds in ~10-15 minutes.

### Required Packages

**Ubuntu/Debian:**

```bash
sudo apt-get update
sudo apt-get install -y \
    build-essential \
    bc \
    bison \
    flex \
    libelf-dev \
    libssl-dev \
    libncurses-dev \
    dwarves \
    wget \
    tar \
    cpio \
    python3
```

The `dwarves` package provides `pahole`, which is required for building the kernel
with `CONFIG_DEBUG_INFO_BTF=y` (needed by Cilium).

**Fedora/RHEL:**

```bash
sudo dnf install -y \
    gcc \
    make \
    bc \
    bison \
    flex \
    elfutils-libelf-devel \
    openssl-devel \
    ncurses-devel \
    dwarves \
    wget \
    tar \
    cpio \
    python3
```

## Quick Start (Automated)

Use the provided build script for a one-command build:

```bash
./scripts/build-kernel.sh
```

The script downloads the kernel source, applies the Firecracker base config, merges
the k3s config fragment, and builds `vmlinux`. The output kernel will be at
`build/vmlinux-<version>-firecracker-k3s`.

To customize the kernel version:

```bash
KERNEL_VERSION=6.1.164 ./scripts/build-kernel.sh
```

To use a different number of parallel jobs:

```bash
BUILD_JOBS=8 ./scripts/build-kernel.sh
```

## Manual Build (Step-by-Step)

### Step 1: Download the Kernel Source

```bash
KERNEL_VERSION=6.1.164
KERNEL_MAJOR=$(echo $KERNEL_VERSION | cut -d. -f1)

wget -q "https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_MAJOR}.x/linux-${KERNEL_VERSION}.tar.xz"
tar xf "linux-${KERNEL_VERSION}.tar.xz"
cd "linux-${KERNEL_VERSION}"
```

### Step 2: Get the Firecracker Base Config

Download the official Firecracker 6.1 guest config:

```bash
wget -q -O .config \
    "https://raw.githubusercontent.com/firecracker-microvm/firecracker/main/resources/guest_configs/microvm-kernel-ci-x86_64-6.1.config"
```

### Step 3: Merge the K3s Config Fragment

The config fragment in `configs/microvm-kernel-x86_64-k3s.config-fragment` contains
all the options k3s needs. Merge it on top of the base config:

```bash
# Use the kernel's built-in merge tool
scripts/kconfig/merge_config.sh .config /path/to/configs/microvm-kernel-x86_64-k3s.config-fragment
```

If `merge_config.sh` is not yet available (it's generated during `make`), you can
alternatively use:

```bash
# Copy base config, then apply fragment
cp .config .config.base
KCONFIG_CONFIG=.config scripts/kconfig/merge_config.sh \
    .config.base /path/to/configs/microvm-kernel-x86_64-k3s.config-fragment
```

Or apply the fragment manually using `make olddefconfig` after appending:

```bash
cat /path/to/configs/microvm-kernel-x86_64-k3s.config-fragment >> .config
make olddefconfig
```

The `make olddefconfig` step resolves any dependency issues and sets new config
symbols to their default values.

### Step 4: (Optional) Interactive Configuration

If you want to inspect or further customize the config:

```bash
make menuconfig
```

Key locations in menuconfig:

- **Networking > VXLAN**: `Networking support > Networking options > Virtual eXtensible Local Area Network`
- **Netfilter**: `Networking support > Networking options > Network packet filtering framework`
- **IPVS**: `Networking support > Networking options > Network packet filtering > IP virtual server support`
- **IP Sets**: `Networking support > Networking options > Network packet filtering > IP set support`

### Step 5: Build the Kernel

Firecracker on x86_64 requires an uncompressed ELF kernel image (`vmlinux`):

```bash
make vmlinux -j$(nproc)
```

This produces `vmlinux` in the kernel source root directory.

### Step 6: Verify the Build

Run the verification script to confirm all required options are enabled:

```bash
/path/to/scripts/verify-kernel-config.sh .config
```

Or check manually:

```bash
grep -E "CONFIG_VXLAN=|CONFIG_NF_TABLES=|CONFIG_IP_SET=|CONFIG_IP_VS=" .config
```

Expected output:

```
CONFIG_VXLAN=y
CONFIG_NF_TABLES=y
CONFIG_IP_SET=y
CONFIG_IP_VS=y
```

### Step 7: Copy the Kernel

```bash
cp vmlinux /path/to/your/firecracker/vmlinux-${KERNEL_VERSION}-k3s
```

## Using the Kernel with Firecracker

Update your Firecracker VM configuration to use the new kernel:

```json
{
  "boot-source": {
    "kernel_image_path": "/path/to/vmlinux-6.1.164-k3s",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off nomodules random.trust_cpu=on i8042.noaux"
  }
}
```

Or if using the Firecracker API:

```bash
curl --unix-socket /tmp/firecracker.socket -X PUT \
    "http://localhost/boot-source" \
    -H "Content-Type: application/json" \
    -d '{
        "kernel_image_path": "/path/to/vmlinux-6.1.164-k3s",
        "boot_args": "console=ttyS0 reboot=k panic=1 pci=off nomodules random.trust_cpu=on i8042.noaux"
    }'
```

## Verifying K3s Inside the MicroVM

After booting the VM with the new kernel, install and verify k3s:

### 1. Check VXLAN Support

```bash
# Should succeed without errors
ip link add vxlan-test type vxlan id 42 dstport 4789 dev eth0
ip link del vxlan-test
echo "VXLAN: OK"
```

### 2. Check iptables

```bash
iptables -L -n
# Should list chains without "missing kernel module" warnings
```

### 3. Check ipset

```bash
ipset list
# Should return empty list, not "Cannot open session to kernel"
```

### 4. Install K3s

```bash
curl -sfL https://get.k3s.io | sh -
```

### 5. Verify Pods Start Successfully

```bash
# Wait 1-2 minutes for k3s to initialize
kubectl get pods -A

# All pods should reach Running state (not stuck in ContainerCreating)
kubectl get nodes
# Node should be Ready
```

### 6. Verify Flannel is Running

```bash
# Check flannel created the subnet.env file
cat /run/flannel/subnet.env

# Check VXLAN interface exists
ip -d link show flannel.1
```

## Troubleshooting

### "failed to create vxlan device: operation not supported"

`CONFIG_VXLAN` is not enabled in the kernel. Rebuild with the config fragment.

Verify:

```bash
grep CONFIG_VXLAN /path/to/.config
# Must show: CONFIG_VXLAN=y
```

### Pods stuck in ContainerCreating

Check flannel logs:

```bash
journalctl -u k3s | grep -i flannel
```

If you see `subnet.env: no such file or directory`, flannel failed to start.
Check `journalctl -u k3s | grep -i "Shutdown request"` for the root cause.

### "Extension comment revision 0 not supported"

`CONFIG_NETFILTER_XT_MATCH_COMMENT` is not enabled. Rebuild with the config fragment.

### "ipset: Cannot open session to kernel"

`CONFIG_IP_SET` is not enabled. Rebuild with the config fragment.

### k3s restart loop

Check `systemctl status k3s` and `journalctl -u k3s -n 100` for the specific
error. Common causes:

1. Flannel can't create VXLAN device (see above)
2. iptables rules fail due to missing netfilter modules
3. Insufficient memory (k3s needs at least 512 MB, 1 GB recommended)

### Boot panic: "Can't open blockdev"

If you're using a kernel newer than 6.1, ensure `CONFIG_PCI=y` is set. The
Firecracker base config has `CONFIG_PCI=n` which works for 6.1 with Amazon Linux
patches but may fail on vanilla kernels. The provided config fragment does not
change this setting since 6.1 is the recommended version.

### Kernel version mismatch warnings

If you see version mismatch warnings when loading modules, remember that
`CONFIG_MODULES=n` in this build -- everything is built-in. The warnings from
`modprobe` are harmless since the features are already in the kernel.

## Kernel Versions

| Version | Type | Recommendation |
|---|---|---|
| 6.1.164 | LTS | **Recommended**. Matches Firecracker's tested config family. |
| 6.12.74 | LTS | Good alternative. Newer features, may need config adjustments. |
| 6.6.127 | LTS | Also viable. Intermediate LTS between 6.1 and 6.12. |
| 6.19.5 | Stable | Not recommended for production. Use LTS for stability. |

When using kernel versions other than 6.1.x, some config option names may have
changed. Run `make olddefconfig` after merging configs to resolve any differences,
and use the verification script to confirm all required options are present.

## Config Fragment Details

See `configs/microvm-kernel-x86_64-k3s.config-fragment` for the complete list of
options added on top of the Firecracker base config. The fragment is organized into
sections:

1. **VXLAN / Tunneling** -- core overlay networking
2. **nftables** -- modern packet filtering framework
3. **iptables extensions** -- additional match/target modules
4. **Netfilter netlink** -- userspace communication (nfacct, logging)
5. **IP Sets** -- efficient IP/port set matching
6. **IPVS** -- kernel-level load balancing for kube-proxy
7. **Traffic Control** -- QoS and CNI plugin support

All options are set to `=y` (built-in) since `CONFIG_MODULES` is disabled in the
Firecracker base config.
