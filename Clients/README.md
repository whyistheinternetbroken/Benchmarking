# NetApp AFX Benchmark Client Tuning Scripts

These scripts configure NFS client hosts for optimal performance during NetApp AFX benchmark testing.

## Scripts

| Script | Purpose |
|--------|--------|
| `tune-client-nic.sh` | Configure NIC ring buffers, PFC, DSCP, and RoCE traffic class |
| `tune-client-os.sh` | Set OS kernel parameters (dirty page writeback, RDMA slot table) |

## Tested Configuration

- Ubuntu 24.04.1 LTS (kernel 6.8.0-51-generic)
- Doca-all 3.4.0 with rpcrdma module
- Dual NICs bonded for RoCE (LACP)

## Usage

Run both scripts on each benchmark client:

```bash
# NIC tuning (replace with your interface names)
sudo ./tune-client-nic.sh ens1f0np0 ens1f1np1

# OS tuning (add --persistent to survive reboots)
sudo ./tune-client-os.sh --persistent
```

## Reference

These scripts implement the tuning recommendations from the [NetApp AFX Test Plan](https://github.com/whyistheinternetbroken/AFXTestPlans/blob/main/setup.adoc#clients).

For ONTAP NFS server configuration, see [ONTAP/NAS/configure-nfs-server.sh](../ONTAP/NAS/configure-nfs-server.sh).
