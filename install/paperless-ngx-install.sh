#!/usr/bin/env bash

# Copyright (c) 2021-2024 tteck
# Author: tteck (tteckster)
# License: MIT
# https://github.com/tteck/Proxmox/raw/main/LICENSE


# Load external functions, set up colors and initial configurations

# Exclude for script check: https://www.shellcheck.net
# shellcheck source=/dev/null
source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# Initialize global variables for paperless/PostgreSQL configuration
DB_PORT="5432"
DB_TIMEZONE="UTC"
OCR_LANGUAGE="eng"
DB_REMOTE="n"

spacer="   > "
sub_spacer="     - "

# Function to install system dependencies
install_dependencies() {
    install_postgresql
    msg_info "Installing Dependencies (Patience)"
    $STD apt -y install --no-install-recommends \
      redis \
      build-essential \
      imagemagick \
      fonts-liberation \
      optipng \
      gnupg \
      libpq-dev \
      libmagic-dev \
      mime-support \
      libzbar0 \
      poppler-utils \
      default-libmysqlclient-dev \
      automake \
      libtool \
      pkg-config \
      git \
      curl \
      libtiff-dev \
      libpng-dev \
      libleptonica-dev \
      sudo \
      mc
    msg_ok "Installed Dependencies"
}

# Function to optionally install PostgreSQL
install_postgresql() {
    read -r -p "${spacer}Do you want to install PostgreSQL or connect to an already installed instance? <yes to install/no to connect> " POSTGRES_INSTALL
    if [[ "${POSTGRES_INSTALL,,}" =~ ^(y|Y|Yes|yEs|yeS|YES|Y)$ ]]; then  
        msg_info "Installing PostgreSQL (Patience)"
        $STD apt -y install --no-install-recommends postgresql
        msg_ok "Installed PostgreSQL"
    fi
}

# Function to install Python dependencies
install_python_dependencies() {
    msg_info "Installing Python3 Dependencies (Patience)"
    $STD apt -y install --no-install-recommends \
      python3 \
      python3-pip \
      python3-dev \
      python3-setuptools \
      python3-wheel
    msg_ok "Installed Python3 Dependencies"
}

# Function to install OCR dependencies and potentially additional languages
install_ocr_dependencies() {
    msg_info "Installing OCR Dependencies (Patience)"
    $STD apt -y install --no-install-recommends \
      unpaper \
      ghostscript \
      icc-profiles-free \
      qpdf \
      liblept5 \
      libxml2 \
      pngquant \
      zlib1g \
      tesseract-ocr \
      tesseract-ocr-eng

    msg_ok "Installed OCR Dependencies"

    install_additional_ocr_languages
}

# Helper function to handle additional OCR language installation
install_additional_ocr_languages() {
    read -r -p "${spacer}Would you like to install additional languages for OCR (English is installed by default)? <y/N> " prompt

    if [[ "${prompt,,}" =~ ^(y|Y|Yes|yEs|yeS|YES|Y)$ ]]; then 
        echo "${sub_spacer}Set the required OCR language codes (For a list of language codes see https://tesseract-ocr.github.io/tessdoc/Data-Files.html)"
        read -r -p "${sub_spacer}Enter the required OCR languages separated by commas (e.g. deu,fra,spa): " prompt
        msg_info "Installing additional OCR Languages"
        IFS=',' read -ra LANGUAGE_ARRAY <<< "$prompt"
        for LANGUAGE_CODE in "${LANGUAGE_ARRAY[@]}"; do
            $STD apt -y install --no-install-recommends "tesseract-ocr-$LANGUAGE_CODE"
            OCR_LANGUAGE+="+$LANGUAGE_CODE"
        done
        msg_ok "Installed additional OCR Languages"
    fi
}

# Function to install JBIG2 encoder for optimizing scanned PDF files
install_jbig2() {
    msg_info "Installing JBIG2 (Patience)"
    $STD git clone https://github.com/agl/jbig2enc /opt/jbig2enc
    cd /opt/jbig2enc || exit 1
    $STD bash ./autogen.sh
    $STD bash ./configure
    $STD make
    $STD make install
    rm -rf /opt/jbig2enc
    msg_ok "Installed JBIG2"
}

# Function to install Paperless-ngx
install_paperless_ngx() {
    msg_info "Installing Paperless-ngx (Patience)"
    local Paperlessngx
    Paperlessngx=$(wget -q https://github.com/paperless-ngx/paperless-ngx/releases/latest -O - | grep "title>Release" | cut -d " " -f 5)
    $STD wget https://github.com/paperless-ngx/paperless-ngx/releases/download/"$Paperlessngx"/paperless-ngx-"$Paperlessngx".tar.xz -P /opt
    $STD tar -xf /opt/paperless-ngx-"$Paperlessngx".tar.xz -C /opt/
    mv /opt/paperless-ngx /opt/paperless
    rm /opt/paperless-ngx-"$Paperlessngx".tar.xz
    cd /opt/paperless/ || exit 1
    $STD pip install --upgrade pip
    $STD pip install -r /opt/paperless/requirements.txt
    curl -s -o /opt/paperless/paperless.conf https://raw.githubusercontent.com/paperless-ngx/paperless-ngx/main/paperless.conf.example
    mkdir -p /opt/paperless/{consume,data,media,static}
    echo "${Paperlessngx}" >"/opt/${APPLICATION}_version.txt"

    sed -i -e 's|#PAPERLESS_REDIS=redis://localhost:6379|PAPERLESS_REDIS=redis://localhost:6379|' /opt/paperless/paperless.conf
    sed -i -e "s|#PAPERLESS_CONSUMPTION_DIR=../consume|PAPERLESS_CONSUMPTION_DIR=/opt/paperless/consume|" /opt/paperless/paperless.conf
    sed -i -e "s|#PAPERLESS_DATA_DIR=../data|PAPERLESS_DATA_DIR=/opt/paperless/data|" /opt/paperless/paperless.conf
    sed -i -e "s|#PAPERLESS_MEDIA_ROOT=../media|PAPERLESS_MEDIA_ROOT=/opt/paperless/media|" /opt/paperless/paperless.conf
    sed -i -e "s|#PAPERLESS_STATICDIR=../static|PAPERLESS_STATICDIR=/opt/paperless/static|" /opt/paperless/paperless.conf
    sed -i -e "s|#PAPERLESS_OCR_LANGUAGE=eng|PAPERLESS_OCR_LANGUAGE=$OCR_LANGUAGE|" /opt/paperless/paperless.conf

    msg_ok "Installed Paperless-ngx"
}

# Function to install the Natural Language Toolkit (NLTK)
install_nltk() {
    msg_info "Installing Natural Language Toolkit (Patience)"
    $STD python3 -m nltk.downloader -d /usr/share/nltk_data all
    msg_ok "Installed Natural Language Toolkit"
}

# Function to configure Paperless-ngx settings in the paperless.conf file
configure_paperless_settings() {
    
    prompt_postgresql_config
    
    read -r -p "${spacer}Enter your timezone (e.g., 'Europe/Vienna', 'America/New_York' or leave empty for UTC): " input_timezone
    DB_TIMEZONE="${input_timezone:-$DB_TIMEZONE}"

    msg_info "Configure paperless.conf settings"

    # Set database and other environment-specific settings
    sed -i -e "s|#PAPERLESS_DBHOST=localhost|PAPERLESS_DBHOST=$DB_HOST|" /opt/paperless/paperless.conf
    sed -i -e "s|#PAPERLESS_DBPORT=5432|PAPERLESS_DBPORT=$DB_PORT|" /opt/paperless/paperless.conf
    sed -i -e "s|#PAPERLESS_DBNAME=paperless|PAPERLESS_DBNAME=$DB_NAME|" /opt/paperless/paperless.conf
    sed -i -e "s|#PAPERLESS_DBUSER=paperless|PAPERLESS_DBUSER=$DB_USER|" /opt/paperless/paperless.conf
    sed -i -e "s|#PAPERLESS_DBPASS=paperless|PAPERLESS_DBPASS=$DB_PASS|" /opt/paperless/paperless.conf
    sed -i -e "s|#PAPERLESS_SECRET_KEY=change-me|PAPERLESS_SECRET_KEY=$SECRET_KEY|" /opt/paperless/paperless.conf
    sed -i -e "s|#PAPERLESS_TIMEZONE=UTC|PAPERLESS_TIMEZONE=$DB_TIMEZONE|" /opt/paperless/paperless.conf
    
    msg_ok "Configured paperless.conf settings"

    # Additional configurations based on user input
    read -r -p "${spacer}Enter paperless URL (e.g. https://paperless.yourdomain.com, leave empty for default setting) ? " PAPERLESS_URL
    if [[ -n $PAPERLESS_URL ]]; then
      sed -i -e "s|#PAPERLESS_URL=https://example.com|PAPERLESS_URL=$PAPERLESS_URL|" /opt/paperless/paperless.conf
    fi

    read -r -p "${spacer}Would you like to enable HTTP remote user (Default 'false')? <y/N> " enable_http_remote
    if [[ "${enable_http_remote,,}" =~ ^(y|Y|Yes|yEs|yeS|YES|Y)$ ]]; then 
      sed -i -e "s|#PAPERLESS_ENABLE_HTTP_REMOTE_USER=false|PAPERLESS_ENABLE_HTTP_REMOTE_USER=true|" /opt/paperless/paperless.conf
      read -r -p "${sub_spacer}Enter Header Name for remote user: " remote_user_header
      echo "PAPERLESS_HTTP_REMOTE_USER_HEADER_NAME=$remote_user_header" >> /opt/paperless/paperless.conf
    fi

    read -r -p "${spacer}Would you like to allow importing PDFs with invalidated signature (Default 'false')? <y/N> " allow_invalid_pdf
    if [[ "${allow_invalid_pdf,,}" =~ ^(y|Y|Yes|yEs|yeS|YES|Y)$ ]]; then 
      sed -i -e 's|#PAPERLESS_OCR_USER_ARGS={}|PAPERLESS_OCR_USER_ARGS={"invalidate_digital_signatures": true}|' /opt/paperless/paperless.conf
    fi

    read -r -p "${spacer}Would you like to enable TIKA (Default 'false')? <y/N> " enable_tika
    if [[ "${enable_tika,,}" =~ ^(y|Y|Yes|yEs|yeS|YES|Y)$ ]]; then 
      sed -i -e "s|#PAPERLESS_TIKA_ENABLED=false|PAPERLESS_TIKA_ENABLED=true|" /opt/paperless/paperless.conf
    fi   
}

# Helper Function to prompt user for PostgreSQL configuration
prompt_postgresql_config() {
    read -r -p "${spacer}Would you like to set your own PostgreSQL credentials? <y/N> " 
    if [[ "${prompt,,}" =~ ^(y|Y|Yes|yEs|yeS|YES|Y)$ ]]; then
        DB_REMOTE="y"
        read -r -p "${sub_spacer}Host address (FQDN or IP): " DB_HOST
        read -r -p "${sub_spacer}Port (leave empty for 5432): " input_port
        DB_PORT=${input_port:-$DB_PORT}
        read -r -p "${sub_spacer}Paperless database name: " DB_NAME
        read -r -p "${sub_spacer}User name: " DB_USER
        read -r -p "${sub_spacer}Password: " DB_PASS
        read -r -p "${sub_spacer}Secret key: " SECRET_KEY
    else
        # Default PostgreSQL setup
        DB_HOST="localhost"
        DB_NAME="paperlessdb"
        DB_USER="paperless"
        DB_PASS="$(openssl rand -base64 18 | cut -c1-13)"
        SECRET_KEY="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 32)"
    fi
}

# Function to configure PostgreSQL database and user
configure_postgresql_database() {
    msg_info "Setting up PostgreSQL database"


    if [[ $DB_REMOTE = "n" ]]; then
        # Create user role and database
        $STD sudo -u postgres psql -c "CREATE ROLE $DB_USER WITH LOGIN PASSWORD '$DB_PASS';"
        $STD sudo -u postgres psql -c "CREATE DATABASE $DB_NAME WITH OWNER $DB_USER ENCODING 'UTF8' TEMPLATE template0;"
        $STD sudo -u postgres psql -c "ALTER ROLE $DB_USER SET client_encoding TO 'utf8';"
        $STD sudo -u postgres psql -c "ALTER ROLE $DB_USER SET default_transaction_isolation TO 'read committed';"
        $STD sudo -u postgres psql -c "ALTER ROLE $DB_USER SET timezone TO '$DB_TIMEZONE';"
    else
        echo "assure databse is correct created ..."
        # Nachricht anzeigen
        echo "Press any key to continue..."

        # Auf Tasteneingabe warten
        read -n 1 -s

        # Nach Tastendruck
        echo "Continuing..."
    fi
    {
        echo -e "Paperless-ngx Database User: \e[32m$DB_USER\e[0m"
        echo -e "Paperless-ngx Database Password: \e[32m$DB_PASS\e[0m"
        echo -e "Paperless-ngx Database Name: \e[32m$DB_NAME\e[0m" 
    } >>~/paperless.creds

    msg_ok "Configured PostgreSQL database"
}

# Function to migrate the database
migrate_database() {
    msg_info "Running database migrations"
    cd /opt/paperless/src || exit 1
    $STD python3 manage.py migrate
    msg_ok "Database migrations completed"
}

# Function to set up admin Paperless-ngx User & Password
setup_paperless_admin_user() {
    local default_username="admin"
    local default_password="$DB_PASS"

    # Prompt the user for custom admin username and password
    read -r -p "${spacer}Enter Paperless admin username (Enter for default: $default_username): " admin_username
    read -r -p "${spacer}Enter Paperless admin password (Enter for default: $default_password): " admin_password

    msg_info "Setting up admin Paperless-ngx User & Password"

    # Use default values if the user did not provide any input
    admin_username=${admin_username:-$default_username}
    admin_password=${admin_password:-$default_password}

    # Create the admin user with the provided or default username and password
    cat <<EOF | python3 /opt/paperless/src/manage.py shell
from django.contrib.auth import get_user_model
UserModel = get_user_model()
user = UserModel.objects.create_user('$admin_username', password='$admin_password')
user.is_superuser = True
user.is_staff = True
user.save()
EOF

    # Save the admin credentials to a file
    {
      echo ""
      echo -e "Paperless-ngx WebUI User: \e[32m$admin_username\e[0m"
      echo -e "Paperless-ngx WebUI Password: \e[32m$admin_password\e[0m"
      echo "" 
    } >>~/paperless.creds

    msg_ok "Set up admin Paperless-ngx User & Password"
}

# Function to install Adminer (Optional) 
install_adminer() {
    read -r -p "${spacer}Would you like to add Adminer? <y/N> " prompt
    if [[ "${prompt,,}" =~ ^(y|Y|Yes|yEs|yeS|YES|Y)$ ]]; then
    msg_info "Installing Adminer"
    $STD apt -y install adminer
    $STD a2enconf adminer
    systemctl reload apache2
    IP=$(hostname -I | awk '{print $1}')
    
    {
        echo ""
        echo -e "Adminer Interface: \e[32m$IP/adminer/\e[0m"
        echo -e "Adminer System: \e[32mPostgreSQL\e[0m"
        echo -e "Adminer Server: \e[32mlocalhost:5432\e[0m"
        echo -e "Adminer Username: \e[32m$DB_USER\e[0m"
        echo -e "Adminer Password: \e[32m$DB_PASS\e[0m"
        echo -e "Adminer Database: \e[32m$DB_NAME\e[0m" 
    } >>~/paperless.creds
    msg_ok "Installed Adminer"
    fi
}

# Function to create systemd services
create_services() {
    msg_info "Creating Services"
    
    cat <<EOF >/etc/systemd/system/paperless-scheduler.service
[Unit]
Description=Paperless Celery beat
Requires=redis.service

[Service]
WorkingDirectory=/opt/paperless/src
ExecStart=celery --app paperless beat --loglevel INFO

[Install]
WantedBy=multi-user.target
EOF

    cat <<EOF >/etc/systemd/system/paperless-task-queue.service
[Unit]
Description=Paperless Celery Workers
Requires=redis.service

[Service]
WorkingDirectory=/opt/paperless/src
ExecStart=celery --app paperless worker --loglevel INFO

[Install]
WantedBy=multi-user.target
EOF

    cat <<EOF >/etc/systemd/system/paperless-consumer.service
[Unit]
Description=Paperless consumer
Requires=redis.service

[Service]
WorkingDirectory=/opt/paperless/src
ExecStart=python3 manage.py document_consumer

[Install]
WantedBy=multi-user.target
EOF

    cat <<EOF >/etc/systemd/system/paperless-webserver.service
[Unit]
Description=Paperless webserver
After=network.target
Wants=network.target
Requires=redis.service

[Service]
WorkingDirectory=/opt/paperless/src
ExecStart=/usr/local/bin/gunicorn -c /opt/paperless/gunicorn.conf.py paperless.asgi:application

[Install]
WantedBy=multi-user.target
EOF
    sed -i -e 's/rights="none" pattern="PDF"/rights="read|write" pattern="PDF"/' /etc/ImageMagick-6/policy.xml

    systemctl daemon-reload

    read -r -p "${spacer}Do you want to start the Paperless services now (Default: yes)? <y/N> " start_services
    start_services=${start_services:-y}

    if [[ "${start_services,,}" =~ ^(y|Y|Yes|yEs|yeS|YES|Y|)$ ]]; then
        $STD systemctl enable --now paperless-consumer paperless-webserver paperless-scheduler paperless-task-queue.service
        msg_ok "Started and enabled Services"
    else
        $STD systemctl enable paperless-consumer paperless-webserver paperless-scheduler paperless-task-queue.service
        msg_ok "Services enabled but not started"
    fi
}

# Function for customizing MOTD and SSH
customize_motd_ssh() {
    msg_info "Customizing MOTD and SSH"
    motd_ssh
    customize
    msg_ok "Customized MOTD and SSH"
}

# Function for cleaning up the system
cleanup_system() {
    msg_info "Cleaning up"
    rm -rf /opt/paperless/docker
    $STD apt autoremove
    $STD apt autoclean
    msg_ok "Cleaned"
}

# Main program execution
install_dependencies          # Install necessary system dependencies
install_python_dependencies   # Install Python3 and related dependencies
install_ocr_dependencies      # Install OCR (Optical Character Recognition) dependencies and optional languages
install_jbig2                 # Install JBIG2 encoder for optimizing scanned PDF files
install_paperless_ngx         # Download and install Paperless-ngx
install_nltk                  # Install Natural Language Toolkit (NLTK)
configure_paperless_settings  # Configure Paperless-ngx settings in the paperless.conf file
configure_postgresql_database # Configure PostgreSQL database and user
migrate_database              # Run the database migration step
setup_paperless_admin_user    # Setup the admin Paperless-ngx user
install_adminer               # Optionally install Adminer
create_services               # Create and manage the systemd services for Paperless-ngx
customize_motd_ssh            # Customize MOTD (Message of the Day) and SSH settings
cleanup_system                # Clean up the system by removing temporary files and unnecessary packages
