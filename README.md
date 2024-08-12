## GLPI Installation Script for Debian
This script automates the installation and configuration of GLPI on Debian servers with Apache and MariaDB. It simplifies the setup process by performing all necessary tasks, including configuring PHP, setting up the database, and configuring GLPI with Apache.

## Prerequisites
Ensure your Debian server meets the following requirements:

- Debian 10 (Buster) or higher
- Apache
- MariaDB
- PHP (version detected automatically)

## Installation Steps

**1. Clone the Repository:**

```
git clone https://github.com/allanlopesprado/glpi-install
cd glpi-install
```

**2. Make the Script Executable:**

```
chmod +x glpi-install.sh
```

**3. Run the Script:**

```
sudo ./glpi-install.sh
```

**4. Follow the On-Screen Prompts:**

The script will prompt for database passwords and display progress information. Enter the required information as prompted.

## GLPI Configuration
During the installation, the script sets up GLPI with the following database configuration:

```
- SQL Server: localhost
- SQL User: glpi
- SQL Password: your password
```
**The password you provided when the script prompted for the GLPI database user during execution.**


## Post-Installation
**1. Access the GLPI Web Interface:**
After the installation completes, you can access GLPI at:

```
http://<YOUR_LOCAL_IP>
```

**2. Remove Installation Script for Security:**
For security reasons, please remove the installation script file install/install.php from your server. This file is no longer needed and should be deleted to prevent unauthorized access.

Run the following command to remove the file:

```
rm -rf /var/www/html/glpi/install/install.php
```

## Customization
- **Script Configuration:** You can modify the script to adjust paths or configurations according to your environment.
- **GLPI Directory:** By default, GLPI will be installed in /var/www/html/glpi. Adjust this path in the script if needed.

## Troubleshooting
- **Error Messages:** The script provides error messages for common issues such as missing files or failed operations.
- **Logs:** Check the Apache and GLPI logs for additional information if you encounter problems.

## License

[![License: GPL v2](https://img.shields.io/badge/License-GPL%20v2-blue.svg)](https://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html)

This software is licensed under the terms of GPLv2+, see LICENSE file for
details.
