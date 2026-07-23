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
Usage: cleanup_interfaces.bash [--debug]

Options:
  --debug   Enable verbose REST request/response tracing to a log file.
            Default path: <networking>/logs/cleanup_interfaces_debug_YYYYmmdd_HHMMSS.log
            Optional: set DEBUG_LOG_FILE=/path/to/file.log
EOF
}

init_debug_logging() {
  if [ "$DEBUG" != "true" ]; then
    return
  fi

  if [ -z "$DEBUG_LOG_FILE" ]; then
    DEBUG_LOG_FILE="$SCRIPT_DIR/logs/cleanup_interfaces_debug_$(date +%Y%m%d_%H%M%S).log"
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

print_hint() {
  echo "  - $1"
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
  local svm_input
  local svms_json

  while true; do
    print_hint "Provide ? to list SVM names"
    if [ -n "$SVM" ]; then
      read -r -p "Enter SVM name [$SVM]: " svm_input
    else
      read -r -p "Enter SVM name: " svm_input
    fi
    svm_input=$(normalize_input "$svm_input")

    if [ -z "$svm_input" ] && [ -n "$SVM" ]; then
      svm_input=$SVM
    fi

    svms_json=$(get_data_svms_json)

    if [ "$svm_input" = "?" ]; then
      show_svms "$svms_json"
      continue
    fi

    if [ -z "$svm_input" ]; then
      echo "SVM is required." >&2
      continue
    fi

    if ! svm_exists "$svm_input" "$svms_json"; then
      echo "SVM '$svm_input' was not found. Type ? to list available SVMs." >&2
      continue
    fi

    SVM=$svm_input
    return
  done
}

get_svm_interfaces_json() {
  local encoded_svm
  encoded_svm=$(uri_encode "$SVM")
  api_request "GET" "https://$MGMT_IP/api/network/ip/interfaces?svm.name=$encoded_svm&fields=uuid,name,ip.address,location.home_node.name,location.home_port.name&return_records=true&return_timeout=15&max_records=10000"
}

get_subnets_json() {
  api_request "GET" "https://$MGMT_IP/api/network/ip/subnets?fields=uuid,name,broadcast_domain.name,ipspace.name,subnet.address,subnet.netmask,gateway&return_records=true&return_timeout=15&max_records=10000"
}

get_svm_routes_json() {
  local encoded_svm
  encoded_svm=$(uri_encode "$SVM")
  api_request "GET" "https://$MGMT_IP/api/network/ip/routes?svm.name=$encoded_svm&fields=uuid,svm.name,destination,gateway&return_records=true&return_timeout=15&max_records=10000"
}

show_interfaces() {
  local interfaces_json=$1
  local rows

  rows=$(printf '%s' "$interfaces_json" | jq -r '
    .records[]
    | [.name, (.ip.address // "-"), (.location.home_node.name // "-"), (.location.home_port.name // "-")]
    | @tsv
  ' | sort)

  if [ -z "$rows" ]; then
    echo "No interfaces found in SVM '$SVM'."
    return
  fi

  echo
  echo "Available interfaces in SVM '$SVM':"
  while IFS=$'\t' read -r name ip_address node_name port_name; do
    echo "  - $name ($ip_address) on $node_name/$port_name"
  done <<< "$rows"
  echo
}

build_interface_inventory() {
  local interfaces_json=$1
  local name
  local uuid

  ALL_INTERFACE_NAMES=()
  ALL_INTERFACE_UUIDS=()

  while IFS=$'\t' read -r name uuid; do
    ALL_INTERFACE_NAMES+=("$name")
    ALL_INTERFACE_UUIDS+=("$uuid")
  done < <(printf '%s' "$interfaces_json" | jq -r '.records[] | [.name, .uuid] | @tsv' | sort -V)
}

show_interfaces_numbered() {
  local interfaces_json=$1
  local idx
  local all_option_number

  build_interface_inventory "$interfaces_json"
  all_option_number=$(( ${#ALL_INTERFACE_NAMES[@]} + 1 ))

  echo
  echo "Available LIFs in SVM '$SVM':"
  for idx in "${!ALL_INTERFACE_NAMES[@]}"; do
    echo "  $((idx + 1))) ${ALL_INTERFACE_NAMES[$idx]}"
  done
  echo "  $all_option_number) ALL LIFs"
  echo "  0) No LIFs"
  echo
}

resolve_interface_selection_by_number() {
  local selection=$1
  local all_option_number=$2
  local normalized
  local except_index
  local one_based_index
  local idx
  local raw_item
  local -a selected_indices=()

  TARGET_INTERFACE_NAMES=()
  TARGET_INTERFACE_UUIDS=()

  normalized=$(normalize_input "$selection")
  if [ -z "$normalized" ]; then
    echo "Selection is required." >&2
    return 1
  fi

  if [ "$normalized" = "0" ]; then
    return 0
  fi

  if [[ "$normalized" == !* ]]; then
    except_index=${normalized#!}
    if [[ ! "$except_index" =~ ^[0-9]+$ ]]; then
      echo "Use !<number> to keep one LIF and delete all others." >&2
      return 1
    fi
    if [ "$except_index" -lt 1 ] || [ "$except_index" -gt "${#ALL_INTERFACE_NAMES[@]}" ]; then
      echo "Invalid LIF number for !selection: $except_index" >&2
      return 1
    fi
    for idx in "${!ALL_INTERFACE_NAMES[@]}"; do
      one_based_index=$((idx + 1))
      if [ "$one_based_index" -ne "$except_index" ]; then
        TARGET_INTERFACE_NAMES+=("${ALL_INTERFACE_NAMES[$idx]}")
        TARGET_INTERFACE_UUIDS+=("${ALL_INTERFACE_UUIDS[$idx]}")
      fi
    done
    return 0
  fi

  if [ "$normalized" = "$all_option_number" ]; then
    TARGET_INTERFACE_NAMES=("${ALL_INTERFACE_NAMES[@]}")
    TARGET_INTERFACE_UUIDS=("${ALL_INTERFACE_UUIDS[@]}")
    return 0
  fi

  IFS=',' read -r -a raw_items <<< "$normalized"
  for raw_item in "${raw_items[@]}"; do
    raw_item=$(normalize_input "$raw_item")
    if [ -z "$raw_item" ]; then
      continue
    fi
    if [[ ! "$raw_item" =~ ^[0-9]+$ ]]; then
      echo "LIF selections must be numbers, comma-separated, $all_option_number for all, 0 for none, or !number." >&2
      return 1
    fi
    if [ "$raw_item" -lt 1 ] || [ "$raw_item" -gt "${#ALL_INTERFACE_NAMES[@]}" ]; then
      echo "Invalid LIF number: $raw_item" >&2
      return 1
    fi
    selected_indices+=("$raw_item")
  done

  if [ "${#selected_indices[@]}" -eq 0 ]; then
    echo "No valid LIF numbers were provided." >&2
    return 1
  fi

  for one_based_index in "${selected_indices[@]}"; do
    idx=$((one_based_index - 1))
    TARGET_INTERFACE_NAMES+=("${ALL_INTERFACE_NAMES[$idx]}")
    TARGET_INTERFACE_UUIDS+=("${ALL_INTERFACE_UUIDS[$idx]}")
  done
}

show_subnets() {
  local subnets_json=$1
  local rows

  rows=$(printf '%s' "$subnets_json" | jq -r '
    .records[]
    | [.name, (.broadcast_domain.name // "-"), (.subnet.address // "-"), (.subnet.netmask // "-"), (.gateway // "-")]
    | @tsv
  ' | sort)

  if [ -z "$rows" ]; then
    echo "No subnets returned by the API."
    return
  fi

  echo
  echo "Available subnets:"
  while IFS=$'\t' read -r name bd_name subnet_address subnet_netmask gateway; do
    echo "  - $name ($subnet_address/$subnet_netmask, broadcast domain: $bd_name, gateway: $gateway)"
  done <<< "$rows"
  echo
}

show_default_routes() {
  local routes_json=$1
  local rows

  rows=$(printf '%s' "$routes_json" | jq -r '
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
    | [(.gateway // "-")]
    | @tsv
  ' | sort -u)

  if [ -z "$rows" ]; then
    echo "No default routes found in SVM '$SVM'."
    return
  fi

  echo
  echo "Default routes in SVM '$SVM':"
  while IFS=$'\t' read -r gateway; do
    echo "  - gateway: $gateway"
  done <<< "$rows"
  echo
}

resolve_target_interfaces() {
  local interfaces_json=$1
  local selector=$2
  local normalized_selector
  local has_wildcard=false
  local name
  local uuid

  TARGET_INTERFACE_NAMES=()
  TARGET_INTERFACE_UUIDS=()

  normalized_selector=$(normalize_input "$selector")
  if [[ "$normalized_selector" == *"*"* ]]; then
    has_wildcard=true
  fi

  while IFS=$'\t' read -r name uuid; do
    if [ "$normalized_selector" = "__ALL__" ]; then
      TARGET_INTERFACE_NAMES+=("$name")
      TARGET_INTERFACE_UUIDS+=("$uuid")
      continue
    fi

    if [ "$has_wildcard" = "true" ]; then
      if [[ "$name" == $normalized_selector ]]; then
        TARGET_INTERFACE_NAMES+=("$name")
        TARGET_INTERFACE_UUIDS+=("$uuid")
      fi
    else
      if [ "$name" = "$normalized_selector" ]; then
        TARGET_INTERFACE_NAMES+=("$name")
        TARGET_INTERFACE_UUIDS+=("$uuid")
      fi
    fi
  done < <(printf '%s' "$interfaces_json" | jq -r '.records[] | [.name, .uuid] | @tsv' | sort -V)
}

resolve_target_subnets() {
  local subnets_json=$1
  local selector=$2
  local normalized_selector
  local has_wildcard=false
  local name
  local uuid

  TARGET_SUBNET_NAMES=()
  TARGET_SUBNET_UUIDS=()

  normalized_selector=$(normalize_input "$selector")
  if [[ "$normalized_selector" == *"*"* ]]; then
    has_wildcard=true
  fi

  while IFS=$'\t' read -r name uuid; do
    if [ "$normalized_selector" = "__ALL__" ]; then
      TARGET_SUBNET_NAMES+=("$name")
      TARGET_SUBNET_UUIDS+=("$uuid")
      continue
    fi

    if [ "$has_wildcard" = "true" ]; then
      if [[ "$name" == $normalized_selector ]]; then
        TARGET_SUBNET_NAMES+=("$name")
        TARGET_SUBNET_UUIDS+=("$uuid")
      fi
    else
      if [ "$name" = "$normalized_selector" ]; then
        TARGET_SUBNET_NAMES+=("$name")
        TARGET_SUBNET_UUIDS+=("$uuid")
      fi
    fi
  done < <(printf '%s' "$subnets_json" | jq -r '.records[] | [.name, .uuid] | @tsv' | sort -V)
}

resolve_target_default_routes() {
  local routes_json=$1
  local gateway
  local uuid

  TARGET_ROUTE_UUIDS=()
  TARGET_ROUTE_GATEWAYS=()

  while IFS=$'\t' read -r uuid gateway; do
    TARGET_ROUTE_UUIDS+=("$uuid")
    TARGET_ROUTE_GATEWAYS+=("$gateway")
  done < <(printf '%s' "$routes_json" | jq -r '
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
    | [.uuid, (.gateway // "-")]
    | @tsv
  ')
}

prompt_interfaces_cleanup() {
  local interfaces_json
  local cleanup_choice
  local delete_all_choice
  local lif_selection_input
  local all_option_number

  interfaces_json=$(get_svm_interfaces_json)
  if [ "$(printf '%s' "$interfaces_json" | jq -r '.num_records // 0')" -eq 0 ]; then
    echo "No interfaces found in SVM '$SVM'."
    return
  fi

  while true; do
    read -r -p "Would you like to clean up interfaces in SVM '$SVM'? [y/N]: " cleanup_choice
    cleanup_choice=$(normalize_input "$cleanup_choice")
    cleanup_choice=${cleanup_choice,,}
    case "$cleanup_choice" in
      y|yes)
        while true; do
          read -r -p "Delete all interfaces (data and management) in SVM '$SVM'? [y/N]: " delete_all_choice
          delete_all_choice=$(normalize_input "$delete_all_choice")
          delete_all_choice=${delete_all_choice,,}
          case "$delete_all_choice" in
            y|yes)
              resolve_target_interfaces "$interfaces_json" "__ALL__"
              return
              ;;
            ""|n|no)
              while true; do
                show_interfaces_numbered "$interfaces_json"
                all_option_number=$(( ${#ALL_INTERFACE_NAMES[@]} + 1 ))
                echo "Delete selected LIFs:"
                print_hint "Use one number, comma-separated numbers, or $all_option_number for all LIFs"
                print_hint "Use 0 to delete no LIFs"
                print_hint "Use !number to delete all except one LIF"
                read -r -p "Selection: " lif_selection_input
                lif_selection_input=$(normalize_input "$lif_selection_input")
                if [ "$lif_selection_input" = "?" ]; then
                  continue
                fi
                if [ -z "$lif_selection_input" ]; then
                  echo "LIF selection is required." >&2
                  continue
                fi
                if resolve_interface_selection_by_number "$lif_selection_input" "$all_option_number"; then
                  return
                else
                  continue
                fi
              done
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

prompt_subnets_cleanup() {
  local subnets_json
  local cleanup_choice
  local delete_all_choice
  local selector_input

  subnets_json=$(get_subnets_json)
  if [ "$(printf '%s' "$subnets_json" | jq -r '.num_records // 0')" -eq 0 ]; then
    echo "No subnets returned by the API."
    return
  fi

  while true; do
    read -r -p "Would you like to clean up subnets? [y/N]: " cleanup_choice
    cleanup_choice=$(normalize_input "$cleanup_choice")
    cleanup_choice=${cleanup_choice,,}
    case "$cleanup_choice" in
      y|yes)
        while true; do
          read -r -p "Delete all subnets returned by the API? [y/N]: " delete_all_choice
          delete_all_choice=$(normalize_input "$delete_all_choice")
          delete_all_choice=${delete_all_choice,,}
          case "$delete_all_choice" in
            y|yes)
              resolve_target_subnets "$subnets_json" "__ALL__"
              return
              ;;
            ""|n|no)
              while true; do
                print_hint "Provide ? to list subnets"
                read -r -p "Specify a subnet name or wildcard (for example affx*) to delete: " selector_input
                selector_input=$(normalize_input "$selector_input")
                if [ "$selector_input" = "?" ]; then
                  show_subnets "$subnets_json"
                  continue
                fi
                if [ -z "$selector_input" ]; then
                  echo "Subnet selector is required." >&2
                  continue
                fi
                resolve_target_subnets "$subnets_json" "$selector_input"
                if [ ${#TARGET_SUBNET_NAMES[@]} -eq 0 ]; then
                  echo "No subnets matched '$selector_input'." >&2
                  continue
                fi
                return
              done
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

prompt_default_routes_cleanup() {
  local routes_json
  local cleanup_choice

  routes_json=$(get_svm_routes_json)
  resolve_target_default_routes "$routes_json"

  if [ ${#TARGET_ROUTE_UUIDS[@]} -eq 0 ]; then
    echo "No default routes found in SVM '$SVM'."
    return
  fi

  while true; do
    print_hint "Provide ? to list default routes"
    read -r -p "Would you like to clean up default routes in SVM '$SVM'? [y/N]: " cleanup_choice
    cleanup_choice=$(normalize_input "$cleanup_choice")
    if [ "$cleanup_choice" = "?" ]; then
      show_default_routes "$routes_json"
      continue
    fi
    cleanup_choice=${cleanup_choice,,}
    case "$cleanup_choice" in
      y|yes)
        return
        ;;
      ""|n|no)
        TARGET_ROUTE_UUIDS=()
        TARGET_ROUTE_GATEWAYS=()
        return
        ;;
      *)
        echo "Please enter y or n." >&2
        ;;
    esac
  done
}

show_cleanup_summary() {
  local idx

  echo
  echo "Cleanup summary:"
  if [ ${#TARGET_INTERFACE_NAMES[@]} -gt 0 ]; then
    echo "Interfaces to delete:"
    for idx in "${!TARGET_INTERFACE_NAMES[@]}"; do
      echo "  - ${TARGET_INTERFACE_NAMES[$idx]}"
    done
  fi

  if [ ${#TARGET_SUBNET_NAMES[@]} -gt 0 ]; then
    echo "Subnets to delete:"
    for idx in "${!TARGET_SUBNET_NAMES[@]}"; do
      echo "  - ${TARGET_SUBNET_NAMES[$idx]}"
    done
  fi

  if [ ${#TARGET_ROUTE_GATEWAYS[@]} -gt 0 ]; then
    echo "Default routes to delete:"
    for idx in "${!TARGET_ROUTE_GATEWAYS[@]}"; do
      echo "  - gateway: ${TARGET_ROUTE_GATEWAYS[$idx]}"
    done
  fi
  echo
}

delete_interface() {
  local interface_uuid=$1
  local interface_name=$2
  echo "Deleting interface: $interface_name"
  api_request "DELETE" "https://$MGMT_IP/api/network/ip/interfaces/$interface_uuid?return_timeout=0&return_records=false" >/dev/null
}

delete_subnet() {
  local subnet_uuid=$1
  local subnet_name=$2
  echo "Deleting subnet: $subnet_name"
  api_request "DELETE" "https://$MGMT_IP/api/network/ip/subnets/$subnet_uuid?return_timeout=0&return_records=false" >/dev/null
}

delete_route() {
  local route_uuid=$1
  local gateway=$2
  echo "Deleting default route with gateway: $gateway"
  api_request "DELETE" "https://$MGMT_IP/api/network/ip/routes/$route_uuid?return_timeout=0&return_records=false" >/dev/null
}

parse_args "$@"
init_debug_logging

require_command curl
require_command jq

MGMT_IP=${MGMT_IP:-}
AUTH_TOK=${AUTH_TOK:-}
SVM=${SVM:-}

TARGET_INTERFACE_NAMES=()
TARGET_INTERFACE_UUIDS=()
TARGET_SUBNET_NAMES=()
TARGET_SUBNET_UUIDS=()
TARGET_ROUTE_UUIDS=()
TARGET_ROUTE_GATEWAYS=()

prompt_if_empty MGMT_IP "Enter cluster management IP: "
prompt_auth_token
prompt_svm_name
prompt_interfaces_cleanup
prompt_subnets_cleanup
prompt_default_routes_cleanup

if [ ${#TARGET_INTERFACE_NAMES[@]} -eq 0 ] && [ ${#TARGET_SUBNET_NAMES[@]} -eq 0 ] && [ ${#TARGET_ROUTE_UUIDS[@]} -eq 0 ]; then
  echo "No cleanup actions were selected."
  exit 0
fi

show_cleanup_summary

while true; do
  read -r -p "Proceed with the selected cleanup actions? [y/N]: " confirm_cleanup
  confirm_cleanup=$(normalize_input "$confirm_cleanup")
  confirm_cleanup=${confirm_cleanup,,}
  case "$confirm_cleanup" in
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

for idx in "${!TARGET_INTERFACE_NAMES[@]}"; do
  delete_interface "${TARGET_INTERFACE_UUIDS[$idx]}" "${TARGET_INTERFACE_NAMES[$idx]}"
done

for idx in "${!TARGET_ROUTE_UUIDS[@]}"; do
  delete_route "${TARGET_ROUTE_UUIDS[$idx]}" "${TARGET_ROUTE_GATEWAYS[$idx]}"
done

for idx in "${!TARGET_SUBNET_NAMES[@]}"; do
  delete_subnet "${TARGET_SUBNET_UUIDS[$idx]}" "${TARGET_SUBNET_NAMES[$idx]}"
done

echo
echo "Cleanup complete."
