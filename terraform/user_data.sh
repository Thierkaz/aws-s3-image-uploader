#!/bin/bash
set -ex

# ==========================================================================
# user_data.sh — Bootstrap minimal de l'instance EC2
#
# Le code applicatif (app.py + templates/) est stocke dans S3 sous deploy/.
# Ce script installe les dependances, telecharge l'app et la lance.
# ==========================================================================

# --- Installation des paquets ---
dnf update -y
dnf install -y python3 python3-pip

# --- Dependances Python ---
pip3 install flask boto3

# --- Repertoire de l'application ---
APP_DIR=/opt/image-uploader
mkdir -p $APP_DIR/templates

# --- Variables d'environnement ---
cat > $APP_DIR/.env <<EOF
S3_BUCKET_NAME=${bucket_name}
AWS_REGION=${aws_region}
EOF

# --- Telecharger l'application depuis S3 ---
aws s3 cp s3://${bucket_name}/deploy/app.py $APP_DIR/app.py
aws s3 cp s3://${bucket_name}/deploy/templates/index.html $APP_DIR/templates/index.html

# --- Service systemd ---
cat > /etc/systemd/system/image-uploader.service <<EOF
[Unit]
Description=Image Uploader Flask App
After=network.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env
ExecStart=/usr/bin/python3 $APP_DIR/app.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable image-uploader
systemctl start image-uploader

echo "=== user_data.sh termine ==="
