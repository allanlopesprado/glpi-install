#!/bin/bash

# -------------------------------------------------------------------------
# @Name: glpi-install.sh
# @Version: 1.0.0
# @Date: 2024-08-08
# @Author: Allan Lopes Prado
# @License: GNU General Public License v2.0
# @Description: Automates the installation of GLPI.
# --------------------------------------------------------------------------
# LICENSE
#
# glpi-install.sh is free software; you can redistribute and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# glpi-install.sh is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this software. If not, see <http://www.gnu.org/licenses/>.
# --------------------------------------------------------------------------

# Function to display error messages
error() {
  echo "Error: $1"
  exit 1
}

# Function to detect PHP version
detect_php_version() {
  php -r "echo PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION;"
}

# Function to get the latest GLPI version
get_latest_version() {
  curl -s https://api.github.com/repos/glpi-project/glpi/releases/latest | grep 'tag_name' | cut -d '"' -f 4 | sed 's/^v//'
}

# Function to get local IP address
get_local_ip() {
  hostname -I | awk '{print $1}'
}

# Function to adjust php.ini
adjust_php_ini() {
  PHP_VERSION=$(detect_php_version)
  if [ -z "$PHP_VERSION" ]; then
    error "Unable to detect PHP version."
  fi
  
  PHP_INI_PATH="/etc/php/$PHP_VERSION/apache2/php.ini"
  
  if [ ! -f "$PHP_INI_PATH" ]; then
    error "php.ini file not found at $PHP_INI_PATH."
  fi
  
  echo "php.ini file located: $PHP_INI_PATH"

  sed -i -e 's/^;*\s*session.cookie_httponly\s*=.*/session.cookie_httponly = 1/' \
         -e 's/^;*\s*session.cookie_secure\s*=.*/session.cookie_secure = 0/' \
         -e 's/^;*\s*session.cookie_samesite\s*=.*/session.cookie_samesite = Lax/' "$PHP_INI_PATH" || error "Unable to update php.ini."
}

# Install all dependencies
apt update && apt upgrade -y && apt install -y || error "Unable to update packages."
apt install -y apache2 bzip2 curl php php-apcu php-bcmath php-cli php-curl php-fpm php-gd php-intl php-ldap php-mbstring php-mysql php-pgsql php-xml php-zip php-imap php-bz2 mariadb-server sudo tar wget || error "Unable to install dependencies."

# Detect PHP version
PHP_VERSION=$(detect_php_version)
echo "Detected PHP version: $PHP_VERSION"

# Adjust php.ini
adjust_php_ini

# Get the latest GLPI version
GLPI_VERSION=$(get_latest_version)
if [ -z "$GLPI_VERSION" ]; then
  error "Unable to get the latest GLPI version."
fi

echo "Latest GLPI version: $GLPI_VERSION"

# Database name
DB_NAME="glpi"

# Request database user password
read -s -p "Enter the password for the database user '$DB_NAME' (used by GLPI): " DB_PASSWORD
echo

# Request root database user password
read -s -p "Enter the password for the root database user (for general database administration): " DB_ROOT_PASSWORD
echo

# Store information in a temporary file
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

# Create the .htaccess file in the GLPI directory
HTACCESS_FILE="$GLPI_DIR/.htaccess"
HTACCESS_CONTENT="RewriteBase /
RewriteEngine On
RewriteCond %{REQUEST_URI} !^/public
RewriteRule ^(.*)$ public/index.php [QSA,L]"

echo "$HTACCESS_CONTENT" > "$HTACCESS_FILE"
chmod 644 "$HTACCESS_FILE"
echo ".htaccess file successfully created at $HTACCESS_FILE."

# Load information from the temporary file
source $TEMP_FILE

# Load MySQL timezone database
mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql -u root -p$DB_ROOT_PASSWORD mysql || error "Unable to load timezone database."

# Database configuration
mysql -uroot -p$DB_ROOT_PASSWORD -e "CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || error "Unable to create database."
mysql -uroot -p$DB_ROOT_PASSWORD -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO 'glpi'@'localhost' IDENTIFIED BY '$DB_PASSWORD';" || error "Unable to grant privileges to glpi user."
mysql -uroot -p$DB_ROOT_PASSWORD -e "GRANT SELECT ON mysql.time_zone_name TO 'glpi'@'localhost';" || error "Unable to grant SELECT privileges on time_zone_name table to glpi user."
mysql -uroot -p$DB_ROOT_PASSWORD -e "FLUSH PRIVILEGES;" || error "Unable to update database privileges."

# Download GLPI
wget $GLPI_URL -O /tmp/glpi.tgz || error "Unable to download GLPI."

# Extract files
mkdir -p $GLPI_DIR || error "Unable to create GLPI directory."
tar -xvzf /tmp/glpi.tgz -C $GLPI_DIR --strip-components=1 || error "Unable to extract GLPI files."

# Set permissions
chown -R www-data:www-data $GLPI_DIR || error "Unable to change permissions for GLPI files."
chmod -R 755 $GLPI_DIR || error "Unable to set permissions for GLPI files."

# Apache configuration
cat <<EOL > /etc/apache2/sites-available/glpi.conf
<VirtualHost *:80>
    ServerName glpi.localhost

    DocumentRoot /var/www/html/glpi/public

    <Directory /var/www/html/glpi/public>
        Require all granted
        RewriteEngine On
        RewriteCond %{HTTP:Authorization} ^(.+)$
        RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteRule ^(.*)$ index.php [QSA,L]
    </Directory>
</VirtualHost>
EOL

# Check if the configuration file was created
if [ ! -f /etc/apache2/sites-available/glpi.conf ]; then
  error "GLPI configuration file not created correctly."
fi

# Enable GLPI site and disable default Apache site
a2ensite glpi.conf || error "Unable to enable GLPI site."
a2dissite 000-default.conf || error "Unable to disable default Apache site."
a2enmod rewrite || error "Unable to enable rewrite module."

# Restart Apache to apply changes
systemctl restart apache2 || error "Unable to restart Apache."

# Configure GLPI configuration and data directories
mkdir -p $CONFIG_DIR || error "Unable to create GLPI configuration directory."
mkdir -p $VAR_DIR || error "Unable to create GLPI data directory."
mkdir -p $LOG_DIR || error "Unable to create GLPI log directory."

# Copy configuration and data files to new directories
cp -r $GLPI_DIR/config/* $CONFIG_DIR 2>/dev/null
cp -r $GLPI_DIR/files/* $VAR_DIR 2>/dev/null

# Create local_define.php file
cat <<EOL > $CONFIG_DIR/local_define.php
<?php
define('GLPI_VAR_DIR', '$VAR_DIR');
define('GLPI_LOG_DIR', '$LOG_DIR');
EOL

# Create downstream.php file
cat <<EOL > $GLPI_DIR/inc/downstream.php
<?php
define('GLPI_CONFIG_DIR', '$CONFIG_DIR');

if (file_exists(GLPI_CONFIG_DIR . '/local_define.php')) {
   require_once GLPI_CONFIG_DIR . '/local_define.php';
}
EOL

# Adjust permissions for configuration and data directories
chown -R www-data:www-data $CONFIG_DIR || error "Unable to change permissions for configuration directory."
chown -R www-data:www-data $VAR_DIR || error "Unable to change permissions for data directory."
chown -R www-data:www-data $LOG_DIR || error "Unable to change permissions for log directory."
chmod -R 755 $CONFIG_DIR || error "Unable to set permissions for configuration directory."
chmod -R 755 $VAR_DIR || error "Unable to set permissions for data directory."
chmod -R 755 $LOG_DIR || error "Unable to set permissions for log directory."

# Conclusion
LOCAL_IP=$(get_local_ip)
echo "GLPI installation completed successfully!"
echo "Access the GLPI web interface at: http://$LOCAL_IP"
