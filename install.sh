#!/bin/bash

export DEBIAN_FRONTEND=noninteractive

# defaults 
HOSTNAME="localhost"
USERNAME="admin"
PASSWORD="password123"
EMAIL="test@example.com"
STORAGEACCOUNT=""
CONTAINER=""

for i in "$@"
do
	case $i in
		--hostname=*)
		HOSTNAME="${i#*=}" 
		;;
		--username=*)
		USERNAME="${i#*=}"
		;;
		--password=*)
		PASSWORD="${i#*=}"
		;;
		--email=*)
		EMAIL="${i#*=}"
		;;
		--storageaccount=*)
		STORAGEACCOUNT="${i#*=}"
		;;	
		--container=*)
		CONTAINER="${i#*=}"
		;;			
		*)
		;;
	esac
done

#Create apt-get wrapper to let apt-get commands to execute sequentially
tee -a /usr/local/sbin << EOF
#!/bin/bash
i=0
tput sc
while fuser /var/lib/dpkg/lock >/dev/null 2>&1 ; do
    case $(($i % 4)) in
        0 ) j="-" ;;
        1 ) j="\\" ;;
        2 ) j="|" ;;
        3 ) j="/" ;;
    esac
    tput rc
    echo -en "\r[$j] Waiting for other software managers to finish..." 
    sleep 0.5
    ((i=i+1))
done 
/usr/bin/apt-get "$@"
EOF

sleep 20s

#Install Dependencies
apt-get update
apt-get upgrade -y
apt-get install -y  php8.1 php8.1-cli php8.1-common php8.1-imap php8.1-redis php8.1-snmp php8.1-xml php8.1-zip php8.1-mbstring php8.1-curl php8.1-gd php8.1-mysql apache2 mariadb-server certbot nfs-common python3-certbot-apache unzip php-intl

#Create the database and user
DBPASSWORD=$(openssl rand -base64 14)
mysql -e "CREATE DATABASE nextcloud;GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextcloud'@'localhost' IDENTIFIED BY '$DBPASSWORD';FLUSH PRIVILEGES;"

#Mount the file storage
mkdir -p /mnt/filesx
echo "$STORAGEACCOUNT.privatelink.blob.core.windows.net:/$STORAGEACCOUNT/$CONTAINER  /mnt/filesx    nfs defaults,sec=sys,vers=3,nolock,proto=tcp,nofail    0 0" >> /etc/fstab 
mount /mnt/filesx


#Download Nextcloud
cd /var/www/html
# wget https://download.nextcloud.com/server/releases/nextcloud-24.0.1.zip
wget https://download.nextcloud.com/server/releases/nextcloud-28.0.1.zip
# unzip nextcloud-24.0.1.zip
unzip nextcloud-28.0.1.zip
chown -R root:root nextcloud
cd nextcloud

#Install Nextcloud
php occ  maintenance:install --database "mysql" --database-name "nextcloud"  --database-user "nextcloud" --database-pass "$DBPASSWORD" --admin-user "$USERNAME" --admin-pass "$PASSWORD" --data-dir /mnt/filesx
sed -i "s/0 => 'localhost',/0 => '$HOSTNAME',/g" ./config/config.php
sed -i "s/  'overwrite.cli.url' => 'https:\/\/localhost',/  'overwrite.cli.url' => 'http:\/\/$HOSTNAME',/g" ./config/config.php

cd ..
chown -R www-data:www-data nextcloud
chown -R www-data:www-data /mnt/filesx

#Configure Apache
tee -a /etc/apache2/sites-available/nextcloud.conf << EOF
<VirtualHost *:80>
ServerName $HOSTNAME
DocumentRoot /var/www/html/nextcloud

<Directory /var/www/html/nextcloud/>
 Require all granted
 Options FollowSymlinks MultiViews
 AllowOverride All
 <IfModule mod_dav.c>
 Dav off
 </IfModule>
</Directory>

ErrorLog /var/log/apache2/$HOSTNAME.error_log
CustomLog /var/log/apache2/$HOSTNAME.access_log common
</VirtualHost>
EOF

a2ensite nextcloud.conf
a2enmod rewrite

#Obtain a Certificate from Let's Encrypt
certbot run -d $HOSTNAME --agree-tos --apache -m $EMAIL -n

#Apache additional security settings ()
sed -i '/ErrorLog/i \
<IfModule mod_headers.c>\
Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains"\
Header always set Referrer-Policy "strict-origin-when-cross-origin"\
Header always set X-Content-Type-Options "nosniff"\
Header always set X-Frame-Options "SAMEORIGIN"\
</IfModule>\
\
SSLEngine on\
SSLOptions +StrictRequire\
SSLProtocol -all +TLSv1.3 +TLSv1.2\ \
' /etc/apache2/sites-available/nextcloud-le-ssl.conf

a2enmod headers

#restart Apache
systemctl restart apache2
