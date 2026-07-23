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

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
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

is_back_command() {
  local value
  value=$(normalize_input "$1")
  value=${value,,}
  [ "$value" = "b" ] || [ "$value" = "back" ]
}

print_hint() {
  echo "  - $1"
}

get_data_svms_json() {
  api_request "GET" "https://$MGMT_IP/api/svm/svms?fields=name,subtype&return_records=true&return_timeout=15&max_records=10000"
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

svm_exists() {
  local svm_name=$1
  local svms_json=$2
  local count
  count=$(printf '%s' "$svms_json" | jq -r --arg svm "$svm_name" '[.records[] | select(.name == $svm)] | length')
  [ "$count" -gt 0 ]
}

prompt_svm_name() {
  local current_value=${SVM:-}
  local input_value
  local svms_json

  while true; do
    print_hint "Provide ? to list SVM names"
    print_hint "Type B to go back to previous question."
    if [ -n "$current_value" ]; then
      read -r -p "Enter SVM name [$current_value]: " input_value
    else
      read -r -p "Enter SVM name: " input_value
    fi

    input_value=$(normalize_input "$input_value")
    if [ "$input_value" = "?" ]; then
      svms_json=$(get_data_svms_json)
      show_svms "$svms_json"
      continue
    fi

    if is_back_command "$input_value"; then
      return 2
    fi

    if [ -z "$input_value" ] && [ -n "$current_value" ]; then
      input_value=$current_value
    fi

    if [ -z "$input_value" ]; then
      echo "SVM is required." >&2
      continue
    fi

    svms_json=$(get_data_svms_json)
    if ! svm_exists "$input_value" "$svms_json"; then
      echo "SVM '$input_value' was not found. Type ? to list available SVM names." >&2
      continue
    fi

    SVM=$input_value
    return
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

validate_data_ports() {
  local raw_value=$1
  local normalized
  local entry

  DATA_PORT_LIST=()
  IFS=',' read -r -a raw_ports <<< "$raw_value"

  for entry in "${raw_ports[@]}"; do
    normalized=$(normalize_input "$entry")
    if [ -z "$normalized" ]; then
      continue
    fi
    DATA_PORT_LIST+=("$normalized")
  done

  if [ "${#DATA_PORT_LIST[@]}" -eq 0 ]; then
    echo "At least one data port is required." >&2
    return 1
  fi
}

validate_port_families() {
  local raw_value=$1
  local normalized
  local entry

  DATA_PORT_FAMILY_LIST=()
  IFS=',' read -r -a raw_families <<< "$raw_value"

  for entry in "${raw_families[@]}"; do
    normalized=$(normalize_input "$entry")
    if [ -z "$normalized" ]; then
      continue
    fi
    DATA_PORT_FAMILY_LIST+=("$normalized")
  done

  if [ "${#DATA_PORT_FAMILY_LIST[@]}" -eq 0 ]; then
    echo "At least one port family is required." >&2
    return 1
  fi
}

get_nodes_json() {
  api_request "GET" "https://$MGMT_IP/api/cluster/nodes?fields=name&return_records=true&return_timeout=15&max_records=10000"
}

load_node_ports() {
  local node_name=$1
  local filter_broadcast_domain=${PORT_BROADCAST_DOMAIN_NAME:-}

  if [ -z "$BROADCAST_DOMAINS_PORTS_JSON" ]; then
    BROADCAST_DOMAINS_PORTS_JSON=$(get_broadcast_domains_json)
  fi

  mapfile -t NODE_PORT_NAMES < <(
    printf '%s' "$BROADCAST_DOMAINS_PORTS_JSON" | jq -r --arg node "$node_name" --arg bd "$filter_broadcast_domain" '
      .records[]
      | select(($bd == "") or ((.name // "") == $bd))
      | .ports[]?
      | select((.node.name // "") == $node)
      | .name // empty
    ' | sort
  )
}

show_available_ports() {
  local node_name
  local port_name
  local found_any=false

  echo
  if [ -n "${PORT_BROADCAST_DOMAIN_NAME:-}" ]; then
    echo "Available ports in broadcast domain '$PORT_BROADCAST_DOMAIN_NAME':"
  else
    echo "Available ports:"
  fi

  for node_name in "${TARGET_NODES[@]}"; do
    load_node_ports "$node_name"
    for port_name in "${NODE_PORT_NAMES[@]}"; do
      echo "  - $node_name/$port_name"
      found_any=true
    done
  done

  if [ "$found_any" = "false" ]; then
    echo "No matching ports were returned by the API."
  fi
  echo
}

append_unique_value() {
  local value=$1
  local existing

  for existing in "${MATCHED_PORTS[@]}"; do
    if [ "$existing" = "$value" ]; then
      return
    fi
  done

  MATCHED_PORTS+=("$value")
}

resolve_balancing_ports_for_node() {
  local node_name=$1
  local port_token
  local port_name
  local matched=false

  load_node_ports "$node_name"
  MATCHED_PORTS=()

  for port_token in "${DATA_PORT_LIST[@]}"; do
    matched=false
    for port_name in "${NODE_PORT_NAMES[@]}"; do
      if [ "$port_name" = "$port_token" ]; then
        append_unique_value "$port_name"
        matched=true
        break
      fi
    done

    if [ "$matched" = "true" ]; then
      continue
    fi

    for port_name in "${NODE_PORT_NAMES[@]}"; do
      if [[ "$port_name" == "$port_token"* ]]; then
        append_unique_value "$port_name"
        matched=true
      fi
    done
  done

  [ "${#MATCHED_PORTS[@]}" -gt 0 ]
}

resolve_fixed_port_for_node() {
  local node_name=$1
  local port_token=$2
  local port_name

  load_node_ports "$node_name"

  for port_name in "${NODE_PORT_NAMES[@]}"; do
    if [ "$port_name" = "$port_token" ]; then
      printf '%s' "$port_name"
      return 0
    fi
  done

  for port_name in "${NODE_PORT_NAMES[@]}"; do
    if [[ "$port_name" == "$port_token"* ]]; then
      printf '%s' "$port_name"
      return 0
    fi
  done

  return 1
}

validate_port_families_for_target_nodes() {
  local node_name
  local port_name
  local family
  local matched_count

  if ! validate_port_families "$DATA_PORT_FAMILIES" >/dev/null 2>&1; then
    return 1
  fi

  for node_name in "${TARGET_NODES[@]}"; do
    load_node_ports "$node_name"
    matched_count=0
    for port_name in "${NODE_PORT_NAMES[@]}"; do
      for family in "${DATA_PORT_FAMILY_LIST[@]}"; do
        if [[ "$port_name" == "$family"* ]]; then
          matched_count=$((matched_count + 1))
          break
        fi
      done
    done

    if [ "$matched_count" -le 0 ]; then
      echo "No ports on node '$node_name' matched the requested port families: $DATA_PORT_FAMILIES" >&2
      return 1
    fi
  done
}

validate_selected_ports_for_strategy() {
  local node_index
  local node_name
  local selected_index

  if [ "$USE_SAME_DATA_PORT" = "true" ]; then
    if [ "${#DATA_PORT_LIST[@]}" -ne 1 ]; then
      echo "Enter exactly one data port when using the same port on all nodes." >&2
      return 1
    fi

    for node_name in "${TARGET_NODES[@]}"; do
      if ! resolve_fixed_port_for_node "$node_name" "${DATA_PORT_LIST[0]}" >/dev/null; then
        if [ -n "${PORT_BROADCAST_DOMAIN_NAME:-}" ]; then
          echo "Port '${DATA_PORT_LIST[0]}' is not in broadcast domain '$PORT_BROADCAST_DOMAIN_NAME' on node '$node_name'." >&2
        else
          echo "Port '${DATA_PORT_LIST[0]}' was not found on node '$node_name'." >&2
        fi
        return 1
      fi
    done
    return 0
  fi

  if [ "$BALANCE_ACROSS_PORTS" = "true" ]; then
    for node_name in "${TARGET_NODES[@]}"; do
      if ! resolve_balancing_ports_for_node "$node_name"; then
        if [ -n "${PORT_BROADCAST_DOMAIN_NAME:-}" ]; then
          echo "The selected ports did not match any ports in broadcast domain '$PORT_BROADCAST_DOMAIN_NAME' on node '$node_name'." >&2
        else
          echo "The selected ports did not match any ports on node '$node_name'." >&2
        fi
        return 1
      fi
    done
    return 0
  fi

  for node_index in "${!TARGET_NODES[@]}"; do
    node_name=${TARGET_NODES[$node_index]}
    selected_index=$(( node_index % ${#DATA_PORT_LIST[@]} ))
    if ! resolve_fixed_port_for_node "$node_name" "${DATA_PORT_LIST[$selected_index]}" >/dev/null; then
      if [ -n "${PORT_BROADCAST_DOMAIN_NAME:-}" ]; then
        echo "Port '${DATA_PORT_LIST[$selected_index]}' is not in broadcast domain '$PORT_BROADCAST_DOMAIN_NAME' on node '$node_name'." >&2
      else
        echo "Port '${DATA_PORT_LIST[$selected_index]}' was not found on node '$node_name'." >&2
      fi
      return 1
    fi
  done
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
  local allow_all=${3:-false}
  local current_value=${!var_name:-}
  local input_value
  local nodes_json

  while true; do
    print_hint "Provide ? to list node names"
    print_hint "Type B to go back to previous question."
    if [ "$allow_all" = "true" ]; then
      print_hint "Type all to add LIFs to all nodes."
    fi
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

    if is_back_command "$input_value"; then
      return 2
    fi

    if [ "$allow_all" = "true" ]; then
      if [ "${input_value,,}" = "all" ]; then
        printf -v "$var_name" '%s' "__ALL__"
        return
      fi
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

get_all_node_names() {
  local nodes_json=$1
  printf '%s' "$nodes_json" | jq -r '.records[].name // empty' | sort
}

get_subnets_json() {
  api_request "GET" "https://$MGMT_IP/api/network/ip/subnets?fields=name,broadcast_domain.name&return_records=true&return_timeout=15&max_records=10000"
}

get_broadcast_domains_json() {
  api_request "GET" "https://$MGMT_IP/api/network/ethernet/broadcast-domains?fields=name,uuid,ipspace.name,ports.node.name,ports.name&return_records=true&return_timeout=15&max_records=10000"
}

get_ipspaces_json() {
  api_request "GET" "https://$MGMT_IP/api/network/ipspaces?fields=name&return_records=true&return_timeout=15&max_records=10000"
}

show_subnets() {
  local subnets_json=$1
  local subnet_names

  subnet_names=$(printf '%s' "$subnets_json" | jq -r '.records[].name // empty' | sort)
  if [ -z "$subnet_names" ]; then
    echo "No subnet names returned by the API."
    return
  fi

  echo
  echo "Available subnet names:"
  while IFS= read -r subnet_name; do
    echo "  - $subnet_name"
  done <<< "$subnet_names"
  echo
}

show_broadcast_domains() {
  local broadcast_domains_json=$1
  local rows

  rows=$(printf '%s' "$broadcast_domains_json" | jq -r '
    .records[]
    | [.name, (.ipspace.name // "-")]
    | @tsv
  ' | sort)

  if [ -z "$rows" ]; then
    echo "No broadcast domains returned by the API."
    return
  fi

  echo
  echo "Available broadcast domains:"
  while IFS=$'\t' read -r bd_name ipspace_name; do
    echo "  - $bd_name (IPspace: $ipspace_name)"
  done <<< "$rows"
  echo
}

show_ipspaces() {
  local ipspaces_json=$1
  local ipspace_names

  ipspace_names=$(printf '%s' "$ipspaces_json" | jq -r '.records[].name // empty' | sort)
  if [ -z "$ipspace_names" ]; then
    echo "No IPspaces returned by the API."
    return
  fi

  echo
  echo "Available IPspaces:"
  while IFS= read -r ipspace_name; do
    echo "  - $ipspace_name"
  done <<< "$ipspace_names"
  echo
}

subnet_exists() {
  local subnet_name=$1
  local subnets_json=$2
  local count
  count=$(printf '%s' "$subnets_json" | jq -r --arg subnet "$subnet_name" '[.records[] | select(.name == $subnet)] | length')
  [ "$count" -gt 0 ]
}

get_subnet_broadcast_domain_name() {
  local subnet_name=$1
  local subnets_json=$2

  printf '%s' "$subnets_json" | jq -r --arg subnet "$subnet_name" '
    .records[]
    | select(.name == $subnet)
    | .broadcast_domain.name // empty
  ' | head -n 1
}

broadcast_domain_exists() {
  local broadcast_domain_name=$1
  local broadcast_domains_json=$2
  local count
  count=$(printf '%s' "$broadcast_domains_json" | jq -r --arg name "$broadcast_domain_name" '[.records[] | select(.name == $name)] | length')
  [ "$count" -gt 0 ]
}

get_broadcast_domain_ipspace_name() {
  local broadcast_domain_name=$1
  local broadcast_domains_json=$2

  printf '%s' "$broadcast_domains_json" | jq -r --arg name "$broadcast_domain_name" '
    .records[]
    | select(.name == $name)
    | .ipspace.name // empty
  ' | head -n 1
}

ipspace_exists() {
  local ipspace_name=$1
  local ipspaces_json=$2
  local count
  count=$(printf '%s' "$ipspaces_json" | jq -r --arg name "$ipspace_name" '[.records[] | select(.name == $name)] | length')
  [ "$count" -gt 0 ]
}

parse_subnet_value() {
  local subnet_value=$1
  local subnet_address
  local subnet_mask

  if [[ "$subnet_value" != */* ]]; then
    echo "Subnet must be in the form x.x.x.x/len or x.x.x.x/netmask." >&2
    return 1
  fi

  subnet_address=${subnet_value%/*}
  subnet_mask=${subnet_value#*/}

  if ! is_valid_ipv4 "$subnet_address"; then
    echo "Subnet address must be a valid IPv4 address." >&2
    return 1
  fi

  if [[ "$subnet_mask" =~ ^([1-9]|[12][0-9]|3[0-2])$ ]] || is_valid_ipv4 "$subnet_mask"; then
    SUBNET_ADDRESS=$subnet_address
    SUBNET_NETMASK=$subnet_mask
    SUBNET_CIDR=$subnet_value
    return 0
  fi

  echo "Subnet mask must be a prefix length (1-32) or dotted IPv4 mask." >&2
  return 1
}

parse_ip_ranges_value() {
  local raw_value=$1
  local normalized_value
  local range_item
  local range_start
  local range_end
  local -a raw_ranges=()
  local ranges_json='[]'

  normalized_value=$(normalize_input "$raw_value")
  if [ -z "$normalized_value" ]; then
    SUBNET_IP_RANGES_INPUT=
    SUBNET_IP_RANGES_JSON='[]'
    return 0
  fi

  IFS=',' read -r -a raw_ranges <<< "$normalized_value"
  for range_item in "${raw_ranges[@]}"; do
    range_item=$(normalize_input "$range_item")
    if [ -z "$range_item" ]; then
      continue
    fi
    if [[ "$range_item" != *-* ]]; then
      echo "Each IP range must be in the form x.x.x.x-x.x.x.y." >&2
      return 1
    fi
    range_start=${range_item%-*}
    range_end=${range_item#*-}
    range_start=$(normalize_input "$range_start")
    range_end=$(normalize_input "$range_end")
    if ! is_valid_ipv4 "$range_start" || ! is_valid_ipv4 "$range_end"; then
      echo "Each IP range start and end must be valid IPv4 addresses." >&2
      return 1
    fi
    ranges_json=$(printf '%s' "$ranges_json" | jq --arg range_start "$range_start" --arg range_end "$range_end" '. + [{"start": $range_start, "end": $range_end}]')
  done

  SUBNET_IP_RANGES_INPUT=$normalized_value
  SUBNET_IP_RANGES_JSON=$ranges_json
  return 0
}

prompt_broadcast_domain_name() {
  local current_value=${BROADCAST_DOMAIN_NAME:-}
  local input_value
  local broadcast_domains_json

  while true; do
    print_hint "Provide ? to list broadcast domains"
    print_hint "Type B to go back to previous question."
    if [ -n "$current_value" ]; then
      read -r -p "Enter broadcast domain name [$current_value]: " input_value
    else
      read -r -p "Enter broadcast domain name: " input_value
    fi

    input_value=$(normalize_input "$input_value")
    if [ "$input_value" = "?" ]; then
      broadcast_domains_json=$(get_broadcast_domains_json)
      show_broadcast_domains "$broadcast_domains_json"
      continue
    fi

    if is_back_command "$input_value"; then
      return 2
    fi

    if [ -z "$input_value" ] && [ -n "$current_value" ]; then
      input_value=$current_value
    fi

    if [ -z "$input_value" ]; then
      echo "BROADCAST_DOMAIN_NAME is required." >&2
      continue
    fi

    broadcast_domains_json=$(get_broadcast_domains_json)
    if broadcast_domain_exists "$input_value" "$broadcast_domains_json"; then
      BROADCAST_DOMAIN_NAME=$input_value
      return
    fi
    echo "Broadcast domain '$input_value' was not found. Type ? to list available broadcast domains." >&2
  done
}

prompt_ipspace_name_optional() {
  local current_value=${IPSPACE_NAME:-}
  local input_value
  local ipspaces_json

  while true; do
    print_hint "Provide ? to list IPspaces"
    print_hint "Type B to go back to previous question."
    if [ -n "$current_value" ]; then
      read -r -p "Enter IPspace name (optional) [$current_value]: " input_value
    else
      read -r -p "Enter IPspace name (optional): " input_value
    fi

    input_value=$(normalize_input "$input_value")
    if [ "$input_value" = "?" ]; then
      ipspaces_json=$(get_ipspaces_json)
      show_ipspaces "$ipspaces_json"
      continue
    fi

    if is_back_command "$input_value"; then
      return 2
    fi

    if [ -z "$input_value" ]; then
      IPSPACE_NAME=
      return
    fi

    if [ -n "$current_value" ] && [ "$input_value" = "$current_value" ]; then
      IPSPACE_NAME=$input_value
      return
    fi

    ipspaces_json=$(get_ipspaces_json)
    if ipspace_exists "$input_value" "$ipspaces_json"; then
      IPSPACE_NAME=$input_value
      return
    fi
    echo "IPspace '$input_value' was not found. Type ? to list available IPspaces." >&2
  done
}

create_subnet() {
  local payload
  local effective_ipspace_name="${IPSPACE_NAME:-}"
  local broadcast_domains_json

  if [ -z "$effective_ipspace_name" ]; then
    broadcast_domains_json=$(get_broadcast_domains_json)
    effective_ipspace_name=$(get_broadcast_domain_ipspace_name "$BROADCAST_DOMAIN_NAME" "$broadcast_domains_json")
  fi

  if [ -n "${SUBNET_GATEWAY:-}" ] && [ -z "$effective_ipspace_name" ]; then
    echo "Unable to determine the IPspace for broadcast domain '$BROADCAST_DOMAIN_NAME'. A subnet gateway requires an IPspace." >&2
    return 1
  fi

  payload=$(jq -n \
    --arg subnet_name "$SUBNET_NAME" \
    --arg broadcast_domain_name "$BROADCAST_DOMAIN_NAME" \
    --arg ipspace_name "$effective_ipspace_name" \
    --arg subnet_address "$SUBNET_ADDRESS" \
    --arg subnet_netmask "$SUBNET_NETMASK" \
    --argjson ip_ranges "${SUBNET_IP_RANGES_JSON:-[]}" \
    --arg gateway "${SUBNET_GATEWAY:-}" \
    '{
      name: $subnet_name,
      broadcast_domain: { name: $broadcast_domain_name },
      subnet: {
        address: $subnet_address,
        netmask: $subnet_netmask
      }
    }
    + (if $ip_ranges | length > 0 then { ip_ranges: $ip_ranges } else {} end)
    + (if $ipspace_name != "" then { ipspace: { name: $ipspace_name } } else {} end)
    + (if $gateway != "" then { gateway: $gateway } else {} end)')

  echo "Creating subnet '$SUBNET_NAME'"
  api_request "POST" "https://$MGMT_IP/api/network/ip/subnets?return_timeout=0&return_records=false" "$payload" >/dev/null
}

prompt_and_create_subnet() {
  local subnet_step="name"

  while true; do
    case "$subnet_step" in
      name)
        print_hint "Type B to go back to previous question."
        if [ -n "${SUBNET_NAME:-}" ]; then
          read -r -p "Enter new subnet name [$SUBNET_NAME]: " subnet_name_input
        else
          read -r -p "Enter new subnet name: " subnet_name_input
        fi
        subnet_name_input=$(normalize_input "$subnet_name_input")
        if is_back_command "$subnet_name_input"; then
          return 2
        fi
        if [ -z "$subnet_name_input" ] && [ -n "${SUBNET_NAME:-}" ]; then
          subnet_name_input=$SUBNET_NAME
        fi
        if [ -z "$subnet_name_input" ]; then
          echo "Subnet name is required." >&2
          continue
        fi
        SUBNET_NAME=$subnet_name_input
        subnet_step="broadcast_domain"
        ;;
      broadcast_domain)
        if prompt_broadcast_domain_name; then
          rc=0
        else
          rc=$?
        fi
        if [ "$rc" -eq 0 ]; then
          subnet_step="subnet"
        elif [ "$rc" -eq 2 ]; then
          subnet_step="name"
        else
          return "$rc"
        fi
        ;;
      subnet)
        print_hint "Type B to go back to previous question."
        if [ -n "${SUBNET_CIDR:-}" ]; then
          read -r -p "Enter subnet (for example 10.10.10.0/24) [$SUBNET_CIDR]: " subnet_value_input
        else
          read -r -p "Enter subnet (for example 10.10.10.0/24): " subnet_value_input
        fi
        subnet_value_input=$(normalize_input "$subnet_value_input")
        if is_back_command "$subnet_value_input"; then
          subnet_step="broadcast_domain"
          continue
        fi
        if [ -z "$subnet_value_input" ] && [ -n "${SUBNET_CIDR:-}" ]; then
          subnet_value_input=$SUBNET_CIDR
        fi
        if [ -z "$subnet_value_input" ]; then
          echo "Subnet is required." >&2
          continue
        fi
        if parse_subnet_value "$subnet_value_input"; then
          subnet_step="ip_ranges"
          continue
        fi
        ;;
      ip_ranges)
        print_hint "Type B to go back to previous question."
        if [ -n "${SUBNET_IP_RANGES_INPUT:-}" ]; then
          read -r -p "Enter ip-ranges (optional, example x.x.x.x-x.x.x.y) [$SUBNET_IP_RANGES_INPUT]: " subnet_ip_ranges_input
        else
          read -r -p "Enter ip-ranges (optional, example x.x.x.x-x.x.x.y): " subnet_ip_ranges_input
        fi
        subnet_ip_ranges_input=$(normalize_input "$subnet_ip_ranges_input")
        if is_back_command "$subnet_ip_ranges_input"; then
          subnet_step="subnet"
          continue
        fi
        if parse_ip_ranges_value "$subnet_ip_ranges_input"; then
          subnet_step="ipspace"
        fi
        ;;
      ipspace)
        if prompt_ipspace_name_optional; then
          rc=0
        else
          rc=$?
        fi
        if [ "$rc" -eq 0 ]; then
          subnet_step="gateway"
        elif [ "$rc" -eq 2 ]; then
          subnet_step="ip_ranges"
        else
          return "$rc"
        fi
        ;;
      gateway)
        print_hint "Type B to go back to previous question."
        if [ -n "${SUBNET_GATEWAY:-}" ]; then
          read -r -p "Enter subnet gateway IP (optional) [$SUBNET_GATEWAY]: " subnet_gateway_input
        else
          read -r -p "Enter subnet gateway IP (optional): " subnet_gateway_input
        fi
        subnet_gateway_input=$(normalize_input "$subnet_gateway_input")
        if is_back_command "$subnet_gateway_input"; then
          subnet_step="ipspace"
          continue
        fi
        if [ -n "$subnet_gateway_input" ] && ! is_valid_ipv4 "$subnet_gateway_input"; then
          echo "Subnet gateway must be a valid IPv4 address." >&2
          continue
        fi
        SUBNET_GATEWAY=$subnet_gateway_input
        if create_subnet; then
          return
        fi
        continue
        ;;
    esac
  done
}

prompt_subnet_name() {
  local current_value=${SUBNET_NAME:-}
  local input_value
  local subnets_json

  while true; do
    print_hint "Provide ? to list subnet names"
    print_hint "Type create to create a subnet."
    print_hint "Type B to go back to previous question."
    if [ -n "$current_value" ]; then
      read -r -p "Enter subnet name [$current_value]: " input_value
    else
      read -r -p "Enter subnet name: " input_value
    fi

    input_value=$(normalize_input "$input_value")
    if [ "$input_value" = "?" ]; then
      subnets_json=$(get_subnets_json)
      show_subnets "$subnets_json"
      continue
    fi

    if is_back_command "$input_value"; then
      return 2
    fi

    if [ "${input_value,,}" = "create" ]; then
      if prompt_and_create_subnet; then
        rc=0
      else
        rc=$?
      fi
      if [ "$rc" -eq 0 ]; then
        return
      fi
      if [ "$rc" -eq 2 ]; then
        return 2
      fi
      return "$rc"
    fi

    if [ -z "$input_value" ] && [ -n "$current_value" ]; then
      input_value=$current_value
    fi

    if [ -z "$input_value" ]; then
      echo "SUBNET_NAME is required." >&2
      continue
    fi

    subnets_json=$(get_subnets_json)
    if ! subnet_exists "$input_value" "$subnets_json"; then
      echo "Subnet '$input_value' was not found. Type ? to list available subnet names." >&2
      continue
    fi

    SUBNET_NAME=$input_value
    BROADCAST_DOMAIN_NAME=$(get_subnet_broadcast_domain_name "$SUBNET_NAME" "$subnets_json")
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
    print_hint "Type B to go back to previous question."
    read -r -p "Would you like to add a default gateway route now? [y/N]: " add_gateway_choice
    add_gateway_choice=$(normalize_input "$add_gateway_choice")
    if is_back_command "$add_gateway_choice"; then
      return 2
    fi
    add_gateway_choice=${add_gateway_choice,,}
    case "$add_gateway_choice" in
      y|yes)
        while true; do
          print_hint "Type B to go back to previous question."
          if [ -n "${DEFAULT_GATEWAY:-}" ]; then
            read -r -p "Enter default gateway IP [$DEFAULT_GATEWAY]: " gateway_input
          else
            read -r -p "Enter default gateway IP: " gateway_input
          fi
          gateway_input=$(normalize_input "$gateway_input")
          if is_back_command "$gateway_input"; then
            break
          fi
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

get_svm_interfaces_json() {
  local encoded_svm
  encoded_svm=$(uri_encode "$SVM")
  api_request "GET" "https://$MGMT_IP/api/network/ip/interfaces?svm.name=$encoded_svm&fields=name,ip.address&return_records=true&return_timeout=15&max_records=10000"
}

lookup_interface_ip() {
  local interfaces_json=$1
  local lif_name=$2

  printf '%s' "$interfaces_json" | jq -r --arg lif_name "$lif_name" '
    [.records[] | select(.name == $lif_name) | .ip.address // empty][0] // empty
  '
}

wait_for_interface_ip() {
  local lif_name=$1
  local fallback_ip=${2:-}
  local max_attempts=30
  local attempt=1
  local interfaces_json
  local interface_ip

  while [ "$attempt" -le "$max_attempts" ]; do
    interfaces_json=$(get_svm_interfaces_json)
    interface_ip=$(lookup_interface_ip "$interfaces_json" "$lif_name")
    if [ -n "$interface_ip" ]; then
      printf '%s' "$interface_ip"
      return 0
    fi
    sleep 2
    attempt=$((attempt + 1))
  done

  if [ -n "$fallback_ip" ] && [ "$fallback_ip" != "-" ]; then
    printf '%s' "$fallback_ip"
    return 0
  fi

  return 1
}

ping_host() {
  local ip_address=$1
  local uname_value

  uname_value=$(uname -s 2>/dev/null || printf '%s' "unknown")
  case "$uname_value" in
    MINGW*|MSYS*|CYGWIN*)
      ping -n 2 -w 2000 "$ip_address" >/dev/null
      ;;
    *)
      ping -c 2 -W 2 "$ip_address" >/dev/null
      ;;
  esac
}

run_optional_ping_test() {
  local ping_choice
  local idx
  local lif_name
  local fallback_ip
  local resolved_ip
  local passed_count=0
  local failed_count=0

  while true; do
    read -r -p "Run ping test for created interfaces? [y/N]: " ping_choice
    ping_choice=$(normalize_input "$ping_choice")
    ping_choice=${ping_choice,,}
    case "$ping_choice" in
      y|yes)
        require_command ping
        echo
        echo "Running ping tests..."
        for idx in "${!PLANNED_NAMES[@]}"; do
          lif_name=${PLANNED_NAMES[$idx]}
          fallback_ip=${PLANNED_IPS[$idx]}

          if resolved_ip=$(wait_for_interface_ip "$lif_name" "$fallback_ip"); then
            printf 'Pinging %s (%s)... ' "$lif_name" "$resolved_ip"
            if ping_host "$resolved_ip"; then
              echo "PASS"
              passed_count=$((passed_count + 1))
            else
              echo "FAIL"
              failed_count=$((failed_count + 1))
            fi
          else
            echo "Pinging $lif_name... SKIPPED (no IP assigned yet)"
            failed_count=$((failed_count + 1))
          fi
        done
        echo
        echo "Ping test summary: $passed_count passed, $failed_count failed."
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

sanitize_node_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]/_/g'
}

build_lif_name_dynamic() {
  local node_name=$1
  local per_node_ordinal=$2
  local safe_node
  safe_node=$(sanitize_node_name "$node_name")
  printf '%s_%s_%s' "$LIF_PREFIX" "$safe_node" "$per_node_ordinal"
}

select_port_for_plan() {
  local node_index=$1
  local per_node_index=$2
  local node_name=${TARGET_NODES[$node_index]}
  local port_count=${#DATA_PORT_LIST[@]}
  local selected_index
  local family_port_count

  if [ "$USE_SAME_DATA_PORT" = "true" ]; then
    if [ "$port_count" -le 0 ]; then
      echo "No data ports are available for planning." >&2
      exit 1
    fi
    printf '%s' "${DATA_PORT_LIST[0]}"
    return
  fi

  if [ "$BALANCE_ACROSS_PORTS" = "true" ]; then
    if [ "$port_count" -le 0 ]; then
      echo "No data ports are available for planning." >&2
      exit 1
    fi
    if ! resolve_balancing_ports_for_node "$node_name"; then
      echo "No ports on node '$node_name' matched the requested data port values: $DATA_PORTS" >&2
      exit 1
    fi
    port_count=${#MATCHED_PORTS[@]}
    selected_index=$(( (per_node_index - 1) % port_count ))
    printf '%s' "${MATCHED_PORTS[$selected_index]}"
    return
  fi

  if [ "$USE_PORT_FAMILY_BALANCING" = "true" ]; then
    if ! validate_port_families "$DATA_PORT_FAMILIES" >/dev/null 2>&1; then
      echo "Port family balancing is enabled, but DATA_PORT_FAMILIES is empty or invalid." >&2
      exit 1
    fi
    load_node_ports "$node_name"

    MATCHED_PORTS=()
    local port_name
    local family
    for port_name in "${NODE_PORT_NAMES[@]}"; do
      for family in "${DATA_PORT_FAMILY_LIST[@]}"; do
        if [[ "$port_name" == "$family"* ]]; then
          MATCHED_PORTS+=("$port_name")
          break
        fi
      done
    done

    family_port_count=${#MATCHED_PORTS[@]}
    if [ "$family_port_count" -le 0 ]; then
      echo "No ports on node '$node_name' matched the requested port families: $DATA_PORT_FAMILIES" >&2
      exit 1
    fi

    selected_index=$(( (per_node_index - 1) % family_port_count ))
    printf '%s' "${MATCHED_PORTS[$selected_index]}"
    return
  fi

  if [ "$port_count" -le 0 ]; then
    echo "No data ports are available for planning." >&2
    exit 1
  fi

  selected_index=$(( node_index % port_count ))
  if resolve_fixed_port_for_node "$node_name" "${DATA_PORT_LIST[$selected_index]}"; then
    return
  fi

  echo "Port '${DATA_PORT_LIST[$selected_index]}' did not match any ports on node '$node_name'." >&2
  exit 1
}

build_payload_static() {
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

build_payload_dynamic() {
  local lif_name=$1
  local node_name=$2
  local port_name=$3

  jq -n \
    --arg lif_name "$lif_name" \
    --arg svm_name "$SVM" \
    --arg subnet_name "$SUBNET_NAME" \
    --arg node_name "$node_name" \
    --arg port_name "$port_name" \
    '{
      name: $lif_name,
      scope: "svm",
      svm: { name: $svm_name },
      subnet: { name: $subnet_name },
      location: {
        home_node: $node_name,
        home_port: $port_name
      }
    }'
}

create_lif_static() {
  local data_ip=$1
  local node_name=$2
  local port_name=$3
  local lif_name
  local payload

  lif_name=$(build_lif_name "$data_ip")
  payload=$(build_payload_static "$lif_name" "$data_ip" "$node_name" "$port_name")

  echo "Creating interface $lif_name with IP address $data_ip on $node_name/$port_name"
  api_request "POST" "https://$MGMT_IP/api/network/ip/interfaces?return_timeout=0&return_records=false" "$payload" >/dev/null
}

create_lif_dynamic() {
  local lif_name=$1
  local node_name=$2
  local port_name=$3
  local payload

  payload=$(build_payload_dynamic "$lif_name" "$node_name" "$port_name")

  echo "Creating interface $lif_name from subnet $SUBNET_NAME on $node_name/$port_name"
  api_request "POST" "https://$MGMT_IP/api/network/ip/interfaces?return_timeout=0&return_records=false" "$payload" >/dev/null
}

prompt_lif_prefix() {
  local lif_prefix_input

  while true; do
    print_hint "Type B to go back to previous question."
    if [ -n "$LIF_PREFIX" ]; then
      read -r -p "Enter LIF prefix [$LIF_PREFIX]: " lif_prefix_input
    else
      read -r -p "Enter LIF prefix: " lif_prefix_input
    fi
    lif_prefix_input=$(normalize_input "$lif_prefix_input")
    if is_back_command "$lif_prefix_input"; then
      return 2
    fi
    if [ -z "$lif_prefix_input" ] && [ -n "$LIF_PREFIX" ]; then
      lif_prefix_input=$LIF_PREFIX
    fi
    if [ -z "$lif_prefix_input" ]; then
      echo "LIF prefix is required." >&2
      continue
    fi
    LIF_PREFIX=$lif_prefix_input
    return
  done
}

prompt_target_nodes() {
  local rc
  local nodes_json

  while true; do
    if prompt_node_name NODE1 "Enter node 1 name" "true"; then
      rc=0
    else
      rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      return "$rc"
    fi

    if [ "$NODE1" = "__ALL__" ]; then
      nodes_json=$(get_nodes_json)
      TARGET_NODES=()
      while IFS= read -r node_name; do
        if [ -n "$node_name" ]; then
          TARGET_NODES+=("$node_name")
        fi
      done < <(get_all_node_names "$nodes_json")
      if [ "${#TARGET_NODES[@]}" -eq 0 ]; then
        echo "No node names returned by the API." >&2
        exit 1
      fi
      return
    fi

    if prompt_node_name NODE2 "Enter node 2 name"; then
      rc=0
    else
      rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
      TARGET_NODES=("$NODE1" "$NODE2")
      return
    fi
    if [ "$rc" -eq 2 ]; then
      continue
    fi
    return "$rc"
  done
}

prompt_multiplier_value() {
  local multiplier_input

  while true; do
    print_hint "Type B to go back to previous question."
    if [ -n "$LIFS_PER_NODE" ]; then
      read -r -p "Enter multiplier (number of LIFs per node) [$LIFS_PER_NODE]: " multiplier_input
    else
      read -r -p "Enter multiplier (number of LIFs per node): " multiplier_input
    fi
    multiplier_input=$(normalize_input "$multiplier_input")
    if is_back_command "$multiplier_input"; then
      return 2
    fi
    if [ -z "$multiplier_input" ] && [ -n "$LIFS_PER_NODE" ]; then
      multiplier_input=$LIFS_PER_NODE
    fi
    if ! is_positive_integer "$multiplier_input"; then
      echo "Multiplier must be a positive integer." >&2
      continue
    fi
    LIFS_PER_NODE=$multiplier_input
    return
  done
}

prompt_data_port_strategy() {
  local same_port_choice
  local balance_ports_choice
  local balance_port_families_choice
  local data_port_input
  local data_ports_input
  local data_port_families_input
  local default_port_value

  if [ "$USE_SUBNET_DYNAMIC" = "true" ]; then
    PORT_BROADCAST_DOMAIN_NAME=${BROADCAST_DOMAIN_NAME:-}
  else
    PORT_BROADCAST_DOMAIN_NAME=""
  fi

  while true; do
    print_hint "Type B to go back to previous question."
    read -r -p "Use the same data port on all nodes? [y/N]: " same_port_choice
    same_port_choice=$(normalize_input "$same_port_choice")
    if is_back_command "$same_port_choice"; then
      return 2
    fi
    same_port_choice=${same_port_choice,,}
    case "$same_port_choice" in
      y|yes)
        USE_SAME_DATA_PORT=true
        BALANCE_ACROSS_PORTS=false
        USE_PORT_FAMILY_BALANCING=false
        DATA_PORT_FAMILIES=""
        while true; do
          print_hint "Provide ? to list available ports"
          print_hint "Type B to go back to previous question."
          default_port_value=""
          if validate_data_ports "$DATA_PORTS" >/dev/null 2>&1; then
            default_port_value=${DATA_PORT_LIST[0]}
          fi
          if [ -n "$default_port_value" ]; then
            read -r -p "Enter data port name [$default_port_value]: " data_port_input
          else
            read -r -p "Enter data port name: " data_port_input
          fi
          data_port_input=$(normalize_input "$data_port_input")
          if [ "$data_port_input" = "?" ]; then
            show_available_ports
            continue
          fi
          if is_back_command "$data_port_input"; then
            break
          fi
          if [ -z "$data_port_input" ] && [ -n "$default_port_value" ]; then
            data_port_input=$default_port_value
          fi
          if validate_data_ports "$data_port_input" && validate_selected_ports_for_strategy; then
            DATA_PORTS=$data_port_input
            DATA_PORT_FAMILIES=""
            return
          fi
        done
        ;;
      ""|n|no)
        USE_SAME_DATA_PORT=false
        if [ "$LIFS_PER_NODE" -gt 1 ]; then
          while true; do
            print_hint "Type B to go back to previous question."
            read -r -p "Balance interfaces across ports on each node? [y/N]: " balance_ports_choice
            balance_ports_choice=$(normalize_input "$balance_ports_choice")
            if is_back_command "$balance_ports_choice"; then
              break
            fi
            balance_ports_choice=${balance_ports_choice,,}
            case "$balance_ports_choice" in
              y|yes)
                BALANCE_ACROSS_PORTS=true
                USE_PORT_FAMILY_BALANCING=false
                DATA_PORT_FAMILIES=""
                ;;
              ""|n|no)
                BALANCE_ACROSS_PORTS=false
                while true; do
                  print_hint "Type B to go back to previous question."
                  read -r -p "Balance interfaces across specific port families (ie, e2 or e2,e4)? [y/N]: " balance_port_families_choice
                  balance_port_families_choice=$(normalize_input "$balance_port_families_choice")
                  if is_back_command "$balance_port_families_choice"; then
                    balance_port_families_choice="__BACK__"
                    break
                  fi
                  balance_port_families_choice=${balance_port_families_choice,,}
                  case "$balance_port_families_choice" in
                    y|yes)
                      USE_PORT_FAMILY_BALANCING=true
                      while true; do
                        print_hint "Provide ? to list available ports"
                        print_hint "Type B to go back to previous question."
                        if [ -n "$DATA_PORT_FAMILIES" ]; then
                          read -r -p "Enter port families to balance across (comma-separated wildcard prefixes) [$DATA_PORT_FAMILIES]: " data_port_families_input
                        else
                          read -r -p "Enter port families to balance across (comma-separated wildcard prefixes): " data_port_families_input
                        fi
                        data_port_families_input=$(normalize_input "$data_port_families_input")
                        if [ "$data_port_families_input" = "?" ]; then
                          show_available_ports
                          continue
                        fi
                        if is_back_command "$data_port_families_input"; then
                          break
                        fi
                        if [ -z "$data_port_families_input" ] && [ -n "$DATA_PORT_FAMILIES" ]; then
                          data_port_families_input=$DATA_PORT_FAMILIES
                        fi
                        if validate_port_families "$data_port_families_input"; then
                          DATA_PORT_FAMILIES=$data_port_families_input
                          DATA_PORTS=""
                          if validate_port_families_for_target_nodes; then
                            return
                          fi
                        fi
                      done
                      ;;
                    ""|n|no)
                      USE_PORT_FAMILY_BALANCING=false
                      break
                      ;;
                    *)
                      echo "Please enter y or n." >&2
                      ;;
                  esac
                done
                if [ "${balance_port_families_choice:-}" = "__BACK__" ]; then
                  continue
                fi
                ;;
              *)
                echo "Please enter y or n." >&2
                continue
                ;;
            esac

            while true; do
              print_hint "Provide ? to list available ports"
              print_hint "Type B to go back to previous question."
              if [ -n "$DATA_PORTS" ]; then
                read -r -p "Enter data ports to use (comma-separated; use eN for all ports on a specific slot, such as e2 for e2a,e2b) [$DATA_PORTS]: " data_ports_input
              else
                read -r -p "Enter data ports to use (comma-separated; use eN for all ports on a specific slot, such as e2 for e2a,e2b): " data_ports_input
              fi
              data_ports_input=$(normalize_input "$data_ports_input")
              if [ "$data_ports_input" = "?" ]; then
                show_available_ports
                continue
              fi
              if is_back_command "$data_ports_input"; then
                break
              fi
              if [ -z "$data_ports_input" ] && [ -n "$DATA_PORTS" ]; then
                data_ports_input=$DATA_PORTS
              fi
              if validate_data_ports "$data_ports_input" && validate_selected_ports_for_strategy; then
                DATA_PORTS=$data_ports_input
                DATA_PORT_FAMILIES=""
                return
              fi
            done
          done
        else
          BALANCE_ACROSS_PORTS=false
          USE_PORT_FAMILY_BALANCING=false
          while true; do
            print_hint "Provide ? to list available ports"
            print_hint "Type B to go back to previous question."
            if [ -n "$DATA_PORTS" ]; then
              read -r -p "Enter data ports to use (comma-separated; use eN for all ports on a specific slot, such as e2 for e2a,e2b) [$DATA_PORTS]: " data_ports_input
            else
              read -r -p "Enter data ports to use (comma-separated; use eN for all ports on a specific slot, such as e2 for e2a,e2b): " data_ports_input
            fi
            data_ports_input=$(normalize_input "$data_ports_input")
            if [ "$data_ports_input" = "?" ]; then
              show_available_ports
              continue
            fi
            if is_back_command "$data_ports_input"; then
              break
            fi
            if [ -z "$data_ports_input" ] && [ -n "$DATA_PORTS" ]; then
              data_ports_input=$DATA_PORTS
            fi
            if validate_data_ports "$data_ports_input" && validate_selected_ports_for_strategy; then
              DATA_PORTS=$data_ports_input
              DATA_PORT_FAMILIES=""
              return
            fi
          done
        fi
        ;;
      *)
        echo "Please enter y or n." >&2
        ;;
    esac
  done
}

prompt_subnet_dynamic_choice() {
  local use_subnet_choice

  while true; do
    print_hint "Type B to go back to previous question."
    read -r -p "Use network subnets to provision IPs dynamically? [y/N]: " use_subnet_choice
    use_subnet_choice=$(normalize_input "$use_subnet_choice")
    if is_back_command "$use_subnet_choice"; then
      return 2
    fi
    use_subnet_choice=${use_subnet_choice,,}
    case "$use_subnet_choice" in
      y|yes)
        USE_SUBNET_DYNAMIC=true
        return
        ;;
      ""|n|no)
        USE_SUBNET_DYNAMIC=false
        return
        ;;
      *)
        echo "Please enter y or n." >&2
        ;;
    esac
  done
}

set_required_lif_count() {
  required_lif_count=$(( ${#TARGET_NODES[@]} * LIFS_PER_NODE ))
  if [ "$required_lif_count" -le 0 ]; then
    echo "Calculated LIF count is invalid." >&2
    exit 1
  fi
}

prompt_static_networking() {
  local data_mask_input
  local data_ips_input
  local static_step="netmask"

  set_required_lif_count

  while true; do
    case "$static_step" in
      netmask)
        print_hint "Type B to go back to previous question."
        if [ -n "$DATA_MASK" ]; then
          read -r -p "Enter netmask in dotted decimal [$DATA_MASK]: " data_mask_input
        else
          read -r -p "Enter netmask in dotted decimal: " data_mask_input
        fi
        data_mask_input=$(normalize_input "$data_mask_input")
        if is_back_command "$data_mask_input"; then
          return 2
        fi
        if [ -z "$data_mask_input" ] && [ -n "$DATA_MASK" ]; then
          data_mask_input=$DATA_MASK
        fi
        if ! is_valid_ipv4 "$data_mask_input"; then
          echo "Netmask must be a valid dotted IPv4 value." >&2
          continue
        fi
        DATA_MASK=$data_mask_input
        static_step="ips"
        ;;
      ips)
        print_hint "Type B to go back to previous question."
        if [ -n "$DATA_IPS" ]; then
          read -r -p "Enter $required_lif_count data interface IPs (comma-separated) [$DATA_IPS]: " data_ips_input
        else
          read -r -p "Enter $required_lif_count data interface IPs (comma-separated): " data_ips_input
        fi
        data_ips_input=$(normalize_input "$data_ips_input")
        if is_back_command "$data_ips_input"; then
          static_step="netmask"
          continue
        fi
        if [ -z "$data_ips_input" ] && [ -n "$DATA_IPS" ]; then
          data_ips_input=$DATA_IPS
        fi
        if validate_data_ips "$data_ips_input"; then
          if [ "${#DATA_IP_LIST[@]}" -ne "$required_lif_count" ]; then
            echo "Expected $required_lif_count IP addresses, but received ${#DATA_IP_LIST[@]}." >&2
            continue
          fi
          DATA_IPS=$data_ips_input
          return
        fi
        ;;
    esac
  done
}

build_interface_plan() {
  local node_index
  local node_name
  local per_node_index
  local selected_port
  local lif_name
  local ip_value

  PLANNED_NAMES=()
  PLANNED_NODES=()
  PLANNED_PORTS=()
  PLANNED_IPS=()

  set_required_lif_count

  plan_index=0
  for node_index in "${!TARGET_NODES[@]}"; do
    node_name=${TARGET_NODES[$node_index]}
    per_node_index=1
    while [ "$per_node_index" -le "$LIFS_PER_NODE" ]; do
      selected_port=$(select_port_for_plan "$node_index" "$per_node_index")

      if [ "$USE_SUBNET_DYNAMIC" = "true" ]; then
        lif_name=$(build_lif_name_dynamic "$node_name" "$per_node_index")
        ip_value="-"
      else
        ip_value=${DATA_IP_LIST[$plan_index]}
        lif_name=$(build_lif_name "$ip_value")
      fi

      PLANNED_NAMES+=("$lif_name")
      PLANNED_NODES+=("$node_name")
      PLANNED_PORTS+=("$selected_port")
      PLANNED_IPS+=("$ip_value")

      plan_index=$((plan_index + 1))
      per_node_index=$((per_node_index + 1))
    done
  done
}

show_interface_plan() {
  local idx

  echo
  echo "Interfaces to create in SVM '$SVM':"
  for idx in "${!PLANNED_NAMES[@]}"; do
    if [ "$USE_SUBNET_DYNAMIC" = "true" ]; then
      echo "  - ${PLANNED_NAMES[$idx]} (subnet: $SUBNET_NAME) on ${PLANNED_NODES[$idx]}/${PLANNED_PORTS[$idx]}"
    else
      echo "  - ${PLANNED_NAMES[$idx]} (${PLANNED_IPS[$idx]}) on ${PLANNED_NODES[$idx]}/${PLANNED_PORTS[$idx]}"
    fi
  done
  echo
}

prompt_creation_confirmation() {
  local confirm_create

  while true; do
    print_hint "Type B to go back to previous question."
    read -r -p "Proceed to create ${#PLANNED_NAMES[@]} interface(s)? [y/N]: " confirm_create
    confirm_create=$(normalize_input "$confirm_create")
    if is_back_command "$confirm_create"; then
      return 2
    fi
    confirm_create=${confirm_create,,}
    case "$confirm_create" in
      y|yes)
        return
        ;;
      ""|n|no)
        echo "Cancelled."
        return 3
        ;;
      *)
        echo "Please enter y or n." >&2
        ;;
    esac
  done
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
DATA_PORT=${DATA_PORT:-}
DATA_PORT1=${DATA_PORT1:-}
DATA_PORT2=${DATA_PORT2:-}
DATA_PORTS=${DATA_PORTS:-}
DATA_PORT_FAMILIES=${DATA_PORT_FAMILIES:-}
DATA_IPS=${DATA_IPS:-}
BROADCAST_DOMAIN_NAME=${BROADCAST_DOMAIN_NAME:-}
IPSPACE_NAME=${IPSPACE_NAME:-}
SUBNET_NAME=${SUBNET_NAME:-}
SUBNET_CIDR=${SUBNET_CIDR:-}
SUBNET_IP_RANGES_INPUT=${SUBNET_IP_RANGES_INPUT:-}
SUBNET_IP_RANGES_JSON=${SUBNET_IP_RANGES_JSON:-[]}
LIFS_PER_NODE=${LIFS_PER_NODE:-${MULTIPLIER:-1}}
USE_SUBNET_DYNAMIC=${USE_SUBNET_DYNAMIC:-false}
USE_SAME_DATA_PORT=${USE_SAME_DATA_PORT:-false}
BALANCE_ACROSS_PORTS=${BALANCE_ACROSS_PORTS:-false}
USE_PORT_FAMILY_BALANCING=${USE_PORT_FAMILY_BALANCING:-false}
DEFAULT_GATEWAY=${DEFAULT_GATEWAY:-${DATA_GATEWAY:-}}
BROADCAST_DOMAINS_PORTS_JSON=${BROADCAST_DOMAINS_PORTS_JSON:-}

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

if [ -z "$DATA_PORTS" ]; then
  if [ -n "$DATA_PORT" ]; then
    DATA_PORTS=$DATA_PORT
  elif [ -n "$DATA_PORT1" ] && [ -n "$DATA_PORT2" ]; then
    DATA_PORTS="$DATA_PORT1,$DATA_PORT2"
  elif [ -n "$DATA_PORT1" ]; then
    DATA_PORTS=$DATA_PORT1
  elif [ -n "$DATA_PORT2" ]; then
    DATA_PORTS=$DATA_PORT2
  fi
fi

prompt_if_empty MGMT_IP "Enter cluster management IP: "
prompt_auth_token
wizard_step="svm"
while true; do
  case "$wizard_step" in
    svm)
      if prompt_svm_name; then
        rc=0
      else
        rc=$?
      fi
      if [ "$rc" -eq 0 ]; then
        wizard_step="lif_prefix"
      fi
      ;;
    lif_prefix)
      if prompt_lif_prefix; then
        rc=0
      else
        rc=$?
      fi
      if [ "$rc" -eq 0 ]; then
        wizard_step="nodes"
      elif [ "$rc" -eq 2 ]; then
        wizard_step="svm"
      else
        exit "$rc"
      fi
      ;;
    nodes)
      if prompt_target_nodes; then
        rc=0
      else
        rc=$?
      fi
      if [ "$rc" -eq 0 ]; then
        wizard_step="multiplier"
      elif [ "$rc" -eq 2 ]; then
        wizard_step="lif_prefix"
      else
        exit "$rc"
      fi
      ;;
    multiplier)
      if prompt_multiplier_value; then
        rc=0
      else
        rc=$?
      fi
      if [ "$rc" -eq 0 ]; then
        wizard_step="dynamic_subnet"
      elif [ "$rc" -eq 2 ]; then
        wizard_step="nodes"
      else
        exit "$rc"
      fi
      ;;
    dynamic_subnet)
      if prompt_subnet_dynamic_choice; then
        rc=0
      else
        rc=$?
      fi
      if [ "$rc" -eq 0 ]; then
        if [ "$USE_SUBNET_DYNAMIC" = "true" ]; then
          wizard_step="subnet"
        else
          wizard_step="static_networking"
        fi
      elif [ "$rc" -eq 2 ]; then
        wizard_step="multiplier"
      else
        exit "$rc"
      fi
      ;;
    subnet)
      if prompt_subnet_name; then
        rc=0
      else
        rc=$?
      fi
      if [ "$rc" -eq 0 ]; then
        wizard_step="ports"
      elif [ "$rc" -eq 2 ]; then
        wizard_step="dynamic_subnet"
      else
        exit "$rc"
      fi
      ;;
    static_networking)
      if prompt_static_networking; then
        rc=0
      else
        rc=$?
      fi
      if [ "$rc" -eq 0 ]; then
        wizard_step="ports"
      elif [ "$rc" -eq 2 ]; then
        wizard_step="dynamic_subnet"
      else
        exit "$rc"
      fi
      ;;
    ports)
      if prompt_data_port_strategy; then
        rc=0
      else
        rc=$?
      fi
      if [ "$rc" -eq 0 ]; then
        wizard_step="default_gateway"
      elif [ "$rc" -eq 2 ]; then
        if [ "$USE_SUBNET_DYNAMIC" = "true" ]; then
          wizard_step="subnet"
        else
          wizard_step="static_networking"
        fi
      else
        exit "$rc"
      fi
      ;;
    default_gateway)
      if ensure_default_gateway_for_svm; then
        rc=0
      else
        rc=$?
      fi
      if [ "$rc" -eq 0 ]; then
        wizard_step="confirm"
      elif [ "$rc" -eq 2 ]; then
        wizard_step="ports"
      else
        exit "$rc"
      fi
      ;;
    confirm)
      build_interface_plan
      show_interface_plan
      if prompt_creation_confirmation; then
        rc=0
      else
        rc=$?
      fi
      if [ "$rc" -eq 0 ]; then
        break
      elif [ "$rc" -eq 2 ]; then
        wizard_step="default_gateway"
      elif [ "$rc" -eq 3 ]; then
        exit 0
      else
        exit "$rc"
      fi
      ;;
  esac
done

for idx in "${!PLANNED_NAMES[@]}"; do
  if [ "$USE_SUBNET_DYNAMIC" = "true" ]; then
    create_lif_dynamic "${PLANNED_NAMES[$idx]}" "${PLANNED_NODES[$idx]}" "${PLANNED_PORTS[$idx]}"
  else
    create_lif_static "${PLANNED_IPS[$idx]}" "${PLANNED_NODES[$idx]}" "${PLANNED_PORTS[$idx]}"
  fi
done

echo
echo "Create requests submitted for ${#PLANNED_NAMES[@]} interface(s) in SVM '$SVM'."
run_optional_ping_test
