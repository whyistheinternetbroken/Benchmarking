#!/bin/bash

set -euo pipefail

TB_BYTES=1099511627776

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

api_request() {
  local method=$1
  local url=$2
  local payload=${3:-}
  local response
  local http_code
  local body

  if [ -n "$payload" ]; then
    response=$(curl -sS -k -X "$method" "$url" \
      -H "accept: application/json" \
      -H "authorization: Basic $AUTH_TOK" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      -w '\n%{http_code}')
  else
    response=$(curl -sS -k -X "$method" "$url" \
      -H "accept: application/json" \
      -H "authorization: Basic $AUTH_TOK" \
      -w '\n%{http_code}')
  fi

  http_code=${response##*$'\n'}
  body=${response%$'\n'*}

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
  api_request "GET" "https://$MGMT_IP/api/svm/svms?fields=name,subtype,type&return_records=true&return_timeout=15&max_records=10000"
}

show_svms() {
  local svms_json=$1
  local rows
  local max_name_width
  local max_type_width
  local name
  local type
  local subtype
  local header_name="SVM"
  local header_type="Type/Subtype"
  local separator_width

  rows=$(printf '%s' "$svms_json" | jq -r '
    .records[]
    | [.name, ((.type // "-") + "/" + (.subtype // "-"))]
    | @tsv
  ' | sort)

  if [ -z "$rows" ]; then
    echo "No SVMs returned by the API."
    return
  fi

  max_name_width=${#header_name}
  max_type_width=${#header_type}

  while IFS=$'\t' read -r name type; do
    if [ ${#name} -gt "$max_name_width" ]; then
      max_name_width=${#name}
    fi
    if [ ${#type} -gt "$max_type_width" ]; then
      max_type_width=${#type}
    fi
  done <<< "$rows"

  printf '\n'
  printf "%-${max_name_width}s | %-${max_type_width}s\n" "$header_name" "$header_type"
  separator_width=$((max_name_width + max_type_width + 3))
  printf '%*s\n' "$separator_width" '' | tr ' ' '-'
  while IFS=$'\t' read -r name subtype; do
    printf "%-${max_name_width}s | %-${max_type_width}s\n" "$name" "$subtype"
  done <<< "$rows"
  printf '\n'
}

svm_exists() {
  local svm_name=$1
  local svms_json=$2
  local count
  count=$(printf '%s' "$svms_json" | jq -r --arg svm "$svm_name" '[.records[] | select(.name == $svm)] | length')
  [ "$count" -gt 0 ]
}

get_svm_volumes_json() {
  local svm_name=$1
  local encoded_svm
  encoded_svm=$(uri_encode "$svm_name")
  api_request "GET" "https://$MGMT_IP/api/storage/volumes?svm.name=$encoded_svm&fields=uuid,name,size,space.used,state,nas.path,is_constituent&return_records=true&return_timeout=15&max_records=10000"
}

bytes_to_tb() {
  local bytes=$1
  echo "scale=2; $bytes / $TB_BYTES" | bc
}

show_volumes() {
  local volumes_json=$1
  local rows
  local -a row_names
  local -a row_sizes
  local -a row_used
  local -a row_states
  local -a row_paths
  local idx
  local name
  local size_bytes
  local used_bytes
  local state
  local path
  local size_tb
  local used_tb
  local max_name_width
  local max_size_width
  local max_used_width
  local max_state_width
  local max_path_width
  local header_name="Volume"
  local header_size="Size (TB)"
  local header_used="Used (TB)"
  local header_state="State"
  local header_path="Junction Path"
  local separator_width

  rows=$(printf '%s' "$volumes_json" | jq -r '
    .records[]
    | select((.is_constituent // false) == false)
    | [.name, (.size // 0 | tostring), (.space.used // 0 | tostring), (.state // "-"), (.nas.path // "-")]
    | @tsv
  ' | sort)

  if [ -z "$rows" ]; then
    echo "No non-constituent volumes found in SVM '$SVM'."
    return
  fi

  max_name_width=${#header_name}
  max_size_width=${#header_size}
  max_used_width=${#header_used}
  max_state_width=${#header_state}
  max_path_width=${#header_path}

  while IFS=$'\t' read -r name size_bytes used_bytes state path; do
    size_tb=$(bytes_to_tb "$size_bytes")
    used_tb=$(bytes_to_tb "$used_bytes")

    row_names+=("$name")
    row_sizes+=("$size_tb")
    row_used+=("$used_tb")
    row_states+=("$state")
    row_paths+=("$path")

    if [ ${#name} -gt "$max_name_width" ]; then
      max_name_width=${#name}
    fi
    if [ ${#size_tb} -gt "$max_size_width" ]; then
      max_size_width=${#size_tb}
    fi
    if [ ${#used_tb} -gt "$max_used_width" ]; then
      max_used_width=${#used_tb}
    fi
    if [ ${#state} -gt "$max_state_width" ]; then
      max_state_width=${#state}
    fi
    if [ ${#path} -gt "$max_path_width" ]; then
      max_path_width=${#path}
    fi
  done <<< "$rows"

  printf '\n'
  printf "%-${max_name_width}s | %${max_size_width}s | %${max_used_width}s | %-${max_state_width}s | %-${max_path_width}s\n" \
    "$header_name" "$header_size" "$header_used" "$header_state" "$header_path"
  separator_width=$((max_name_width + max_size_width + max_used_width + max_state_width + max_path_width + 12))
  printf '%*s\n' "$separator_width" '' | tr ' ' '-'

  for idx in "${!row_names[@]}"; do
    printf "%-${max_name_width}s | %${max_size_width}s | %${max_used_width}s | %-${max_state_width}s | %-${max_path_width}s\n" \
      "${row_names[$idx]}" "${row_sizes[$idx]}" "${row_used[$idx]}" "${row_states[$idx]}" "${row_paths[$idx]}"
  done
  printf '\n'
}

resolve_target_volumes() {
  local volumes_json=$1
  local selector=$2
  local normalized_selector
  local selector_no_spaces
  local has_wildcard=false
  local name
  local uuid
  local state
  local path

  TARGET_NAMES=()
  TARGET_UUIDS=()

  normalized_selector=$(normalize_input "$selector")
  selector_no_spaces=$(printf '%s' "$normalized_selector" | tr -d '[:space:]')
  if [[ "$selector_no_spaces" == *,!vsroot ]]; then
    normalized_selector=${selector_no_spaces%%,*}
  fi

  if [[ "$normalized_selector" == *"*"* ]]; then
    has_wildcard=true
  fi

  while IFS=$'\t' read -r name uuid state path; do
    if [ "$name" = "vsroot" ]; then
      continue
    fi

    if [ "$normalized_selector" = "__ALL__" ]; then
      TARGET_NAMES+=("$name")
      TARGET_UUIDS+=("$uuid")
      continue
    fi

    if [ "$has_wildcard" = "true" ]; then
      if [[ "$name" == $normalized_selector ]]; then
        TARGET_NAMES+=("$name")
        TARGET_UUIDS+=("$uuid")
      fi
    else
      if [ "$name" = "$normalized_selector" ]; then
        TARGET_NAMES+=("$name")
        TARGET_UUIDS+=("$uuid")
      fi
    fi
  done < <(printf '%s' "$volumes_json" | jq -r '
    .records[]
    | select((.is_constituent // false) == false)
    | [.name, .uuid, (.state // "-"), (.nas.path // "-")]
    | @tsv
  ')
}

show_target_volumes() {
  local idx

  if [ ${#TARGET_NAMES[@]} -eq 0 ]; then
    echo "No volumes matched the selection."
    return 1
  fi

  printf '\n'
  echo "Volumes selected for delete:"
  for idx in "${!TARGET_NAMES[@]}"; do
    echo "  - ${TARGET_NAMES[$idx]}"
  done
  printf '\n'
}

wait_for_volume_state() {
  local volume_uuid=$1
  local expected_state=$2
  local volume_name=$3
  local attempts=60
  local attempt=1
  local volume_json
  local current_state

  while [ "$attempt" -le "$attempts" ]; do
    volume_json=$(api_request "GET" "https://$MGMT_IP/api/storage/volumes/$volume_uuid?fields=state")
    current_state=$(printf '%s' "$volume_json" | jq -r '.state // ""')
    if [ "$current_state" = "$expected_state" ]; then
      return
    fi
    sleep 2
    attempt=$((attempt + 1))
  done

  echo "Timed out waiting for volume '$volume_name' to reach state '$expected_state'." >&2
  exit 1
}

wait_for_volume_unmounted() {
  local volume_uuid=$1
  local volume_name=$2
  local attempts=60
  local attempt=1
  local volume_json
  local current_path

  while [ "$attempt" -le "$attempts" ]; do
    volume_json=$(api_request "GET" "https://$MGMT_IP/api/storage/volumes/$volume_uuid?fields=nas.path")
    current_path=$(printf '%s' "$volume_json" | jq -r '.nas.path // ""')
    if [ -z "$current_path" ]; then
      return
    fi
    sleep 2
    attempt=$((attempt + 1))
  done

  echo "Timed out waiting for volume '$volume_name' to unmount." >&2
  exit 1
}

offline_volume() {
  local volume_uuid=$1
  local volume_name=$2
  local payload='{"state":"offline"}'

  echo "Offlining volume: $volume_name"
  api_request "PATCH" "https://$MGMT_IP/api/storage/volumes/$volume_uuid?return_timeout=0&return_records=false" "$payload" >/dev/null
  wait_for_volume_state "$volume_uuid" "offline" "$volume_name"
}

unmount_volume() {
  local volume_uuid=$1
  local volume_name=$2
  local payload='{"nas":{"path":null}}'

  echo "Unmounting volume: $volume_name"
  api_request "PATCH" "https://$MGMT_IP/api/storage/volumes/$volume_uuid?return_timeout=0&return_records=false" "$payload" >/dev/null
  wait_for_volume_unmounted "$volume_uuid" "$volume_name"
}

delete_volume() {
  local volume_uuid=$1
  local volume_name=$2
  local delete_url

  if [ "$FORCE_DELETE" = "true" ]; then
    delete_url="https://$MGMT_IP/api/storage/volumes/$volume_uuid?force=true&return_timeout=0&return_records=false"
  else
    delete_url="https://$MGMT_IP/api/storage/volumes/$volume_uuid?return_timeout=0&return_records=false"
  fi

  echo "Deleting volume: $volume_name"
  api_request "DELETE" "$delete_url" >/dev/null
}

show_rest_translation_notes() {
  cat <<'EOF'
REST translation notes:
- ONTAP CLI diagnostic context toggles (set diag -c / set diag -c off) do not have a REST equivalent.
- CLI wildcard/list forms (for example vol1,vol2 or vol*) are resolved client-side here, then REST calls run per volume UUID.
- CLI -foreground false is represented by asynchronous REST calls using return_timeout=0.
EOF
  printf '\n'
}

require_command curl
require_command jq
require_command bc

MGMT_IP=${MGMT_IP:-}
AUTH_TOK=${AUTH_TOK:-}
SVM=${SVM:-}
FORCE_DELETE=false

prompt_if_empty MGMT_IP "Enter cluster management IP: "
prompt_auth_token

while true; do
  if [ -n "$SVM" ]; then
    read -r -p "Enter SVM name [? to list SVMs] [$SVM]: " svm_input
  else
    read -r -p "Enter SVM name [? to list SVMs]: " svm_input
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
  break
done

show_rest_translation_notes

volumes_json=$(get_svm_volumes_json "$SVM")

while true; do
  read -r -p "Do you want to delete all volumes in the SVM (except vsroot)? [y/N]: " delete_all_choice
  delete_all_choice=$(normalize_input "$delete_all_choice")
  delete_all_choice=${delete_all_choice,,}

  case "$delete_all_choice" in
    y|yes)
      resolve_target_volumes "$volumes_json" "__ALL__"
      break
      ;;
    ""|n|no)
      while true; do
        read -r -p "Specify a volume name or wildcard (for example vol*) to delete (type ? to list volumes in the selected SVM): " selector_input
        selector_input=$(normalize_input "$selector_input")

        if [ "$selector_input" = "?" ]; then
          show_volumes "$volumes_json"
          continue
        fi

        if [ -z "$selector_input" ]; then
          echo "Volume selector is required." >&2
          continue
        fi

        resolve_target_volumes "$volumes_json" "$selector_input"
        if [ ${#TARGET_NAMES[@]} -eq 0 ]; then
          echo "No volumes matched '$selector_input' in SVM '$SVM'." >&2
          continue
        fi
        break
      done
      break
      ;;
    *)
      echo "Please enter y or n." >&2
      ;;
  esac
done

if ! show_target_volumes; then
  exit 1
fi

while true; do
  read -r -p "Force delete volumes to bypass the 12-hour recovery queue? [y/N]: " force_choice
  force_choice=$(normalize_input "$force_choice")
  force_choice=${force_choice,,}
  case "$force_choice" in
    y|yes)
      FORCE_DELETE=true
      break
      ;;
    ""|n|no)
      FORCE_DELETE=false
      break
      ;;
    *)
      echo "Please enter y or n." >&2
      ;;
  esac
done

while true; do
  read -r -p "Proceed to offline, unmount, and delete ${#TARGET_NAMES[@]} volume(s) from SVM '$SVM'? [y/N]: " confirm_delete
  confirm_delete=$(normalize_input "$confirm_delete")
  confirm_delete=${confirm_delete,,}
  case "$confirm_delete" in
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

for idx in "${!TARGET_NAMES[@]}"; do
  volume_name=${TARGET_NAMES[$idx]}
  volume_uuid=${TARGET_UUIDS[$idx]}
  offline_volume "$volume_uuid" "$volume_name"
  unmount_volume "$volume_uuid" "$volume_name"
  delete_volume "$volume_uuid" "$volume_name"
done

echo
echo "Delete requests submitted for ${#TARGET_NAMES[@]} volume(s) in SVM '$SVM'."
if [ "$FORCE_DELETE" = "true" ]; then
  echo "Force delete was enabled."
else
  echo "Force delete was not enabled."
fi
