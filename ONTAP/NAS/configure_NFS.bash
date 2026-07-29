#!/bin/bash

set -euo pipefail

DEBUG=${DEBUG:-false}
DEBUG_LOG_FILE=${DEBUG_LOG_FILE:-}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

normalize_input() {
  printf '%s' "$1" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

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
Usage: configure_NFS.bash [--debug]

Create or modify ONTAP NFS server configuration through an interactive wizard.

Options:
  --debug   Enable verbose REST request/response tracing to a log file.
            Default path: <ONTAP/NAS>/logs/configure_NFS_debug_YYYYmmdd_HHMMSS.log
            Optional: set DEBUG_LOG_FILE=/path/to/file.log
EOF
}

init_debug_logging() {
  if [ "$DEBUG" != "true" ]; then
    return
  fi

  if [ -z "$DEBUG_LOG_FILE" ]; then
    DEBUG_LOG_FILE="$SCRIPT_DIR/logs/configure_NFS_debug_$(date +%Y%m%d_%H%M%S).log"
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
  local current_value=${!var_name:-}

  if [ -n "$current_value" ]; then
    return
  fi

  read -r -p "$prompt_text" current_value
  current_value=$(normalize_input "$current_value")
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
    return
  done
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

get_svms_json() {
  api_request "GET" "https://$MGMT_IP/api/svm/svms?fields=name,uuid,subtype&return_records=true&return_timeout=15&max_records=10000"
}

show_svms() {
  local svms_json=$1
  local rows

  rows=$(printf '%s' "$svms_json" | jq -r '
    .records[]
    | [.name, (.subtype // "-")]
    | @tsv
  ' | sort)

  if [ -z "$rows" ]; then
    echo "No SVMs returned by the API."
    return
  fi

  echo
  echo "Available SVM names:"
  while IFS=$'\t' read -r svm_name svm_subtype; do
    echo "  - $svm_name ($svm_subtype)"
  done <<< "$rows"
  echo
}

get_nfs_services_json() {
  api_request "GET" "https://$MGMT_IP/api/protocols/nfs/services?fields=svm.name,svm.uuid,enabled,protocol.v3_enabled,protocol.v40_enabled,protocol.v41_enabled,protocol.v42_enabled,protocol.v4_id_domain,transport.rdma_enabled&return_records=true&return_timeout=15&max_records=10000"
}

show_nfs_servers() {
  local nfs_json=$1
  local rows

  rows=$(printf '%s' "$nfs_json" | jq -r '
    .records[]
    | [
        (.svm.name // "-"),
        (
          [
            (if (.protocol.v3_enabled // false) then "v3" else empty end),
            (if (.protocol.v41_enabled // false) then "v4.1" else empty end),
            (if (.protocol.v42_enabled // false) then "v4.2" else empty end)
          ]
          | if length == 0 then "none" else join(",") end
        ),
        (if (.transport.rdma_enabled // false) then "enabled" else "disabled" end)
      ]
    | @tsv
  ' | sort)

  if [ -z "$rows" ]; then
    echo "No NFS servers returned by the API."
    return
  fi

  echo
  echo "Existing NFS servers:"
  while IFS=$'\t' read -r svm_name versions rdma_state; do
    echo "  - SVM: $svm_name | protocols: $versions | RDMA: $rdma_state"
  done <<< "$rows"
  echo
}

nfs_service_record_by_svm() {
  local nfs_json=$1
  local svm_name=$2

  printf '%s' "$nfs_json" | jq -c --arg svm "$svm_name" '
    [.records[] | select((.svm.name // "") == $svm)][0] // empty
  '
}

prompt_mode() {
  local input_value

  while true; do
    echo
    echo "Select operation:"
    echo "  1) Create an NFS server"
    echo "  2) Modify an existing NFS server"
    read -r -p "Choose 1 or 2 [1]: " input_value
    input_value=$(normalize_input "$input_value")
    if [ -z "$input_value" ]; then
      input_value="1"
    fi
    case "$input_value" in
      1)
        NFS_MODE="create"
        return
        ;;
      2)
        NFS_MODE="modify"
        return
        ;;
      *)
        echo "Please enter 1 or 2." >&2
        ;;
    esac
  done
}

prompt_target_svm() {
  local input_value
  local svms_json
  local nfs_json
  local service_record
  local existing_count

  if [ "$NFS_MODE" = "create" ]; then
    svms_json=$(get_svms_json)
    nfs_json=$(get_nfs_services_json)
    while true; do
      echo "Enter target SVM name: [type ? to list SVM names]"
      read -r -p "SVM name: " input_value
      input_value=$(normalize_input "$input_value")
      if [ "$input_value" = "?" ]; then
        show_svms "$svms_json"
        continue
      fi
      if [ -z "$input_value" ]; then
        echo "SVM name is required." >&2
        continue
      fi

      existing_count=$(printf '%s' "$svms_json" | jq -r --arg svm "$input_value" '[.records[] | select(.name == $svm)] | length')
      if [ "$existing_count" -eq 0 ]; then
        echo "SVM '$input_value' was not found. Type ? to list SVM names." >&2
        continue
      fi

      service_record=$(nfs_service_record_by_svm "$nfs_json" "$input_value")
      if [ -n "$service_record" ]; then
        echo "An NFS server already exists for SVM '$input_value'. Choose modify mode instead." >&2
        continue
      fi

      SVM_NAME=$input_value
      SVM_UUID=$(printf '%s' "$svms_json" | jq -r --arg svm "$SVM_NAME" '[.records[] | select(.name == $svm) | .uuid][0] // empty')
      return
    done
  fi

  while true; do
    echo "Enter SVM name to modify: [type ? to list existing NFS servers]"
    read -r -p "SVM name: " input_value
    input_value=$(normalize_input "$input_value")

    nfs_json=$(get_nfs_services_json)
    if [ "$input_value" = "?" ]; then
      show_nfs_servers "$nfs_json"
      continue
    fi
    if [ -z "$input_value" ]; then
      echo "SVM name is required." >&2
      continue
    fi

    service_record=$(nfs_service_record_by_svm "$nfs_json" "$input_value")
    if [ -z "$service_record" ]; then
      echo "No NFS server was found for SVM '$input_value'. Type ? to list existing NFS servers." >&2
      continue
    fi

    SVM_NAME=$input_value
    SVM_UUID=$(printf '%s' "$service_record" | jq -r '.svm.uuid // empty')
    EXISTING_NFS_RECORD=$service_record
    return
  done
}

parse_protocol_selection() {
  local selection=$1
  local token
  local seen_any=false

  PROTOCOL_V3_ENABLED=false
  PROTOCOL_V41_ENABLED=false
  PROTOCOL_V42_ENABLED=false
  PROTOCOL_V40_ENABLED=false

  IFS=',' read -r -a tokens <<< "$selection"
  for token in "${tokens[@]}"; do
    token=$(normalize_input "$token")
    if [ -z "$token" ]; then
      continue
    fi
    seen_any=true
    case "$token" in
      1)
        PROTOCOL_V3_ENABLED=true
        ;;
      2)
        PROTOCOL_V41_ENABLED=true
        ;;
      3)
        PROTOCOL_V42_ENABLED=true
        ;;
      4)
        PROTOCOL_V3_ENABLED=true
        PROTOCOL_V41_ENABLED=true
        PROTOCOL_V42_ENABLED=true
        ;;
      *)
        return 1
        ;;
    esac
  done

  [ "$seen_any" = "true" ]
}

protocol_default_selection() {
  local selections=()

  if [ "$NFS_MODE" = "modify" ] && [ -n "$EXISTING_NFS_RECORD" ]; then
    if [ "$(printf '%s' "$EXISTING_NFS_RECORD" | jq -r '.protocol.v3_enabled // false')" = "true" ]; then
      selections+=("1")
    fi
    if [ "$(printf '%s' "$EXISTING_NFS_RECORD" | jq -r '.protocol.v41_enabled // false')" = "true" ]; then
      selections+=("2")
    fi
    if [ "$(printf '%s' "$EXISTING_NFS_RECORD" | jq -r '.protocol.v42_enabled // false')" = "true" ]; then
      selections+=("3")
    fi
  else
    selections+=("1")
  fi

  if [ "${#selections[@]}" -eq 0 ]; then
    printf '%s' "1"
    return
  fi

  printf '%s' "$(IFS=, ; echo "${selections[*]}")"
}

prompt_nfs_protocols() {
  local selection_input
  local default_selection

  default_selection=$(protocol_default_selection)

  while true; do
    echo
    echo "Select NFS versions to enable:"
    echo "  1) NFSv3"
    echo "  2) NFSv4.1"
    echo "  3) NFSv4.2"
    echo "  4) Enable all"
    read -r -p "Enter number(s), comma-separated [$default_selection]: " selection_input
    selection_input=$(normalize_input "$selection_input")
    if [ -z "$selection_input" ]; then
      selection_input=$default_selection
    fi

    if parse_protocol_selection "$selection_input"; then
      return
    fi

    echo "Invalid selection. Use 1,2,3,4 (or comma-separated combinations)." >&2
  done
}

prompt_v4_id_domain_if_needed() {
  local domain_input
  local current_value=""
  local should_prompt=false

  if [ "$PROTOCOL_V41_ENABLED" = "true" ] || [ "$PROTOCOL_V42_ENABLED" = "true" ]; then
    should_prompt=true
  fi
  if [ "$APPLY_BENCHMARK_SETTINGS" = "true" ]; then
    should_prompt=true
  fi

  if [ "$should_prompt" != "true" ]; then
    SET_V4_ID_DOMAIN=false
    V4_ID_DOMAIN=""
    return
  fi

  if [ "$NFS_MODE" = "modify" ] && [ -n "$EXISTING_NFS_RECORD" ]; then
    current_value=$(printf '%s' "$EXISTING_NFS_RECORD" | jq -r '.protocol.v4_id_domain // empty')
  fi

  echo
  echo "NFSv4.x is enabled."
  echo "Default NFSv4 ID domain is defaultv4iddomain.com."
  echo "Leave blank to keep the default behavior."
  while true; do
    if [ -n "$current_value" ]; then
      read -r -p "Enter NFSv4 ID domain [$current_value]: " domain_input
    else
      read -r -p "Enter NFSv4 ID domain: " domain_input
    fi
    domain_input=$(normalize_input "$domain_input")
    if [ -z "$domain_input" ]; then
      if [ -n "$current_value" ]; then
        V4_ID_DOMAIN=$current_value
        SET_V4_ID_DOMAIN=true
      else
        V4_ID_DOMAIN=""
        SET_V4_ID_DOMAIN=false
      fi
      return
    fi
    V4_ID_DOMAIN=$domain_input
    SET_V4_ID_DOMAIN=true
    return
  done
}

prompt_benchmark_settings() {
  local choice
  local apply_choice

  APPLY_BENCHMARK_SETTINGS=false
  while true; do
    read -r -p "Apply recommended NFS settings for benchmarking? [y/N]: " choice
    choice=$(normalize_input "$choice")
    choice=${choice,,}
    case "$choice" in
      y|yes)
        echo
        echo "The following settings will be applied:"
        echo "  - Protocol: NFSv4.1"
        echo "  - pNFS: Enabled"
        echo "  - Session Trunking: Enabled"
        echo "  - v4.x Session Slots: 64"
        echo "  - TCP Max Transfer Size: 262144"
        echo "  - Mount rootonly: Disabled"
        echo "  - NFS rootonly: Disabled (mapped through NFS root-only controls available in REST)"
        echo "  - NFSv4.0: Disabled"
        echo "  - V3 64 bit IDs: Enabled"
        echo "  - V4 64 bit IDs: Enabled"
        echo "  - V3 hide snapshot: Enabled"
        while true; do
          read -r -p "Apply these benchmarking settings now? [y/N]: " apply_choice
          apply_choice=$(normalize_input "$apply_choice")
          apply_choice=${apply_choice,,}
          case "$apply_choice" in
            y|yes)
              APPLY_BENCHMARK_SETTINGS=true
              PROTOCOL_V3_ENABLED=false
              PROTOCOL_V40_ENABLED=false
              PROTOCOL_V41_ENABLED=true
              PROTOCOL_V42_ENABLED=false
              return
              ;;
            ""|n|no)
              return
              ;;
            *)
              echo "Please enter y or n." >&2
              ;;
          esac
        done
        ;;
      ""|n|no)
        return
        ;;
      *)
        echo "Please enter y or n." >&2
        ;;
    esac
  done
}

prompt_rdma_enable() {
  local rdma_choice
  local default_choice="N"

  if [ "$NFS_MODE" = "modify" ] && [ -n "$EXISTING_NFS_RECORD" ]; then
    if [ "$(printf '%s' "$EXISTING_NFS_RECORD" | jq -r '.transport.rdma_enabled // false')" = "true" ]; then
      default_choice="Y"
    fi
  fi

  while true; do
    if [ "$default_choice" = "Y" ]; then
      read -r -p "Enable RDMA on the NFS server? [Y/n]: " rdma_choice
    else
      read -r -p "Enable RDMA on the NFS server? [y/N]: " rdma_choice
    fi
    rdma_choice=$(normalize_input "$rdma_choice")
    rdma_choice=${rdma_choice,,}

    if [ -z "$rdma_choice" ]; then
      if [ "$default_choice" = "Y" ]; then
        ENABLE_RDMA=true
      else
        ENABLE_RDMA=false
      fi
      return
    fi

    case "$rdma_choice" in
      y|yes)
        ENABLE_RDMA=true
        return
        ;;
      n|no)
        ENABLE_RDMA=false
        return
        ;;
      *)
        echo "Please enter y or n." >&2
        ;;
    esac
  done
}

build_nfs_payload() {
  local include_svm_in_payload=${1:-false}

  jq -n \
    --arg svm_name "$SVM_NAME" \
    --argjson include_svm "$include_svm_in_payload" \
    --argjson v3_enabled "$PROTOCOL_V3_ENABLED" \
    --argjson v40_enabled "$PROTOCOL_V40_ENABLED" \
    --argjson v41_enabled "$PROTOCOL_V41_ENABLED" \
    --argjson v42_enabled "$PROTOCOL_V42_ENABLED" \
    --argjson rdma_enabled "$ENABLE_RDMA" \
    --arg v4_id_domain "$V4_ID_DOMAIN" \
    --argjson set_v4_id_domain "$SET_V4_ID_DOMAIN" \
    --argjson apply_benchmark "$APPLY_BENCHMARK_SETTINGS" \
    '
    (
      {
        protocol: {
          v3_enabled: $v3_enabled,
          v40_enabled: $v40_enabled,
          v41_enabled: $v41_enabled,
          v42_enabled: $v42_enabled
        },
        transport: {
          rdma_enabled: $rdma_enabled
        }
      }
      + (if $set_v4_id_domain then { protocol: { v4_id_domain: $v4_id_domain } } else {} end)
      + (if $apply_benchmark then {
          protocol: {
            v3_enabled: false,
            v40_enabled: false,
            v41_enabled: true,
            v42_enabled: false,
            v4_session_slots: 64,
            v3_64bit_identifiers_enabled: true,
            v4_64bit_identifiers_enabled: true,
            v3_features: {
              mount_root_only: false,
              hide_snapshot_enabled: true
            },
            v41_features: {
              pnfs_enabled: true,
              trunking_enabled: true
            }
          },
          transport: {
            tcp_max_transfer_size: 262144
          }
        } else {} end)
    )
    + (if $include_svm then { svm: { name: $svm_name } } else {} end)
    '
}

get_svm_data_lifs_json() {
  local encoded_svm
  encoded_svm=$(uri_encode "$SVM_NAME")
  api_request "GET" "https://$MGMT_IP/api/network/ip/interfaces?svm.name=$encoded_svm&fields=name,uuid,scope,services,service_policy.name&return_records=true&return_timeout=15&max_records=10000"
}

collect_data_lifs() {
  local lifs_json=$1

  mapfile -t DATA_LIFS < <(
    printf '%s' "$lifs_json" | jq -r '
      .records[]
      | select((.scope // "") == "svm")
      | . as $lif
      | select(
          (
            ($lif.services // [])
            | map(
                if type == "string"
                then ascii_downcase
                else ((.name // "") | ascii_downcase)
                end
              )
            | any(startswith("data_"))
          )
          or
          (((.service_policy.name // "") | ascii_downcase) | contains("data"))
        )
      | [.name, .uuid]
      | @tsv
    '
  )
}

invoke_create_interfaces_for_rdma() {
  local create_script
  create_script="$SCRIPT_DIR/../networking/create_interfaces.bash"

  if [ ! -f "$create_script" ]; then
    echo "Unable to find create interfaces script at: $create_script" >&2
    exit 1
  fi

  echo
  echo "Launching interface creation script so data LIFs can be created with RDMA support."
  MGMT_IP="$MGMT_IP" AUTH_TOK="$AUTH_TOK" SVM="$SVM_NAME" ENABLE_RDMA=true bash "$create_script"
}

enable_rdma_on_data_lifs() {
  local lifs_json
  local create_choice
  local lif_name
  local lif_uuid
  local payload

  lifs_json=$(get_svm_data_lifs_json)
  collect_data_lifs "$lifs_json"

  if [ "${#DATA_LIFS[@]}" -eq 0 ]; then
    while true; do
      echo "No data-role network interfaces were found in SVM '$SVM_NAME'."
      read -r -p "Would you like to create them now using create_interfaces.bash? [y/N]: " create_choice
      create_choice=$(normalize_input "$create_choice")
      create_choice=${create_choice,,}
      case "$create_choice" in
        y|yes)
          invoke_create_interfaces_for_rdma
          lifs_json=$(get_svm_data_lifs_json)
          collect_data_lifs "$lifs_json"
          if [ "${#DATA_LIFS[@]}" -eq 0 ]; then
            echo "No data-role interfaces found after interface creation. RDMA LIF updates skipped."
            return
          fi
          break
          ;;
        ""|n|no)
          echo "Skipping data LIF RDMA updates."
          return
          ;;
        *)
          echo "Please enter y or n." >&2
          ;;
      esac
    done
  fi

  payload=$(jq -n '{ rdma_protocols: ["roce"] }')
  echo
  echo "Enabling RDMA (roce) on existing data-role interfaces in SVM '$SVM_NAME':"
  for lif_entry in "${DATA_LIFS[@]}"; do
    IFS=$'\t' read -r lif_name lif_uuid <<< "$lif_entry"
    echo "  - Updating $lif_name"
    api_request "PATCH" "https://$MGMT_IP/api/network/ip/interfaces/$lif_uuid?return_timeout=0&return_records=false" "$payload" >/dev/null
  done
}

apply_nfs_configuration() {
  local payload

  if [ "$NFS_MODE" = "create" ]; then
    payload=$(build_nfs_payload true)
    debug_print_json "Final NFS payload" "$payload"
    echo
    echo "Creating NFS server configuration on SVM '$SVM_NAME'..."
    api_request "POST" "https://$MGMT_IP/api/protocols/nfs/services?return_timeout=0&return_records=false" "$payload" >/dev/null
  else
    payload=$(build_nfs_payload false)
    debug_print_json "Final NFS payload" "$payload"
    echo
    echo "Modifying NFS server configuration on SVM '$SVM_NAME'..."
    api_request "PATCH" "https://$MGMT_IP/api/protocols/nfs/services/$SVM_UUID?return_timeout=0&return_records=false" "$payload" >/dev/null
  fi

  echo "NFS configuration request completed for SVM '$SVM_NAME'."
}

parse_args "$@"
init_debug_logging

require_command curl
require_command jq

MGMT_IP=${MGMT_IP:-}
AUTH_TOK=${AUTH_TOK:-}
NFS_MODE=""
SVM_NAME=""
SVM_UUID=""
EXISTING_NFS_RECORD=""
PROTOCOL_V3_ENABLED=false
PROTOCOL_V40_ENABLED=false
PROTOCOL_V41_ENABLED=false
PROTOCOL_V42_ENABLED=false
SET_V4_ID_DOMAIN=false
V4_ID_DOMAIN=""
ENABLE_RDMA=false
APPLY_BENCHMARK_SETTINGS=false
DATA_LIFS=()

prompt_if_empty MGMT_IP "Enter cluster management IP: "
prompt_auth_token
prompt_mode
prompt_target_svm
prompt_nfs_protocols
prompt_v4_id_domain_if_needed
prompt_benchmark_settings
prompt_v4_id_domain_if_needed
prompt_rdma_enable
apply_nfs_configuration

if [ "$ENABLE_RDMA" = "true" ]; then
  enable_rdma_on_data_lifs
fi

echo
echo "configure_NFS completed."
