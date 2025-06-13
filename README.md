R-studioConf
Bash script to configure RStudio and Nginx reverse proxy

Table of Contents
Overview
Features
Requirements
Installation
Configuration
Usage
How it Works
Troubleshooting
Contributing
License
Overview
R-studioConf is an automated bash script designed to streamline the setup of an RStudio Server environment, protected behind an Nginx reverse proxy. This project aims to simplify the deployment of secure, production-ready RStudio instances for data science teams, researchers, and organizations.

Features
Automated installation and configuration of RStudio Server
Automated setup of Nginx as a secure reverse proxy
Support for SSL/TLS (HTTPS) with self-signed certificates or integration with Let’s Encrypt
Customizable configuration options for both RStudio and Nginx
User management and access control setup
Error handling and informative logging
Modular and easy to extend
Requirements
Operating System: Ubuntu 20.04+ (other Debian-based distros may work)
Root/Sudo Access: Required for installing system packages and modifying server configuration
Internet Connection: For downloading software packages
Dependencies
bash
curl or wget
apt (or the system package manager)
nginx
R (installed via script or system package manager)
rstudio-server
Installation
Clone the repository:

bash
git clone https://github.com/gsamuele78/R-studioConf.git
cd R-studioConf
Make the script executable:

bash
chmod +x configure-rstudio-nginx.sh
Run the script:

bash
sudo ./configure-rstudio-nginx.sh
Note: The script must be run with root privileges to install and configure system packages.

Configuration
Script Variables:
The script includes variables at the top for customizing RStudio and Nginx settings (such as port numbers, SSL certificate paths, domain name, etc.).
SSL/TLS:
By default, the script generates a self-signed certificate. For production, update the script or follow the prompts to use Let’s Encrypt.
Firewall:
Ensure that required ports (default 80 for HTTP, 443 for HTTPS) are open.
Usage
After running the script:

Access RStudio at https://your-server-domain/
Login with the user credentials as configured during the installation process
Nginx will forward connections securely to the RStudio Server
How it Works
R and RStudio Installation:
The script checks for R and RStudio Server, installing them if missing.
Nginx Installation and Configuration:
Installs Nginx and sets it up as a reverse proxy, forwarding HTTPS requests to the RStudio Server running on a specified port.
SSL/TLS Setup:
Creates or configures SSL certificates for secure access.
Service Management:
Ensures both RStudio Server and Nginx are started and enabled at boot.
Troubleshooting
Port Conflicts:
Ensure no other services are using the same ports as RStudio or Nginx.
Permissions:
The script must be run as root to modify system configurations.
Logs:
Check /var/log/nginx/error.log and rstudio-server logs for issues.
Contributing
Contributions are welcome! Please open issues or pull requests for improvements, bug fixes, or feature requests.

License
This project is licensed under the MIT License. See LICENSE for details.

