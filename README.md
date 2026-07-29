# Benchmarking

Benchmarking scripts and utilities for ONTAP REST-based storage and networking workflows.

## Script overview

All ONTAP-focused scripts are organized under `ONTAP/`.

### `ONTAP/volumes/`

- `vol_create.bash`
  - Interactive volume creation workflow.
- `vol_delete.bash`
  - Interactive volume cleanup workflow with selective delete options.

### `ONTAP/networking/`

- `create_interfaces.bash`
  - Interactive LIF creation workflow.
  - Supports static IP and subnet-based interface provisioning.
  - Supports optional RDMA enablement for created interfaces.
- `cleanup_interfaces.bash`
  - Interactive cleanup workflow for interfaces, subnets, and default routes.

### `ONTAP/NAS/`

- `configure_NFS.bash`
  - Interactive create/modify workflow for SVM NFS server configuration.
  - Supports NFS protocol version selection, optional NFSv4 ID domain, benchmarking profile settings, and RDMA workflows.

## Common requirements

- Bash (Git Bash works on Windows)
- `curl`
- `jq`
- `base64` (if generating auth token in-script)

## Getting started

Run any script with `--help` to see its options and prompt behavior.
