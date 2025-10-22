#!/bin/bash

# ===========================
# Simple Automated Deployment Script
# ===========================
# Author: Indomak (DevOps Engineer)
# Description: Clones repo, sets up Docker + Nginx on remote server, deploys app, logs and handles errors.

# Exit immediately on error
set -e

# Create logs folder
mkdir -p logs
LOG_FILE="logs/deploy_$(date +%F_%T).log"
exec > >(tee -i "$LOG_FILE")
exec 2>&1

# Handle unexpected errors
trap 'echo "[ERROR] Something went wrong! Check $LOG_FILE for details." >&2' ERR

echo "🚀 Starting Deployment..."

# ===========================
# Step 1: Setup Parameters
# ===========================
REPO_URL="https://github.com/IndomakHub/stage-one-project.git"
BRANCH="main"
SERVER_USER="ubuntu"
SERVER_IP="3.90.103.160"
SSH_KEY="aws-key.pem"
APP_PORT="8080"

# Use GitHub token for authentication (if private repo)
AUTH_REPO_URL="https://${GITHUB_TOKEN}@github.com/IndomakHub/stage-one-project.git"
WORKDIR=$(basename "$REPO_URL" .git)

echo "[INFO] Repository: $REPO_URL"
echo "[INFO] Branch: $BRANCH"
echo "[INFO] Remote Server: $SERVER_USER@$SERVER_IP"
echo "[INFO] App Port: $APP_PORT"
echo "----------------------------------------"

# ===========================
# Step 2: GitHub Access Setup
# ===========================
mkdir -p ~/.ssh
chmod 700 ~/.ssh
ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null

# ===========================
# Step 3: Clone or Update Repository
# ===========================
if [ -d "$WORKDIR" ]; then
  echo "[INFO] Updating existing repo..."
  cd "$WORKDIR" && git pull origin "$BRANCH"
else
  echo "[INFO] Cloning repository..."
  rm -rf "$WORKDIR"
  git clone -b "$BRANCH" "$AUTH_REPO_URL"
  cd "$WORKDIR"
fi

# ===========================
# Step 4: Transfer Files to Remote Server
# ===========================
echo "[INFO] Transferring files to remote server..."
chmod 600 "$SSH_KEY"
scp -o StrictHostKeyChecking=no -i "$SSH_KEY" -r * "$SERVER_USER@$SERVER_IP:/tmp/$WORKDIR"

# ===========================
# Step 5: Remote Setup and Deployment
# ===========================
echo "[INFO] Connecting to $SERVER_IP to deploy..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "$SERVER_USER@$SERVER_IP" bash <<EOF
set -e
trap 'echo "[REMOTE ERROR] Something went wrong on the server!" >&2' ERR

echo "== Updating and Installing Dependencies =="
sudo apt update -y
sudo apt install -y docker.io docker-compose nginx

echo "== Starting Docker and Nginx =="
sudo systemctl enable docker --now
sudo systemctl enable nginx --now

echo "== Preparing Application =="
cd /tmp/$WORKDIR

# Stop old container if running
sudo docker stop app_container || true
sudo docker rm app_container || true

# Build and run container
if [ -f docker-compose.yml ]; then
  echo "[INFO] Using docker-compose to deploy..."
  sudo docker compose up -d --build || sudo docker-compose up -d --build
else
  echo "[INFO] Using Dockerfile to build and run..."
  sudo docker build -t myapp .
  sudo docker run -d --name app_container -p $APP_PORT:$APP_PORT myapp
fi

# --- Nginx Reverse Proxy Setup ---
NGINX_CONF="/etc/nginx/sites-available/app"
sudo bash -c "cat > \$NGINX_CONF" <<'NGINXCONF'
server {
  listen 80;
  server_name _;
  location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
NGINXCONF

sudo ln -sf \$NGINX_CONF /etc/nginx/sites-enabled/app
sudo nginx -t
sudo systemctl reload nginx

echo "== Checking Container and Nginx Status =="
sudo docker ps
sudo systemctl status nginx --no-pager

echo "== Deployment Successful! =="
echo " Application is live at: http://$SERVER_IP"
EOF

echo "----------------------------------------"
echo "✅ Deployment finished successfully!"
echo "📜 Logs saved to: $LOG_FILE"
