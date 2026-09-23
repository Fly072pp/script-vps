#!/bin/bash
set -e

# Vérification root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Exécute ce script en root (sudo ./nas.sh)"
  exit 1
fi

echo "=== Onboarding NAS Pi Zero 2W ==="
read -p "Nom d'utilisateur [axel]: " CONFIG_USER
CONFIG_USER=${CONFIG_USER:-axel}

read -p "Nom du partage Samba [NAS]: " SHARE_NAME
SHARE_NAME=${SHARE_NAME:-NAS}

read -s -p "Mot de passe unique (Samba, Nginx & Web) : " CONFIG_PASS
echo ""

SHARE_DIR="/srv/nas"
mkdir -p "$SHARE_DIR/$SHARE_NAME"
chown -R "$CONFIG_USER:$CONFIG_USER" "$SHARE_DIR"
chmod -R 775 "$SHARE_DIR"

echo "📦 Installation des paquets..."
apt update
apt install -y samba curl glances acl nginx apache2-utils python3-flask

echo "📁 Configuration Samba (smbd uniquement)..."
SMBCONF="/etc/samba/smb.conf"
cat <<EOF > "$SMBCONF"
[global]
   workgroup = WORKGROUP
   security = user
   map to guest = bad user

[$SHARE_NAME]
   path = $SHARE_DIR/$SHARE_NAME
   browsable = yes
   writeable = yes
   read only = no
   guest ok = no
   valid users = $CONFIG_USER
   create mask = 0664
   directory mask = 0775
EOF

systemctl enable smbd
systemctl restart smbd
systemctl stop nmbd 2>/dev/null || true
systemctl disable nmbd 2>/dev/null || true
(echo "$CONFIG_PASS"; echo "$CONFIG_PASS") | smbpasswd -s -a "$CONFIG_USER" || true

echo "📊 Configuration Glances..."
cat <<EOF > /etc/systemd/system/glances.service
[Unit]
Description=Glances Web Monitoring
After=network.target network-online.target

[Service]
ExecStart=/usr/bin/python3 /usr/bin/glances -w -b 127.0.0.1 -p 61208
Restart=always
RestartSec=5
User=$CONFIG_USER

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl reset-failed glances.service 2>/dev/null || true
systemctl enable glances.service
systemctl restart glances.service

echo "📁 Configuration File Browser (racine /srv/nas)..."
cat <<EOF > /etc/systemd/system/filebrowser.service
[Unit]
Description=File Browser
After=network.target

[Service]
ExecStart=/usr/local/bin/filebrowser -r /srv/nas -d /etc/filebrowser.db -a 127.0.0.1 -p 8080
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable filebrowser.service
systemctl restart filebrowser.service

echo "🌐 Configuration Nginx..."
mkdir -p /etc/nginx
htpasswd -b -c /etc/nginx/.htpasswd "$CONFIG_USER" "$CONFIG_PASS" 2>/dev/null || htpasswd -b /etc/nginx/.htpasswd "$CONFIG_USER" "$CONFIG_PASS"

cat <<EOF > /etc/nginx/sites-available/nas
server {
    listen 80;
    server_name _;

    auth_basic "Restricted Access";
    auth_basic_user_file /etc/nginx/.htpasswd;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location /glances/ {
        proxy_pass http://127.0.0.1:61208/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600;
    }
}
EOF

ln -sf /etc/nginx/sites-available/nas /etc/nginx/sites-enabled/nas
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

echo "✅ Déploiement terminé et nettoyé !"
