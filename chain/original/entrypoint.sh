#!/bin/sh

if [ -f /etc/alpine-release ]; then
    OS="alpine"
else
    OS="other"
fi

if [ "$OS" = "alpine" ]; then
  # если в системе нет модуля nftables
  if ! lsmod | grep -q nf_tables; then
      # удалить nftables если есть
      apk info -e nftables >/dev/null 2>&1 && apk del nftables >/dev/null 2>&1
      # установить iptables если отсутствуют
      apk info -e iptables >/dev/null 2>&1 || apk add iptables
      # установить iptables-legacy если отсутствует и исправить символьные ссылки
      if ! apk info -e iptables-legacy >/dev/null 2>&1; then
        apk add iptables-legacy
        # IPv4
        rm -f /usr/sbin/iptables /usr/sbin/iptables-save /usr/sbin/iptables-restore
        ln -s /usr/sbin/iptables-legacy         /usr/sbin/iptables
        ln -s /usr/sbin/iptables-legacy-save    /usr/sbin/iptables-save
        ln -s /usr/sbin/iptables-legacy-restore /usr/sbin/iptables-restore
        # IPv6
        rm -f /usr/sbin/ip6tables /usr/sbin/ip6tables-save /usr/sbin/ip6tables-restore
        ln -s /usr/sbin/ip6tables-legacy         /usr/sbin/ip6tables
        ln -s /usr/sbin/ip6tables-legacy-save    /usr/sbin/ip6tables-save
        ln -s /usr/sbin/ip6tables-legacy-restore /usr/sbin/ip6tables-restore
      fi
  # если в системе есть модуль nftables
  else
      export DISABLE_NFTABLES=0
      # удалить iptables и legacy если есть
      if apk info -e iptables iptables-legacy >/dev/null 2>&1; then
        apk del iptables iptables-legacy >/dev/null 2>&1
      fi
      # установить nftables если отсутствует
      apk info -e nftables >/dev/null 2>&1 || apk add nftables
  fi
fi

DEFAULT_CONFIG=$(cat << 'EOF'
external-controller: $EXTERNAL_CONTROLLER_ADDRESS:$UI_PORT
external-ui: $EXTERNAL_UI_PATH
external-ui-url: $EXTERNAL_UI_URL
secret: $UI_SECRET
unified-delay: true
log-level: $LOG_LEVEL
ipv6: $IPV6

dns:
  enable: $DNS_ENABLE
  use-system-hosts: $DNS_USE_SYSTEM_HOSTS
  nameserver:
  - system

proxy-providers:
$PROVIDERS_BLOCK

proxy-groups:
  - name: SELECTOR
    type: select
    use:
$PROVIDERS_LIST
  - name: QUIC
    type: select
    proxies:
      - PASS
      - REJECT

listeners:
  - name: mixed-in
    type: mixed
    port: $MIXED_PORT
  - name: tun-in
    type: tun
    stack: $TUN_STACK
    auto-detect-interface: $TUN_AUTO_DETECT_INTERFACE
    auto-route: $TUN_AUTO_ROUTE
    auto-redirect: $TUN_AUTO_REDIRECT
    inet4-address:
    - $TUN_INET4_ADDRESS

rules:
  - AND,((NETWORK,udp),(DST-PORT,443)),QUIC
  - IN-NAME,tun-in,SELECTOR
  - IN-NAME,mixed-in,SELECTOR
  - MATCH,GLOBAL
EOF
)

AWG_DIR="$WORKDIR/awg"
TEMPLATE_DIR="$WORKDIR/template"
mkdir -p $TEMPLATE_DIR
mkdir -p $AWG_DIR
TEMPLATE_FILE="$TEMPLATE_DIR/$CONFIG"
BACKUP_PATH="$TEMPLATE_DIR/default_config_old.yaml"

# завершаем работу если не используется кастомный конфиг или для дефолта не задан хотя бы один необходимый параметр
if [ "$CONFIG" = "default_config.yaml" ]; then
  has_env_vars=$(env | grep -qE '^(SRV|SUB)[0-9]' && echo 1 || echo 0)
  has_conf_files=$(find "$AWG_DIR" -type f -name '*.conf' 2>/dev/null | grep -q . && echo 1 || echo 0)
  if [ "$has_env_vars" -eq 0 ] && [ "$has_conf_files" -eq 0 ]; then
    echo "No server/subscription variables (SRV*/SUB*) and no *.conf files wireguard/amneziawg in $AWG_DIR. Exiting."
    exit 1
  fi
fi

# если не указано имя кастомного конфига, испольузем и актуализируем default
if [ "$CONFIG" = "default_config.yaml" ]; then
  if [ -f "$TEMPLATE_FILE" ]; then
    if ! diff -q <(echo "$DEFAULT_CONFIG") "$TEMPLATE_FILE" >/dev/null; then
      mv "$TEMPLATE_FILE" "$BACKUP_PATH"
      echo "$DEFAULT_CONFIG" > "$TEMPLATE_FILE"
    fi
  else
    echo "$DEFAULT_CONFIG" > "$TEMPLATE_FILE"
  fi
else
  if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "$DEFAULT_CONFIG" > "$TEMPLATE_FILE"
  fi
fi

# смена веб панели при замене ссылки на её загрузку
UI_URL_CHECK="$WORKDIR/.ui_url"
LAST_UI_URL=$(cat "$UI_URL_CHECK" 2>/dev/null)
if [[ "$EXTERNAL_UI_URL" != "$LAST_UI_URL" ]]; then
  rm -rf "$WORKDIR/$EXTERNAL_UI_PATH"
  echo "$EXTERNAL_UI_URL" > "$UI_URL_CHECK"
fi

parse_awg_config() {
  local config_file="$1"
  local awg_name=$(basename "$config_file" .conf)

  # Чтение параметра WG/AWG без учёта регистра
  read_cfg() {
    local key="$1"
    grep -Ei "^${key}[[:space:]]*=" "$config_file" | sed -E "s/^${key}[[:space:]]*=[[:space:]]*//I"
  }

  local private_key=$(read_cfg "PrivateKey")
  local address=$(read_cfg "Address")
  address=$(echo "$address" | tr ',' '\n' | grep -v ':' | head -n1)
  local dns=$(read_cfg "DNS")
  dns=$(echo "$dns" | tr ',' '\n' | grep -v ':' | sed 's/^ *//;s/ *$//' | paste -sd, -)

  local mtu=$(read_cfg "MTU")
  local jc=$(read_cfg "Jc")
  local jmin=$(read_cfg "Jmin")
  local jmax=$(read_cfg "Jmax")
  local s1=$(read_cfg "S1")
  local s2=$(read_cfg "S2")
  local h1=$(read_cfg "H1")
  local h2=$(read_cfg "H2")
  local h3=$(read_cfg "H3")
  local h4=$(read_cfg "H4")
  local i1=$(read_cfg "I1")
  local i2=$(read_cfg "I2")
  local i3=$(read_cfg "I3")
  local i4=$(read_cfg "I4")
  local i5=$(read_cfg "I5")
  local j1=$(read_cfg "J1")
  local j2=$(read_cfg "J2")
  local j3=$(read_cfg "J3")
  local itime=$(read_cfg "ITime")

  local public_key=$(read_cfg "PublicKey")
  local psk=$(read_cfg "PresharedKey")
  local endpoint=$(read_cfg "Endpoint")

  local server=$(echo "$endpoint" | cut -d':' -f1)
  local port=$(echo "$endpoint" | cut -d':' -f2)

  echo "  - name: \"$awg_name\""
  echo "    type: wireguard"

  [ -n "$private_key" ] && echo "    private-key: $private_key"
  [ -n "$server" ] && echo "    server: $server"
  [ -n "$port" ] && echo "    port: $port"
  [ -n "$address" ] && echo "    ip: $address"
  [ -n "$mtu" ] && echo "    mtu: $mtu"
  [ -n "$public_key" ] && echo "    public-key: $public_key"

  echo "    allowed-ips: ['0.0.0.0/0']"
  [ -n "$psk" ] && echo "    pre-shared-key: $psk"

  echo "    udp: true"

  [ -n "$dns" ] && echo "    dns: [ $dns ]"
  echo "    remote-dns-resolve: true"
  awg_params="jc jmin jmax s1 s2 h1 h2 h3 h4 i1 i2 i3 i4 i5 j1 j2 j3 itime"
  awg_has_value=false
  for v in $awg_params; do
      eval val=\$$v
      if [ -n "$val" ]; then
          awg_has_value=true
          break
      fi
  done
  if $awg_has_value; then
      echo "    amnezia-wg-option:"
      for v in $awg_params; do
          eval val=\$$v
          [ -n "$val" ] && echo "      $v: $val"
      done
  fi
}

add_provider_block() {
    local name="$1"
    local path="$2"

    PROVIDERS_BLOCK="${PROVIDERS_BLOCK}  ${name}:
    type: file
    path: ${path}
    health-check:
      enable: true
      url: $HEALTH_CHECK_URL
      interval: 300
      timeout: 5000
      lazy: true
      expected-status: 204
"
    PROVIDERS_LIST="${PROVIDERS_LIST}      - ${name}
"
}

PROVIDERS_BLOCK=""
PROVIDERS_LIST=""
####
srv_file="$WORKDIR/srv.yaml"
if env | grep -qE '^(SRV)[0-9]'; then
> "$srv_file"
env | while IFS='=' read -r name value; do
    case "$name" in
        SRV[0-9]*)
            echo "#== $name ==" >> "$srv_file"
            printf "%s\n" "$value" | while IFS= read -r line; do
                echo "$line" >> "$srv_file"
            done
            ;;
    esac
done

add_provider_block "SRV" "$srv_file"

fi
###
awg_file="$WORKDIR/awg.yaml"
if find "$AWG_DIR" -name "*.conf" | grep -q . 2>/dev/null; then
    echo "proxies:" > "$awg_file"
    find "$AWG_DIR" -name "*.conf" | while read -r conf; do
      parse_awg_config "$conf"
    done >> $awg_file

add_provider_block "AWG" "$awg_file"

fi
###

while IFS='=' read -r name value; do
  case "$name" in
    SUB[0-9]*)
      PROVIDERS_BLOCK="${PROVIDERS_BLOCK}  ${name}:
    url: \"${value}\"
    type: http
    interval: 86400
    health-check:
      enable: true
      url: \"${HEALTH_CHECK_URL}\"
      interval: 86400
"
    PROVIDERS_LIST="${PROVIDERS_LIST}      - $(echo "$name")
"
      ;;
  esac
done <<EOF
$(env)
EOF

export PROVIDERS_BLOCK
export PROVIDERS_LIST

envsubst < "$TEMPLATE_DIR/$CONFIG" > "$WORKDIR/$CONFIG"

CMD_MIHOMO="${@:-"-d $WORKDIR -f $WORKDIR/$CONFIG"}"
# print version mihomo to log
mihomo -v
exec mihomo $CMD_MIHOMO || exit 1