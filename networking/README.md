# Networking scripts

This folder contains ONTAP REST API Bash wizards for interface lifecycle tasks.

## Scripts

- `create_interfaces.bash`
  - Interactive interface (LIF) creation for an SVM
  - Supports static IPs or subnet-based dynamic provisioning
  - Supports multi-node and per-node multiplier workflows
  - Supports data port selection, wildcard families (for example `e2`), and optional ping tests

- `cleanup_interfaces.bash`
  - Interactive cleanup for:
    - SVM interfaces (LIFs)
    - Subnets
    - SVM default routes
  - Supports delete-all or targeted cleanup selections
  - LIF and subnet cleanup support numbered selection (`0`, `all`, `!N`, comma-separated numbers)

## Requirements

- Bash (Git Bash works on Windows)
- `curl`
- `jq`
- `base64` (if generating auth token in script)

## Auth

Both scripts use ONTAP REST Basic auth (`Authorization: Basic <AUTH_TOK>`).

You can:
- set `AUTH_TOK` before running, or
- let the script prompt for username/password and generate it.

## Usage

From this folder:

```bash
bash create_interfaces.bash --help
bash cleanup_interfaces.bash --help
```

Run with debug logging:

```bash
bash create_interfaces.bash --debug
bash cleanup_interfaces.bash --debug
```

Debug logs are written to `networking/logs/` by default.
