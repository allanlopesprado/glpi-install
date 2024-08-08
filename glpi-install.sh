#!/bin/bash

# Função para exibir mensagens de erro
erro() {
  echo "Erro: $1"
  exit 1
}

# Função para detectar a versão do PHP
detectar_versao_php() {
  php -r "echo PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION;"
}

# Função para obter a última versão do GLPI
obter_ultima_versao() {
  curl -s https://api.github.com/repos/glpi-project/glpi/releases/latest | grep 'tag_name' | cut -d '"' -f 4 | sed 's/^v//'
}

# Função para obter o IP local da máquina
obter_ip_local() {
  hostname -I | awk '{print $1}'
}

# Função para ajustar o php.ini
ajustar_php_ini() {
  # Detectar a versão do PHP
  PHP_VERSION=$(detectar_versao_php)
  if [ -z "$PHP_VERSION" ]; then
    erro "Não foi possível detectar a versão do PHP."
  fi
  
  # Localizar o arquivo php.ini
  PHP_INI_PATH="/etc/php/$PHP_VERSION/apache2/php.ini"
  
  if [ ! -f "$PHP_INI_PATH" ]; then
    erro "O arquivo php.ini não foi encontrado em $PHP_INI_PATH."
  fi
  
  echo "Arquivo php.ini localizado: $PHP_INI_PATH"

  # Modificar as configurações
  sed -i -e 's/^;*\s*session.cookie_httponly\s*=.*/session.cookie_httponly = 1/' \
         -e 's/^;*\s*session.cookie_secure\s*=.*/session.cookie_secure = 1/' \
         -e 's/^;*\s*session.cookie_samesite\s*=.*/session.cookie_samesite = Lax/' "$PHP_INI_PATH" || erro "Não foi possível atualizar o php.ini."
}

# Instalação de todas as dependências
apt update && apt upgrade -y && apt install -y || erro "Não foi possível atualizar os pacotes."
apt install -y apache2 bzip2 curl php php-apcu php-bcmath php-cli php-curl php-fpm php-gd php-intl php-ldap php-mbstring php-mysql php-pgsql php-xml php-zip php-imap php-bz2 mariadb-server sudo tar wget || erro "Não foi possível instalar as dependências."

# Detectar a versão do PHP
PHP_VERSION=$(detectar_versao_php)
echo "Versão do PHP detectada: $PHP_VERSION"

# Ajustar o php.ini
ajustar_php_ini

# Obtém a última versão do GLPI
GLPI_VERSION=$(obter_ultima_versao)
if [ -z "$GLPI_VERSION" ]; then
  erro "Não foi possível obter a última versão do GLPI."
fi

echo "Última versão do GLPI: $GLPI_VERSION"

# Nome do banco de dados
DB_NAME="glpi"

# Solicita a senha do banco de dados
read -s -p "Digite a senha para o usuário do banco de dados '$DB_NAME' (este usuário será usado pelo GLPI): " DB_PASSWORD
echo

# Solicita a senha do usuário root do banco de dados
read -s -p "Digite a senha do usuário root do banco de dados (para administração geral do banco de dados): " DB_ROOT_PASSWORD
echo

# Armazenar informações em um arquivo temporário
TEMP_FILE="/tmp/glpi_install_config"
GLPI_DIR="/var/www/html/glpi"
CONFIG_DIR="/etc/glpi"
VAR_DIR="/var/lib/glpi"
LOG_DIR="/var/log/glpi"

cat <<EOL > $TEMP_FILE
GLPI_VERSION="$GLPI_VERSION"
DB_NAME="$DB_NAME"
DB_PASSWORD="$DB_PASSWORD"
DB_ROOT_PASSWORD="$DB_ROOT_PASSWORD"
GLPI_URL="https://github.com/glpi-project/glpi/releases/download/$GLPI_VERSION/glpi-$GLPI_VERSION.tgz"
GLPI_DIR="$GLPI_DIR"
CONFIG_DIR="$CONFIG_DIR"
VAR_DIR="$VAR_DIR"
LOG_DIR="$LOG_DIR"
EOL

# Carregar informações do arquivo temporário
source $TEMP_FILE

# Carregar a base de dados de fusos horários do MySQL
mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql -u root -p$DB_ROOT_PASSWORD mysql || erro "Não foi possível carregar a base de dados de fusos horários."

# Configuração do banco de dados
mysql -uroot -p$DB_ROOT_PASSWORD -e "CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || erro "Não foi possível criar o banco de dados."
mysql -uroot -p$DB_ROOT_PASSWORD -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO 'glpi'@'localhost' IDENTIFIED BY '$DB_PASSWORD';" || erro "Não foi possível conceder permissões ao usuário glpi."
mysql -uroot -p$DB_ROOT_PASSWORD -e "FLUSH PRIVILEGES;" || erro "Não foi possível atualizar as permissões do banco de dados."

# Download do GLPI
wget $GLPI_URL -O /tmp/glpi.tgz || erro "Não foi possível baixar o GLPI."

# Extração dos arquivos
mkdir -p $GLPI_DIR || erro "Não foi possível criar o diretório GLPI."
tar -xvzf /tmp/glpi.tgz -C $GLPI_DIR --strip-components=1 || erro "Não foi possível extrair os arquivos do GLPI."

# Configuração das permissões
chown -R www-data:www-data $GLPI_DIR || erro "Não foi possível alterar as permissões dos arquivos do GLPI."
chmod -R 755 $GLPI_DIR || erro "Não foi possível definir as permissões dos arquivos do GLPI."

# Configuração do Apache
cat <<EOL > /etc/apache2/sites-available/glpi.conf
<VirtualHost *:80>
    ServerName glpi.localhost

    DocumentRoot /var/www/html/glpi/

    <Directory /var/www/html/glpi/public>
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog ${APACHE_LOG_DIR}/glpi_error.log
    CustomLog ${APACHE_LOG_DIR}/glpi_access.log combined

    <Directory /var/www/html/glpi/public>
        RewriteEngine On
        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteCond %{REQUEST_FILENAME} !-d
        RewriteRule ^(.*)$ index.php [QSA,L]
    </Directory>
</VirtualHost>
EOL

# Verificar a criação do arquivo de configuração
if [ ! -f /etc/apache2/sites-available/glpi.conf ]; then
  erro "O arquivo de configuração do GLPI não foi criado corretamente."
fi

# Habilitar o site do GLPI e desabilitar o site padrão do Apache
a2ensite glpi.conf || erro "Não foi possível ativar o site do GLPI."
a2dissite 000-default.conf || erro "Não foi possível desabilitar o site padrão do Apache."
a2enmod rewrite || erro "Não foi possível habilitar o módulo rewrite."

# Reiniciar o Apache para aplicar as mudanças
systemctl restart apache2 || erro "Não foi possível reiniciar o Apache."

# Configuração dos diretórios de configuração e dados do GLPI
mkdir -p $CONFIG_DIR || erro "Não foi possível criar o diretório de configuração do GLPI."
mkdir -p $VAR_DIR || erro "Não foi possível criar o diretório de dados do GLPI."
mkdir -p $LOG_DIR || erro "Não foi possível criar o diretório de logs do GLPI."

# Copiar os arquivos de configuração e dados para os novos diretórios
cp -r $GLPI_DIR/config/* $CONFIG_DIR 2>/dev/null
cp -r $GLPI_DIR/files/* $VAR_DIR 2>/dev/null

# Criar o arquivo local_define.php
cat <<EOL > $CONFIG_DIR/local_define.php
<?php
define('GLPI_VAR_DIR', '$VAR_DIR');
define('GLPI_LOG_DIR', '$LOG_DIR');
EOL

# Criar o arquivo downstream.php
cat <<EOL > $GLPI_DIR/inc/downstream.php
<?php
define('GLPI_CONFIG_DIR', '$CONFIG_DIR');

if (file_exists(GLPI_CONFIG_DIR . '/local_define.php')) {
   require_once GLPI_CONFIG_DIR . '/local_define.php';
}
EOL

# Criar o arquivo .htaccess
HTACCESS_FILE="$GLPI_DIR/install/.htaccess"
echo "Criando arquivo .htaccess em $HTACCESS_FILE"
mkdir -p "$(dirname "$HTACCESS_FILE")" || erro "Não foi possível criar o diretório para o arquivo .htaccess."

cat <<EOL > $HTACCESS_FILE
<IfModule mod_authz_core.c>
    Require local
</IfModule>
<IfModule !mod_authz_core.c>
    order deny, allow
    deny from all
    allow from 127.0.0.1
    allow from ::1
</IfModule>
ErrorDocument 403 "<p><b>Restricted area.</b><br />Only local access allowed.<br />Check your configuration or contact your administrator.</p>"
EOL

if [ ! -f "$HTACCESS_FILE" ]; then
  erro "Não foi possível criar o arquivo .htaccess."
fi

# Ajustar permissões dos diretórios de configuração e dados
chown -R www-data:www-data $CONFIG_DIR || erro "Não foi possível alterar as permissões do diretório de configuração."
chown -R www-data:www-data $VAR_DIR || erro "Não foi possível alterar as permissões do diretório de dados."
chown -R www-data:www-data $LOG_DIR || erro "Não foi possível alterar as permissões do diretório de logs."
chmod -R 755 $CONFIG_DIR || erro "Não foi possível definir as permissões do diretório de configuração."
chmod -R 755 $VAR_DIR || erro "Não foi possível definir as permissões do diretório de dados."
chmod -R 755 $LOG_DIR || erro "Não foi possível definir as permissões do diretório de logs."

# Remover o arquivo de instalação
# rm -f $GLPI_DIR/install/install.php || echo "Não foi possível remover o arquivo install.php."

# Reiniciar o Apache para aplicar todas as mudanças
systemctl restart apache2 || erro "Não foi possível reiniciar o Apache."

# Exibir a URL de acesso
IP_ADDRESS=$(obter_ip_local)
echo "Instalação concluída. Acesse o GLPI em http://$IP_ADDRESS/"
