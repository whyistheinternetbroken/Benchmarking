# NAS scripts

This folder contains ONTAP REST API Bash wizard scripts for NAS configuration tasks.

## Scripts

- `configure_NFS.bash`
  - Interactive create/modify workflow for SVM NFS server settings.
  - Supports version selection (NFSv3, NFSv4.1, NFSv4.2), optional NFSv4 ID domain, and RDMA enablement.
  - Includes optional benchmarking-focused NFS settings profile.
  - Can enable RDMA on existing data-role LIFs and hand off to `ONTAP/networking/create_interfaces.bash` if no data LIFs exist.

## Requirements

- Bash (Git Bash works on Windows)
- `curl`
- `jq`
- `base64` (if generating auth token in script)

## Usage

From this folder:

```bash
bash configure_NFS.bash --help
```

Run with debug logging:

```bash
bash configure_NFS.bash --debug
```

Debug logs are written to `ONTAP/NAS/logs/` by default.
