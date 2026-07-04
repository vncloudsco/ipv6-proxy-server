#!/bin/bash
# =============================================================================
# ipv6-proxy-server.sh — IPv6 backconnect proxy installer
# =============================================================================

# --- 1. GUARDS & CONSTANTS ---

readonly DEFAULT_SUBNET=64
readonly DEFAULT_START_PORT=30000
readonly DEFAULT_PROXIES_TYPE="http"
readonly DEFAULT_ROTATING_INTERVAL=0
readonly SCRIPT_LOG_FILE="/var/tmp/ipv6-proxy-server-logs.log"
readonly PROXY_3PROXY_VERSION="0.9.4"
readonly MIN_START_PORT=5000
readonly MAX_PORT=65535
readonly REQUIRED_PACKAGES=(make g++ wget curl cron ndppd procps)

require_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
  fi
}

# --- 2. LOGGING ---

log_err() {
  echo "$1" 1>&2
  echo -e "$1\n" &>> "$script_log_file"
}

log_err_and_exit() {
  log_err "$1"
  exit 1
}

log_err_print_usage_and_exit() {
  log_err "$1"
  usage
}

# --- 3. CLI (usage, defaults, parse_args) ---

usage() {
  cat >&2 <<EOF
Usage: $0 [-s | --subnet <16|32|48|64|80|96|112> proxy subnet (default 64)]
          [-c | --proxy-count <number> count of proxies]
          [-u | --username <string> shared proxy auth username for all proxies]
          [-p | --password <string> shared proxy auth password for all proxies]
          [--random <bool> random 8-char alphanumeric username/password per proxy (default true)]
          [--no-auth <bool> disable proxy authentication]
          [-t | --proxies-type <http|socks5> result proxies type (default http)]
          [-r | --rotating-interval <0-59> rotating time of external proxies address in minutes (default 0, disabled)]
          [--rotate-every-request <bool> use random external address for every request (--rotating-interval will be ignored)]
          [--start-port <5000-65536> start port for backconnect ipv4 (default 30000)]
          [-l | --localhost <bool> allow connections only for localhost (backconnect on 127.0.0.1)]
          [-f | --backconnect-proxies-file <string> base path for exported proxy files (.list, .txt, .json, .csv)
                when proxies start working (default \`~/proxyserver/backconnect_proxies\`)]
          [-m | --ipv6-mask <string> constant ipv6 address mask, to which the rotated part is added (or gateaway)
                use only if the gateway is different from the subnet address]
          [-i | --interface <string> full name of ethernet interface, on which IPv6 subnet was allocated
                automatically parsed by default, use ONLY if you have non-standard/additional interfaces on your server]
          [-b | --backconnect-ip <string> server IPv4 backconnect address for proxies
                automatically parsed by default, use ONLY if you have non-standard ip allocation on your server]
          [--allowed-hosts <string> allowed hosts or IPs (3proxy format), for example "google.com,*.google.com,*.gstatic.com"
                if at least one host is allowed, the rest are banned by default]
          [--denied-hosts <string> banned hosts or IP addresses in quotes (3proxy format)]
          [--append <bool> add more proxies to existing server without changing old config]
          [--uninstall <bool> disable active proxies, uninstall server and clear all metadata]
          [--info <bool> print info about running proxy server]
EOF
  exit 1
}

set_defaults() {
  subnet=$DEFAULT_SUBNET
  proxies_type=$DEFAULT_PROXIES_TYPE
  start_port=$DEFAULT_START_PORT
  rotating_interval=$DEFAULT_ROTATING_INTERVAL
  use_localhost=false
  use_random_auth=true
  use_no_auth=false
  random_flag_set=false
  append_mode=false
  uninstall=false
  try_rotate_every_request=false
  rotate_every_request=false
  print_info=false
  backconnect_proxies_file="default"
  add_proxy_count=""
  interface_name="$(ip -br l | awk '$1 !~ "lo|vir|wl|@NONE" { print $1 }' | awk 'NR==1')"
  script_log_file=$SCRIPT_LOG_FILE
  backconnect_ipv4=""
  subnet_mask=""
}

parse_args() {
  local options
  options=$(getopt -o lhs:c:u:p:t:r:m:f:i:b: \
    --long help,rotate-every-request,localhost,random,no-auth,append,uninstall,info,subnet:,proxy-count:,username:,password:,proxies-type:,rotating-interval:,ipv6-mask:,interface:,start-port:,backconnect-proxies-file:,backconnect-ip:,allowed-hosts:,denied-hosts: \
    -- "$@")

  if [ $? != 0 ]; then
    echo "Error: no arguments provided. Terminating..." >&2
    usage
  fi

  eval set -- "$options"
  set_defaults

  while true; do
    case "$1" in
      -h | --help) usage ;;
      -s | --subnet) subnet="$2"; shift 2 ;;
      -c | --proxy-count) proxy_count="$2"; shift 2 ;;
      -u | --username) user="$2"; use_random_auth=false; shift 2 ;;
      -p | --password) password="$2"; use_random_auth=false; shift 2 ;;
      -t | --proxies-type) proxies_type="$2"; shift 2 ;;
      -r | --rotating-interval) rotating_interval="$2"; shift 2 ;;
      -m | --ipv6-mask) subnet_mask="$2"; shift 2 ;;
      -b | --backconnect-ip) backconnect_ipv4="$2"; shift 2 ;;
      -f | --backconnect_proxies_file | --backconnect-proxies-file) backconnect_proxies_file="$2"; shift 2 ;;
      -i | --interface) interface_name="$2"; shift 2 ;;
      -l | --localhost) use_localhost=true; shift ;;
      --allowed-hosts) allowed_hosts="$2"; shift 2 ;;
      --denied-hosts) denied_hosts="$2"; shift 2 ;;
      --uninstall) uninstall=true; shift ;;
      --info) print_info=true; shift ;;
      --start-port) start_port="$2"; shift 2 ;;
      --random) use_random_auth=true; random_flag_set=true; shift ;;
      --no-auth) use_no_auth=true; use_random_auth=false; shift ;;
      --append) append_mode=true; shift ;;
      --rotate-every-request) try_rotate_every_request=true; shift ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
}

# --- 4. PATHS & DERIVED STATE ---

apply_export_paths_from_base() {
  backconnect_proxies_file="$backconnect_proxies_base.list"
  backconnect_proxies_txt_file="$backconnect_proxies_base.txt"
  backconnect_proxies_json_file="$backconnect_proxies_base.json"
  backconnect_proxies_csv_file="$backconnect_proxies_base.csv"
}

init_paths() {
  bash_location="$(which bash)"
  cd ~ || exit 1
  user_home_dir="$(pwd)"
  proxy_dir="$user_home_dir/proxyserver"
  proxyserver_config_path="$proxy_dir/3proxy/3proxy.cfg"
  proxyserver_info_file="$proxy_dir/running_server.info"
  random_ipv6_list_file="$proxy_dir/ipv6.list"
  ndppd_routing_file="$proxy_dir/ndppd.routed"
  random_users_list_file="$proxy_dir/random_users.list"

  if [[ "$backconnect_proxies_file" == "default" ]]; then
    backconnect_proxies_base="$proxy_dir/backconnect_proxies"
  else
    case "$backconnect_proxies_file" in
      *.list|*.txt|*.json|*.csv) backconnect_proxies_base="${backconnect_proxies_file%.*}" ;;
      *) backconnect_proxies_base="$backconnect_proxies_file" ;;
    esac
  fi
  apply_export_paths_from_base

  server_state_file="$proxy_dir/server.state"
  lock_file="$proxy_dir/.lock"
  startup_script_path="$proxy_dir/proxy-startup.sh"
  cron_script_path="$proxy_dir/proxy-server.cron"
  last_port=""
  credentials=""
}

refresh_derived_values() {
  last_port=$((start_port + proxy_count - 1))
  credentials=$(is_auth_used && [[ "$use_random_auth" == false ]] && echo -n ":$user:$password" || echo -n "")
}

# --- 5. VALIDATION ---

is_valid_ip() {
  if [[ "$1" =~ ^(([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])$ ]]; then
    return 0
  fi
  return 1
}

is_auth_used() {
  if [ -z "$user" ] && [ -z "$password" ] && [ "$use_random_auth" = false ]; then
    return 1
  fi
  return 0
}

validate_auth_options() {
  if "$use_no_auth" && "$random_flag_set"; then
    log_err_print_usage_and_exit "Error: don't use '--no-auth' together with '--random'"
  fi

  if "$use_no_auth" && ([[ -n "$user" ]] || [[ -n "$password" ]]); then
    log_err_print_usage_and_exit "Error: don't use '--no-auth' together with '--username' or '--password'"
  fi

  if ([ -z "$user" ] || [ -z "$password" ]) && is_auth_used && [ "$use_random_auth" = false ]; then
    log_err_print_usage_and_exit "Error: user and password for proxy with auth is required (specify both '--username' and '--password' startup parameters)"
  fi

  if ([[ -n "$user" ]] || [[ -n "$password" ]]) && { [ "$use_random_auth" = true ] || "$random_flag_set"; }; then
    log_err_print_usage_and_exit "Error: don't provide user or password as arguments, if '--random' flag is set (or leave defaults for random auth)."
  fi
}

check_port_range() {
  if [ "$start_port" -lt "$MIN_START_PORT" ] || (( start_port + proxy_count - 1 > MAX_PORT )); then
    log_err_and_exit "Error: port range $start_port-$((start_port + proxy_count - 1)) is invalid (need start-port >= $MIN_START_PORT and last port <= $MAX_PORT)"
  fi
}

check_startup_parameters() {
  local re='^[0-9]+$'

  if ! [[ $proxy_count =~ $re ]] || [ "$proxy_count" -le 0 ]; then
    log_err_print_usage_and_exit "Error: Argument -c (proxy count) must be a positive integer number"
  fi

  if "$append_mode" && "$uninstall"; then
    log_err_print_usage_and_exit "Error: don't use '--append' together with '--uninstall'"
  fi

  if "$append_mode" && "$print_info"; then
    log_err_print_usage_and_exit "Error: don't use '--append' together with '--info'"
  fi

  if "$append_mode"; then
    if "$random_flag_set" || "$use_no_auth" || [[ -n "$user" ]] || [[ -n "$password" ]]; then
      log_err_print_usage_and_exit "Error: with '--append' do not pass auth options (-u/-p/--random/--no-auth); existing auth is preserved"
    fi
    return
  fi

  validate_auth_options

  if [ "$proxies_type" != "http" ] && [ "$proxies_type" != "socks5" ]; then
    log_err_print_usage_and_exit "Error: invalid value of '-t' (proxy type) parameter"
  fi

  if [ $(expr "$subnet" % 4) -ne 0 ]; then
    log_err_print_usage_and_exit "Error: invalid value of '-s' (subnet) parameter, must be divisible by 4"
  fi

  if [ "$rotating_interval" -lt 0 ] || [ "$rotating_interval" -gt 59 ]; then
    log_err_print_usage_and_exit "Error: invalid value of '-r' (proxy external ip rotating interval) parameter"
  fi

  if [ "$start_port" -lt "$MIN_START_PORT" ] || (( start_port + proxy_count - 1 > MAX_PORT )); then
    log_err_print_usage_and_exit "Wrong '--start-port' parameter value, it must be more than $MIN_START_PORT and '--start-port' + '--proxy-count' - 1 must be lower than 65536,
  because Linux has only 65536 potentially ports"
  fi

  if [ -n "$backconnect_ipv4" ]; then
    if ! is_valid_ip "$backconnect_ipv4"; then
      log_err_and_exit "Error: ip provided in 'backconnect-ip' argument is invalid. Provide valid IP or don't use this argument"
    fi
  fi

  if [ -n "$allowed_hosts" ] && [ -n "$denied_hosts" ]; then
    log_err_print_usage_and_exit "Error: if '--allowed-hosts' is specified, you cannot use '--denied-hosts', the rest that isn't allowed is denied by default"
  fi

  if cat "/sys/class/net/$interface_name/operstate" 2>&1 | grep -q "No such file or directory"; then
    log_err_print_usage_and_exit "Incorrect ethernet interface name \"$interface_name\", provide correct name using parameter '--interface'"
  fi
}

# --- 6. STATE & LOCK ---

acquire_lock() {
  mkdir -p "$proxy_dir"
  exec 9>"$lock_file"
  if ! flock -n 9; then
    log_err_and_exit "Error: another ipv6-proxy-server operation is in progress (lock: $lock_file). Wait for it to finish."
  fi
}

save_server_state() {
  cat > "$server_state_file" <<-EOF
proxy_count=$(printf '%q' "$proxy_count")
start_port=$(printf '%q' "$start_port")
last_port=$(printf '%q' "$last_port")
proxies_type=$(printf '%q' "$proxies_type")
use_random_auth=$(printf '%q' "$use_random_auth")
use_no_auth=$(printf '%q' "$use_no_auth")
user=$(printf '%q' "$user")
password=$(printf '%q' "$password")
subnet=$(printf '%q' "$subnet")
subnet_mask=$(printf '%q' "$subnet_mask")
backconnect_ipv4=$(printf '%q' "$backconnect_ipv4")
interface_name=$(printf '%q' "$interface_name")
rotating_interval=$(printf '%q' "$rotating_interval")
rotate_every_request=$(printf '%q' "$rotate_every_request")
try_rotate_every_request=$(printf '%q' "$try_rotate_every_request")
allowed_hosts=$(printf '%q' "$allowed_hosts")
denied_hosts=$(printf '%q' "$denied_hosts")
use_localhost=$(printf '%q' "$use_localhost")
backconnect_proxies_base=$(printf '%q' "$backconnect_proxies_base")
EOF
}

load_server_state() {
  if [ ! -f "$server_state_file" ]; then
    log_err_and_exit "Error: server state file not found ($server_state_file). Cannot append. Reinstall once, or use --uninstall then install again."
  fi
  # shellcheck disable=SC1090
  source "$server_state_file"
  apply_export_paths_from_base
  refresh_derived_values
}

verify_state_consistency() {
  if "$use_random_auth"; then
    if [ ! -f "$random_users_list_file" ]; then
      log_err_and_exit "Error: random users file missing ($random_users_list_file). State is inconsistent; use --uninstall and reinstall."
    fi
    local users_lines
    users_lines=$(wc -l < "$random_users_list_file" | tr -d ' ')
    if [ "$users_lines" -ne "$proxy_count" ]; then
      log_err_and_exit "Error: random users count ($users_lines) does not match proxy_count ($proxy_count). Use --uninstall and reinstall."
    fi
  fi

  if [ -f "$backconnect_proxies_file" ]; then
    local list_lines
    list_lines=$(wc -l < "$backconnect_proxies_file" | tr -d ' ')
    if [ "$list_lines" -ne "$proxy_count" ]; then
      log_err_and_exit "Error: proxy list lines ($list_lines) does not match proxy_count ($proxy_count). Use --uninstall and reinstall."
    fi
  fi
}

prepare_append() {
  if ! is_proxyserver_installed; then
    log_err_and_exit "Error: proxy server is not installed. Install first, then use --append."
  fi

  add_proxy_count="$proxy_count"
  load_server_state
  verify_state_consistency

  local old_proxy_count=$proxy_count
  local old_last_port=$last_port
  proxy_count=$((old_proxy_count + add_proxy_count))
  check_port_range
  refresh_derived_values

  echo -e "Appending $add_proxy_count proxies to existing pool ($old_proxy_count -> $proxy_count)"
  echo "Existing ports $start_port-$old_last_port kept; new ports $((old_last_port + 1))-$last_port"
}

# --- 7. SYSTEM CHECKS ---

is_proxyserver_installed() {
  # Ignore lock-only proxy_dir (e.g. after acquire_lock on a fresh install).
  if [ -f "$server_state_file" ] || [ -f "$startup_script_path" ] || [ -f "$proxy_dir/3proxy/bin/3proxy" ]; then
    return 0
  fi
  return 1
}

is_proxyserver_running() {
  if ps aux | grep -q "$proxyserver_config_path"; then
    return 0
  fi
  return 1
}

is_package_installed() {
  if [ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -c "ok installed")" -eq 0 ]; then
    return 1
  fi
  return 0
}

is_ndppd_running() {
  if ps aux | grep -q "[n]dppd"; then
    return 0
  fi
  return 1
}

delete_file_if_exists() {
  if test -f "$1"; then
    rm "$1"
  fi
}

create_random_string() {
  tr -dc A-Za-z0-9 </dev/urandom | head -c "$1"
  echo ''
}

kill_3proxy() {
  ps -ef | awk '/[3]proxy/{print $2}' | while read -r pid; do
    kill "$pid"
  done
}

# --- 8. NETWORK ---

remove_ipv6_addresses_from_iface() {
  if ! test -s "$random_ipv6_list_file"; then
    return
  fi
  if ! test -f "$ndppd_routing_file" || grep -q "false" "$ndppd_routing_file" 2>/dev/null || ! test -s "$ndppd_routing_file"; then
    local ipv6_address
    for ipv6_address in $(cat "$random_ipv6_list_file"); do
      ip -6 addr del "$ipv6_address" dev "$interface_name"
    done
    rm "$random_ipv6_list_file"
  fi
}

parse_ipv6_from_interface() {
  ip -6 addr | awk '{print $2}' | grep -m1 -oP '^(?!fe80)([0-9a-fA-F]{1,4}:)+[0-9a-fA-F]{1,4}' | cut -d '/' -f1
}

compute_subnet_mask_from_ipv6() {
  local ipv6=$1
  local full_blocks_count block_part symbols_to_include

  full_blocks_count=$(($subnet / 16))
  subnet_mask=$(echo "$ipv6" | grep -m1 -oP '^(?!fe80)([0-9a-fA-F]{1,4}:){'$(($full_blocks_count - 1))'}[0-9a-fA-F]{1,4}')

  if [ $(expr "$subnet" % 16) -ne 0 ]; then
    block_part=$(echo "$ipv6" | awk -v block=$(($full_blocks_count + 1)) -F ':' '{print $block}' | tr -d ' ')
    while ((${#block_part} < 4)); do
      block_part="0$block_part"
    done
    symbols_to_include=$(echo "$block_part" | head -c $(($(expr "$subnet" % 16) / 4)))
    subnet_mask="$subnet_mask:$symbols_to_include"
  fi

  echo "$subnet_mask"
}

get_subnet_mask() {
  if [ -z "$subnet_mask" ]; then
    if is_proxyserver_running; then
      kill_3proxy
    fi
    if is_proxyserver_installed; then
      remove_ipv6_addresses_from_iface
    fi

    local ipv6
    ipv6=$(parse_ipv6_from_interface)
    subnet_mask=$(compute_subnet_mask_from_ipv6 "$ipv6")
  fi

  echo "$subnet_mask"
}

get_backconnect_ipv4() {
  if "$use_localhost"; then
    echo "127.0.0.1"
    return
  fi
  if [ -n "$backconnect_ipv4" ] && [ "$backconnect_ipv4" != " " ]; then
    echo "$backconnect_ipv4"
    return
  fi

  local maybe_ipv4
  maybe_ipv4=$(ip addr show "$interface_name" | awk '$1 == "inet" {gsub(/\/.*$/, "", $2); print $2}')
  if is_valid_ip "$maybe_ipv4"; then
    echo "$maybe_ipv4"
    return
  fi

  if ! is_package_installed "curl"; then
    install_package "curl"
  fi

  maybe_ipv4=$(curl https://ipinfo.io/ip 2>/dev/null)
  if is_valid_ip "$maybe_ipv4"; then
    echo "$maybe_ipv4"
    return
  fi

  log_err_and_exit "Error: curl package not installed and cannot parse valid IP from interface info"
}

check_ipv6() {
  if test -f /proc/net/if_inet6; then
    echo "IPv6 interface is enabled"
  else
    log_err_and_exit "Error: inet6 (ipv6) interface is not enabled. Enable IP v6 on your system."
  fi

  if [[ $(ip -6 addr show scope global) ]]; then
    echo "IPv6 global address is allocated on server successfully"
  else
    log_err_and_exit "Error: IPv6 global address is not allocated on server, allocate it or contact your VPS/VDS support."
  fi

  local ifaces_config="/etc/network/interfaces"
  if [ ! -f "$ifaces_config" ]; then
    log_err "Potential error: interfaces config ($ifaces_config) doesn't exist"
  fi

  if grep 'inet6' "$ifaces_config" > /dev/null; then
    echo "Network interfaces for IPv6 configured correctly"
  else
    log_err "Potential error: $ifaces_config has no inet6 (IPv6) configuration."
  fi

  if [[ $(ping6 -c 1 google.com) != *"Network is unreachable"* ]] &> /dev/null; then
    echo "Test ping google.com using IPv6 successfully"
  else
    log_err_and_exit "Error: test ping google.com through IPv6 failed, network is unreachable."
  fi
}

is_ndppd_routing_working() {
  local random_ipv6_for_test

  if ! is_ndppd_running; then
    log_err "ndppd isn't running. You cannot use every-request rotation."
    return 1
  fi
  if ! is_package_installed "curl"; then
    install_package "curl"
  fi
  if [[ $(cat "/proc/sys/net/ipv6/conf/$interface_name/proxy_ndp") != 1 ]]; then
    log_err "proxy_ndp not set, you cannot use every-request rotation before it."
    return 1
  fi

  random_ipv6_for_test=$subnet_mask::5252

  if curl -m 5 -s --interface "$random_ipv6_for_test" ipv6.ip.sb | grep -q "$random_ipv6_for_test"; then return 0; fi
  if curl -m 5 -s --interface "$random_ipv6_for_test" https://whatismyv6.com | grep -q "$random_ipv6_for_test"; then return 0; fi
  if curl -m 5 -s --interface "$random_ipv6_for_test" http://ip6only.me | grep -q "$random_ipv6_for_test"; then return 0; fi
  if curl -m 5 -s --interface "$random_ipv6_for_test" https://myipv6.is | grep -q "$random_ipv6_for_test"; then return 0; fi
  if curl -m 5 -s --interface "$random_ipv6_for_test" https://dnschecker.org/whats-my-ip-address.php | grep -q "$random_ipv6_for_test"; then return 0; fi

  log_err "Cannot connect to at least one website to verify, that test IPv6 address for ndppd subnet is available."
  return 1
}

configure_ipv6() {
  local option full_option
  local required_options=("conf.$interface_name.proxy_ndp" "conf.all.proxy_ndp" "conf.default.forwarding" "conf.all.forwarding" "ip_nonlocal_bind")

  for option in "${required_options[@]}"; do
    full_option="net.ipv6.$option=1"
    if ! cat /etc/sysctl.conf | grep -v "#" | grep -q "$full_option"; then
      echo "$full_option" >> /etc/sysctl.conf
    fi
  done
  sysctl -p &>> "$script_log_file"

  if [[ $(cat "/proc/sys/net/ipv6/conf/$interface_name/proxy_ndp") == 1 ]] && [[ $(cat /proc/sys/net/ipv6/ip_nonlocal_bind) == 1 ]]; then
    echo "IPv6 network sysctl data configured successfully"
  else
    cat /etc/sysctl.conf &>> "$script_log_file"
    log_err_and_exit "Error: cannot configure IPv6 config"
  fi
}

configure_ndppd() {
  ip route add local "$subnet_mask::/$subnet" dev "$interface_name"

  cat > /etc/ndppd.conf <<-EOF
route-ttl 30000

proxy $interface_name {
  router no
  timeout 500
  ttl 30000

  rule $subnet_mask::/$subnet {
    static
  }
}
EOF

  service ndppd restart
  systemctl is-active --quiet ndppd | echo "ndppd is up and running"
}

# --- 9. INSTALL ---

install_package() {
  if ! is_package_installed "$1"; then
    apt install "$1" -y &>> "$script_log_file"
    if ! is_package_installed "$1"; then
      log_err_and_exit "Error: cannot install \"$1\" package"
    fi
  fi
}

install_required_packages() {
  local package
  apt update &>> "$script_log_file"

  for package in "${REQUIRED_PACKAGES[@]}"; do
    install_package "$package"
  done

  echo -e "\nAll required packages installed successfully"
}

install_3proxy() {
  mkdir "$proxy_dir" && cd "$proxy_dir"

  echo -e "\nDownloading proxy server source..."
  (
    wget "https://github.com/3proxy/3proxy/archive/refs/tags/${PROXY_3PROXY_VERSION}.tar.gz" &> /dev/null
    tar -xf "${PROXY_3PROXY_VERSION}.tar.gz"
    rm "${PROXY_3PROXY_VERSION}.tar.gz"
    mv "3proxy-${PROXY_3PROXY_VERSION}" 3proxy
  ) &>> "$script_log_file"
  echo "Proxy server source code downloaded successfully"

  echo -e "\nStart building proxy server execution file from source..."
  cd 3proxy
  make -f Makefile.Linux &>> "$script_log_file"
  if test -f "$proxy_dir/3proxy/bin/3proxy"; then
    echo "Proxy server builded successfully"
  else
    log_err_and_exit "Error: proxy server build from source code failed."
  fi
  cd ..
}

# --- 10. PROXY RUNTIME ---

add_to_cron() {
  delete_file_if_exists "$cron_script_path"

  echo "@reboot $bash_location $startup_script_path" > "$cron_script_path"
  if [ "$rotating_interval" -ne 0 ]; then
    echo "*/$rotating_interval * * * * $bash_location $startup_script_path" >> "$cron_script_path"
  fi

  crontab -l | grep -v "$startup_script_path" >> "$cron_script_path"

  crontab "$cron_script_path"
  systemctl restart cron

  if crontab -l | grep -q "$startup_script_path"; then
    echo "Proxy startup script added to cron autorun successfully"
  else
    log_err "Warning: adding script to cron autorun failed."
  fi
}

remove_from_cron() {
  crontab -l | grep -v "$startup_script_path" > "$cron_script_path"
  crontab "$cron_script_path"
  systemctl restart cron

  if crontab -l | grep -q "$startup_script_path"; then
    log_err "Warning: cannot delete proxy script from crontab"
  else
    echo "Proxy script deleted from crontab successfully"
  fi
}

generate_random_users_if_needed() {
  local i
  if ! "$use_random_auth"; then
    delete_file_if_exists "$random_users_list_file"
    return
  fi
  delete_file_if_exists "$random_users_list_file"

  for i in $(seq 1 "$proxy_count"); do
    echo "$(create_random_string 8):$(create_random_string 8)" >> "$random_users_list_file"
  done
}

append_random_users_if_needed() {
  local i
  if ! "$use_random_auth"; then
    return
  fi
  for i in $(seq 1 "$add_proxy_count"); do
    echo "$(create_random_string 8):$(create_random_string 8)" >> "$random_users_list_file"
  done
}

resolve_rotation_settings() {
  local can_route_via_ndppd=$1

  if "$try_rotate_every_request"; then
    if [ "$can_route_via_ndppd" -eq 0 ]; then
      echo "Rotation for every request is possible, starting config generation..."
      rotate_every_request=true
    else
      log_err_and_exit "IP rotation for every request isn't possible for your server. Check logs, maybe it's a problem with your VPS provider"
    fi
  fi
}

write_startup_script_file() {
  local use_auth=$1
  local can_route_via_ndppd=$2

  # Variables with \$ are expanded at runtime inside proxy-startup.sh, not here.
  cat > "$startup_script_path" <<-EOF
  #!$bash_location

  dedent() {
    local -n reference="\$1"
    reference="\$(echo "\$reference" | sed 's/^[[:space:]]*//')"
  }

  proxyserver_process_pids=(\`pgrep -f [3]proxy\`)

  old_ipv6_list_file="$random_ipv6_list_file.old"
  if test -f $random_ipv6_list_file; then
    cp $random_ipv6_list_file \$old_ipv6_list_file
    rm $random_ipv6_list_file
  fi

  old_ndppd_routing_file="$ndppd_routing_file.old"
  if test -f $ndppd_routing_file; then
    cp $ndppd_routing_file \$old_ndppd_routing_file
  fi
  if [ $can_route_via_ndppd -eq 0 ]; then echo "true" > $ndppd_routing_file; else echo "false" > $ndppd_routing_file; fi

  array=( 1 2 3 4 5 6 7 8 9 0 a b c d e f )

  get_truncated_subnet_mask () {
    redundant_symbols_count=$(( ($subnet % 16) / 4 ))
    last_subnet_block=$(echo $subnet_mask | awk -F ':' '{print $NF}')
    symbols_count=\${#last_subnet_block}
    trunc_symbols_count=\$(( \$redundant_symbols_count - (4 - \$symbols_count) ))
    mask=$subnet_mask
    echo \${mask::${#subnet_mask}-\$trunc_symbols_count}
  }

  rh () { echo \${array[\$RANDOM%16]}; }

  rnd_subnet_ip () {
    echo -n \$(get_truncated_subnet_mask)
    symbol=$subnet
    while (( \$symbol < 128 )); do
      if ((\$symbol % 16 == 0)); then echo -n :; fi
      echo -n \$(rh)
      let "symbol += 4"
    done
    echo
  }

  immutable_config_part="daemon
    nserver 1.1.1.1
    maxconn 200
    nscache 65536
    timeouts 1 5 30 60 180 1800 15 60
    setgid 65535
    setuid 65535"

  auth_part="auth iponly"
  if [ $use_auth -eq 0 ]; then
    if [ $use_random_auth = true ]; then
      auth_part="auth strong"
    else
      auth_part="
        auth strong
        users $user:CL:$password"
    fi
  fi

  if [ -n "$denied_hosts" ]; then
    access_rules_part="
      deny * * $denied_hosts
      allow *"
  elif [ -n "$allowed_hosts" ]; then
    access_rules_part="
      allow * * $allowed_hosts
      deny *"
  else
    access_rules_part="allow *"
  fi
  if $rotate_every_request; then
    access_rules_part="
      \${access_rules_part}
      parent 1000 extip $subnet_mask::/$subnet 0"
  fi

  dedent immutable_config_part
  dedent auth_part
  dedent access_rules_part

  echo "\$immutable_config_part"\$'\n'"\$auth_part"\$'\n'"\$access_rules_part" > $proxyserver_config_path

  port=$start_port
  count=0
  if [ "$proxies_type" = "http" ]; then proxy_startup_depending_on_type="proxy -6 -n -a"; else proxy_startup_depending_on_type="socks -6 -a"; fi
  if [ $use_random_auth = true ]; then readarray -t proxy_random_credentials < $random_users_list_file; fi
  while [ "\$count" -lt $proxy_count ]; do
      if [ $use_random_auth = true ]; then
        IFS=":"
        read -r username password <<< "\${proxy_random_credentials[\$count]}"
        echo "flush" >> $proxyserver_config_path
        echo "users \$username:CL:\$password" >> $proxyserver_config_path
        echo "\$access_rules_part" >> $proxyserver_config_path
        IFS=\$' \t\n'
      fi
      if $rotate_every_request; then
        echo "\$proxy_startup_depending_on_type -p\$port -i$backconnect_ipv4" >> $proxyserver_config_path
      else
        random_gateway_ipv6=\$(rnd_subnet_ip)
        echo "\$random_gateway_ipv6" >> $random_ipv6_list_file
        echo "\$proxy_startup_depending_on_type -p\$port -i$backconnect_ipv4 -e\$random_gateway_ipv6" >> $proxyserver_config_path
      fi
      ((port+=1))
      ((count+=1))
  done

  ulimit -n 600000
  ulimit -u 600000
  if [ $can_route_via_ndppd -eq 1 ]; then
    for ipv6_address in \$(cat ${random_ipv6_list_file}); do ip -6 addr add \$ipv6_address dev $interface_name; done
  fi
  ${user_home_dir}/proxyserver/3proxy/bin/3proxy ${proxyserver_config_path}

  for pid in "\${proxyserver_process_pids[@]}"; do
    kill \$pid
  done

  if grep -q "false" \$old_ndppd_routing_file || ! test -s \$old_ndppd_routing_file && [ -s \$old_ipv6_list_file ]; then
    for ipv6_address in \$(cat \$old_ipv6_list_file); do ip -6 addr del \$ipv6_address dev $interface_name; done
    rm \$old_ipv6_list_file
  fi

  exit 0
EOF
}

create_startup_script() {
  local use_auth can_route_via_ndppd

  delete_file_if_exists "$startup_script_path"

  is_auth_used
  use_auth=$?

  is_ndppd_routing_working
  can_route_via_ndppd=$?
  resolve_rotation_settings "$can_route_via_ndppd"

  write_startup_script_file "$use_auth" "$can_route_via_ndppd"
}

close_ufw_backconnect_ports() {
  if ! is_package_installed "ufw" || [ "$use_localhost" = true ] || ! test -f "$backconnect_proxies_file"; then
    return
  fi

  local first_opened_port last_opened_port
  first_opened_port=$(head -n 1 "$backconnect_proxies_file" | awk -F ':' '{print $2}')
  last_opened_port=$(tail -n 1 "$backconnect_proxies_file" | awk -F ':' '{print $2}')

  ufw delete allow "$first_opened_port:$last_opened_port/tcp" >> "$script_log_file"
  ufw delete allow "$first_opened_port:$last_opened_port/udp" >> "$script_log_file"

  if ufw status | grep -qw "$first_opened_port:$last_opened_port"; then
    log_err "Cannot delete UFW rules for backconnect proxies"
  else
    echo "UFW rules for backconnect proxies cleared successfully"
  fi
}

open_ufw_backconnect_ports() {
  close_ufw_backconnect_ports

  if "$use_localhost"; then
    return
  fi

  if ! is_package_installed "ufw"; then
    echo "Firewall not installed, ports for backconnect proxy opened successfully"
    return
  fi

  if ufw status | grep -qw active; then
    ufw allow "$start_port:$last_port/tcp" >> "$script_log_file"
    ufw allow "$start_port:$last_port/udp" >> "$script_log_file"

    if ufw status | grep -qw "$start_port:$last_port"; then
      echo "UFW ports for backconnect proxies opened successfully"
    else
      log_err "$(ufw status)"
      log_err_and_exit "Cannot open ports for backconnect proxies, configure ufw please"
    fi
  else
    echo "UFW protection disabled, ports for backconnect proxy opened successfully"
  fi
}

run_proxy_server() {
  if [ ! -f "$startup_script_path" ]; then
    log_err_and_exit "Error: proxy startup script doesn't exist."
  fi

  chmod +x "$startup_script_path"
  "$bash_location" "$startup_script_path"
  if is_proxyserver_running; then
    echo -e "\nIPv6 proxy server started successfully. Backconnect IPv4 is available from $backconnect_ipv4:$start_port$credentials to $backconnect_ipv4:$last_port$credentials via $proxies_type protocol"
  else
    log_err_and_exit "Error: cannot run proxy server"
  fi
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

csv_escape() {
  local s="$1"
  if [[ "$s" == *","* || "$s" == *"\""* || "$s" == *$'\n'* ]]; then
    s="${s//\"/\"\"}"
    printf '"%s"' "$s"
  else
    printf '%s' "$s"
  fi
}

append_proxy_export_line() {
  local port=$1
  local proxy_credentials=$2
  local proxy_user=$3
  local proxy_password=$4
  local first_json_entry=$5

  local list_line proxy_url

  list_line="$backconnect_ipv4:$port$proxy_credentials"
  if is_auth_used; then
    proxy_url="$proxies_type://$proxy_user:$proxy_password@$backconnect_ipv4:$port"
  else
    proxy_url="$proxies_type://$backconnect_ipv4:$port"
  fi

  echo "$list_line" >> "$backconnect_proxies_file"
  echo "$proxy_url" >> "$backconnect_proxies_txt_file"
  echo "$(csv_escape "$proxies_type"),$(csv_escape "$backconnect_ipv4"),$(csv_escape "$port"),$(csv_escape "$proxy_user"),$(csv_escape "$proxy_password"),$(csv_escape "$proxy_url")" >> "$backconnect_proxies_csv_file"

  if [ "$first_json_entry" = true ]; then
    :
  else
    echo "," >> "$backconnect_proxies_json_file"
  fi
  printf '  {"protocol":"%s","host":"%s","port":%s,"username":"%s","password":"%s","url":"%s"}' \
    "$(json_escape "$proxies_type")" \
    "$(json_escape "$backconnect_ipv4")" \
    "$port" \
    "$(json_escape "$proxy_user")" \
    "$(json_escape "$proxy_password")" \
    "$(json_escape "$proxy_url")" >> "$backconnect_proxies_json_file"
  echo >> "$backconnect_proxies_json_file"
}

write_backconnect_proxies_to_file() {
  delete_file_if_exists "$backconnect_proxies_file"
  delete_file_if_exists "$backconnect_proxies_txt_file"
  delete_file_if_exists "$backconnect_proxies_json_file"
  delete_file_if_exists "$backconnect_proxies_csv_file"

  local proxy_credentials=$credentials
  local proxy_user=""
  local proxy_password=""
  local count=0
  local first_json_entry=true
  local port
  local proxy_random_credentials

  if is_auth_used && [ "$use_random_auth" = false ]; then
    proxy_user="$user"
    proxy_password="$password"
  fi

  if ! touch "$backconnect_proxies_file" "$backconnect_proxies_txt_file" "$backconnect_proxies_json_file" "$backconnect_proxies_csv_file" &> "$script_log_file"; then
    echo "Backconnect proxies list file path: $backconnect_proxies_file" >> "$script_log_file"
    log_err "Warning: provided invalid path to backconnect proxies list file"
    return
  fi

  if "$use_random_auth"; then
    readarray -t proxy_random_credentials < "$random_users_list_file"
  fi

  echo "protocol,host,port,username,password,url" > "$backconnect_proxies_csv_file"
  echo "[" > "$backconnect_proxies_json_file"

  for port in $(eval echo "{$start_port..$last_port}"); do
    if "$use_random_auth"; then
      proxy_credentials=":${proxy_random_credentials[$count]}"
      IFS=":"
      read -r proxy_user proxy_password <<< "${proxy_random_credentials[$count]}"
      IFS=$' \t\n'
      ((count+=1))
    fi

    append_proxy_export_line "$port" "$proxy_credentials" "$proxy_user" "$proxy_password" "$first_json_entry"
    first_json_entry=false
  done

  echo "]" >> "$backconnect_proxies_json_file"
}

format_auth_summary() {
  if ! is_auth_used; then
    echo "disabled"
  elif [ "$use_random_auth" = true ]; then
    echo "random 8-char alphanumeric user/password for each proxy"
  else
    echo "user - $user, password - $password"
  fi
}

format_rules_summary() {
  if [ -n "$denied_hosts" ] || [ -n "$allowed_hosts" ]; then
    if [ -n "$denied_hosts" ]; then
      echo "denied hosts - $denied_hosts, all others are allowed"
    else
      echo "allowed hosts - $allowed_hosts, all others are denied"
    fi
  else
    echo "no rules specified, all hosts are allowed"
  fi
}

format_rotation_summary() {
  if [ "$rotating_interval" -ne 0 ]; then
    echo "Rotating interval: every $rotating_interval minutes"
  elif "$rotate_every_request"; then
    echo "Rotating: every request"
  else
    echo "Rotating: disabled"
  fi
}

write_proxyserver_info() {
  delete_file_if_exists "$proxyserver_info_file"

  cat > "$proxyserver_info_file" <<-EOF
User info:
  Proxy count: $proxy_count
  Proxy type: $proxies_type
  Proxy IP: $backconnect_ipv4
  Proxy ports: between $start_port and $last_port
  Auth: $(format_auth_summary)
  Rules: $(format_rules_summary)
  Exported proxy files:
    list (host:port[:user:password]): $backconnect_proxies_file
    txt (protocol://user:password@host:port): $backconnect_proxies_txt_file
    json: $backconnect_proxies_json_file
    csv: $backconnect_proxies_csv_file
  State file: $server_state_file


EOF

  cat >> "$proxyserver_info_file" <<-EOF
Technical info:
  Subnet: /$subnet
  Subnet mask: $subnet_mask
  File with generated IPv6 gateway addresses: $(if "$rotate_every_request"; then echo "No file specified, rotating every request with different random IP"; else echo "$random_ipv6_list_file"; fi)
  $(format_rotation_summary)
EOF
}

apply_proxy_configuration() {
  if "$append_mode"; then
    append_random_users_if_needed
  else
    generate_random_users_if_needed
  fi
  create_startup_script
  add_to_cron
  open_ufw_backconnect_ports
  run_proxy_server
  write_backconnect_proxies_to_file
  echo "Exported proxy files:"
  echo "  list: $backconnect_proxies_file"
  echo "  txt:  $backconnect_proxies_txt_file"
  echo "  json: $backconnect_proxies_json_file"
  echo "  csv:  $backconnect_proxies_csv_file"
  write_proxyserver_info
  save_server_state
}

# --- 11. MAIN ---

cmd_info() {
  if ! is_proxyserver_installed; then
    log_err_and_exit "Proxy server isn't installed"
  fi
  if ! is_proxyserver_running; then
    log_err_and_exit "Proxy server isn't running. You can check log of previous run attempt in $script_log_file"
  fi
  if ! test -f "$proxyserver_info_file"; then
    log_err_and_exit "File with information about running proxy server not found"
  fi

  cat "$proxyserver_info_file"
  exit 0
}

cmd_uninstall() {
  if ! is_proxyserver_installed && [ ! -d "$proxy_dir" ]; then
    log_err_and_exit "Proxy server is not installed"
  fi

  acquire_lock

  if [ -f "$server_state_file" ]; then
    # shellcheck disable=SC1090
    source "$server_state_file"
    apply_export_paths_from_base
  fi

  remove_from_cron
  kill_3proxy
  remove_ipv6_addresses_from_iface
  close_ufw_backconnect_ports
  rm -rf "$proxy_dir"
  delete_file_if_exists "$backconnect_proxies_file"
  delete_file_if_exists "$backconnect_proxies_txt_file"
  delete_file_if_exists "$backconnect_proxies_json_file"
  delete_file_if_exists "$backconnect_proxies_csv_file"
  echo -e "\nIPv6 proxy server successfully uninstalled. If you want to reinstall, just run this script again."
  exit 0
}

cmd_append() {
  prepare_append
  apply_proxy_configuration
  echo -e "\nAppend completed successfully. Total proxies: $proxy_count (ports $start_port-$last_port)"
  exit 0
}

guard_fresh_install_not_overwriting() {
  local local_existing_count="unknown"

  if is_proxyserver_installed; then
    if [ -f "$server_state_file" ]; then
      # shellcheck disable=SC1090
      source "$server_state_file"
      local_existing_count="$proxy_count"
    elif [ -f "$backconnect_proxies_file" ]; then
      local_existing_count=$(wc -l < "$backconnect_proxies_file" | tr -d ' ')
    fi
    log_err_and_exit "Error: proxy server already installed ($local_existing_count proxies). Use '--append -c <N>' to add more proxies without changing existing ones, or '--uninstall' to remove everything first."
  fi
}

cmd_install() {
  check_ipv6
  backconnect_ipv4=$(get_backconnect_ipv4)
  subnet_mask=$(get_subnet_mask)
  refresh_derived_values
  configure_ipv6
  install_required_packages
  install_3proxy
  configure_ndppd
  apply_proxy_configuration
  exit 0
}

main() {
  require_root
  parse_args "$@"
  init_paths

  if "$print_info"; then
    cmd_info
  fi

  if "$uninstall"; then
    cmd_uninstall
  fi

  delete_file_if_exists "$script_log_file"
  check_startup_parameters

  if ! "$append_mode"; then
    guard_fresh_install_not_overwriting
  fi

  acquire_lock

  if "$append_mode"; then
    cmd_append
  fi

  cmd_install
}

main "$@"
