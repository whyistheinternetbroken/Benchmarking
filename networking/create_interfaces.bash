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
  local allow_all=${3:-false}
  local current_value=${!var_name:-}
  local input_value
  local nodes_json

  while true; do
    echo "Provide ? to list node names"
    if [ "$allow_all" = "true" ]; then
      echo "Type all to add LIFs to all nodes."
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
  api_request "GET" "https://$MGMT_IP/api/network/ip/subnets?fields=name&return_records=true&return_timeout=15&max_records=10000"
}

get_broadcast_domains_json() {
  api_request "GET" "https://$MGMT_IP/api/network/ethernet/broadcast-domains?fields=name,uuid,ipspace.name&return_records=true&return_timeout=15&max_records=10000"
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
    | [.name, (.ipspace.name // "-"), (.uuid // "-")]
    | @tsv
  ' | sort)

  if [ -z "$rows" ]; then
    echo "No broadcast domains returned by the API."
    return
  fi

  echo
  echo "Available broadcast domains:"
  while IFS=$'\t' read -r bd_name ipspace_name bd_uuid; do
    echo "  - $bd_name (IPspace: $ipspace_name, UUID: $bd_uuid)"
  done <<< "$rows"
  echo
}

subnet_exists() {
  local subnet_name=$1
  local subnets_json=$2
  local count
  count=$(printf '%s' "$subnets_json" | jq -r --arg subnet "$subnet_name" '[.records[] | select(.name == $subnet)] | length')
  [ "$count" -gt 0 ]
}

resolve_broadcast_domain_uuid() {
  local broadcast_domain_selector=$1
  local broadcast_domains_json=$2
  local matches

  matches=$(printf '%s' "$broadcast_domains_json" | jq -r --arg selector "$broadcast_domain_selector" '
    [
      .records[]
      | select(.uuid == $selector or .name == $selector)
      | .uuid
    ]
  ')

  if [ "$(printf '%s' "$matches" | jq 'length')" -eq 1 ]; then
    printf '%s' "$matches" | jq -r '.[0]'
    return 0
  fi

  if [ "$(printf '%s' "$matches" | jq 'length')" -gt 1 ]; then
    echo "Multiple broadcast domains matched '$broadcast_domain_selector'. Please use the UUID shown in the list." >&2
    return 1
  fi

  echo "Broadcast domain '$broadcast_domain_selector' was not found." >&2
  return 1
}

prompt_broadcast_domain_uuid() {
  local current_value=${BROADCAST_DOMAIN_UUID:-}
  local input_value
  local broadcast_domains_json
  local resolved_uuid

  while true; do
    echo "Provide ? to list broadcast domains"
    if [ -n "$current_value" ]; then
      read -r -p "Enter broadcast domain name or UUID [$current_value]: " input_value
    else
      read -r -p "Enter broadcast domain name or UUID: " input_value
    fi

    input_value=$(normalize_input "$input_value")
    if [ "$input_value" = "?" ]; then
      broadcast_domains_json=$(get_broadcast_domains_json)
      show_broadcast_domains "$broadcast_domains_json"
      continue
    fi

    if [ -z "$input_value" ] && [ -n "$current_value" ]; then
      input_value=$current_value
    fi

    if [ -z "$input_value" ]; then
      echo "BROADCAST_DOMAIN_UUID is required." >&2
      continue
    fi

    broadcast_domains_json=$(get_broadcast_domains_json)
    if resolved_uuid=$(resolve_broadcast_domain_uuid "$input_value" "$broadcast_domains_json"); then
      BROADCAST_DOMAIN_UUID=$resolved_uuid
      return
    fi
  done
}

create_subnet() {
  local payload

  payload=$(jq -n \
    --arg subnet_name "$SUBNET_NAME" \
    --arg broadcast_domain_uuid "$BROADCAST_DOMAIN_UUID" \
    --arg subnet_address "$SUBNET_ADDRESS" \
    --arg subnet_netmask "$SUBNET_NETMASK" \
    --arg range_start "$SUBNET_RANGE_START" \
    --arg range_end "$SUBNET_RANGE_END" \
    --arg gateway "${SUBNET_GATEWAY:-}" \
    '{
      name: $subnet_name,
      broadcast_domain: { uuid: $broadcast_domain_uuid },
      subnet: {
        address: $subnet_address,
        netmask: $subnet_netmask
      },
      ip_ranges: [
        {
          start: $range_start,
          end: $range_end
        }
      ]
    }
    + (if $gateway != "" then { gateway: $gateway } else {} end)')

  echo "Creating subnet '$SUBNET_NAME'"
  api_request "POST" "https://$MGMT_IP/api/network/ip/subnets?return_timeout=0&return_records=false" "$payload" >/dev/null
}

prompt_and_create_subnet() {
  while true; do
    if [ -n "${SUBNET_NAME:-}" ]; then
      read -r -p "Enter new subnet name [$SUBNET_NAME]: " subnet_name_input
    else
      read -r -p "Enter new subnet name: " subnet_name_input
    fi
    subnet_name_input=$(normalize_input "$subnet_name_input")
    if [ -z "$subnet_name_input" ] && [ -n "${SUBNET_NAME:-}" ]; then
      subnet_name_input=$SUBNET_NAME
    fi
    if [ -z "$subnet_name_input" ]; then
      echo "Subnet name is required." >&2
      continue
    fi
    SUBNET_NAME=$subnet_name_input
    break
  done

  prompt_broadcast_domain_uuid

  while true; do
    if [ -n "${SUBNET_ADDRESS:-}" ]; then
      read -r -p "Enter subnet network address [$SUBNET_ADDRESS]: " subnet_address_input
    else
      read -r -p "Enter subnet network address: " subnet_address_input
    fi
    subnet_address_input=$(normalize_input "$subnet_address_input")
    if [ -z "$subnet_address_input" ] && [ -n "${SUBNET_ADDRESS:-}" ]; then
      subnet_address_input=$SUBNET_ADDRESS
    fi
    if ! is_valid_ipv4 "$subnet_address_input"; then
      echo "Subnet network address must be a valid IPv4 address." >&2
      continue
    fi
    SUBNET_ADDRESS=$subnet_address_input
    break
  done

  while true; do
    if [ -n "${SUBNET_NETMASK:-}" ]; then
      read -r -p "Enter subnet netmask or prefix length [$SUBNET_NETMASK]: " subnet_netmask_input
    else
      read -r -p "Enter subnet netmask or prefix length: " subnet_netmask_input
    fi
    subnet_netmask_input=$(normalize_input "$subnet_netmask_input")
    if [ -z "$subnet_netmask_input" ] && [ -n "${SUBNET_NETMASK:-}" ]; then
      subnet_netmask_input=$SUBNET_NETMASK
    fi
    if [[ "$subnet_netmask_input" =~ ^([1-9]|[12][0-9]|3[0-2])$ ]] || is_valid_ipv4 "$subnet_netmask_input"; then
      SUBNET_NETMASK=$subnet_netmask_input
      break
    fi
    echo "Subnet netmask must be a prefix length (1-32) or dotted IPv4 mask." >&2
  done

  while true; do
    if [ -n "${SUBNET_GATEWAY:-}" ]; then
      read -r -p "Enter subnet gateway IP (optional) [$SUBNET_GATEWAY]: " subnet_gateway_input
    else
      read -r -p "Enter subnet gateway IP (optional): " subnet_gateway_input
    fi
    subnet_gateway_input=$(normalize_input "$subnet_gateway_input")
    if [ -z "$subnet_gateway_input" ] && [ -n "${SUBNET_GATEWAY:-}" ]; then
      subnet_gateway_input=$SUBNET_GATEWAY
    fi
    if [ -n "$subnet_gateway_input" ] && ! is_valid_ipv4 "$subnet_gateway_input"; then
      echo "Subnet gateway must be a valid IPv4 address." >&2
      continue
    fi
    SUBNET_GATEWAY=$subnet_gateway_input
    break
  done

  while true; do
    if [ -n "${SUBNET_RANGE_START:-}" ]; then
      read -r -p "Enter subnet IP range start [$SUBNET_RANGE_START]: " subnet_range_start_input
    else
      read -r -p "Enter subnet IP range start: " subnet_range_start_input
    fi
    subnet_range_start_input=$(normalize_input "$subnet_range_start_input")
    if [ -z "$subnet_range_start_input" ] && [ -n "${SUBNET_RANGE_START:-}" ]; then
      subnet_range_start_input=$SUBNET_RANGE_START
    fi
    if ! is_valid_ipv4 "$subnet_range_start_input"; then
      echo "Subnet IP range start must be a valid IPv4 address." >&2
      continue
    fi
    SUBNET_RANGE_START=$subnet_range_start_input
    break
  done

  while true; do
    if [ -n "${SUBNET_RANGE_END:-}" ]; then
      read -r -p "Enter subnet IP range end [$SUBNET_RANGE_END]: " subnet_range_end_input
    else
      read -r -p "Enter subnet IP range end: " subnet_range_end_input
    fi
    subnet_range_end_input=$(normalize_input "$subnet_range_end_input")
    if [ -z "$subnet_range_end_input" ] && [ -n "${SUBNET_RANGE_END:-}" ]; then
      subnet_range_end_input=$SUBNET_RANGE_END
    fi
    if ! is_valid_ipv4 "$subnet_range_end_input"; then
      echo "Subnet IP range end must be a valid IPv4 address." >&2
      continue
    fi
    SUBNET_RANGE_END=$subnet_range_end_input
    break
  done

  create_subnet
}

prompt_subnet_name() {
  local current_value=${SUBNET_NAME:-}
  local input_value
  local subnets_json

  while true; do
    echo "Provide ? to list subnet names"
    echo "Type create to create a subnet."
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

    if [ "${input_value,,}" = "create" ]; then
      prompt_and_create_subnet
      return
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
  local port_count=${#DATA_PORT_LIST[@]}
  local selected_index

  if [ "$port_count" -le 0 ]; then
    echo "No data ports are available for planning." >&2
    exit 1
  fi

  if [ "$USE_SAME_DATA_PORT" = "true" ]; then
    printf '%s' "${DATA_PORT_LIST[0]}"
    return
  fi

  if [ "$BALANCE_ACROSS_PORTS" = "true" ]; then
    selected_index=$(( (per_node_index - 1) % port_count ))
    printf '%s' "${DATA_PORT_LIST[$selected_index]}"
    return
  fi

  selected_index=$(( node_index % port_count ))
  printf '%s' "${DATA_PORT_LIST[$selected_index]}"
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
DATA_IPS=${DATA_IPS:-}
SUBNET_NAME=${SUBNET_NAME:-}
LIFS_PER_NODE=${LIFS_PER_NODE:-${MULTIPLIER:-1}}
USE_SUBNET_DYNAMIC=${USE_SUBNET_DYNAMIC:-false}
USE_SAME_DATA_PORT=${USE_SAME_DATA_PORT:-false}
BALANCE_ACROSS_PORTS=${BALANCE_ACROSS_PORTS:-false}
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

prompt_node_name NODE1 "Enter node 1 name" "true"
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
else
  prompt_node_name NODE2 "Enter node 2 name"
  TARGET_NODES=("$NODE1" "$NODE2")
fi

while true; do
  if [ -n "$LIFS_PER_NODE" ]; then
    read -r -p "Enter multiplier (number of LIFs per node) [$LIFS_PER_NODE]: " multiplier_input
  else
    read -r -p "Enter multiplier (number of LIFs per node): " multiplier_input
  fi
  multiplier_input=$(normalize_input "$multiplier_input")
  if [ -z "$multiplier_input" ] && [ -n "$LIFS_PER_NODE" ]; then
    multiplier_input=$LIFS_PER_NODE
  fi
  if ! is_positive_integer "$multiplier_input"; then
    echo "Multiplier must be a positive integer." >&2
    continue
  fi
  LIFS_PER_NODE=$multiplier_input
  break
done

while true; do
  read -r -p "Use the same data port on all nodes? [y/N]: " same_port_choice
  same_port_choice=$(normalize_input "$same_port_choice")
  same_port_choice=${same_port_choice,,}
  case "$same_port_choice" in
    y|yes)
      USE_SAME_DATA_PORT=true
      BALANCE_ACROSS_PORTS=false
      while true; do
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
        if [ -z "$data_port_input" ] && [ -n "$default_port_value" ]; then
          data_port_input=$default_port_value
        fi
        if validate_data_ports "$data_port_input"; then
          DATA_PORTS=$data_port_input
          break
        fi
      done
      break
      ;;
    ""|n|no)
      USE_SAME_DATA_PORT=false
      if [ "$LIFS_PER_NODE" -gt 1 ]; then
        while true; do
          read -r -p "Balance interfaces across ports on each node? [y/N]: " balance_ports_choice
          balance_ports_choice=$(normalize_input "$balance_ports_choice")
          balance_ports_choice=${balance_ports_choice,,}
          case "$balance_ports_choice" in
            y|yes)
              BALANCE_ACROSS_PORTS=true
              break
              ;;
            ""|n|no)
              BALANCE_ACROSS_PORTS=false
              break
              ;;
            *)
              echo "Please enter y or n." >&2
              ;;
          esac
        done
      else
        BALANCE_ACROSS_PORTS=false
      fi

      while true; do
        if [ -n "$DATA_PORTS" ]; then
          read -r -p "Enter data ports to use (comma-separated) [$DATA_PORTS]: " data_ports_input
        else
          read -r -p "Enter data ports to use (comma-separated): " data_ports_input
        fi
        data_ports_input=$(normalize_input "$data_ports_input")
        if [ -z "$data_ports_input" ] && [ -n "$DATA_PORTS" ]; then
          data_ports_input=$DATA_PORTS
        fi
        if validate_data_ports "$data_ports_input"; then
          DATA_PORTS=$data_ports_input
          break
        fi
      done
      break
      ;;
    *)
      echo "Please enter y or n." >&2
      ;;
  esac
done

while true; do
  read -r -p "Use network subnets to provision IPs dynamically? [y/N]: " use_subnet_choice
  use_subnet_choice=$(normalize_input "$use_subnet_choice")
  use_subnet_choice=${use_subnet_choice,,}
  case "$use_subnet_choice" in
    y|yes)
      USE_SUBNET_DYNAMIC=true
      break
      ;;
    ""|n|no)
      USE_SUBNET_DYNAMIC=false
      break
      ;;
    *)
      echo "Please enter y or n." >&2
      ;;
  esac
done

required_lif_count=$(( ${#TARGET_NODES[@]} * LIFS_PER_NODE ))
if [ "$required_lif_count" -le 0 ]; then
  echo "Calculated LIF count is invalid." >&2
  exit 1
fi

if [ "$USE_SUBNET_DYNAMIC" = "true" ]; then
  prompt_subnet_name
else
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

  while true; do
    if [ -n "$DATA_IPS" ]; then
      read -r -p "Enter $required_lif_count data interface IPs (comma-separated) [$DATA_IPS]: " data_ips_input
    else
      read -r -p "Enter $required_lif_count data interface IPs (comma-separated): " data_ips_input
    fi
    data_ips_input=$(normalize_input "$data_ips_input")
    if [ -z "$data_ips_input" ] && [ -n "$DATA_IPS" ]; then
      data_ips_input=$DATA_IPS
    fi
    if validate_data_ips "$data_ips_input"; then
      if [ "${#DATA_IP_LIST[@]}" -ne "$required_lif_count" ]; then
        echo "Expected $required_lif_count IP addresses, but received ${#DATA_IP_LIST[@]}." >&2
        continue
      fi
      DATA_IPS=$data_ips_input
      break
    fi
  done
fi

PLANNED_NAMES=()
PLANNED_NODES=()
PLANNED_PORTS=()
PLANNED_IPS=()

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

while true; do
  read -r -p "Proceed to create ${#PLANNED_NAMES[@]} interface(s)? [y/N]: " confirm_create
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
