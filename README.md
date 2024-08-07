# GLPI Install Script for Debian/Ubuntu
**Overview**

This script automates the installation and configuration of GLPI (Gestionnaire Libre de Parc Informatique) on Debian and Ubuntu systems. GLPI is a powerful open-source IT asset management and helpdesk solution. This script simplifies the process by handling the setup of required packages, configuration of the web server, database setup, and GLPI installation.

**Features**

- **Automated Installation:** Installs and configures Apache, PHP, MariaDB, and other dependencies.
- **GLPI Download and Setup:** Automatically downloads the latest GLPI release, extracts it, and sets the correct permissions.
- **Apache Configuration:** Configures Apache for both HTTP and HTTPS, including SSL setup with Certbot for secure connections.
- **Database Configuration:** Sets up a MariaDB database and user for GLPI with the necessary privileges.
- **PHP Configuration:** Modifies PHP settings in php.ini to improve security and performance.
- **GLPI Configuration:** Configures GLPI to use specific directories for configuration, data, and logs.
