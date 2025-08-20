#!/usr/bin/env bash
set -euo pipefail

########## 0) Basics & sanity ##########
echo "[0/9] Updating apt and installing helpers..."
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg lsb-release openssl

# Working dir under /vagrant so files are easy to commit to GitHub later.
WORKDIR="/vagrant/deploy"
APP_SRC="/home/vagrant/webapp"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

########## 1) Install Docker Engine + Compose ##########
# Official Docker repo for Ubuntu 22.04 (Jammy)
if ! command -v docker >/dev/null 2>&1; then
  echo "[1/9] Installing Docker Engine..."
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo $UBUNTU_CODENAME) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker vagrant || true
fi

########## 2) Prepare app for containerization ##########
echo "[2/9] Staging Flask app for Docker..."
APP_DIR="$WORKDIR/app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"
# Copy your existing app into the build context
rsync -a --delete "$APP_SRC/" "$APP_DIR/"

# Patch config.py so the app connects to the MySQL service name ("db") inside Compose
# (Your original file used 'localhost', which wouldn't work inside a container.)
if grep -q "MYSQL_HOST = 'localhost'" "$APP_DIR/config.py"; then
  sed -i "s/MYSQL_HOST = 'localhost'/MYSQL_HOST = 'db'/" "$APP_DIR/config.py"
fi

# Create requirements.txt based on your current stack
cat > "$APP_DIR/requirements.txt" << 'REQS'
Flask==2.3.3
flask-cors
Flask-MySQLdb
Flask-SQLAlchemy
gunicorn
mysqlclient
REQS

# App Dockerfile (Debian slim; installs the bits needed to build mysqlclient)
cat > "$APP_DIR/Dockerfile" << 'DOCKER'
FROM python:3.11-slim

# System deps for mysqlclient / Flask-MySQLdb
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential default-libmysqlclient-dev pkg-config && \
    rm -rf /var/lib/apt/lists/*

# Workdir
WORKDIR /app

# Requirements first for better layer caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# App code
COPY . .

# Expose Flask port
EXPOSE 5000

# Run with gunicorn (module 'web.views' exposes 'app')
CMD ["gunicorn", "-b", "0.0.0.0:5000", "web.views:app"]
DOCKER

########## 3) MySQL (data + init from your init.sql) ##########
echo "[3/9] Preparing MySQL init..."
mkdir -p "$WORKDIR/mysql-init"
# Use your repo's init.sql that Vagrant provisioned to /home/vagrant
cp -f /home/vagrant/init.sql "$WORKDIR/mysql-init/"

########## 4) Nginx with SSL (self-signed) + redirect HTTP→HTTPS ##########
echo "[4/9] Creating Nginx config and self-signed cert..."
NGINX_DIR="$WORKDIR/nginx"
mkdir -p "$NGINX_DIR/conf.d" "$NGINX_DIR/certs"

# Self-signed cert (valid 825 days); CN matches your private IP
if [ ! -f "$NGINX_DIR/certs/server.key" ]; then
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$NGINX_DIR/certs/server.key" \
    -out "$NGINX_DIR/certs/server.crt" \
    -subj "/C=CR/ST=SanJose/L=SanJose/O=MiniWebApp/OU=Dev/CN=192.168.60.3" \
    -days 825
fi

# Nginx site config: 80 -> 443 redirect, HTTPS proxy to Flask app
cat > "$NGINX_DIR/conf.d/app.conf" << 'NGINX'
server {
    listen 80;
    server_name _;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name _;

    ssl_certificate     /etc/nginx/certs/server.crt;
    ssl_certificate_key /etc/nginx/certs/server.key;

    location / {
        proxy_pass http://app:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGINX

########## 5) Prometheus + Node Exporter ##########
echo "[5/9] Writing Prometheus config (scrapes Prometheus + Node Exporter)..."
PROM_DIR="$WORKDIR/prometheus"
mkdir -p "$PROM_DIR"
cat > "$PROM_DIR/prometheus.yml" << 'PROM'
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['prometheus:9090']

  - job_name: 'node_exporter'
    static_configs:
      - targets: ['node-exporter:9100']
PROM

########## 6) (Optional) Grafana service ##########
# Included by default so you can complete the optional part; you can comment it out in compose if not needed.

########## 7) docker-compose.yml (app, db, nginx, prometheus, node-exporter, grafana) ##########
echo "[6/9] Creating docker-compose.yml..."
cat > "$WORKDIR/docker-compose.yml" << 'COMPOSE'
services:
  db:
    image: mysql:8.0
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: root
    ports:
      - "3306:3306"   # optional: expose for host tools
    volumes:
      - db_data:/var/lib/mysql
      - ./mysql-init:/docker-entrypoint-initdb.d:ro

  app:
    build:
      context: ./app
    restart: unless-stopped
    depends_on:
      - db
    environment:
      # In case your code uses SQLALCHEMY_DATABASE_URI:
      SQLALCHEMY_DATABASE_URI: "mysql://root:root@db/myflaskapp"
    expose:
      - "5000"

  nginx:
    image: nginx:stable
    restart: unless-stopped
    depends_on:
      - app
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - ./nginx/certs:/etc/nginx/certs:ro

  node-exporter:
    image: prom/node-exporter:latest
    restart: unless-stopped
    command: ["--path.rootfs=/host"]
    pid: "host"
    volumes:
      - /:/host:ro,rslave
    ports:
      - "9100:9100"

  prometheus:
    image: prom/prometheus:latest
    restart: unless-stopped
    depends_on:
      - node-exporter
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro

  grafana:
    image: grafana/grafana:latest
    restart: unless-stopped
    depends_on:
      - prometheus
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin

volumes:
  db_data:
COMPOSE

########## 8) Bring the whole stack up ##########
echo "[7/9] Building and starting the stack (this can take a few minutes the first time)..."
docker compose -f "$WORKDIR/docker-compose.yml" up -d --build

########## 9) Final messages ##########
echo
echo "=========================================================="
echo " All set!"
echo " - App via Nginx+SSL:  https://192.168.60.3  (accept the self-signed certificate)"
echo " - Prometheus:         http://192.168.60.3:9090"
echo " - Node Exporter:      http://192.168.60.3:9100/metrics"
echo " - Grafana:            http://192.168.60.3:3000  (admin/admin)"
echo
echo "Files created in: $WORKDIR"
echo "  - app/Dockerfile, app/requirements.txt"
echo "  - mysql-init/init.sql"
echo "  - nginx/conf.d/app.conf  + nginx/certs/server.(crt|key)"
echo "  - prometheus/prometheus.yml"
echo "  - docker-compose.yml"
echo
echo "To view logs:      docker compose -f $WORKDIR/docker-compose.yml logs -f"
echo "To stop stack:     docker compose -f $WORKDIR/docker-compose.yml down"
echo "=========================================================="

