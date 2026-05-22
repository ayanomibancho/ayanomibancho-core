# 🌟 AyanomiBancho - Custom osu! Private Server

Welcome to **AyanomiBancho**, a high-performance, lightweight custom web backend and custom in-game Bancho protocol server for osu! private servers. 

Designed specifically for **Linux VPS** deployment (fully compatible with Windows local development), AyanomiBancho features a premium, state-of-the-art **Hatsune Miku Neon Dark-Mode** design system with a responsive glassmorphic UI.

---

## ✨ Features

- **⚡ Lightweight Template Engine**: Built-in HTML renderer in Lua with automatic hot-reloading for development.
- **🎨 Hatsune Miku UI Theme**: Stunning cyberpunk glassmorphism style sheet with glowing cyan/pink neon indicators and responsive flex layout.
- **🎮 Custom Bancho Handler**: Non-blocking in-game connection processing, user presence, login handling, and real-time statistics updates.
- **📦 Dual-Database Support**: Out-of-the-box SQLite3 configuration, with fallback to an in-memory mock database for isolated testing.
- **☁️ rclone Cloud Synchronization**: Automated background scripts to backup, sync, or dynamically mount your game data (avatars, replays, beatmaps) to Google Drive.
- **🔒 Production Ready**: Configured for Nginx reverse proxy management and Let's Encrypt SSL.

---

## 📂 Project Directory Structure

```
AyanomiBancho/
├── config.lua             # Global Server Configurations
├── db.lua                 # Database Connection Adapter (SQLite / Mock DB)
├── main.lua               # Entry Point & HTTP/Bancho Request Router
├── Caddyfile              # Local SSL Configuration (optional)
├── deps/                  # Lua Libraries and Dependency Packages
│   └── sqlite3.lua        # Cross-Platform SQLite3 Wrapper (supports libsqlite3.so.0)
├── handlers/              # Backend Route Handlers (Auth, Bancho, Leaderboard, API)
├── public/                # Static assets (images, fonts, stylesheets)
│   └── css/style.css      # Core Hatsune Miku Design Theme CSS
├── views/                 # HTML templates (Home, Profile, Leaderboard, etc.)
└── rclone_*.sh / .bat     # Synchronization & Mount Automation scripts
```

---

## 🔧 Prerequisites & Setup

### 1. Install Luvit
AyanomiBancho runs on **Luvit** (Node.js engine rewritten for Lua). Install it using the following commands:

**On Linux (Ubuntu/Debian):**
```bash
curl -L https://github.com/luvit/lit/raw/master/get-lit.sh | sh
```
This downloads a local `luvit` executable in your directory. Optionally move it to a global path:
```bash
sudo mv luvit /usr/local/bin/
```

### 2. Linux VPS Deployment (Nginx + Certbot)
To run the server live behind your domain (e.g., `o.ayanomi.io.vn`), map your subdomains in Cloudflare/DNS as **DNS Only** (Grey Cloud) first:
- `o.ayanomi.io.vn` (Home & Web Interface)
- `c.o.ayanomi.io.vn` (In-game Bancho client endpoint)
- `ce.o.ayanomi.io.vn`
- `c4.o.ayanomi.io.vn`
- `osu.o.ayanomi.io.vn`
- `a.o.ayanomi.io.vn` (Avatar Service)

#### Set up Nginx config:
Create an Nginx configuration file at `/etc/nginx/sites-available/osu-server` proxying request traffic to `127.0.0.1:13380`:
```nginx
server {
    server_name o.ayanomi.io.vn c.o.ayanomi.io.vn ce.o.ayanomi.io.vn c4.o.ayanomi.io.vn osu.o.ayanomi.io.vn a.o.ayanomi.io.vn;
    client_max_body_size 20M;

    location / {
        proxy_pass http://127.0.0.1:13380;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```
Enable the site and run Certbot to request SSL Certificates:
```bash
sudo ln -s /etc/nginx/sites-available/osu-server /etc/nginx/sites-enabled/
sudo certbot --nginx -d o.ayanomi.io.vn -d c.o.ayanomi.io.vn -d ce.o.ayanomi.io.vn -d c4.o.ayanomi.io.vn -d osu.o.ayanomi.io.vn -d a.o.ayanomi.io.vn
```
*Note: Once Let's Encrypt confirms the DNS challenge, you can enable Cloudflare proxying (Orange Cloud) as long as your SSL settings are set to **Full** or **Full (Strict)**.*

### 3. Setup rclone Data Sync (Optional)
Configure a Google Drive connection to keep avatars, replays, and maps backed up:
```bash
./rclone_setup.sh
```

---

## 🚀 Running the Server

### Start the server locally:
```bash
# On Linux:
./start.sh

# On Windows:
start.bat
```

### Start the server on VPS (with Cloud Backup):
```bash
# On Linux VPS:
./start_cloud.sh
```

### Mount Cloud Storage directly:
If you want to read/write files directly from/to Google Drive without copying files locally:
```bash
./rclone_mount.sh
```
*Ensure to adjust `config.lua` `paths.data` to `/mnt/osu_data`.*

---

## 🛠️ In-Game Configuration

To connect the game client, run your osu! client executable with the `-devserver` argument directing to your domain:
```cmd
osu!.exe -devserver o.ayanomi.io.vn
```

---

## 📜 License
This project is licensed under the MIT License.
