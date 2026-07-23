# Volumes scripts

This folder contains NetApp ONTAP REST automation scripts:

- `vol_create.bash` - create FlexVol/FlexGroup volumes
- `vol_delete.bash` - delete selected volumes from an SVM

## Help

Each script supports built-in help:

```bash
./vol_create.bash --help
./vol_delete.bash --help
```

## Debug logging

Both scripts support:

```bash
--debug
```

When `--debug` is used, REST tracing is written to log files under:

```text
ONTAP/volumes/logs/
```

Default log names:

- `vol_create_debug_YYYYmmdd_HHMMSS.log`
- `vol_delete_debug_YYYYmmdd_HHMMSS.log`

Optional override:

```bash
DEBUG_LOG_FILE=/path/to/custom.log ./vol_create.bash --debug
DEBUG_LOG_FILE=/path/to/custom.log ./vol_delete.bash --debug
```
