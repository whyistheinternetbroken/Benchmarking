#!/bin/bash

set -euo pipefail

DEBUG=${DEBUG:-false}
DEBUG_LOG_FILE=${DEBUG_LOG_FILE:-}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

require_command() {
  local cmd=$1
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Required command not found: $cmd" >&2
    exit 1
  fi
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
Usage: create_interfaces.bash [--debug]

Options:
  --debug   Enable verbose REST request/response tracing to a log file.
            Default path: <networking>/logs/create_interfaces_debug_YYYYmmdd_HHMMSS.log
            Optional: set DEBUG_LOG_FILE=/path/to/file.log
EOF
}

init_debug_logging() {
  if [ "$DEBUG" != "true" ]; then
    return
  fi

  if [ -z "$DEBUG_LOG_FILE" ]; then
    DEBUG_LOG_FILE="$SCRIPT_DIR/logs/create_interfaces_debug_$(date +%Y%m%d_%H%M%S).log"
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

is_valid_ipv4() {
  local ip=$1
  local IFS=.
  local -a octets=()
  local octet

  if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    return 1
  fi

  read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do
    if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
      return 1
    fi
  done
}

validate_data_ips() {
  local raw_value=$1
  local normalized
  local entry

  DATA_IP_LIST=()
  IFS=',' read -r -a raw_ips <<< "$raw_value"

  for entry in "${raw_ips[@]}"; do
    normalized=$(normalize_input "$entry")
    if [ -z "$normalized" ]; then
      continue
    fi
    if ! is_valid_ipv4 "$normalized"; then
      echo "Invalid IPv4 address: $normalized" >&2
      return 1
    fi
    DATA_IP_LIST+=("$normalized")
  done

  if [ "${#DATA_IP_LIST[@]}" -eq 0 ]; then
    echo "At least one data IP is required." >&2
    return 1
  fi
}

get_nodes_json() {
  api_request "GET" "https://$MGMT_IP/api/cluster/nodes?fields=name&return_records=true&return_timeout=15&max_records=10000"
}

show_nodes() {
  local nodes_json=$1
  local node_names

  node_names=$(printf '%s' "$nodes_json" | jq -r '.records[].name // empty' | sort)
  if [ -z "$node_names" ]; then
    echo "No node names returned by the API."
    return
  fi

  echo
  echo "Available node names:"
  while IFS= read -r node_name; do
    echo "  - $node_name"
  done <<< "$node_names"
  echo
}

node_exists() {
  local node_name=$1
  local nodes_json=$2
  local count
  count=$(printf '%s' "$nodes_json" | jq -r --arg node "$node_name" '[.records[] | select(.name == $node)] | length')
  [ "$count" -gt 0 ]
}

prompt_node_name() {
  local var_name=$1
  local prompt_label=$2
  local current_value=${!var_name:-}
  local input_value
  local nodes_json

  while true; do
    echo "Provide ? to list node names"
    if [ -n "$current_value" ]; then
      read -r -p "$prompt_label [$current_value]: " input_value
    else
      read -r -p "$prompt_label: " input_value
    fi

    input_value=$(normalize_input "$input_value")
    if [ "$input_value" = "?" ]; then
      nodes_json=$(get_nodes_json)
      show_nodes "$nodes_json"
      continue
    fi

    if [ -z "$input_value" ] && [ -n "$current_value" ]; then
      input_value=$current_value
    fi

    if [ -z "$input_value" ]; then
      echo "$var_name is required." >&2
      continue
    fi

    nodes_json=$(get_nodes_json)
    if ! node_exists "$input_value" "$nodes_json"; then
      echo "Node '$input_value' was not found. Type ? to list available node names." >&2
      continue
    fi

    printf -v "$var_name" '%s' "$input_value"
    return
  done
}

get_svm_routes_json() {
  local encoded_svm
  encoded_svm=$(uri_encode "$SVM")
  api_request "GET" "https://$MGMT_IP/api/network/ip/routes?svm.name=$encoded_svm&fields=svm.name,destination,gateway&return_records=true&return_timeout=15&max_records=10000"
}

has_default_gateway_route() {
  local routes_json=$1
  local count
  count=$(printf '%s' "$routes_json" | jq -r '
    [
      .records[]
      | select(
          ((.destination.network // .destination.cidr // "") == "0.0.0.0/0")
          or
          (
            ((.destination.address // .destination.ip // "") == "0.0.0.0")
            and
            (
              ((.destination.netmask // "") == "0.0.0.0")
              or
              ((.destination.prefix_length // -1) == 0)
            )
          )
        )
    ]
    | length
  ')
  [ "$count" -gt 0 ]
}

create_default_gateway_route() {
  local gateway_ip=$1
  local payload

  payload=$(jq -n \
    --arg svm_name "$SVM" \
    --arg gateway_ip "$gateway_ip" \
    '{
      svm: { name: $svm_name },
      destination: {
        address: "0.0.0.0",
        netmask: "0.0.0.0"
      },
      gateway: $gateway_ip
    }')

  echo "Adding default gateway route ($gateway_ip) to SVM '$SVM'"
  api_request "POST" "https://$MGMT_IP/api/network/ip/routes?return_timeout=0&return_records=false" "$payload" >/dev/null
}

ensure_default_gateway_for_svm() {
  local routes_json
  local add_gateway_choice
  local gateway_input

  routes_json=$(get_svm_routes_json)
  if has_default_gateway_route "$routes_json"; then
    echo "Default gateway route already exists for SVM '$SVM'."
    return
  fi

  echo "No default gateway route found for SVM '$SVM'."
  while true; do
    read -r -p "Would you like to add a default gateway route now? [y/N]: " add_gateway_choice
    add_gateway_choice=$(normalize_input "$add_gateway_choice")
    add_gateway_choice=${add_gateway_choice,,}
    case "$add_gateway_choice" in
      y|yes)
        while true; do
          if [ -n "${DEFAULT_GATEWAY:-}" ]; then
            read -r -p "Enter default gateway IP [$DEFAULT_GATEWAY]: " gateway_input
          else
            read -r -p "Enter default gateway IP: " gateway_input
          fi
          gateway_input=$(normalize_input "$gateway_input")
          if [ -z "$gateway_input" ] && [ -n "${DEFAULT_GATEWAY:-}" ]; then
            gateway_input=$DEFAULT_GATEWAY
          fi
          if ! is_valid_ipv4 "$gateway_input"; then
            echo "Default gateway must be a valid IPv4 address." >&2
            continue
          fi
          DEFAULT_GATEWAY=$gateway_input
          create_default_gateway_route "$DEFAULT_GATEWAY"
          return
        done
        ;;
      ""|n|no)
        echo "Continuing without creating a default gateway route."
        return
        ;;
      *)
        echo "Please enter y or n." >&2
        ;;
    esac
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

extract_last_octet() {
  local ip_address=$1
  printf '%s' "${ip_address##*.}"
}

build_lif_name() {
  local ip_address=$1
  local ip_octet
  ip_octet=$(extract_last_octet "$ip_address")
  printf '%s_%s' "$LIF_PREFIX" "$ip_octet"
}

select_location_for_index() {
  local idx=$1
  local pattern=$((idx % 4))

  case "$pattern" in
    0)
      SELECTED_NODE=$NODE1
      SELECTED_PORT=$DATA_PORT1
      ;;
    1)
      SELECTED_NODE=$NODE1
      SELECTED_PORT=$DATA_PORT2
      ;;
    2)
      SELECTED_NODE=$NODE2
      SELECTED_PORT=$DATA_PORT1
      ;;
    *)
      SELECTED_NODE=$NODE2
      SELECTED_PORT=$DATA_PORT2
      ;;
  esac
}

build_payload() {
  local lif_name=$1
  local data_ip=$2
  local node_name=$3
  local port_name=$4

  jq -n \
    --arg lif_name "$lif_name" \
    --arg svm_name "$SVM" \
    --arg ip_address "$data_ip" \
    --arg data_mask "$DATA_MASK" \
    --arg node_name "$node_name" \
    --arg port_name "$port_name" \
    '{
      name: $lif_name,
      scope: "svm",
      svm: { name: $svm_name },
      ip: {
        address: $ip_address,
        netmask: $data_mask
      },
      location: {
        home_node: $node_name,
        home_port: $port_name
      }
    }'
}

create_lif() {
  local data_ip=$1
  local node_name=$2
  local port_name=$3
  local lif_name
  local payload

  lif_name=$(build_lif_name "$data_ip")
  payload=$(build_payload "$lif_name" "$data_ip" "$node_name" "$port_name")

  echo "Creating interface $lif_name with IP address $data_ip on $node_name/$port_name"
  api_request "POST" "https://$MGMT_IP/api/network/ip/interfaces?return_timeout=0&return_records=false" "$payload" >/dev/null
}

parse_args "$@"
init_debug_logging

require_command curl
require_command jq

MGMT_IP=${MGMT_IP:-}
AUTH_TOK=${AUTH_TOK:-}
SVM=${SVM:-}
LIF_PREFIX=${LIF_PREFIX:-data}
DATA_MASK=${DATA_MASK:-255.255.248.0}
NODE1=${NODE1:-}
NODE2=${NODE2:-}
DATA_PORT1=${DATA_PORT1:-}
DATA_PORT2=${DATA_PORT2:-}
DATA_IPS=${DATA_IPS:-}
DEFAULT_GATEWAY=${DEFAULT_GATEWAY:-${DATA_GATEWAY:-}}

if [ -z "$DATA_IPS" ]; then
  legacy_ips=()
  for legacy_var in DATA_IP1 DATA_IP2 DATA_IP3 DATA_IP4 DATA_IP5 DATA_IP6; do
    legacy_val=${!legacy_var:-}
    if [ -n "$legacy_val" ]; then
      legacy_ips+=("$legacy_val")
    fi
  done
  if [ "${#legacy_ips[@]}" -gt 0 ]; then
    DATA_IPS=$(IFS=, ; echo "${legacy_ips[*]}")
  fi
fi

prompt_if_empty MGMT_IP "Enter cluster management IP: "
prompt_auth_token
prompt_if_empty SVM "Enter SVM name: "
ensure_default_gateway_for_svm

while true; do
  if [ -n "$LIF_PREFIX" ]; then
    read -r -p "Enter LIF prefix [$LIF_PREFIX]: " lif_prefix_input
  else
    read -r -p "Enter LIF prefix: " lif_prefix_input
  fi
  lif_prefix_input=$(normalize_input "$lif_prefix_input")
  if [ -z "$lif_prefix_input" ] && [ -n "$LIF_PREFIX" ]; then
    lif_prefix_input=$LIF_PREFIX
  fi
  if [ -z "$lif_prefix_input" ]; then
    echo "LIF prefix is required." >&2
    continue
  fi
  LIF_PREFIX=$lif_prefix_input
  break
done

while true; do
  if [ -n "$DATA_MASK" ]; then
    read -r -p "Enter netmask in dotted decimal [$DATA_MASK]: " data_mask_input
  else
    read -r -p "Enter netmask in dotted decimal: " data_mask_input
  fi
  data_mask_input=$(normalize_input "$data_mask_input")
  if [ -z "$data_mask_input" ] && [ -n "$DATA_MASK" ]; then
    data_mask_input=$DATA_MASK
  fi
  if ! is_valid_ipv4 "$data_mask_input"; then
    echo "Netmask must be a valid dotted IPv4 value." >&2
    continue
  fi
  DATA_MASK=$data_mask_input
  break
done

prompt_node_name NODE1 "Enter node 1 name"
prompt_node_name NODE2 "Enter node 2 name"
prompt_if_empty DATA_PORT1 "Enter data port 1 name: "
prompt_if_empty DATA_PORT2 "Enter data port 2 name: "

while true; do
  if [ -n "$DATA_IPS" ]; then
    read -r -p "Enter data interface IPs (comma-separated) [$DATA_IPS]: " data_ips_input
  else
    read -r -p "Enter data interface IPs (comma-separated): " data_ips_input
  fi
  data_ips_input=$(normalize_input "$data_ips_input")
  if [ -z "$data_ips_input" ] && [ -n "$DATA_IPS" ]; then
    data_ips_input=$DATA_IPS
  fi
  if validate_data_ips "$data_ips_input"; then
    DATA_IPS=$data_ips_input
    break
  fi
done

echo
echo "Interfaces to create in SVM '$SVM':"
for idx in "${!DATA_IP_LIST[@]}"; do
  data_ip=${DATA_IP_LIST[$idx]}
  lif_name=$(build_lif_name "$data_ip")
  select_location_for_index "$idx"
  echo "  - $lif_name ($data_ip) on $SELECTED_NODE/$SELECTED_PORT"
done
echo

while true; do
  read -r -p "Proceed to create ${#DATA_IP_LIST[@]} interface(s)? [y/N]: " confirm_create
  confirm_create=$(normalize_input "$confirm_create")
  confirm_create=${confirm_create,,}
  case "$confirm_create" in
    y|yes)
      break
      ;;
    ""|n|no)
      echo "Cancelled."
      exit 0
      ;;
    *)
      echo "Please enter y or n." >&2
      ;;
  esac
done

for idx in "${!DATA_IP_LIST[@]}"; do
  data_ip=${DATA_IP_LIST[$idx]}
  select_location_for_index "$idx"
  create_lif "$data_ip" "$SELECTED_NODE" "$SELECTED_PORT"
done

echo
echo "Create requests submitted for ${#DATA_IP_LIST[@]} interface(s) in SVM '$SVM'."
