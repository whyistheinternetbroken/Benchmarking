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

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_non_negative_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

normalize_input() {
  printf '%s' "$1" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
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

  printf "%-${max_name_width}s | %-${max_style_width}s | %${max_size_width}s | %-${max_path_width}s\n" "$header_name" "$header_style" "$header_size" "$header_path"
  separator_width=$((max_name_width + max_style_width + max_size_width + max_path_width + 9))
  printf '%*s\n' "$separator_width" '' | tr ' ' '-'

  for idx in "${!row_names[@]}"; do
    printf "%-${max_name_width}s | %-${max_style_width}s | %${max_size_width}s | %-${max_path_width}s\n" \
      "${row_names[$idx]}" "${row_styles[$idx]}" "${row_sizes[$idx]}" "${row_paths[$idx]}"
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

build_payload() {
  local volume_name=$1
  local volume_path="/$volume_name"

  if [ "$VOLUME_STYLE" = "flexgroup" ]; then
    jq -n \
      --arg name "$volume_name" \
      --arg svm "$SVM" \
      --arg path "$volume_path" \
      --argjson size "$VOL_SIZE_BYTES" \
      '{
        constituent_count: 32,
        guarantee: { type: "none" },
        name: $name,
        nas: {
          export_policy: { name: "default" },
          junction_parent: { name: $svm },
          path: $path,
          security_style: "unix",
          unix_permissions: 777
        },
        size: $size,
        space: { large_size_enabled: true },
        style: "flexgroup",
        svm: { name: $svm },
        type: "rw"
      }'
  else
    jq -n \
      --arg name "$volume_name" \
      --arg svm "$SVM" \
      --arg path "$volume_path" \
      --argjson size "$VOL_SIZE_BYTES" \
      '{
        guarantee: { type: "none" },
        name: $name,
        nas: {
          export_policy: { name: "default" },
          junction_parent: { name: $svm },
          path: $path,
          security_style: "unix",
          unix_permissions: 777
        },
        size: $size,
        style: "flexvol",
        svm: { name: $svm },
        type: "rw"
      }'
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
    if [ -n "$VOL_SIZE_TB" ]; then
      read -r -p "Enter volume size in TB (2..$CAPACITY_TB) [$VOL_SIZE_TB]: " size_input
    else
      read -r -p "Enter volume size in TB (2..$CAPACITY_TB): " size_input
    fi
    size_input=$(normalize_input "$size_input")
    if [ -z "$size_input" ] && [ -n "$VOL_SIZE_TB" ]; then
      size_input=$VOL_SIZE_TB
    fi
    if ! is_positive_integer "$size_input"; then
      echo "Volume size must be a positive integer (TB)." >&2
      continue
    fi
    if [ "$size_input" -lt 2 ] || [ "$size_input" -gt "$CAPACITY_TB" ]; then
      echo "Volume size must be between 2 and $CAPACITY_TB TB." >&2
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
