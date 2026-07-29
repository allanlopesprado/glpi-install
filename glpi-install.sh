#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Nome: glpi-install-debian.sh
# Versão: 2.0.0
# Descrição: Instala a versão estável mais recente do GLPI no Debian 12 ou 13.
# Ambiente: Apache 2 + PHP-FPM + MariaDB
# Autor original: Allan Lopes Prado
# Licença: GNU General Public License v2.0 ou posterior
# -----------------------------------------------------------------------------

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

readonly SCRIPT_VERSION="2.0.0"
readonly GLPI_DIR="${GLPI_DIR:-/var/www/glpi}"
readonly GLPI_CONFIG_DIR="${GLPI_CONFIG_DIR:-/etc/glpi}"
readonly GLPI_VAR_DIR="${GLPI_VAR_DIR:-/var/lib/glpi/files}"
readonly GLPI_LOG_DIR="${GLPI_LOG_DIR:-/var/log/glpi}"
readonly GLPI_TIMEZONE="${GLPI_TIMEZONE:-America/Sao_Paulo}"
readonly GLPI_LANGUAGE="${GLPI_LANGUAGE:-pt_BR}"
readonly GITHUB_API_URL="https://api.github.com/repos/glpi-project/glpi/releases/latest"
readonly APACHE_SITE_FILE="/etc/apache2/sites-available/glpi.conf"
readonly CRON_FILE="/etc/cron.d/glpi"
readonly LOGROTATE_FILE="/etc/logrotate.d/glpi"

TMP_DIR=""
DB_PASSWORD="${GLPI_DB_PASSWORD:-}"
DB_NAME="${GLPI_DB_NAME:-glpi}"
DB_USER="${GLPI_DB_USER:-glpi}"
SERVER_NAME="${GLPI_SERVER_NAME:-}"

log() {
    printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"
}

success() {
    printf '\033[1;32m[OK]\033[0m %s\n' "$*"
}

warn() {
    printf '\033[1;33m[AVISO]\033[0m %s\n' "$*" >&2
}

fatal() {
    printf '\033[1;31m[ERRO]\033[0m %s\n' "$*" >&2
    exit 1
}

cleanup() {
    local exit_code=$?

    unset GLPI_EXPECT_PASSWORD GLPI_EXPECT_DIR GLPI_EXPECT_COMMAND
    unset GLPI_EXPECT_DB_NAME GLPI_EXPECT_DB_USER GLPI_EXPECT_DB_HOST
    unset GLPI_EXPECT_LANGUAGE
    unset DB_PASSWORD DB_PASSWORD_SQL GLPI_DB_PASSWORD

    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf -- "$TMP_DIR"
    fi

    exit "$exit_code"
}

on_error() {
    local exit_code=$?
    local line_number=$1
    printf '\n\033[1;31m[ERRO]\033[0m Falha na linha %s. Código de saída: %s.\n' \
        "$line_number" "$exit_code" >&2
    exit "$exit_code"
}

trap cleanup EXIT
trap 'on_error "$LINENO"' ERR

require_root() {
    [[ $EUID -eq 0 ]] || fatal "Execute este script como root. Exemplo: sudo bash $0"
}

check_debian_version() {
    [[ -r /etc/os-release ]] || fatal "Não foi possível identificar o sistema operacional."

    # shellcheck disable=SC1091
    source /etc/os-release

    [[ "${ID:-}" == "debian" ]] || fatal "Este script é exclusivo para Debian. Sistema detectado: ${PRETTY_NAME:-desconhecido}."

    case "${VERSION_ID:-}" in
        12|13)
            success "Sistema suportado: ${PRETTY_NAME}."
            ;;
        *)
            fatal "Versão não suportada: ${PRETTY_NAME:-Debian desconhecido}. Use Debian 12 ou Debian 13."
            ;;
    esac
}

validate_identifier() {
    local value=$1
    local description=$2

    [[ "$value" =~ ^[A-Za-z0-9_]+$ ]] || \
        fatal "$description inválido: '$value'. Use somente letras, números e sublinhado."
}

sql_escape_string() {
    local value=$1
    printf '%s' "${value//\'/\'\'}"
}

detect_primary_ip() {
    local ip=""

    if command -v ip >/dev/null 2>&1; then
        ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')
    fi

    if [[ -z "$ip" ]]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi

    printf '%s' "$ip"
}

collect_configuration() {
    local default_server_name=""
    local password_confirmation=""

    default_server_name=$(hostname -f 2>/dev/null || true)
    if [[ -z "$default_server_name" || "$default_server_name" == "localhost" || "$default_server_name" == "localhost.localdomain" ]]; then
        default_server_name=$(detect_primary_ip)
    fi
    [[ -n "$default_server_name" ]] || default_server_name="glpi.local"

    if [[ -z "$SERVER_NAME" ]]; then
        read -r -p "Nome DNS ou IP usado para acessar o GLPI [$default_server_name]: " SERVER_NAME
        SERVER_NAME=${SERVER_NAME:-$default_server_name}
    fi

    [[ "$SERVER_NAME" =~ ^[A-Za-z0-9._:-]+$ ]] || \
        fatal "Nome DNS/IP inválido: $SERVER_NAME."
    [[ "$GLPI_LANGUAGE" =~ ^[A-Za-z]{2,3}_[A-Za-z]{2,3}$ ]] || \
        fatal "Idioma GLPI inválido: $GLPI_LANGUAGE."
    [[ "$GLPI_TIMEZONE" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)+$ ]] || \
        fatal "Formato de fuso horário inválido: $GLPI_TIMEZONE."

    validate_identifier "$DB_NAME" "Nome do banco"
    validate_identifier "$DB_USER" "Usuário do banco"

    if [[ -z "$DB_PASSWORD" ]]; then
        while true; do
            read -r -s -p "Senha do usuário MariaDB '$DB_USER' (mínimo de 12 caracteres): " DB_PASSWORD
            printf '\n'

            [[ ${#DB_PASSWORD} -ge 12 ]] || {
                warn "A senha precisa ter pelo menos 12 caracteres."
                continue
            }

            [[ "$DB_PASSWORD" != *$'\n'* && "$DB_PASSWORD" != *$'\r'* ]] || {
                warn "A senha não pode conter quebra de linha."
                continue
            }

            read -r -s -p "Confirme a senha: " password_confirmation
            printf '\n'

            [[ "$DB_PASSWORD" == "$password_confirmation" ]] || {
                warn "As senhas não coincidem."
                continue
            }

            break
        done
    else
        [[ ${#DB_PASSWORD} -ge 12 ]] || fatal "GLPI_DB_PASSWORD precisa ter pelo menos 12 caracteres."
        [[ "$DB_PASSWORD" != *$'\n'* && "$DB_PASSWORD" != *$'\r'* ]] || \
            fatal "GLPI_DB_PASSWORD não pode conter quebra de linha."
    fi

    [[ -e "/usr/share/zoneinfo/$GLPI_TIMEZONE" ]] || fatal "Fuso horário inválido: $GLPI_TIMEZONE."
}

check_fresh_install() {
    if [[ -e "$GLPI_DIR" ]]; then
        fatal "O caminho $GLPI_DIR já existe. Este instalador é apenas para instalação nova."
    fi

    if [[ -e "$GLPI_CONFIG_DIR" ]]; then
        fatal "O caminho $GLPI_CONFIG_DIR já existe. Este instalador é apenas para instalação nova."
    fi

    if [[ -e "$GLPI_VAR_DIR" ]]; then
        fatal "O caminho $GLPI_VAR_DIR já existe. Este instalador é apenas para instalação nova."
    fi

    if [[ -e "$GLPI_LOG_DIR" ]]; then
        fatal "O caminho $GLPI_LOG_DIR já existe. Este instalador é apenas para instalação nova."
    fi

    if [[ -e "$APACHE_SITE_FILE" ]]; then
        fatal "A configuração Apache $APACHE_SITE_FILE já existe."
    fi
}

install_packages() {
    log "Atualizando os índices do APT..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update

    log "Instalando Apache, PHP-FPM, MariaDB e dependências do GLPI..."
    apt-get install -y --no-install-recommends \
        apache2 \
        mariadb-server \
        cron \
        ca-certificates \
        curl \
        expect \
        jq \
        tar \
        bzip2 \
        xz-utils \
        iproute2 \
        php-fpm \
        php-cli \
        php-mysql \
        php-curl \
        php-gd \
        php-intl \
        php-mbstring \
        php-xml \
        php-bcmath \
        php-ldap \
        php-zip \
        php-bz2 \
        php-apcu \
        php-imap \
        php-soap \
        php-opcache

    systemctl enable --now mariadb apache2 cron
}

validate_runtime_versions() {
    local php_full_version=""
    local mariadb_version=""

    PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')
    php_full_version=$(php -r 'echo PHP_VERSION;')

    dpkg --compare-versions "$php_full_version" ge "8.2" || \
        fatal "O GLPI 11 requer PHP 8.2 ou superior. Versão detectada: $php_full_version."

    mariadb_version=$(mariadb --protocol=socket -uroot -Nse 'SELECT VERSION();' | sed 's/-.*//')
    dpkg --compare-versions "$mariadb_version" ge "10.6" || \
        fatal "O GLPI 11 requer MariaDB 10.6 ou superior. Versão detectada: $mariadb_version."

    readonly PHP_VERSION
    success "PHP $php_full_version e MariaDB $mariadb_version atendem aos requisitos."
}

configure_php() {
    local sapi=""
    local ini_dir=""

    log "Configurando PHP $PHP_VERSION..."

    for sapi in fpm cli; do
        ini_dir="/etc/php/$PHP_VERSION/$sapi/conf.d"
        [[ -d "$ini_dir" ]] || fatal "Diretório do PHP não encontrado: $ini_dir"

        cat > "$ini_dir/99-glpi.ini" <<EOF
; Configuração gerenciada por glpi-install-debian.sh
expose_php = Off
memory_limit = 512M
max_execution_time = 300
max_input_time = 300
max_input_vars = 5000
post_max_size = 64M
upload_max_filesize = 64M
date.timezone = $GLPI_TIMEZONE
session.cookie_httponly = 1
session.cookie_samesite = Lax
session.use_strict_mode = 1
apc.enable_cli = 1
opcache.enable = 1
opcache.memory_consumption = 256
opcache.interned_strings_buffer = 32
opcache.max_accelerated_files = 20000
opcache.validate_timestamps = 1
EOF
    done

    systemctl enable --now "php${PHP_VERSION}-fpm"
    systemctl restart "php${PHP_VERSION}-fpm"
}

configure_mariadb() {
    local tzinfo_command=""
    local db_exists=""
    local user_exists=""

    log "Configurando MariaDB para o GLPI..."

    cat > /etc/mysql/mariadb.conf.d/60-glpi.cnf <<'EOF'
# Configuração gerenciada por glpi-install-debian.sh
[mariadb]
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
innodb_file_per_table = 1
innodb_default_row_format = dynamic
max_allowed_packet = 64M
EOF

    systemctl restart mariadb

    mariadb --protocol=socket -uroot -e 'SELECT 1;' >/dev/null || \
        fatal "Não foi possível administrar o MariaDB pelo socket local como root."

    db_exists=$(mariadb --protocol=socket -uroot -Nse \
        "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${DB_NAME}';")
    [[ -z "$db_exists" ]] || fatal "O banco '$DB_NAME' já existe."

    user_exists=$(mariadb --protocol=socket -uroot -Nse \
        "SELECT User FROM mysql.user WHERE User='${DB_USER}' AND Host='localhost';")
    [[ -z "$user_exists" ]] || fatal "O usuário MariaDB '${DB_USER}'@'localhost' já existe."

    if command -v mariadb-tzinfo-to-sql >/dev/null 2>&1; then
        tzinfo_command=$(command -v mariadb-tzinfo-to-sql)
    elif command -v mysql_tzinfo_to_sql >/dev/null 2>&1; then
        tzinfo_command=$(command -v mysql_tzinfo_to_sql)
    else
        fatal "O utilitário de carga de fusos horários do MariaDB não foi encontrado."
    fi

    "$tzinfo_command" /usr/share/zoneinfo 2>/dev/null | \
        mariadb --protocol=socket -uroot mysql
    systemctl restart mariadb

    DB_PASSWORD_SQL=$(sql_escape_string "$DB_PASSWORD")

    mariadb --protocol=socket -uroot <<SQL
SET SESSION sql_mode = 'NO_BACKSLASH_ESCAPES';
CREATE DATABASE \`$DB_NAME\`
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;
CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD_SQL';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
GRANT SELECT ON \`mysql\`.\`time_zone_name\` TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL

    unset DB_PASSWORD_SQL
    success "Banco e usuário MariaDB criados."
}

get_latest_release() {
    local release_json=""
    local asset_name=""

    log "Consultando a versão estável mais recente do GLPI..."

    release_json=$(curl -fsSL --retry 3 --retry-delay 2 \
        -H 'Accept: application/vnd.github+json' \
        -H 'User-Agent: glpi-install-debian' \
        "$GITHUB_API_URL")

    GLPI_VERSION=$(jq -er '.tag_name' <<< "$release_json")
    asset_name="glpi-${GLPI_VERSION}.tgz"

    GLPI_DOWNLOAD_URL=$(jq -er --arg asset "$asset_name" \
        '.assets[] | select(.name == $asset) | .browser_download_url' <<< "$release_json")

    GLPI_SHA256=$(jq -er --arg asset "$asset_name" \
        '.assets[] | select(.name == $asset) | .digest | select(startswith("sha256:")) | sub("^sha256:"; "")' \
        <<< "$release_json")

    [[ "$GLPI_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
        fatal "Versão retornada pela API é inválida: $GLPI_VERSION"
    [[ "${GLPI_VERSION%%.*}" == "11" ]] || \
        fatal "Este script foi validado para GLPI 11.x. A versão estável retornada foi $GLPI_VERSION."
    [[ "$GLPI_SHA256" =~ ^[a-fA-F0-9]{64}$ ]] || \
        fatal "O GitHub não forneceu um SHA-256 válido para o pacote."

    readonly GLPI_VERSION GLPI_DOWNLOAD_URL GLPI_SHA256
    success "Versão estável encontrada: GLPI $GLPI_VERSION."
}

download_and_extract_glpi() {
    local archive=""
    local extraction_dir=""
    local calculated_sha256=""

    TMP_DIR=$(mktemp -d -t glpi-install.XXXXXXXX)
    chmod 700 "$TMP_DIR"
    archive="$TMP_DIR/glpi-${GLPI_VERSION}.tgz"
    extraction_dir="$TMP_DIR/extracted"

    mkdir -p "$extraction_dir"

    log "Baixando GLPI $GLPI_VERSION..."
    curl -fL --retry 3 --retry-delay 2 \
        -H 'User-Agent: glpi-install-debian' \
        "$GLPI_DOWNLOAD_URL" \
        -o "$archive"

    calculated_sha256=$(sha256sum "$archive" | awk '{print $1}')
    [[ "$calculated_sha256" == "$GLPI_SHA256" ]] || \
        fatal "Falha na integridade do pacote. SHA-256 esperado: $GLPI_SHA256; obtido: $calculated_sha256."

    success "Integridade SHA-256 validada."

    tar -xzf "$archive" -C "$extraction_dir"
    [[ -f "$extraction_dir/glpi/bin/console" ]] || \
        fatal "O pacote baixado não contém a estrutura esperada do GLPI."

    install -d -o root -g www-data -m 0750 "$GLPI_DIR"
    cp -a "$extraction_dir/glpi/." "$GLPI_DIR/"
}

configure_glpi_directories() {
    log "Separando código, configuração, dados e logs conforme o FHS..."

    install -d -o www-data -g www-data -m 0770 \
        "$GLPI_CONFIG_DIR" "$GLPI_VAR_DIR" "$GLPI_LOG_DIR"

    cp -a "$GLPI_DIR/config/." "$GLPI_CONFIG_DIR/"
    cp -a "$GLPI_DIR/files/." "$GLPI_VAR_DIR/"

    if [[ -e "$GLPI_DIR/inc/downstream.php" ]]; then
        fatal "O pacote já contém $GLPI_DIR/inc/downstream.php. Revise-o antes de continuar."
    fi

    cat > "$GLPI_DIR/inc/downstream.php" <<EOF
<?php
define('GLPI_CONFIG_DIR', '$GLPI_CONFIG_DIR/');

if (file_exists(GLPI_CONFIG_DIR . '/local_define.php')) {
    require_once GLPI_CONFIG_DIR . '/local_define.php';
}
EOF

    cat > "$GLPI_CONFIG_DIR/local_define.php" <<EOF
<?php
define('GLPI_VAR_DIR', '$GLPI_VAR_DIR');
define('GLPI_LOG_DIR', '$GLPI_LOG_DIR');
EOF

    chown -R root:www-data "$GLPI_DIR"
    find "$GLPI_DIR" -type d -exec chmod 0750 {} +
    find "$GLPI_DIR" -type f -exec chmod 0640 {} +

    # Diretórios que precisam permanecer graváveis pelo processo web.
    install -d -o www-data -g www-data -m 0750 "$GLPI_DIR/marketplace"

    chown -R www-data:www-data "$GLPI_CONFIG_DIR" "$GLPI_VAR_DIR" "$GLPI_LOG_DIR"
    find "$GLPI_CONFIG_DIR" "$GLPI_VAR_DIR" "$GLPI_LOG_DIR" -type d -exec chmod 0770 {} +
    find "$GLPI_CONFIG_DIR" "$GLPI_VAR_DIR" "$GLPI_LOG_DIR" -type f -exec chmod 0660 {} +
}

configure_apache() {
    log "Configurando o VirtualHost do Apache..."

    cat > "$APACHE_SITE_FILE" <<EOF
<VirtualHost *:80>
    ServerName $SERVER_NAME

    DocumentRoot $GLPI_DIR/public
    DirectoryIndex index.php

    <Directory $GLPI_DIR/public>
        Options FollowSymLinks
        AllowOverride None
        Require all granted

        RewriteEngine On

        # Preserva o cabeçalho Authorization para API, CalDAV e integrações.
        RewriteCond %{HTTP:Authorization} ^(.+)$
        RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]

        # Direciona ao roteador do GLPI quando o arquivo solicitado não existe.
        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteRule ^(.*)$ index.php [QSA,L]
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/glpi_error.log
    CustomLog \${APACHE_LOG_DIR}/glpi_access.log combined
</VirtualHost>
EOF

    a2enmod proxy_fcgi setenvif rewrite
    a2enconf "php${PHP_VERSION}-fpm"
    a2ensite glpi.conf
    a2dissite 000-default.conf || true

    apache2ctl configtest
    systemctl restart "php${PHP_VERSION}-fpm"
    systemctl restart apache2
}

run_glpi_console() {
    runuser -u www-data -- bash -c '
        cd "$1"
        shift
        exec /usr/bin/php bin/console "$@"
    ' bash "$GLPI_DIR" "$@"
}

pick_console_command() {
    local commands=$1
    shift
    local candidate=""

    for candidate in "$@"; do
        if awk '{print $1}' <<< "$commands" | grep -Fxq "$candidate"; then
            printf '%s' "$candidate"
            return 0
        fi
    done

    return 1
}

install_glpi_database() {
    local commands=""
    local requirements_command=""
    local install_command=""

    log "Validando os requisitos internos do GLPI..."

    commands=$(run_glpi_console list --raw)

    requirements_command=$(pick_console_command "$commands" \
        "system:check_requirements" \
        "glpi:system:check_requirements") || \
        fatal "Comando de validação de requisitos não encontrado no GLPI $GLPI_VERSION."

    install_command=$(pick_console_command "$commands" \
        "database:install" \
        "db:install" \
        "glpi:database:install") || \
        fatal "Comando de instalação do banco não encontrado no GLPI $GLPI_VERSION."

    run_glpi_console "$requirements_command" --no-interaction

    log "Instalando o banco do GLPI por linha de comando..."

    export GLPI_EXPECT_PASSWORD="$DB_PASSWORD"
    export GLPI_EXPECT_DIR="$GLPI_DIR"
    export GLPI_EXPECT_COMMAND="$install_command"
    export GLPI_EXPECT_DB_NAME="$DB_NAME"
    export GLPI_EXPECT_DB_USER="$DB_USER"
    export GLPI_EXPECT_DB_HOST="localhost"
    export GLPI_EXPECT_LANGUAGE="$GLPI_LANGUAGE"

    expect <<'EXPECT_SCRIPT'
set timeout -1
set command [list \
    runuser -u www-data -- \
    /usr/bin/php "$env(GLPI_EXPECT_DIR)/bin/console" \
    "$env(GLPI_EXPECT_COMMAND)" \
    "--db-host=$env(GLPI_EXPECT_DB_HOST)" \
    "--db-name=$env(GLPI_EXPECT_DB_NAME)" \
    "--db-user=$env(GLPI_EXPECT_DB_USER)" \
    "--default-language=$env(GLPI_EXPECT_LANGUAGE)" \
    "--no-telemetry" \
    "--db-password"]

spawn {*}$command

expect {
    -re {(?i)password[^:]*:} {
        send -- "$env(GLPI_EXPECT_PASSWORD)\r"
        exp_continue
    }
    eof
}

set result [wait]
exit [lindex $result 3]
EXPECT_SCRIPT

    unset GLPI_EXPECT_PASSWORD GLPI_EXPECT_DIR GLPI_EXPECT_COMMAND
    unset GLPI_EXPECT_DB_NAME GLPI_EXPECT_DB_USER GLPI_EXPECT_DB_HOST
    unset GLPI_EXPECT_LANGUAGE
    unset DB_PASSWORD GLPI_DB_PASSWORD

    # Após a instalação, a configuração precisa apenas ser lida pelo Apache.
    chown -R root:www-data "$GLPI_CONFIG_DIR"
    find "$GLPI_CONFIG_DIR" -type d -exec chmod 0750 {} +
    find "$GLPI_CONFIG_DIR" -type f -exec chmod 0640 {} +

    run_glpi_console "$requirements_command" --no-interaction

    local table_count=""
    table_count=$(mariadb --protocol=socket -uroot -Nse \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';")
    [[ "$table_count" =~ ^[0-9]+$ && "$table_count" -gt 0 ]] || \
        fatal "O banco foi criado, mas nenhuma tabela do GLPI foi encontrada."

    success "Banco do GLPI instalado com $table_count tabelas."
}

configure_cron() {
    log "Configurando as ações automáticas do GLPI..."

    cat > "$CRON_FILE" <<EOF
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

* * * * * www-data cd $GLPI_DIR && /usr/bin/php front/cron.php >/dev/null 2>&1
EOF

    chmod 0644 "$CRON_FILE"
    systemctl enable --now cron
    systemctl restart cron
}

configure_logrotate() {
    cat > "$LOGROTATE_FILE" <<EOF
$GLPI_LOG_DIR/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    su www-data www-data
}
EOF

    chmod 0644 "$LOGROTATE_FILE"
}

validate_installation() {
    local url=""

    log "Executando validações finais..."

    apache2ctl configtest
    systemctl is-active --quiet apache2
    systemctl is-active --quiet "php${PHP_VERSION}-fpm"
    systemctl is-active --quiet mariadb
    systemctl is-active --quiet cron

    curl -fsS --max-time 15 \
        -H "Host: $SERVER_NAME" \
        -o /dev/null \
        http://127.0.0.1/

    if [[ "$SERVER_NAME" == *.* || "$SERVER_NAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        url="http://$SERVER_NAME"
    else
        url="http://$(detect_primary_ip)"
    fi

    printf '\n'
    success "GLPI $GLPI_VERSION instalado com sucesso."
    printf '\nAcesso: %s\n' "$url"
    printf 'Diretório do código: %s\n' "$GLPI_DIR"
    printf 'Diretório de configuração: %s\n' "$GLPI_CONFIG_DIR"
    printf 'Diretório de dados: %s\n' "$GLPI_VAR_DIR"
    printf 'Diretório de logs: %s\n' "$GLPI_LOG_DIR"
    printf 'Banco: %s\n' "$DB_NAME"
    printf 'Usuário do banco: %s@localhost\n' "$DB_USER"
    printf '\nCredencial inicial do GLPI: glpi / glpi\n'
    printf 'Troque imediatamente a senha do usuário glpi e desative/remova as contas padrão não utilizadas.\n'
    printf 'A instalação está em HTTP. Configure HTTPS antes de expor o GLPI à internet.\n'
}

main() {
    printf 'GLPI Installer para Debian - versão %s\n' "$SCRIPT_VERSION"

    require_root
    check_debian_version
    collect_configuration
    check_fresh_install
    install_packages
    validate_runtime_versions
    configure_php
    get_latest_release
    download_and_extract_glpi
    configure_mariadb
    configure_glpi_directories
    configure_apache
    install_glpi_database
    configure_cron
    configure_logrotate
    validate_installation
}

main "$@"
