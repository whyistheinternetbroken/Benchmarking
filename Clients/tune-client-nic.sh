#!/usr/bin/env bash
# tune-client-nic.sh
# Configure NIC settings for NetApp AFX benchmark clients (RoCE/RDMA)
#
# Usage: sudo ./tune-client-nic.sh <interface1> [<interface2> ...]
#
# Applies:
#   - RX/TX ring buffer size = 8192
#   - PFC (Priority Flow Control) enabled on priority 3
#   - DSCP trust mode
#   - RoCE traffic class via cma_roce_tos (TOS=106 = DSCP AF31)
#
# Requirements: ethtool, mlnx_qos (Mellanox OFED/DOCA) or dcb
# Tested on:    Ubuntu 24.04 with Doca-all 3.4.0

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo)." >&2
    exit 1
fi

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <interface1> [<interface2> ...]"
    echo "Example: $0 ens1f0np0 ens1f1np1"
    exit 1
fi

INTERFACES=("$@")
RING_SIZE=8192
PFC_PRIORITY=3
ROCE_TOS=106     # TOS = DSCP AF31 (26) << 2 | ECT(0) = 106

echo "=== NetApp AFX Benchmark NIC Tuning ==="

for IFACE in "${INTERFACES[@]}"; do
    if ! ip link show "$IFACE" &>/dev/null; then
        echo "WARNING: Interface $IFACE not found, skipping."
        continue
    fi

    echo ""
    echo "--- Tuning $IFACE ---"

    # Set RX/TX ring buffers
    echo "  Setting RX/TX ring buffers to $RING_SIZE..."
    ethtool -G "$IFACE" rx "$RING_SIZE" tx "$RING_SIZE" || \
        echo "  WARNING: Could not set ring buffers for $IFACE"

    # PFC - Priority Flow Control
    if command -v mlnx_qos &>/dev/null; then
        echo "  Enabling PFC on priority $PFC_PRIORITY via mlnx_qos..."
        mlnx_qos -i "$IFACE" --pfc 0,0,0,1,0,0,0,0 || \
            echo "  WARNING: mlnx_qos PFC configuration failed"
        echo "  Setting DSCP trust mode..."
        mlnx_qos -i "$IFACE" --trust dscp || \
            echo "  WARNING: DSCP trust configuration failed"
    elif command -v dcb &>/dev/null; then
        echo "  Enabling PFC via dcb..."
        dcb pfc set dev "$IFACE" prio-pfc 3:on || \
            echo "  WARNING: dcb PFC configuration failed"
    else
        echo "  WARNING: mlnx_qos and dcb not found. Install Mellanox OFED/DOCA or iproute2-dcb."
        echo "           Configure PFC manually for $IFACE."
    fi

    echo "  Done: $IFACE"
done

# RoCE traffic class via cma_roce_tos (applies globally to all RDMA/RoCE devices)
echo ""
echo "--- Setting RoCE TOS (cma_roce_tos = $ROCE_TOS) ---"
RDMA_DEVS=$(ls /sys/class/infiniband/ 2>/dev/null || true)

if [[ -z "$RDMA_DEVS" ]]; then
    echo "  WARNING: No RDMA/InfiniBand devices found. Skipping cma_roce_tos."
else
    for RDMA_DEV in $RDMA_DEVS; do
        TOS_FILE="/sys/class/infiniband/${RDMA_DEV}/cma_roce_tos"
        if [[ -f "$TOS_FILE" ]]; then
            echo "  Setting $TOS_FILE = $ROCE_TOS"
            echo "$ROCE_TOS" > "$TOS_FILE"
        fi
    done
fi

echo ""
echo "=== NIC tuning complete ==="
echo "NOTE: These settings are not persistent across reboots."
echo "      For persistent configuration, use a systemd unit or udev rules."
