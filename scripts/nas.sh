#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "❌ Exécute ce script avec sudo : sudo ./setup_nas_unified.sh"
  exit 1
fi

# --- ONBOARDING / CONFIGURATION INITIALE ---
echo "=== Onboarding NAS Pi Zero 2W ==="
read -p "Nom d'utilisateur [pi]: " CONFIG_USER
CONFIG_USER=${CONFIG_USER:-pi}

read -p "Nom du partage Samba [partage]: " SHARE_NAME
SHARE_NAME=${SHARE_NAME:-partage}

read -s -p "Mot de passe unique (Samba & Web) : " CONFIG_PASS
echo ""
if [ -z "$CONFIG_PASS" ]; then
  CONFIG_PASS="nasadmin"
  echo "⚠️ Mot de passe vide détecté, 'nasadmin' utilisé par défaut."
fi

SHARE_DIR="/srv/nas/$SHARE_NAME"
WEB_DIR="/var/www/nas-dashboard"

echo "📦 Installation des paquets..."
apt update && apt upgrade -y
apt install -y samba samba-common-bin curl glances acl nginx apache2-utils

echo "📁 Création des dossiers..."
mkdir -p "$SHARE_DIR" "$WEB_DIR"
chown -R "$CONFIG_USER":"$CONFIG_USER" /srv/nas
chmod -R 775 "$SHARE_DIR"

# Samba
SMBCONF="/etc/samba/smb.conf"
cat <<EOF >> "$SMBCONF"

[$SHARE_NAME]
   path = $SHARE_DIR
   browsable = yes
   writeable = yes
   read only = no
   guest ok = no
   valid users = $CONFIG_USER
   create mask = 0664
   directory mask = 0775
EOF
systemctl restart smbd nmbd
systemctl enable smbd nmbd
(echo "$CONFIG_PASS"; echo "$CONFIG_PASS") | smbpasswd -s -a "$CONFIG_USER"

# File Browser
curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
FB_DB="/etc/filebrowser.db"
filebrowser config init --database "$FB_DB" || true
filebrowser config set --database "$FB_DB" --address 127.0.0.1 --port 8080 --root /srv/nas --baseurl /files
filebrowser users add --database "$FB_DB" "$CONFIG_USER" "$CONFIG_PASS" --perm.admin || true

cat <<EOF > /etc/systemd/system/filebrowser.service
[Unit]
Description=File Browser
After=network.target network-online.target

[Service]
User=root
ExecStart=/usr/local/bin/filebrowser -d /etc/filebrowser.db
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Glances
cat <<EOF > /etc/systemd/system/glances.service
[Unit]
Description=Glances Web Monitoring
After=network.target network-online.target

[Service]
ExecStart=/usr/bin/glances -w -b 127.0.0.1 --port 61208
Restart=always
RestartSec=5
User=$CONFIG_USER

[Install]
WantedBy=multi-user.target
EOF

# HTPasswd pour Nginx
htpasswd -bc /etc/nginx/.htpasswd "$CONFIG_USER" "$CONFIG_PASS"

# Dashboard Web Unifié (HTML léger)
cat <<EOF > "$WEB_DIR/index.html"
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <title>NAS Dashboard - Pi Zero 2W</title>
    <style>
        body { font-family: system-ui, sans-serif; background: #0f172a; color: #f8fafc; margin: 0; padding: 20px; }
        .container { max-width: 1000px; margin: auto; }
        header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; }
        .grid { display: grid; grid-template-columns: 1fr; gap: 20px; }
        .card { background: #1e293b; padding: 20px; border-radius: 12px; box-shadow: 0 4px 6px rgba(0,0,0,0.3); }
        iframe { width: 100%; height: 450px; border: none; border-radius: 8px; background: #000; }
        a.btn { display: inline-block; background: #3b82f6; color: white; padding: 10px 20px; text-decoration: none; border-radius: 6px; font-weight: bold; margin-bottom: 15px; }
        a.btn:hover { background: #2563eb; }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>⚡ Pi Zero 2W NAS</h1>
            <span>Utilisateur: <strong>$CONFIG_USER</strong></span>
        </header>
        <div class="grid">
            <div class="card">
                <h2>📁 Gestionnaire de fichiers</h2>
                <a href="/files/" class="btn" target="_blank">Ouvrir File Browser en plein écran ↗</a>
                <iframe src="/files/"></iframe>
            </div>
            <div class="card">
                <h2>📊 Monitoring système (Glances)</h2>
                <iframe src="/glances/"></iframe>
            </div>
        </div>
    </div>
</body>
</html>
EOF

# Nginx Reverse Proxy
cat <<EOF > /etc/nginx/sites-available/nas
server {
    listen 80 default_server;
    server_name _;

    auth_basic "Restricted Access - NAS Onboarded";
    auth_basic_user_file /etc/nginx/.htpasswd;

    location / {
        root $WEB_DIR;
        index index.html;
    }

    location /files/ {
        proxy_pass http://127.0.0.1:8080/files/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_buffering off;
    }

    location /glances/ {
        proxy_pass http://127.0.0.1:61208/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

ln -sf /etc/nginx/sites-available/nas /etc/nginx/sites-enabled/default
rm -f /etc/nginx/sites-enabled/default.bak || true
nginx -t

echo "🚀 Activation des services et persistance au redémarrage..."
systemctl daemon-reload
systemctl enable --now filebrowser.service
systemctl enable --now glances.service
systemctl enable --now nginx
systemctl restart nginx

IP_LOCAL=$(hostname -I | awk '{print $1}')
echo ""
echo "✅ Configuration unifiée et persistance activées !"
echo "🌐 URL unique : http://${IP_LOCAL}"
echo "🔒 Connexion  : Identifiants définis lors de l'onboarding ($CONFIG_USER)"
