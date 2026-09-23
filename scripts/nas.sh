#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "❌ Exécute ce script avec sudo : sudo ./nas.sh"
  exit 1
fi

# --- ONBOARDING / CONFIGURATION INITIALE ---
echo "=== Onboarding NAS Pi Zero 2W ==="
read -p "Nom d'utilisateur [pi]: " CONFIG_USER
CONFIG_USER=${CONFIG_USER:-pi}

read -p "Nom du partage Samba [partage]: " SHARE_NAME
SHARE_NAME=${SHARE_NAME:-partage}

read -s -p "Mot de passe unique (Samba, Nginx & Web) : " CONFIG_PASS
echo ""
if [ -z "$CONFIG_PASS" ]; then
  CONFIG_PASS="nasadmin"
  echo "⚠️ Mot de passe vide détecté, 'nasadmin' utilisé par défaut."
fi

SHARE_DIR="/srv/nas/$SHARE_NAME"
WEB_DIR="/var/www/nas-dashboard"

echo "📦 Installation des paquets..."
apt update && apt upgrade -y
apt install -y samba samba-common-bin curl glances acl nginx apache2-utils python3-flask

echo "📁 Création des dossiers..."
mkdir -p "$SHARE_DIR" "$WEB_DIR" /etc/samba/conf.d
chown -R "$CONFIG_USER":"$CONFIG_USER" /srv/nas /mnt/nas 2>/dev/null || true
chmod -R 775 "$SHARE_DIR"

# Samba base config
SMBCONF="/etc/samba/smb.conf"
cat <<EOF > "$SMBCONF"
[global]
   workgroup = WORKGROUP
   security = user
   map to guest = bad user

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
filebrowser users rm --database "$FB_DB" "$CONFIG_USER" 2>/dev/null || true
filebrowser users add --database "$FB_DB" "$CONFIG_USER" "$CONFIG_PASS" --perm.admin --scope /srv/nas

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
ExecStart=/usr/bin/glances -w -b 127.0.0.1 --port 61208 --prefix /glances
Restart=always
RestartSec=5
User=$CONFIG_USER

[Install]
WantedBy=multi-user.target
EOF

# Micro-API Flask pour configurer Samba depuis le panel
cat <<EOF > /usr/local/bin/nas-api.py
from flask import Flask, request, jsonify
import subprocess, configparser, os

app = Flask(__name__)
SMBCONF = '/etc/samba/smb.conf'

@app.route('/api/samba', methods=['GET', 'POST'])
def handle_samba():
    config = configparser.ConfigParser(allow_no_value=True, delimiters=('=',))
    config.read(SMBCONF)
    
    # Trouver la section partage (hors global)
    sections = [s for s in config.sections() if s.lower() != 'global']
    current_share = sections[0] if sections else 'partage'
    current_path = config.get(current_share, 'path', fallback='/srv/nas/partage') if config.has_section(current_share) else '/srv/nas/partage'

    if request.method == 'GET':
        status = subprocess.getoutput('systemctl is-active smbd')
        return jsonify({
            'share_name': current_share,
            'path': current_path,
            'status': status.strip()
        })
    
    data = request.json
    new_path = data.get('path', current_path)
    new_name = data.get('name', current_share)
    action = data.get('action') # restart, update

    if action == 'restart':
        subprocess.run(['systemctl', 'restart', 'smbd', 'nmbd'])
        return jsonify({'status': 'restarted'})

    # Mettre à jour la config smb.conf propre
    if config.has_section(current_share) and current_share != new_name:
        config.remove_section(current_share)
    
    if not config.has_section(new_name):
        config.add_section(new_name)
    
    config.set(new_name, 'path', new_path)
    config.set(new_name, 'browsable', 'yes')
    config.set(new_name, 'writeable', 'yes')
    config.set(new_name, 'read only', 'no')
    config.set(new_name, 'guest ok', 'no')
    config.set(new_name, 'create mask', '0664')
    config.set(new_name, 'directory mask', '0775')

    with open(SMBCONF, 'w') as f:
        config.write(f, space_around_delimiters=False)
    
    # Ajuster les droits du nouveau chemin si besoin
    os.makedirs(new_path, exist_ok=True)
    subprocess.run(['chown', '-R', '$CONFIG_USER:$CONFIG_USER', new_path])
    subprocess.run(['chmod', '-R', '775', new_path])
    subprocess.run(['systemctl', 'reload', 'smbd'])

    # Mettre à jour File Browser root au passage pour synchroniser
    subprocess.run(['filebrowser', 'config', 'set', '--database', '/filebrowser.db', '--root', new_path], stderr=subprocess.DEVNULL)

    return jsonify({'status': 'updated'})

if __name__ == '__main__':
    app.run(host='127.0.0.1', port=5000)
EOF
sed -i "s/\$CONFIG_USER/$CONFIG_USER/g" /usr/local/bin/nas-api.py

cat <<EOF > /etc/systemd/system/nas-api.service
[Unit]
Description=NAS Config API (Flask)
After=network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/nas-api.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

# HTPasswd pour Nginx
htpasswd -bc /etc/nginx/.htpasswd "$CONFIG_USER" "$CONFIG_PASS"

# Dashboard Web Unifié (Belle UI Moderne avec Panel de config Samba intégré)
cat <<EOF > "$WEB_DIR/index.html"
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>⚡ Pi Zero 2W — Control Center</title>
    <style>
        :root {
            --bg: #090d16;
            --card-bg: rgba(30, 41, 59, 0.7);
            --card-border: rgba(255, 255, 255, 0.08);
            --accent: #38bdf8;
            --accent-hover: #0ea5e9;
            --text-main: #f8fafc;
            --text-muted: #94a3b8;
            --success: #10b981;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: 'Inter', system-ui, -apple-system, sans-serif;
            background: var(--bg);
            background-image: radial-gradient(at 0% 0%, rgba(56, 189, 248, 0.12) 0px, transparent 50%),
                              radial-gradient(at 100% 100%, rgba(139, 92, 246, 0.1) 0px, transparent 50%);
            color: var(--text-main);
            min-height: 100vh;
            padding: 24px;
        }
        .container { max-width: 1400px; margin: auto; }
        header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 24px;
            padding-bottom: 16px;
            border-bottom: 1px solid var(--card-border);
        }
        .brand { display: flex; align-items: center; gap: 12px; }
        .logo { font-size: 1.8rem; }
        h1 { font-size: 1.5rem; font-weight: 700; letter-spacing: -0.02em; }
        .badge {
            background: rgba(16, 185, 129, 0.15);
            color: var(--success);
            padding: 4px 12px;
            border-radius: 999.9px;
            font-size: 0.75rem;
            font-weight: 600;
            display: flex;
            align-items: center;
            gap: 6px;
        }
        .badge::before { content: ''; width: 6px; height: 6px; background: var(--success); border-radius: 50%; box-shadow: 0 0 8px var(--success); }
        .user-tag { color: var(--text-muted); font-size: 0.85rem; }
        .user-tag strong { color: var(--text-main); }
        
        .grid-layout {
            display: grid;
            grid-template-columns: 1fr 1.2fr;
            gap: 20px;
        }
        @media(max-width: 1024px) { .grid-layout { grid-template-columns: 1fr; } }

        .card {
            background: var(--card-bg);
            backdrop-filter: blur(12px);
            border: 1px solid var(--card-border);
            border-radius: 16px;
            padding: 20px;
            box-shadow: 0 10px 25px -5px rgba(0,0,0,0.4);
            display: flex;
            flex-direction: column;
            gap: 16px;
        }
        .card-header { display: flex; justify-content: space-between; align-items: center; }
        .card-header h2 { font-size: 1.1rem; font-weight: 600; display: flex; align-items: center; gap: 8px; }
        
        a.btn, button.btn {
            background: var(--accent);
            color: #000;
            padding: 8px 16px;
            text-decoration: none;
            border: none;
            border-radius: 8px;
            font-size: 0.85rem;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.2s;
            display: inline-flex;
            align-items: center;
            gap: 6px;
        }
        a.btn:hover, button.btn:hover { background: var(--accent-hover); transform: translateY(-1px); }

        .frame-wrapper {
            width: 100%;
            height: 440px;
            border-radius: 10px;
            overflow: hidden;
            background: #020617;
            border: 1px solid var(--card-border);
        }
        iframe { width: 100%; height: 100%; border: none; }
        .info-pill {
            font-size: 0.75rem;
            color: var(--text-muted);
            background: rgba(255,255,255,0.03);
            padding: 8px 12px;
            border-radius: 8px;
            border: 1px solid var(--card-border);
        }
        
        .form-group { display: flex; flex-direction: column; gap: 6px; }
        .form-group label { font-size: 0.8rem; color: var(--text-muted); }
        .form-group input {
            background: rgba(15, 23, 42, 0.8);
            border: 1px solid var(--card-border);
            color: var(--text-main);
            padding: 10px;
            border-radius: 8px;
            font-size: 0.85rem;
            outline: none;
        }
        .form-group input:focus { border-color: var(--accent); }
        .row-btns { display: flex; gap: 10px; margin-top: 4px; }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <div class="brand">
                <span class="logo">⚡</span>
                <h1>Pi Zero 2W NAS</h1>
            </div>
            <div style="display: flex; align-items: center; gap: 16px;">
                <span class="user-tag">User: <strong>$CONFIG_USER</strong></span>
                <div class="badge">Online</div>
            </div>
        </header>

        <div class="grid-layout">
            <div style="display: flex; flex-direction: column; gap: 20px;">
                <div class="card">
                    <div class="card-header">
                        <h2>⚙️ Config. Samba</h2>
                        <span id="smb-status-badge" style="font-size: 0.75rem; color: var(--accent);">Chargement...</span>
                    </div>
                    <div class="form-group">
                        <label>Nom du partage (Ex: /mnt/nas ou /srv/nas/partage)</label>
                        <input type="text" id="smb-path" placeholder="/mnt/nas">
                    </div>
                    <div class="form-group">
                        <label>Nom de la section réseau</label>
                        <input type="text" id="smb-name" placeholder="partage">
                    </div>
                    <div class="row-btns">
                        <button class="btn" onclick="saveSamba()">💾 Appliquer</button>
                        <button class="btn" style="background: rgba(255,255,255,0.1); color: #fff;" onclick="restartSamba()">🔄 Redémarrer service</button>
                    </div>
                    <div id="smb-msg" style="font-size: 0.75rem; color: var(--success); min-height: 15px;"></div>
                </div>

                <div class="card">
                    <div class="card-header">
                        <h2>📁 Fichiers</h2>
                        <a href="/files/" class="btn" target="_blank">Plein écran ↗</a>
                    </div>
                    <div class="frame-wrapper" style="height: 320px;">
                        <iframe src="/files/"></iframe>
                    </div>
                    <div class="info-pill">Partage réseau : <strong>\\<script>document.write(window.location.hostname);</script>\\<span id="display-share-name">$SHARE_NAME</span></strong></div>
                </div>
            </div>

            <div class="card">
                <div class="card-header">
                    <h2>📊 System Telemetry (Glances)</h2>
                    <a href="/glances/" class="btn" target="_blank">Plein écran ↗</a>
                </div>
                <div class="frame-wrapper" style="height: 740px;">
                    <iframe src="/glances/"></iframe>
                </div>
            </div>
        </div>
    </div>

    <script>
        async function loadSambaConfig() {
            try {
                let res = await fetch('/api/samba');
                let data = await res.json();
                document.getElementById('smb-path').value = data.path;
                document.getElementById('smb-name').value = data.share_name;
                document.getElementById('display-share-name').innerText = data.share_name;
                document.getElementById('smb-status-badge').innerText = 'État smbd: ' + data.status;
            } catch(e) { console.error(e); }
        }

        async function saveSamba() {
            let path = document.getElementById('smb-path').value;
            let name = document.getElementById('smb-name').value;
            let res = await fetch('/api/samba', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({path, name})
            });
            let data = await res.json();
            document.getElementById('display-share-name').innerText = name;
            document.getElementById('smb-msg').innerText = '✅ Paramètres enregistrés et appliqués !';
            setTimeout(() => document.getElementById('smb-msg').innerText = '', 3000);
            loadSambaConfig();
        }

        async function restartSamba() {
            await fetch('/api/samba', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({action: 'restart'})
            });
            document.getElementById('smb-msg').innerText = '🔄 Service Samba redémarré !';
            setTimeout(() => document.getElementById('smb-msg').innerText = '', 3000);
            loadSambaConfig();
        }

        loadSambaConfig();
    </script>
</body>
</html>
EOF

# Nginx Reverse Proxy (ajout de /api/ vers Flask sur port 5000)
cat <<EOF > /etc/nginx/sites-available/nas
server {
    listen 80 default_server;
    server_name _;

    auth_basic "Restricted Access - NAS Control Center";
    auth_basic_user_file /etc/nginx/.htpasswd;

    location / {
        root $WEB_DIR;
        index index.html;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:5000/api/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location /files/ {
        proxy_pass http://127.0.0.1:8080/files/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_buffering off;
        proxy_read_timeout 3600;
    }

    location /glances/ {
        proxy_pass http://127.0.0.1:61208/glances/;
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

ln -sf /etc/nginx/sites-available/nas /etc/nginx/sites-enabled/default
rm -f /etc/nginx/sites-enabled/default.bak || true
nginx -t

echo "🚀 Rechargement des services..."
systemctl daemon-reload
systemctl enable --now filebrowser.service
systemctl enable --now glances.service
systemctl enable --now nas-api.service
systemctl enable --now nginx
systemctl restart nginx filebrowser glances nas-api

IP_LOCAL=$(hostname -I | awk '{print $1}')
echo ""
echo "✅ Mise à jour terminée avec panneau de config Samba !"
echo "🌐 Tableau de bord : http://${IP_LOCAL}"
