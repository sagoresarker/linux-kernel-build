#!/usr/bin/env bash
# =============================================================================
# verify-kernel-config.sh
# Checks a kernel .config file for all options required by k3s on Firecracker.
#
# Usage:
#   ./scripts/verify-kernel-config.sh /path/to/.config
#   ./scripts/verify-kernel-config.sh /proc/config.gz    # on a running system
#
# Exit codes:
#   0 - All required options present
#   1 - One or more critical options missing
#   2 - One or more recommended options missing (warnings only)
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CONFIG_FILE="${1:-}"

if [ -z "$CONFIG_FILE" ]; then
    echo "Usage: $0 <path-to-kernel-.config>"
    echo ""
    echo "Examples:"
    echo "  $0 build/linux-6.1.164/.config"
    echo "  $0 /proc/config.gz"
    echo "  $0 /boot/config-\$(uname -r)"
    exit 1
fi

TMPCONFIG=""
cleanup() {
    [ -n "$TMPCONFIG" ] && rm -f "$TMPCONFIG"
}
trap cleanup EXIT

if [[ "$CONFIG_FILE" == *.gz ]]; then
    TMPCONFIG=$(mktemp)
    zcat "$CONFIG_FILE" > "$TMPCONFIG"
    CONFIG_FILE="$TMPCONFIG"
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: File not found: $CONFIG_FILE"
    exit 1
fi

PASS=0
FAIL=0
WARN=0

check_option() {
    local level="$1"    # CRITICAL or RECOMMENDED
    local option="$2"
    local value="$3"    # y, m, or n (n means must NOT be set)
    local description="$4"

    local expected="${option}=${value}"

    if [ "$value" = "n" ]; then
        if grep -q "^${option}=y" "$CONFIG_FILE" || grep -q "^${option}=m" "$CONFIG_FILE"; then
            # Option is set but shouldn't be -- unusual case, just note it
            return 0
        fi
        PASS=$((PASS + 1))
        return 0
    fi

    if grep -q "^${expected}$" "$CONFIG_FILE"; then
        PASS=$((PASS + 1))
        return 0
    fi

    # Also accept =y when we asked for =m (built-in satisfies module requirement)
    if [ "$value" = "m" ] && grep -q "^${option}=y$" "$CONFIG_FILE"; then
        PASS=$((PASS + 1))
        return 0
    fi

    if [ "$level" = "CRITICAL" ]; then
        printf "  ${RED}FAIL${NC}  %-45s  %s\n" "$expected" "$description"
        FAIL=$((FAIL + 1))
    else
        printf "  ${YELLOW}WARN${NC}  %-45s  %s\n" "$expected" "$description"
        WARN=$((WARN + 1))
    fi
}

echo "============================================="
echo "Firecracker K3s Kernel Config Verification"
echo "Config: $CONFIG_FILE"
echo "============================================="
echo ""

# ---- Section: Core Container Requirements ----
printf "${BLUE}--- Core Container Requirements ---${NC}\n"
check_option CRITICAL CONFIG_NAMESPACES              y "Linux namespaces"
check_option CRITICAL CONFIG_NET_NS                  y "Network namespaces"
check_option CRITICAL CONFIG_PID_NS                  y "PID namespaces"
check_option CRITICAL CONFIG_IPC_NS                  y "IPC namespaces"
check_option CRITICAL CONFIG_UTS_NS                  y "UTS namespaces"
check_option CRITICAL CONFIG_USER_NS                 y "User namespaces"
check_option CRITICAL CONFIG_CGROUPS                 y "Control groups"
check_option CRITICAL CONFIG_CGROUP_PIDS             y "PIDs cgroup"
check_option CRITICAL CONFIG_CGROUP_CPUACCT          y "CPU accounting cgroup"
check_option CRITICAL CONFIG_CGROUP_DEVICE           y "Device cgroup"
check_option CRITICAL CONFIG_CGROUP_FREEZER          y "Freezer cgroup"
check_option CRITICAL CONFIG_CGROUP_SCHED            y "Scheduler cgroup"
check_option CRITICAL CONFIG_CPUSETS                  y "Cpuset cgroup"
check_option CRITICAL CONFIG_MEMCG                   y "Memory cgroup"
check_option CRITICAL CONFIG_BLK_CGROUP              y "Block I/O cgroup"
check_option CRITICAL CONFIG_CFS_BANDWIDTH           y "CFS bandwidth control"
check_option CRITICAL CONFIG_FAIR_GROUP_SCHED         y "Fair group scheduling"
echo ""

# ---- Section: Filesystem ----
printf "${BLUE}--- Filesystem ---${NC}\n"
check_option CRITICAL CONFIG_OVERLAY_FS              y "OverlayFS (container layers)"
check_option CRITICAL CONFIG_EXT4_FS                 y "ext4 filesystem"
echo ""

# ---- Section: Networking Core ----
printf "${BLUE}--- Networking Core ---${NC}\n"
check_option CRITICAL CONFIG_BRIDGE                  y "Ethernet bridge"
check_option CRITICAL CONFIG_VETH                    y "Virtual ethernet pair"
check_option CRITICAL CONFIG_VXLAN                   y "VXLAN tunnel (Flannel)"
check_option CRITICAL CONFIG_GENEVE                  y "Geneve tunnel (Cilium)"
check_option CRITICAL CONFIG_TUN                     y "TUN/TAP device"
check_option CRITICAL CONFIG_DUMMY                   y "Dummy network device"
check_option CRITICAL CONFIG_MACVLAN                 y "MAC-VLAN"
check_option CRITICAL CONFIG_VLAN_8021Q              y "802.1Q VLAN"
check_option RECOMMENDED CONFIG_IPVLAN               y "IP-VLAN"
check_option RECOMMENDED CONFIG_NET_IPGRE            y "GRE tunnel"
check_option RECOMMENDED CONFIG_NET_IPIP             y "IPIP tunnel"
check_option RECOMMENDED CONFIG_IPV6_TUNNEL          y "IPv6 tunnel"
echo ""

# ---- Section: Netfilter Core ----
printf "${BLUE}--- Netfilter Core ---${NC}\n"
check_option CRITICAL CONFIG_NETFILTER               y "Netfilter framework"
check_option CRITICAL CONFIG_NETFILTER_ADVANCED      y "Advanced netfilter"
check_option CRITICAL CONFIG_BRIDGE_NETFILTER        y "Bridge netfilter"
check_option CRITICAL CONFIG_NF_CONNTRACK            y "Connection tracking"
check_option CRITICAL CONFIG_NF_NAT                  y "NAT"
check_option CRITICAL CONFIG_NF_NAT_MASQUERADE       y "Masquerade"
check_option CRITICAL CONFIG_NETFILTER_XTABLES       y "Xtables framework"
echo ""

# ---- Section: nftables ----
printf "${BLUE}--- nftables ---${NC}\n"
check_option CRITICAL CONFIG_NF_TABLES               y "nftables framework"
check_option CRITICAL CONFIG_NFT_COMPAT              y "nftables compat (iptables-nft)"
check_option RECOMMENDED CONFIG_NFT_COUNTER           y "nftables counter expression (may be built into NF_TABLES)"
check_option CRITICAL CONFIG_NFT_CT                  y "nftables conntrack"
check_option CRITICAL CONFIG_NFT_NAT                 y "nftables NAT"
check_option RECOMMENDED CONFIG_NFT_CHAIN_NAT        y "nftables NAT chain (may be built into NF_TABLES)"
check_option CRITICAL CONFIG_NFT_MASQ                y "nftables masquerade"
check_option CRITICAL CONFIG_NFT_REJECT              y "nftables reject"
check_option CRITICAL CONFIG_NFT_LOG                 y "nftables logging"
check_option CRITICAL CONFIG_NFT_LIMIT               y "nftables rate limit"
check_option RECOMMENDED CONFIG_NF_TABLES_INET       y "nftables inet family"
check_option RECOMMENDED CONFIG_NF_TABLES_BRIDGE     y "nftables bridge"
echo ""

# ---- Section: iptables ----
printf "${BLUE}--- iptables ---${NC}\n"
check_option CRITICAL CONFIG_IP_NF_IPTABLES          y "IPv4 iptables"
check_option CRITICAL CONFIG_IP_NF_FILTER            y "IPv4 filter table"
check_option CRITICAL CONFIG_IP_NF_NAT               y "IPv4 NAT table"
check_option CRITICAL CONFIG_IP_NF_MANGLE            y "IPv4 mangle table"
check_option CRITICAL CONFIG_IP_NF_TARGET_MASQUERADE y "IPv4 MASQUERADE target"
check_option CRITICAL CONFIG_IP_NF_TARGET_REJECT     y "IPv4 REJECT target"
check_option CRITICAL CONFIG_IP6_NF_IPTABLES         y "IPv6 iptables"
check_option CRITICAL CONFIG_IP6_NF_FILTER           y "IPv6 filter table"
check_option CRITICAL CONFIG_IP6_NF_NAT              y "IPv6 NAT table"
check_option CRITICAL CONFIG_IP6_NF_MANGLE           y "IPv6 mangle table"
check_option CRITICAL CONFIG_IP6_NF_TARGET_MASQUERADE y "IPv6 MASQUERADE target"
check_option RECOMMENDED CONFIG_IP_NF_RAW            y "IPv4 raw table"
check_option RECOMMENDED CONFIG_IP6_NF_RAW           y "IPv6 raw table"
echo ""

# ---- Section: Xtables Matches ----
printf "${BLUE}--- Xtables Matches ---${NC}\n"
check_option CRITICAL CONFIG_NETFILTER_XT_MATCH_COMMENT    y "Comment match"
check_option CRITICAL CONFIG_NETFILTER_XT_MATCH_CONNTRACK  y "Conntrack match"
check_option CRITICAL CONFIG_NETFILTER_XT_MATCH_MULTIPORT  y "Multiport match"
check_option CRITICAL CONFIG_NETFILTER_XT_MATCH_MARK       y "Mark match"
check_option CRITICAL CONFIG_NETFILTER_XT_MATCH_STATE      y "State match"
check_option CRITICAL CONFIG_NETFILTER_XT_MATCH_STATISTIC  y "Statistic match"
check_option CRITICAL CONFIG_NETFILTER_XT_MATCH_LIMIT      y "Limit match"
check_option CRITICAL CONFIG_NETFILTER_XT_MATCH_CONNMARK   y "Connmark match"
check_option CRITICAL CONFIG_NETFILTER_XT_MATCH_ADDRTYPE   y "Address type match"
check_option RECOMMENDED CONFIG_NETFILTER_XT_MATCH_RECENT  y "Recent match"
check_option RECOMMENDED CONFIG_NETFILTER_XT_MATCH_IPRANGE y "IP range match"
check_option RECOMMENDED CONFIG_NETFILTER_XT_MATCH_LENGTH  y "Length match"
check_option RECOMMENDED CONFIG_NETFILTER_XT_MATCH_OWNER   y "Owner match"
check_option RECOMMENDED CONFIG_NETFILTER_XT_MATCH_MAC     y "MAC match"
check_option RECOMMENDED CONFIG_NETFILTER_XT_MATCH_SOCKET  y "Socket match"
echo ""

# ---- Section: Xtables Targets ----
printf "${BLUE}--- Xtables Targets ---${NC}\n"
check_option CRITICAL CONFIG_NETFILTER_XT_TARGET_MASQUERADE y "MASQUERADE target"
check_option CRITICAL CONFIG_NETFILTER_XT_TARGET_REDIRECT   y "REDIRECT target"
check_option CRITICAL CONFIG_NETFILTER_XT_NAT               y "XT NAT"
check_option CRITICAL CONFIG_NETFILTER_XT_TARGET_NETMAP     y "NETMAP target"
check_option CRITICAL CONFIG_NETFILTER_XT_MARK              y "MARK target"
check_option CRITICAL CONFIG_NETFILTER_XT_TARGET_CONNMARK   y "CONNMARK target"
check_option CRITICAL CONFIG_NETFILTER_XT_SET               y "SET target (ipset)"
check_option RECOMMENDED CONFIG_NETFILTER_XT_TARGET_LOG     y "LOG target"
check_option RECOMMENDED CONFIG_NETFILTER_XT_TARGET_TCPMSS  y "TCPMSS target"
echo ""

# ---- Section: Netfilter Netlink ----
printf "${BLUE}--- Netfilter Netlink ---${NC}\n"
check_option CRITICAL CONFIG_NETFILTER_NETLINK_ACCT  y "nfacct accounting"
check_option CRITICAL CONFIG_NF_CT_NETLINK           y "CT netlink"
check_option RECOMMENDED CONFIG_NETFILTER_NETLINK_LOG   y "Netlink logging"
check_option RECOMMENDED CONFIG_NETFILTER_NETLINK_QUEUE y "Netlink queue"
echo ""

# ---- Section: IP Sets ----
printf "${BLUE}--- IP Sets ---${NC}\n"
check_option CRITICAL CONFIG_IP_SET                  y "IP set support"
check_option CRITICAL CONFIG_IP_SET_HASH_IP          y "hash:ip set type"
check_option CRITICAL CONFIG_IP_SET_HASH_NET         y "hash:net set type"
check_option CRITICAL CONFIG_IP_SET_HASH_IPPORT      y "hash:ip,port set type"
check_option CRITICAL CONFIG_IP_SET_HASH_IPPORTIP    y "hash:ip,port,ip set type"
check_option CRITICAL CONFIG_IP_SET_HASH_IPPORTNET   y "hash:ip,port,net set type"
check_option RECOMMENDED CONFIG_IP_SET_BITMAP_PORT   y "bitmap:port set type"
check_option RECOMMENDED CONFIG_IP_SET_HASH_MAC      y "hash:mac set type"
check_option RECOMMENDED CONFIG_IP_SET_HASH_NETPORT  y "hash:net,port set type"
echo ""

# ---- Section: IPVS ----
printf "${BLUE}--- IPVS (kube-proxy) ---${NC}\n"
check_option CRITICAL CONFIG_IP_VS                   y "IP virtual server"
check_option CRITICAL CONFIG_IP_VS_PROTO_TCP         y "IPVS TCP"
check_option CRITICAL CONFIG_IP_VS_PROTO_UDP         y "IPVS UDP"
check_option CRITICAL CONFIG_IP_VS_RR                y "Round-robin scheduling"
check_option CRITICAL CONFIG_IP_VS_WRR               y "Weighted round-robin"
check_option CRITICAL CONFIG_IP_VS_SH                y "Source hashing"
check_option CRITICAL CONFIG_IP_VS_NFCT              y "IPVS conntrack"
check_option RECOMMENDED CONFIG_IP_VS_LC             y "Least-connection"
check_option RECOMMENDED CONFIG_IP_VS_LBLC           y "Locality-based least-connection"
check_option RECOMMENDED CONFIG_IP_VS_LBLCR          y "Locality-based least-connection/replication"
check_option RECOMMENDED CONFIG_IP_VS_MH             y "Maglev hashing"
echo ""

# ---- Section: Traffic Control ----
printf "${BLUE}--- Traffic Control ---${NC}\n"
check_option RECOMMENDED CONFIG_NET_SCH_HTB          y "HTB qdisc"
check_option RECOMMENDED CONFIG_NET_SCH_INGRESS      y "Ingress qdisc"
check_option RECOMMENDED CONFIG_NET_SCH_FQ_CODEL     y "FQ-CoDel qdisc"
check_option RECOMMENDED CONFIG_NET_CLS_BPF          y "BPF classifier"
check_option RECOMMENDED CONFIG_NET_CLS_U32          y "U32 classifier"
check_option RECOMMENDED CONFIG_NET_CLS_FLOWER       y "Flower classifier"
check_option RECOMMENDED CONFIG_NET_CLS_MATCHALL     y "Matchall classifier"
check_option RECOMMENDED CONFIG_NET_ACT_BPF          y "BPF action"
check_option RECOMMENDED CONFIG_NET_ACT_MIRRED       y "Mirror/redirect action"
check_option RECOMMENDED CONFIG_NET_ACT_GACT         y "Generic action"
echo ""

# ---- Section: Misc ----
printf "${BLUE}--- Misc ---${NC}\n"
check_option CRITICAL CONFIG_SECCOMP                 y "Seccomp (container security)"
check_option CRITICAL CONFIG_BPF_SYSCALL             y "BPF syscall"
check_option CRITICAL CONFIG_CGROUP_BPF              y "BPF cgroup"
check_option RECOMMENDED CONFIG_NETLINK_DIAG         y "Netlink diag"
check_option RECOMMENDED CONFIG_INET_UDP_DIAG        y "UDP diag"
echo ""

# ---- Section: Cilium CNI ----
printf "${BLUE}--- Cilium CNI ---${NC}\n"
check_option CRITICAL CONFIG_BPF_JIT                 y "BPF JIT compiler"
check_option CRITICAL CONFIG_DEBUG_INFO_BTF          y "BTF type information"
check_option CRITICAL CONFIG_GENEVE                  y "Geneve tunnel"
check_option CRITICAL CONFIG_CRYPTO_USER_API_HASH    y "Crypto user API hash"
check_option CRITICAL CONFIG_SCHEDSTATS              y "Scheduler statistics"
check_option CRITICAL CONFIG_NETFILTER_XT_TARGET_TPROXY y "TPROXY target (L7 policy)"
check_option CRITICAL CONFIG_NETFILTER_XT_TARGET_CT  y "CT target (L7 policy)"
check_option RECOMMENDED CONFIG_BPF_JIT_ALWAYS_ON   y "BPF JIT always on"
check_option RECOMMENDED CONFIG_CRYPTO_USER_API      y "Crypto user API"
echo ""

# ---- Summary ----
echo "============================================="
TOTAL=$((PASS + FAIL + WARN))
printf "Results: ${GREEN}${PASS} passed${NC}, "
if [ "$FAIL" -gt 0 ]; then
    printf "${RED}${FAIL} failed${NC}, "
else
    printf "0 failed, "
fi
if [ "$WARN" -gt 0 ]; then
    printf "${YELLOW}${WARN} warnings${NC}"
else
    printf "0 warnings"
fi
printf " (${TOTAL} total)\n"
echo "============================================="

if [ "$FAIL" -gt 0 ]; then
    echo ""
    printf "${RED}CRITICAL options are missing. k3s will not work correctly.${NC}\n"
    echo "Rebuild the kernel with the config fragment applied."
    exit 1
elif [ "$WARN" -gt 0 ]; then
    echo ""
    printf "${YELLOW}Some recommended options are missing. k3s will work but some features may be limited.${NC}\n"
    exit 2
else
    echo ""
    printf "${GREEN}All checks passed. This kernel is ready for k3s on Firecracker.${NC}\n"
    exit 0
fi
