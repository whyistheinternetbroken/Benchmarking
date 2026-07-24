#!/bin/bash

set -euo pipefail

TB_BYTES=1099511627776
DEBUG=${DEBUG:-false}
DEBUG_LOG_FILE=${DEBUG_LOG_FILE:-}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

require_command() {
  local cmd=$1
  if ! command -v "$cmd" >/dev/null 2>&1; then
    local install_choice
    local install_status=1
    local package_manager=""

    echo "Required command not found: $cmd" >&2
    if [ ! -t 0 ]; then
      echo "Cannot prompt to install '$cmd' in a non-interactive shell. Exiting." >&2
      exit 1
    fi

    read -r -p "Would you like this script to try installing '$cmd' now? [y/N]: " install_choice
    install_choice=$(normalize_input "$install_choice")
    install_choice=${install_choice,,}
    if [ "$install_choice" != "y" ] && [ "$install_choice" != "yes" ]; then
      echo "Missing requirement '$cmd'. Exiting." >&2
      exit 1
    fi

    if command -v apt-get >/dev/null 2>&1; then
      package_manager="apt-get"
    elif command -v dnf >/dev/null 2>&1; then
      package_manager="dnf"
    elif command -v yum >/dev/null 2>&1; then
      package_manager="yum"
    elif command -v zypper >/dev/null 2>&1; then
      package_manager="zypper"
    elif command -v brew >/dev/null 2>&1; then
      package_manager="brew"
    elif command -v pacman >/dev/null 2>&1; then
      package_manager="pacman"
    fi

    case "$package_manager" in
      apt-get)
        sudo apt-get update && sudo apt-get install -y "$cmd" && install_status=0
        ;;
      dnf)
        sudo dnf install -y "$cmd" && install_status=0
        ;;
      yum)
        sudo yum install -y "$cmd" && install_status=0
        ;;
      zypper)
        sudo zypper install -y "$cmd" && install_status=0
        ;;
      brew)
        brew install "$cmd" && install_status=0
        ;;
      pacman)
        sudo pacman -Sy --noconfirm "$cmd" && install_status=0
        ;;
      *)
        echo "No supported package manager detected for automatic installation." >&2
        ;;
    esac

    if [ "$install_status" -ne 0 ] || ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Failed to install required command '$cmd'. Please install it manually and re-run." >&2
      exit 1
    fi
  fi
}

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_non_negative_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

normalize_input() {
  printf '%s' "$1" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

debug_log() {
  if [ "$DEBUG" != "true" ]; then
    return
  fi
  printf '[debug] %s\n' "$*" >> "$DEBUG_LOG_FILE"
}

debug_print_json() {
  local label=$1
  local content=${2:-}

  if [ "$DEBUG" != "true" ]; then
    return
  fi

  if [ -z "$content" ]; then
    printf '[debug] %s: <empty>\n' "$label" >> "$DEBUG_LOG_FILE"
    return
  fi

  if printf '%s' "$content" | jq -e . >/dev/null 2>&1; then
    printf '[debug] %s:\n' "$label" >> "$DEBUG_LOG_FILE"
    printf '%s' "$content" | jq . >> "$DEBUG_LOG_FILE"
  else
    printf '[debug] %s: %s\n' "$label" "$content" >> "$DEBUG_LOG_FILE"
  fi
}

print_usage() {
  cat <<'EOF'
Usage: vol_create.bash [--debug]

Options:
  --debug   Enable verbose REST request/response tracing to a log file.
            Default path: <ONTAP/volumes>/logs/vol_create_debug_YYYYmmdd_HHMMSS.log
            Optional: set DEBUG_LOG_FILE=/path/to/file.log
EOF
}

init_debug_logging() {
  if [ "$DEBUG" != "true" ]; then
    return
  fi

  if [ -z "$DEBUG_LOG_FILE" ]; then
    DEBUG_LOG_FILE="$SCRIPT_DIR/logs/vol_create_debug_$(date +%Y%m%d_%H%M%S).log"
  fi

  mkdir -p "$(dirname "$DEBUG_LOG_FILE")"
  : > "$DEBUG_LOG_FILE"
  echo "Debug logging enabled. Writing REST trace to: $DEBUG_LOG_FILE"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --debug)
        DEBUG=true
        ;;
      -h|--help)
        print_usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        print_usage >&2
        exit 1
        ;;
    esac
    shift
  done
}

uri_encode() {
  jq -nr --arg value "$1" '$value|@uri'
}

display_volume_type() {
  if [ "$1" = "flexvol" ]; then
    printf '%s' "FlexVol"
  else
    printf '%s' "FlexGroup"
  fi
}

print_auth_token_help() {
  cat <<'EOF'
How to get the API Basic auth token:
1) Use an ONTAP account that has permission to call REST APIs.
2) Build a Basic credential string as: username:password
3) Base64-encode that string (no extra spaces or newline).
4) Use the encoded output as AUTH_TOK in this script.

Example (Linux/macOS/Git Bash):
  printf '%s' 'admin:YourPassword' | base64

Example (PowerShell):
  [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('admin:YourPassword'))

The script sends this value as:
  Authorization: Basic <AUTH_TOK>
EOF
}

prompt_if_empty() {
  local var_name=$1
  local prompt_text=$2
  local hidden=${3:-false}
  local current_value=${!var_name:-}

  if [ -n "$current_value" ]; then
    return
  fi

  if [ "$hidden" = "true" ]; then
    read -r -s -p "$prompt_text" current_value
    echo
  else
    read -r -p "$prompt_text" current_value
  fi

  if [ -z "$current_value" ]; then
    echo "$var_name is required." >&2
    exit 1
  fi

  printf -v "$var_name" '%s' "$current_value"
}

prompt_auth_token() {
  local current_value=${AUTH_TOK:-}
  local normalized_value
  local choice
  local username
  local password

  if [ -n "$current_value" ]; then
    return
  fi

  while true; do
    read -r -p "Would you like to enter a username and password here to generate a REST API token? (y/n): " choice
    choice=$(normalize_input "$choice")
    choice=${choice,,}

    case "$choice" in
      y|yes)
        require_command base64

        while true; do
          read -r -p "Enter username: " username
          username=$(normalize_input "$username")
          if [ -z "$username" ]; then
            echo "Username is required." >&2
            continue
          fi
          break
        done

        while true; do
          read -r -s -p "Enter password: " password
          echo
          if [ -z "$password" ]; then
            echo "Password is required." >&2
            continue
          fi
          break
        done

        AUTH_TOK=$(printf '%s' "$username:$password" | base64 | tr -d '\r\n')
        unset password
        if [ -z "$AUTH_TOK" ]; then
          echo "Failed to generate API Basic auth token." >&2
          exit 1
        fi
        return
        ;;
      n|no)
        break
        ;;
      *)
        echo "Please enter y or n." >&2
        ;;
    esac
  done

  while true; do
    echo "Enter API Basic auth token: [type ? and hit enter to get help on obtaining this]"
    read -r -p "Auth token: " current_value

    normalized_value=$(normalize_input "$current_value")

    if [ "$normalized_value" = "?" ]; then
      echo "?"
      print_auth_token_help
      continue
    fi

    if [ -z "$normalized_value" ]; then
      echo "AUTH_TOK is required." >&2
      continue
    fi

    AUTH_TOK=$normalized_value
    break
  done
}

show_created_volumes() {
  local created_names_json
  local volumes_json
  local rows
  local -a row_names
  local -a row_styles
  local -a row_sizes
  local -a row_paths
  local name
  local volume_style
  local size_bytes
  local size_tb
  local junction_path
  local idx
  local max_name_width
  local max_style_width
  local max_size_width
  local max_path_width
  local header_name="Volume Name"
  local header_style="volume-style"
  local header_size="Size (TB)"
  local header_path="Junction Path"
  local separator_width

  if [ ${#CREATED_VOLUMES[@]} -eq 0 ]; then
    echo "No created volumes to show."
    return
  fi

  created_names_json=$(printf '%s\n' "${CREATED_VOLUMES[@]}" | jq -R . | jq -s .)
  volumes_json=$(api_request "GET" "https://$MGMT_IP/api/storage/volumes?fields=name,style,size,nas.path&return_records=true&return_timeout=15")
  rows=$(printf '%s' "$volumes_json" | jq -r --argjson names "$created_names_json" '
    .records[]
    | select(.name as $n | $names | index($n))
    | [.name, (.style // "-"), (.size // 0 | tostring), (.nas.path // "-")]
    | @tsv
  ')

  if [ -z "$rows" ]; then
    echo "No matching volume details returned by API."
    return
  fi

  max_name_width=${#header_name}
  max_style_width=${#header_style}
  max_size_width=${#header_size}
  max_path_width=${#header_path}

  while IFS=$'\t' read -r name volume_style size_bytes junction_path; do
    size_tb=$(echo "scale=2; $size_bytes / $TB_BYTES" | bc)
    row_names+=("$name")
    row_styles+=("$volume_style")
    row_sizes+=("$size_tb")
    row_paths+=("$junction_path")

    if [ ${#name} -gt "$max_name_width" ]; then
      max_name_width=${#name}
    fi
    if [ ${#volume_style} -gt "$max_style_width" ]; then
      max_style_width=${#volume_style}
    fi
    if [ ${#size_tb} -gt "$max_size_width" ]; then
      max_size_width=${#size_tb}
    fi
    if [ ${#junction_path} -gt "$max_path_width" ]; then
      max_path_width=${#junction_path}
    fi
  done <<< "$rows"

  printf '\n'
  printf "%-${max_name_width}s | %-${max_style_width}s | %${max_size_width}s | %-${max_path_width}s\n" "$header_name" "$header_style" "$header_size" "$header_path"
  separator_width=$((max_name_width + max_style_width + max_size_width + max_path_width + 9))
  printf '%*s\n' "$separator_width" '' | tr ' ' '-'

  for idx in "${!row_names[@]}"; do
    printf "%-${max_name_width}s | %-${max_style_width}s | %${max_size_width}s | %-${max_path_width}s\n" \
      "${row_names[$idx]}" "${row_styles[$idx]}" "${row_sizes[$idx]}" "${row_paths[$idx]}"
  done

  printf '\n'
}

api_request() {
  local method=$1
  local url=$2
  local payload=${3:-}
  local response
  local response_no_time
  local http_code
  local time_total
  local body

  debug_log "Request: $method $url"
  if [ -n "$payload" ]; then
    debug_print_json "Request payload" "$payload"
  fi

  if [ -n "$payload" ]; then
    response=$(curl -sS -k -X "$method" "$url" \
      -H "accept: application/json" \
      -H "authorization: Basic $AUTH_TOK" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      -w '\n%{http_code}\n%{time_total}')
  else
    response=$(curl -sS -k -X "$method" "$url" \
      -H "accept: application/json" \
      -H "authorization: Basic $AUTH_TOK" \
      -w '\n%{http_code}\n%{time_total}')
  fi

  time_total=${response##*$'\n'}
  response_no_time=${response%$'\n'*}
  http_code=${response_no_time##*$'\n'}
  body=${response_no_time%$'\n'*}

  debug_log "Response: HTTP $http_code (${time_total}s) for $method $url"
  debug_print_json "Response body" "$body"

  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    echo "API request failed ($method $url): HTTP $http_code" >&2
    if [ -n "$body" ]; then
      echo "$body" >&2
    fi
    exit 1
  fi

  printf '%s' "$body"
}

get_cluster_nodes_json() {
  api_request "GET" "https://$MGMT_IP/api/cluster/nodes?fields=name&return_records=true&return_timeout=15&max_records=10000"
}

disable_volume_efficiency_benchmark() {
  local volume_name=$1
  local encoded_volume
  local encoded_svm

  encoded_volume=$(uri_encode "$volume_name")
  encoded_svm=$(uri_encode "$SVM")

  echo "Disabling volume efficiency on $volume_name"
  api_request "POST" "https://$MGMT_IP/api/private/cli/volume/efficiency/off?volume=$encoded_volume&vserver=$encoded_svm&return_timeout=0&return_records=false" >/dev/null
}

apply_aggregate_efficiency_benchmark() {
  local aggregate_name=$1
  local encoded_aggregate

  encoded_aggregate=$(uri_encode "$aggregate_name")

  echo "Applying aggregate efficiency benchmark settings on $aggregate_name"
  api_request "PATCH" "https://$MGMT_IP/api/private/cli/aggr/efficiency/modify?aggregate=$encoded_aggregate&cross-volume-background-dedupe=false&cross-volume-inline-dedupe=false&return_timeout=0&return_records=false" >/dev/null
  api_request "PATCH" "https://$MGMT_IP/api/private/cli/aggr/efficiency/wise-tsse/modify?aggregate=$encoded_aggregate&enable-workload-informed-tsse=false&return_timeout=0&return_records=false" >/dev/null
}

apply_benchmark_post_create_settings() {
  local aggregate_json
  local aggregate_name
  local matched=false
  local created_volume

  for created_volume in "${CREATED_VOLUMES[@]}"; do
    disable_volume_efficiency_benchmark "$created_volume"
  done

  aggregate_json=$(api_request "GET" "https://$MGMT_IP/api/storage/aggregates?fields=name&return_records=true&return_timeout=15&max_records=10000")
  while IFS= read -r aggregate_name; do
    if [ -z "$aggregate_name" ]; then
      continue
    fi
    matched=true
    apply_aggregate_efficiency_benchmark "$aggregate_name"
  done < <(printf '%s' "$aggregate_json" | jq -r '.records[].name // empty' | grep '^data' || true)

  if [ "$matched" = "false" ]; then
    echo "No aggregates matching 'data*' were found for aggregate benchmark settings."
  fi
}

build_payload() {
  local volume_name=$1
  local volume_path="/$volume_name"
  local benchmark_enabled_json=false
  local aggressive_readahead_json=false

  if [ "$ENABLE_BENCHMARK_BEST_PRACTICES" = "true" ]; then
    benchmark_enabled_json=true
  fi
  if [ "$ENABLE_AGGRESSIVE_READAHEAD" = "true" ]; then
    aggressive_readahead_json=true
  fi

  if [ "$VOLUME_STYLE" = "flexgroup" ]; then
    jq -n \
      --arg name "$volume_name" \
      --arg svm "$SVM" \
      --arg path "$volume_path" \
      --argjson size "$VOL_SIZE_BYTES" \
      --argjson benchmark_enabled "$benchmark_enabled_json" \
      --argjson aggressive_readahead "$aggressive_readahead_json" \
      '{
        constituent_count: 32,
        guarantee: { type: "none" },
        name: $name,
        nas: {
          export_policy: { name: "default" },
          junction_parent: { name: $svm },
          path: $path,
          security_style: "unix"
        },
        size: $size,
        style: "flexgroup",
        svm: { name: $svm },
        type: "rw"
      }
      | if $benchmark_enabled then
          .space.large_size_enabled = true
          | .files.set_maximum = true
          | .snapshot_policy.name = "none"
          | .autosize.mode = "grow_shrink"
          | .nas.unix_permissions = 777
          | .analytics.state = "off"
          | .nas.snapdir_access = false
          | .nas.maxdir_size = "4G"
        else
          .
        end
      | if $aggressive_readahead then
          .aggressive_readahead_mode = "cross_file_sequential_read"
        else
          .
        end'
  else
    jq -n \
      --arg name "$volume_name" \
      --arg svm "$SVM" \
      --arg path "$volume_path" \
      --argjson size "$VOL_SIZE_BYTES" \
      --argjson benchmark_enabled "$benchmark_enabled_json" \
      --argjson aggressive_readahead "$aggressive_readahead_json" \
      '{
        guarantee: { type: "none" },
        name: $name,
        nas: {
          export_policy: { name: "default" },
          junction_parent: { name: $svm },
          path: $path,
          security_style: "unix"
        },
        size: $size,
        style: "flexvol",
        svm: { name: $svm },
        type: "rw"
      }
      | if $benchmark_enabled then
          .space.large_size_enabled = true
          | .files.set_maximum = true
          | .snapshot_policy.name = "none"
          | .autosize.mode = "grow_shrink"
          | .nas.unix_permissions = 777
          | .analytics.state = "off"
          | .nas.snapdir_access = false
          | .nas.maxdir_size = "4G"
        else
          .
        end
      | if $aggressive_readahead then
          .aggressive_readahead_mode = "cross_file_sequential_read"
        else
          .
        end'
  fi
}

create_volume() {
  local volume_name=$1
  local payload

  payload=$(build_payload "$volume_name")
  echo "Creating volume: $volume_name"
  api_request "POST" "https://$MGMT_IP/api/storage/volumes?return_timeout=0&return_records=false" "$payload" >/dev/null
  wait_for_volume_ready "$volume_name"
}

wait_for_volume_ready() {
  local volume_name=$1
  local max_attempts=60
  local attempt=1
  local volumes_json
  local current_size

  while [ "$attempt" -le "$max_attempts" ]; do
    volumes_json=$(api_request "GET" "https://$MGMT_IP/api/storage/volumes?fields=name,size&return_records=true&return_timeout=15")
    current_size=$(printf '%s' "$volumes_json" | jq -r --arg volume_name "$volume_name" '
      [.records[] | select(.name == $volume_name) | .size // empty][0] // empty
    ')

    if is_non_negative_integer "${current_size:-}"; then
      if [ "$current_size" -eq "$VOL_SIZE_BYTES" ]; then
        return
      fi
    fi

    sleep 2
    attempt=$((attempt + 1))
  done

  echo "Timed out waiting for volume '$volume_name' to report expected size." >&2
  exit 1
}

parse_args "$@"
init_debug_logging

require_command curl
require_command jq
require_command bc

MGMT_IP=${MGMT_IP:-}
AUTH_TOK=${AUTH_TOK:-}
SVM=${SVM:-}
VOL_NAME_PREFIX=${VOL_NAME_PREFIX:-}
NUM_VOLS=${NUM_VOLS:-}
VOL_SIZE_TB=${VOL_SIZE_TB:-}
VOLUME_STYLE=${VOLUME_STYLE:-}
ENABLE_BENCHMARK_BEST_PRACTICES=${ENABLE_BENCHMARK_BEST_PRACTICES:-false}
ENABLE_AGGRESSIVE_READAHEAD=${ENABLE_AGGRESSIVE_READAHEAD:-false}

prompt_if_empty MGMT_IP "Enter cluster management IP: "
prompt_auth_token
prompt_if_empty SVM "Enter SVM name: "

capacity_json=$(api_request "GET" "https://$MGMT_IP/api/storage/availability-zones?fields=space.size&return_records=true&return_timeout=15")
CAPACITY_BYTES=$(printf '%s' "$capacity_json" | jq -r '[.records[].space.size // empty] | add // 0')

if ! is_positive_integer "$CAPACITY_BYTES"; then
  echo "Could not determine usable capacity from API response." >&2
  exit 1
fi

CAPACITY_TB=$(echo "$CAPACITY_BYTES / $TB_BYTES" | bc)
if ! is_positive_integer "$CAPACITY_TB"; then
  echo "Cluster reported insufficient capacity (<1 TB)." >&2
  exit 1
fi

nodes_json=$(get_cluster_nodes_json)
CLUSTER_NODE_COUNT=$(printf '%s' "$nodes_json" | jq -r '.num_records // ([.records[]] | length)')
if ! is_positive_integer "$CLUSTER_NODE_COUNT"; then
  echo "Could not determine cluster node count from API response." >&2
  exit 1
fi

BENCHMARK_MIN_VOL_SIZE_TB=$((CLUSTER_NODE_COUNT))

if [ -n "$VOLUME_STYLE" ]; then
  VOLUME_STYLE=$(normalize_input "$VOLUME_STYLE")
  VOLUME_STYLE=${VOLUME_STYLE,,}
fi

while true; do
  while true; do
    if [ -n "$VOLUME_STYLE" ]; then
      read -r -p "Enter volume type (flexvol/flexgroup) [$VOLUME_STYLE]: " style_input
    else
      read -r -p "Enter volume type (flexvol/flexgroup): " style_input
    fi
    style_input=$(normalize_input "$style_input")
    style_input=${style_input,,}
    if [ -z "$style_input" ] && [ -n "$VOLUME_STYLE" ]; then
      style_input=$VOLUME_STYLE
    fi
    if [ "$style_input" = "flexvol" ] || [ "$style_input" = "flexgroup" ]; then
      VOLUME_STYLE=$style_input
      break
    fi
    echo "Please enter flexvol or flexgroup." >&2
  done

  while true; do
    if [ -n "$VOL_NAME_PREFIX" ]; then
      read -r -p "Enter volume name prefix (for example customvol) [$VOL_NAME_PREFIX]: " prefix_input
    else
      read -r -p "Enter volume name prefix (for example customvol): " prefix_input
    fi
    prefix_input=$(normalize_input "$prefix_input")
    if [ -z "$prefix_input" ] && [ -n "$VOL_NAME_PREFIX" ]; then
      prefix_input=$VOL_NAME_PREFIX
    fi
    if [ -z "$prefix_input" ]; then
      echo "VOL_NAME_PREFIX is required." >&2
      continue
    fi
    if ! [[ "$prefix_input" =~ ^[A-Za-z0-9._-]+$ ]]; then
      echo "VOL_NAME_PREFIX must only include letters, numbers, dot, underscore, or dash." >&2
      continue
    fi
    VOL_NAME_PREFIX=$prefix_input
    break
  done

  volume_type_display=$(display_volume_type "$VOLUME_STYLE")

  while true; do
    if [ -n "$NUM_VOLS" ]; then
      read -r -p "Enter the number of ${volume_type_display} volumes to create [$NUM_VOLS]: " num_input
    else
      read -r -p "Enter the number of ${volume_type_display} volumes to create: " num_input
    fi
    num_input=$(normalize_input "$num_input")
    if [ -z "$num_input" ] && [ -n "$NUM_VOLS" ]; then
      num_input=$NUM_VOLS
    fi
    if ! is_positive_integer "$num_input"; then
      echo "Number of volumes must be a positive integer." >&2
      continue
    fi
    NUM_VOLS=$num_input
    break
  done

  while true; do
    if [ "$ENABLE_BENCHMARK_BEST_PRACTICES" = "true" ]; then
      benchmark_prompt_default="y"
    else
      benchmark_prompt_default="n"
    fi
    echo "NOTE: This configuration is intended for performance benchmarking. Some of the features may be applicable to your production workloads, but you should engage your NetApp sales team to confirm."
    read -r -p "Do you want to configure the volume for benchmarking best practices? (y/n) [$benchmark_prompt_default]: " benchmark_choice
    benchmark_choice=$(normalize_input "$benchmark_choice")
    benchmark_choice=${benchmark_choice,,}
    if [ -z "$benchmark_choice" ]; then
      benchmark_choice=$benchmark_prompt_default
    fi
    case "$benchmark_choice" in
      y|yes)
        ENABLE_BENCHMARK_BEST_PRACTICES=true
        while true; do
          if [ "$ENABLE_AGGRESSIVE_READAHEAD" = "true" ]; then
            read -r -p "Do you want to enable aggressive readahead? [Y/n]: " readahead_choice
          else
            read -r -p "Do you want to enable aggressive readahead? [y/N]: " readahead_choice
          fi
          readahead_choice=$(normalize_input "$readahead_choice")
          readahead_choice=${readahead_choice,,}
          if [ -z "$readahead_choice" ]; then
            if [ "$ENABLE_AGGRESSIVE_READAHEAD" = "true" ]; then
              readahead_choice="y"
            else
              readahead_choice="n"
            fi
          fi
          case "$readahead_choice" in
            y|yes)
              ENABLE_AGGRESSIVE_READAHEAD=true
              break
              ;;
            n|no)
              ENABLE_AGGRESSIVE_READAHEAD=false
              break
              ;;
            *)
              echo "Please enter y or n." >&2
              ;;
          esac
        done
        break
        ;;
      n|no)
        ENABLE_BENCHMARK_BEST_PRACTICES=false
        ENABLE_AGGRESSIVE_READAHEAD=false
        break
        ;;
      *)
        echo "Please enter y or n." >&2
        ;;
    esac
  done

  min_volume_size_tb=2
  if [ "$ENABLE_BENCHMARK_BEST_PRACTICES" = "true" ] && [ "$BENCHMARK_MIN_VOL_SIZE_TB" -gt "$min_volume_size_tb" ]; then
    min_volume_size_tb=$BENCHMARK_MIN_VOL_SIZE_TB
    echo "Benchmark minimum volume size is $min_volume_size_tb TB (10 x 100G x $CLUSTER_NODE_COUNT cluster node(s))."
  fi

  while true; do
    if [ -n "$VOL_SIZE_TB" ]; then
      read -r -p "Enter volume size in TB ($min_volume_size_tb..$CAPACITY_TB) [$VOL_SIZE_TB]: " size_input
    else
      read -r -p "Enter volume size in TB ($min_volume_size_tb..$CAPACITY_TB): " size_input
    fi
    size_input=$(normalize_input "$size_input")
    if [ -z "$size_input" ] && [ -n "$VOL_SIZE_TB" ]; then
      size_input=$VOL_SIZE_TB
    fi
    if ! is_positive_integer "$size_input"; then
      echo "Volume size must be a positive integer (TB)." >&2
      continue
    fi
    if [ "$size_input" -lt "$min_volume_size_tb" ] || [ "$size_input" -gt "$CAPACITY_TB" ]; then
      echo "Volume size must be between $min_volume_size_tb and $CAPACITY_TB TB." >&2
      continue
    fi
    VOL_SIZE_TB=$size_input
    break
  done

  read -r -p "Create $NUM_VOLS ${volume_type_display} volume(s)? (y=create, b=backout/change, n=cancel): " confirm_create
  confirm_create=$(normalize_input "$confirm_create")
  confirm_create=${confirm_create,,}
  case "$confirm_create" in
    y|yes)
      break
      ;;
    b|back|backout)
      continue
      ;;
    n|no)
      echo "Cancelled."
      exit 0
      ;;
    *)
      echo "Please enter y, b, or n." >&2
      ;;
  esac
done

VOL_SIZE_BYTES=$(echo "$VOL_SIZE_TB * $TB_BYTES" | bc)

volumes_json=$(api_request "GET" "https://$MGMT_IP/api/storage/volumes?fields=name&return_records=true&return_timeout=15")
declare -A EXISTING_NAMES=()
while IFS= read -r existing_name; do
  if [ -n "$existing_name" ]; then
    EXISTING_NAMES["$existing_name"]=1
  fi
done < <(printf '%s' "$volumes_json" | jq -r '.records[].name // empty')

CREATED_VOLUMES=()
next_suffix=1
created_count=0

while [ "$created_count" -lt "$NUM_VOLS" ]; do
  volume_name="${VOL_NAME_PREFIX}${next_suffix}"
  if [ -z "${EXISTING_NAMES[$volume_name]+x}" ]; then
    create_volume "$volume_name"
    CREATED_VOLUMES+=("$volume_name")
    EXISTING_NAMES["$volume_name"]=1
    created_count=$((created_count + 1))
  fi
  next_suffix=$((next_suffix + 1))
done

if [ "$ENABLE_BENCHMARK_BEST_PRACTICES" = "true" ]; then
  apply_benchmark_post_create_settings
fi

echo "Done. Created $NUM_VOLS ${volume_type_display} volume(s) of size ${VOL_SIZE_TB} TB."

while true; do
  read -r -p "Do you want to show these volumes? (y/n): " show_choice
  show_choice=$(normalize_input "$show_choice")
  show_choice=${show_choice,,}

  case "$show_choice" in
    y|yes)
      show_created_volumes
      break
      ;;
    n|no)
      break
      ;;
    *)
      echo "Please enter y or n." >&2
      ;;
  esac
done
