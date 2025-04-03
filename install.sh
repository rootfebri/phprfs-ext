#!/usr/bin/env bash
# shellcheck disable=SC2207

_SCRIPT=$0

usage() {
  echo "Usage: sudo bash $_SCRIPT [options]"
  echo
  echo "Options:"
  echo "  No arguments     : Install for all supported PHP versions found in the system"
  echo "  current          : Install for the current PHP version in the system PATH"
  echo "  <version>        : Install for specific PHP versions (e.g., 82, 83, 84)"
  echo "  <path/to/php>    : Install for PHP binary at the specified path"
  echo
  echo "Examples:"
  echo "  sudo bash $_SCRIPT"
  echo "  sudo bash $_SCRIPT current"
  echo "  sudo bash $_SCRIPT 82 83"
  echo "  sudo bash $_SCRIPT /usr/bin/php /opt/php/8.3/bin/php"
  exit 0
}

# Add this line right after the usage function
[[ "$1" == "-h" || "$1" == "--help" ]] && usage
if [[ $EUID -ne 0 ]]; then
  echo "Please run this script with root privileges: sudo bash $_SCRIPT"
  exit 1
fi

SUPPORTED_PHP_VERSIONS=(82 83 84)
TEMP_FILES=()
REMOVABLE=()
ALL_PHP=()
POSSIBLE_PATHS=(/opt/php /opt/cpanel /usr/bin/php /usr/local/lsws /home/linuxbrew/.linuxbrew/Cellar /usr/bin)

str_contains() {
  if [[ $1 == *$2* ]]; then
    return 0
  else
    return 1
  fi
}
str_starts() {
  if [[ $1 == $2* ]]; then
    return 0
  else
    return 1
  fi
}
str_ends() {
  if [[ $1 == *$2 ]]; then
    return 0
  else
    return 1
  fi
}
call_php() {
  local php=$1
  local code=$2
  local output
  output=$($php -r "$code" 2>/dev/null | grep -v "PHP Warning" | grep -v "Warning:")
  printf "%s" "$(tr -d '\r\n' <<<"$output")"
}
dir_so() {
  call_php "$1" 'echo ini_get("extension_dir");'
}
dir_ini() {
  call_php "$1" 'echo PHP_CONFIG_FILE_SCAN_DIR;'
}
php_version() {
  local php=$1
  call_php "$php" 'echo PHP_VERSION;'
}
dot_version() {
  local version=$1
  version=$(tr -d ' .\r\n' <<<"$1")
  printf "%s.%s" "${version:0:1}" "${version:1:1}"
}
num_version() {
  local version=$1
  version=$(tr -d ' .\r\n' <<<"$1")
  printf "%s%s" "${version:0:1}" "${version:1:1}"
}
clean_trap() {
  echo "Cleaning up..."
  local temp_file
  for temp_file in "${TEMP_FILES[@]}"; do
    if [[ -f "$temp_file" ]]; then
      echo "Removing file: $temp_file"
      rm -f "$temp_file"
    fi
  done
  echo "Restarting PHP services to restore the original state..."
  restart_service
  echo "Script interrupted or completed. Exiting cleanly."
  trap - SIGINT SIGTERM EXIT
  exit 0
}
GET_PHP() {
  local php
  local bin
  local num_ver
  local dot_ver
  local POSSIBLE_PATH
  local TOTAL_PHP=${#ALL_PHP[@]}

  num_ver=$(num_version "$1")
  dot_ver=$(dot_version "$1")

  for POSSIBLE_PATH in "${POSSIBLE_PATHS[@]}"; do
    if [[ ! -d $POSSIBLE_PATH ]]; then
      continue
    fi

    if ! str_contains "${ALL_PHP[*]}" "$POSSIBLE_PATH/php" && executable "$POSSIBLE_PATH/php"; then
      ALL_PHP+=("$POSSIBLE_PATH/php")
    fi

    if executable "$POSSIBLE_PATH/php$num_ver"; then
      ALL_PHP+=("$POSSIBLE_PATH/php$num_ver")
    fi

    if executable "$POSSIBLE_PATH/php$dot_ver"; then
      ALL_PHP+=("$POSSIBLE_PATH/php$dot_ver")
    fi

    for bin in $(dir -R "$POSSIBLE_PATH" | grep -a '/bin' | grep -a 'php' | grep -a "$num_ver" | tr -d ':'); do
      php="$bin/php"
      if executable "$php"; then
        ALL_PHP+=("$php")
      fi
    done
    for bin in $(dir -R "$POSSIBLE_PATH" | grep -a '/bin' | grep -a 'php' | grep -a "$dot_ver" | tr -d ':'); do
      php="$bin/php"
      if executable "$php"; then
        ALL_PHP+=("$php")
      fi
    done
  done

  if [[ $TOTAL_PHP -eq ${#ALL_PHP[@]} ]]; then
    echo "Found $((${#ALL_PHP[@]} - "$TOTAL_PHP")) php bin for PHP $dot_ver"
  else
    echo "PHP $dot_ver nowhere to be found, searched directory ${POSSIBLE_PATHS[*]}"
  fi
  echo "============================================"
}
dl_extension() {
  local url
  local filename

  url=$1
  filename="$(basename "$url")"

  REMOVABLE+=("$filename")
  TEMP_FILES+=("$filename")
  echo "Downloading: $filename"
  curl -s -L -O "$url"
  chmod 775 "$filename" >/dev/null 2>&1
}
restart_service() {
  local phpfpm
  local apache

  phpfpm="/usr/local/cpanel/scripts/restartsrv_apache_php_fpm"
  apache="/usr/local/cpanel/scripts/restartsrv_apache"

  if [[ -f $phpfpm ]]; then
    "$phpfpm" >/dev/null 2>&1
  fi
  if [[ -f $apache ]]; then
    "$apache" >/dev/null 2>&1
  fi

  if command -v service >/dev/null 2>&1; then
    sudo service apache2 restart >/dev/null 2>&1
    sudo service nginx restart >/dev/null 2>&1
  elif command -v systemctl >/dev/null 2>&1; then
    sudo systemctl restart apache2 >/dev/null 2>&1
    sudo systemctl restart nginx >/dev/null 2>&1
  fi
}
install_extension() {
  local php=$1
  local version
  local dotver
  local extension
  local file_so
  local phprfs_ini

  if ! executable "$php"; then
    echo "PHP binary [$php] not found. Skipping extension installation."
    return 1
  fi

  version=$(php_version "$php")
  phprfs_ini="$(dir_ini "$php")/10-phprfs.ini"
  file_so="$(dir_so "$php")/phprfs.so"
  dotver=$(dot_version "$version")
  extension="phprfs-$dotver.so"

  if [[ ! -f "$extension" ]]; then
    echo "Extension file $extension not found. Skipping PHP $dotver."
    return 1
  fi

  cp "$extension" "$file_so" -f
  echo "; Enable phprfs extension module" >"$phprfs_ini"
  echo "extension=phprfs.so" >>"$phprfs_ini"

  TEMP_FILES+=("$file_so" "$phprfs_ini")
  restart_service
  echo "Successfully installed phprfs extension for PHP $dotver [$php]"
}
executable() {
  if [[ -x "$1" ]]; then
    return 0
  else
    return 1
  fi
}
resolve_symlink() {
  realpath -q "$1"
}
trap clean_trap SIGINT SIGTERM EXIT

for dir in "${POSSIBLE_PATHS[@]}"; do
  if [[ ! -d $dir ]]; then
    POSSIBLE_PATHS=($(tr ' ' '\n' <<<"${POSSIBLE_PATHS[*]}" | grep -v "$dir"))
  fi
done

for url in $(curl -s https://api.github.com/repos/rootfebri/phprfs-ext/releases/latest | grep -oP '"browser_download_url": "\K(.*)(?=")'); do
  if [[ $url == *.so ]]; then
    dl_extension "$url"
  fi
done

####### Installation #######
if [[ -n "$1" ]]; then
  if [[ $1 == "current" ]]; then
    if current=$(command -v php); then
      install_extension "$current"
    else
      echo "PHP current version not found. Please install PHP first."
      exit 1
    fi
  else
    for arg in "${@}"; do
      if executable "$arg"; then
        ALL_PHP+=("$arg")
      elif str_contains "${SUPPORTED_PHP_VERSIONS[@]}" "$(num_version "$arg")"; then
        GET_PHP "$arg"
      else
        echo "Unsupported PHP version: $arg, Skipped..."
      fi
    done
  fi
else
  for ver in "${SUPPORTED_PHP_VERSIONS[@]}"; do
    GET_PHP "$ver"
  done
fi

REAL_PHP=()
for __php in "${ALL_PHP[@]}"; do
  __php=$(realpath -q "$__php")
  if ! str_contains "${REAL_PHP[*]}" "$__php" && [[ ! -d $__php ]]; then
    REAL_PHP+=("$__php")
  fi
done

if [[ ${#REAL_PHP[@]} -gt 0 ]]; then
  echo "Found PHP versions to be installed:"
  echo "============================================"
  for php in "${REAL_PHP[@]}"; do
    echo "$php"
  done
  echo "============================================"
  echo "HIT CTRL+C to cancel!!"
  echo "============================================"
  for ((i = 5; i > 0; i--)); do
    printf "Installation started in %s" "$i"
  done

  for php in "${REAL_PHP[@]}"; do
    install_extension "$php"
  done
fi
####### End of Installation #######

for _file in "${REMOVABLE[@]}"; do
  rm "$_file" -rf >/dev/null 2>&1
done

# If the script completes successfully, remove traps
echo "Installation complete!"
trap - SIGINT SIGTERM EXIT
