#!/usr/bin/env bash
# configure-nfs-server.sh
# Configure ONTAP NFS server settings for NetApp AFX benchmark testing
#
# Usage: ./configure-nfs-server.sh <cluster_mgmt_ip> <svm_name> <id_domain> [rdma]
#
# This script connects to an ONTAP cluster via SSH and applies the recommended
# NFS server configuration for NetApp AFX performance benchmarking.
#
# Parameters:
#   cluster_mgmt_ip  - Cluster management IP or hostname
#   svm_name         - SVM (vserver) name
#   id_domain        - NFSv4 ID domain (must match /etc/idmapd.conf on clients)
#   rdma             - Optional: pass "rdma" to enable NFS over RDMA
#
# Requirements: ssh access to the cluster with admin credentials
# Reference:    https://github.com/whyistheinternetbroken/AFXTestPlans/blob/main/setup.adoc

set -euo pipefail

if [[ $# -lt 3 ]]; then
    echo "Usage: $0 <cluster_mgmt_ip> <svm_name> <id_domain> [rdma]"
    echo ""
    echo "Examples:"
    echo "  $0 192.168.1.100 svm1 mycompany.com"
    echo "  $0 192.168.1.100 svm1 mycompany.com rdma"
    exit 1
fi

CLUSTER_IP="$1"
SVM="$2"
ID_DOMAIN="$3"
ENABLE_RDMA="${4:-}"

RDMA_OPT=""
if [[ "$ENABLE_RDMA" == "rdma" ]]; then
    RDMA_OPT="-rdma enabled"
    echo "INFO: RDMA will be enabled. Ensure RDMA-capable NICs and switches are configured."
fi

NFS_CMD="set advanced; nfs modify -vserver ${SVM} \
  -v3 enabled \
  -v4.1 enabled \
  -v4.0 disabled \
  -v4-id-domain ${ID_DOMAIN} \
  -v4.1-pnfs enabled \
  -v4.1-trunking enabled \
  -v4-64bit-identifiers enabled \
  -v3-64bit-identifiers enabled \
  -chown-mode unrestricted \
  -tcp-max-xfer-size 262144 \
  -mount-rootonly disabled \
  -nfs-rootonly disabled \
  -v3-hide-snapshot enabled \
  ${RDMA_OPT}"

echo "=== NetApp AFX NFS Server Configuration ==="
echo "  Cluster: $CLUSTER_IP"
echo "  SVM:     $SVM"
echo "  Domain:  $ID_DOMAIN"
echo "  RDMA:    ${ENABLE_RDMA:-disabled}"
echo ""
echo "  Connecting to $CLUSTER_IP via SSH (admin@${CLUSTER_IP})..."
echo "  You will be prompted for the admin password."
echo ""

ssh -o StrictHostKeyChecking=no "admin@${CLUSTER_IP}" "${NFS_CMD}"

echo ""
echo "=== NFS server configuration applied ==="
echo ""
echo "To verify, run from ONTAP CLI:"
echo "  nfs show -vserver ${SVM}"
echo "  nfs show -vserver ${SVM} -fields v4-id-domain,v4.1-pnfs,v4.1-trunking,rdma"
