#!/bin/sh

# Сначала проверим, запущен ли скрипт в системе Alpine Linux.
# Alpine — это особый «лёгкий» дистрибутив Linux, часто используемый в контейнерах.
if [ -f /etc/alpine-release ]; then
    OS="alpine"
else
    OS="other"
fi

# Если это Alpine, нужно убедиться, что сетевые правила работают правильно.
# Mihomo умеет работать либо с nftables (новая система), либо с iptables (старая).
if [ "$OS" = "alpine" ]; then
  # Если в системе НЕТ nftables (т.е. используется старый iptables):
  if ! lsmod | grep -q nf_tables; then
      # Удалим nftables, если он случайно установлен (он может мешать).
      apk info -e nftables >/dev/null 2>&1 && apk del nftables >/dev/null 2>&1
      # Убедимся, что iptables установлен.
      apk info -e iptables >/dev/null 2>&1 || apk add iptables
      # Установим старую версию iptables (называется iptables-legacy), потому что Mihomo с ней дружит лучше.
      if ! apk info -e iptables-legacy >/dev/null 2>&1; then
        apk add iptables-legacy
        # Заменим стандартные команды iptables на legacy-версии,
        # чтобы система автоматически использовала старую, проверенную систему правил.
        rm -f /usr/sbin/iptables /usr/sbin/iptables-save /usr/sbin/iptables-restore
        ln -s /usr/sbin/iptables-legacy         /usr/sbin/iptables
        ln -s /usr/sbin/iptables-legacy-save    /usr/sbin/iptables-save
        ln -s /usr/sbin/iptables-legacy-restore /usr/sbin/iptables-restore
        # То же самое делаем и для IPv6 (ip6tables).
        rm -f /usr/sbin/ip6tables /usr/sbin/ip6tables-save /usr/sbin/ip6tables-restore
        ln -s /usr/sbin/ip6tables-legacy         /usr/sbin/ip6tables
        ln -s /usr/sbin/ip6tables-legacy-save    /usr/sbin/ip6tables-save
        ln -s /usr/sbin/ip6tables-legacy-restore /usr/sbin/ip6tables-restore
      fi
  else
      # Если же nftables УЖЕ ИСПОЛЬЗУЕТСЯ (модуль nf_tables загружен),
      # то будем работать через nftables, а iptables удалим.
      export DISABLE_NFTABLES=0
      if apk info -e iptables iptables-legacy >/dev/null 2>&1; then
        apk del iptables iptables-legacy >/dev/null 2>&1
      fi
      # Убедимся, что nftables установлен.
      apk info -e nftables >/dev/null 2>&1 || apk add nftables
  fi
fi

# Эта ссылка используется для проверки, работает ли интернет.
# Если ответ приходит — значит, интернет есть.
HEALTH_CHECK_URL="${HEALTH_CHECK_URL:-https://www.gstatic.com/generate_204  }"

# Это основной шаблон конфигурации Mihomo.
# Он будет использоваться, если пользователь не указал свой файл YAML.
# Вместо переменных вроде $UI_PORT или $PROVIDERS_LIST подставятся реальные значения.
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
$PROVIDERS_CHAIN_BLOCK

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

# Пути к папкам:
# — AWG_DIR — где лежат .conf-файлы WireGuard/AmneziaWG
# — TEMPLATE_DIR — где хранятся шаблоны конфигов
AWG_DIR="$WORKDIR/awg"
TEMPLATE_DIR="$WORKDIR/template"
mkdir -p "$TEMPLATE_DIR"
mkdir -p "$AWG_DIR"
TEMPLATE_FILE="$TEMPLATE_DIR/$CONFIG"
BACKUP_PATH="$TEMPLATE_DIR/default_config_old.yaml"

# Если используется стандартный конфиг (default_config.yaml),
# проверим: есть ли хоть какие-то серверы или подписки?
if [ "$CONFIG" = "default_config.yaml" ]; then
  # Смотрим, заданы ли переменные SRV1, SUB2 и т.д.
  has_env_vars=$(env | grep -qE '^(SRV|SUB)[0-9]' && echo 1 || echo 0)
  # Смотрим, есть ли файлы .conf в папке awg
  has_conf_files=$(find "$AWG_DIR" -type f -name '*.conf' 2>/dev/null | grep -q . && echo 1 || echo 0)
  # Если ни того, ни другого — нет смысла запускать Mihomo.
  if [ "$has_env_vars" -eq 0 ] && [ "$has_conf_files" -eq 0 ]; then
    echo "Нет ни одной подписки (SUB*), ни сервера (SRV*), и нет .conf-файлов в $AWG_DIR. Выходим."
    exit 1
  fi
fi

# Если используется стандартный конфиг — убедимся, что файл существует.
# Если файл есть, но отличается от шаблона — сохраним копию и перезапишем.
# Это нужно, чтобы автоматически обновлять конфиг при обновлении entrypoint.sh.
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
  # Если пользователь указал свой файл конфига, но его нет — создадим пустой,
  # чтобы последующая обработка не сломалась.
  if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "$DEFAULT_CONFIG" > "$TEMPLATE_FILE"
  fi
fi

# Проверим, не изменился ли внешний адрес панели управления (UI).
# Если да — удалим старую панель и скачаем новую при запуске Mihomo.
UI_URL_CHECK="$WORKDIR/.ui_url"
LAST_UI_URL=$(cat "$UI_URL_CHECK" 2>/dev/null)
if [ "$EXTERNAL_UI_URL" != "$LAST_UI_URL" ]; then
  rm -rf "$WORKDIR/$EXTERNAL_UI_PATH"
  echo "$EXTERNAL_UI_URL" > "$UI_URL_CHECK"
fi

# Эта функция читает .conf-файл WireGuard/AmneziaWG и превращает его
# в понятный для Mihomo формат YAML.
parse_awg_config() {
  local config_file="$1"
  # Имя прокси — это имя файла без расширения .conf
  local awg_name=$(basename "$config_file" .conf)

  # Вспомогательная функция: читает значение параметра из .conf-файла
  read_cfg() {
    local key="$1"
    # Найдём строку вроде "PrivateKey = Abc123...", удалим всё лишнее
    grep -Ei "^${key}[[:space:]]*=" "$config_file" | sed -E "s/^${key}[[:space:]]*=[[:space:]]*//I"
  }

  # Читаем основные параметры из .conf-файла
  private_key=$(read_cfg "PrivateKey")
  address=$(read_cfg "Address")
  # Берём только IPv4-адрес (игнорируем IPv6)
  address=$(echo "$address" | tr ',' '\n' | grep -v ':' | head -n1)
  dns=$(read_cfg "DNS")
  # Убираем IPv6 из DNS, оставляем только IPv4, и склеиваем через запятую
  dns=$(echo "$dns" | tr ',' '\n' | grep -v ':' | sed 's/^ *//;s/ *$//' | paste -sd, -)

  # Читаем настройки AmneziaWG (если есть)
  mtu=$(read_cfg "MTU")
  jc=$(read_cfg "Jc")
  jmin=$(read_cfg "Jmin")
  jmax=$(read_cfg "Jmax")
  s1=$(read_cfg "S1")
  s2=$(read_cfg "S2")
  h1=$(read_cfg "H1")
  h2=$(read_cfg "H2")
  h3=$(read_cfg "H3")
  h4=$(read_cfg "H4")
  i1=$(read_cfg "I1")
  i2=$(read_cfg "I2")
  i3=$(read_cfg "I3")
  i4=$(read_cfg "I4")
  i5=$(read_cfg "I5")
  j1=$(read_cfg "J1")
  j2=$(read_cfg "J2")
  j3=$(read_cfg "J3")
  itime=$(read_cfg "ITime")

  # Сервер и порт — из строки Endpoint
  public_key=$(read_cfg "PublicKey")
  psk=$(read_cfg "PresharedKey")
  endpoint=$(read_cfg "Endpoint")
  server=$(echo "$endpoint" | cut -d':' -f1)
  port=$(echo "$endpoint" | cut -d':' -f2)

  # Выводим YAML-блок для прокси
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

  # Если есть хотя бы один параметр AmneziaWG — добавим блок amnezia-wg-option
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

# Функция для добавления прокси из локального YAML-файла (например, SRV или AWG)
add_file_provider() {
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

# Функция для добавления подписки по HTTP (SUB1, SUB2 и т.д.)
add_http_provider() {
    local name="$1"
    local url="$2"
    PROVIDERS_BLOCK="${PROVIDERS_BLOCK}  ${name}:
    type: http
    url: \"${url}\"
    interval: 86400        # Обновлять раз в сутки
    health-check:
      enable: true
      url: \"${HEALTH_CHECK_URL}\"
      interval: 86400      # Проверка состояния — тоже раз в сутки
"
    PROVIDERS_LIST="${PROVIDERS_LIST}      - ${name}
"
}

# Функция для создания "цепочек": иностранные серверы → через российский прокси
# Эти провайдеры автоматически перенаправляют трафик через RU_AUTO
add_http_chain_provider() {
    local name="$1"
    local url="$2"
    local chain_name="${name}-via-ru"
    PROVIDERS_CHAIN_BLOCK="${PROVIDERS_CHAIN_BLOCK}  ${chain_name}:
    type: http
    url: \"${url}\"
    interval: 86400
    override:
      dialer-proxy: RU_AUTO            # Сначала идём через RU_AUTO
      exclude-filter: \"(?i)awg|warp\" # Исключаем AWG/WARP — они не поддерживают цепочки
"
    PROVIDERS_CHAIN_LIST="${PROVIDERS_CHAIN_LIST}      - ${chain_name}
"
}

# Обнуляем переменные, которые будут заполнены дальше
PROVIDERS_BLOCK=""
PROVIDERS_LIST=""
PROVIDERS_CHAIN_BLOCK=""
PROVIDERS_CHAIN_LIST=""

####
# Часть 1: обрабатываем SRV* — прямые ссылки на прокси
srv_file="$WORKDIR/srv.yaml"
if env | grep -qE '^(SRV)[0-9]'; then
> "$srv_file"
# Читаем все переменные вроде SRV1, SRV2... и записываем их в файл srv.yaml
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

# Добавляем этот файл как провайдер
add_file_provider "SRV" "$srv_file"
# ВАЖНО: SRV не участвует в цепочках — только напрямую
fi
###

# Часть 2: обрабатываем .conf-файлы WireGuard/AmneziaWG
awg_file="$WORKDIR/awg.yaml"
if find "$AWG_DIR" -name "*.conf" | grep -q . 2>/dev/null; then
    echo "proxies:" > "$awg_file"
    # Преобразуем каждый .conf в формат YAML
    find "$AWG_DIR" -name "*.conf" | while read -r conf; do
      parse_awg_config "$conf"
    done >> "$awg_file"

# Добавляем как провайдер
add_file_provider "AWG" "$awg_file"
# ВАЖНО: AWG тоже не участвует в цепочках
fi
###

# Часть 3: обрабатываем подписки SUB1, SUB2...
# Они участвуют и в обычных прокси, и в цепочках!
while IFS='=' read -r name value; do
  case "$name" in
    SUB[0-9]*)
      # Экранируем кавычки в URL, чтобы YAML не сломался
      value_clean=$(printf '%s' "$value" | sed 's/"/\\"/g')
      # Добавляем обычный провайдер
      add_http_provider "$name" "$value_clean"
      # Добавляем цепочку для этого же источника
      add_http_chain_provider "$name" "$value_clean"
      ;;
  esac
done << EOF
$(env)
EOF

# Экспортируем переменные, чтобы их мог подставить envsubst
export PROVIDERS_BLOCK
export PROVIDERS_LIST
export PROVIDERS_CHAIN_BLOCK
export PROVIDERS_CHAIN_LIST

# Подставляем значения переменных в шаблон и сохраняем финальный конфиг
envsubst < "$TEMPLATE_DIR/$CONFIG" > "$WORKDIR/$CONFIG"

# Готовим команду запуска Mihomo
CMD_MIHOMO="${@:-"-d $WORKDIR -f $WORKDIR/$CONFIG"}"
# Выводим версию — полезно для отладки
mihomo -v
# Запускаем Mihomo!
exec mihomo $CMD_MIHOMO || exit 1