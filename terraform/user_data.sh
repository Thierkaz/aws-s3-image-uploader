#!/bin/bash
set -ex

# ============================================================================
# user_data.sh — Bootstrap de l'instance EC2
#
# Ce script est exécuté automatiquement au premier démarrage de l'instance.
# Il installe les dépendances, déploie l'application Flask et la lance
# en tant que service systemd sur le port 80.
# ============================================================================

# --- Mise à jour et installation des paquets --------------------------------
dnf update -y
dnf install -y python3 python3-pip

# --- Création du répertoire de l'application --------------------------------
APP_DIR=/opt/image-uploader
mkdir -p $APP_DIR/templates

# --- Installation des dépendances Python ------------------------------------
pip3 install flask boto3

# --- Variables d'environnement pour l'application ---------------------------
cat > $APP_DIR/.env <<EOF
S3_BUCKET_NAME=${bucket_name}
AWS_REGION=${aws_region}
EOF

# --- Déploiement de l'application Flask -------------------------------------
cat > $APP_DIR/app.py <<'APPEOF'
import os
import uuid
from flask import Flask, request, redirect, url_for, render_template_string, flash
import boto3
from botocore.config import Config
from botocore.exceptions import ClientError, NoCredentialsError

app = Flask(__name__)
app.secret_key = "dev-secret-key-change-in-prod"

S3_BUCKET = os.environ.get("S3_BUCKET_NAME", "demo-image-uploader-bucket")
AWS_REGION = os.environ.get("AWS_REGION", "eu-west-3")

def get_s3_client():
    """Crée un client S3.
    - Config(signature_version='s3v4') force la signature v4 pour les presigned URLs
    - Les credentials viennent automatiquement de l'Instance Profile (metadata service)"""
    return boto3.client(
        "s3",
        region_name=AWS_REGION,
        config=Config(signature_version="s3v4"),
    )

def list_images():
    """Liste les images dans le bucket S3."""
    try:
        s3 = get_s3_client()
        response = s3.list_objects_v2(Bucket=S3_BUCKET, Prefix="uploads/")
        images = []
        for obj in response.get("Contents", []):
            key = obj["Key"]
            if key.endswith("/"):
                continue
            # URL présignée pour AFFICHER l'image (expire dans 1h)
            view_url = s3.generate_presigned_url(
                "get_object",
                Params={"Bucket": S3_BUCKET, "Key": key},
                ExpiresIn=3600,
            )
            # URL présignée pour TÉLÉCHARGER l'image (force le download)
            download_url = s3.generate_presigned_url(
                "get_object",
                Params={
                    "Bucket": S3_BUCKET,
                    "Key": key,
                },
                ExpiresIn=3600,
            )
            images.append({
                "key": key,
                "filename": os.path.basename(key),
                "view_url": view_url,
                "download_url": download_url,
            })
        return images
    except NoCredentialsError:
        return None  # Signale l'absence de credentials
    except ClientError as e:
        print(f"Erreur S3 list: {e}")
        return None

TEMPLATE = """
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Image Uploader - S3 Demo</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: -apple-system, sans-serif; background: #f5f5f5; padding: 2rem; }
        .container { max-width: 800px; margin: 0 auto; }
        h1 { color: #232f3e; margin-bottom: 1.5rem; }
        .card { background: white; border-radius: 8px; padding: 1.5rem;
                margin-bottom: 1.5rem; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .upload-form { display: flex; gap: 1rem; align-items: center; flex-wrap: wrap; }
        input[type="file"] { flex: 1; }
        button { background: #ff9900; color: white; border: none; padding: 0.6rem 1.5rem;
                 border-radius: 4px; cursor: pointer; font-size: 1rem; }
        button:hover { background: #e88a00; }
        .flash { padding: 1rem; border-radius: 4px; margin-bottom: 1rem; }
        .flash.error { background: #fce4e4; color: #c0392b; border: 1px solid #e74c3c; }
        .flash.success { background: #e4fce4; color: #27ae60; border: 1px solid #2ecc71; }
        .flash.warning { background: #fff3cd; color: #856404; border: 1px solid #ffc107; }
        .image-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(250px, 1fr)); gap: 1rem; }
        .image-card { background: white; border-radius: 8px; overflow: hidden;
                      box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .image-card img { width: 100%; height: 200px; object-fit: cover; cursor: pointer; }
        .image-card .info { padding: 0.8rem; }
        .image-card .info p { font-size: 0.85rem; color: #666; margin-bottom: 0.5rem;
                              overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .image-card .info a { color: #0073bb; text-decoration: none; font-size: 0.9rem; }
        .image-card .info a:hover { text-decoration: underline; }
        .no-creds { text-align: center; padding: 2rem; color: #856404; }
        .no-creds code { background: #f8f9fa; padding: 0.2rem 0.4rem; border-radius: 3px; }

        /* --- Modale fullscreen --- */
        .modal-overlay {
            display: none; position: fixed; inset: 0; z-index: 1000;
            background: rgba(0,0,0,0.9); justify-content: center; align-items: center;
            flex-direction: column;
        }
        .modal-overlay.active { display: flex; }
        .modal-toolbar {
            position: fixed; top: 0; left: 0; right: 0; z-index: 1001;
            display: flex; justify-content: flex-end; align-items: center;
            gap: 0.5rem; padding: 0.8rem 1.2rem; background: rgba(0,0,0,0.5);
        }
        .modal-toolbar button {
            background: rgba(255,255,255,0.15); color: white; border: 1px solid rgba(255,255,255,0.3);
            padding: 0.4rem 0.9rem; border-radius: 4px; cursor: pointer; font-size: 0.85rem;
        }
        .modal-toolbar button:hover { background: rgba(255,255,255,0.3); }
        .modal-toolbar .btn-close { font-size: 1.3rem; line-height: 1; padding: 0.3rem 0.7rem; }
        .modal-img-container {
            flex: 1; display: flex; justify-content: center; align-items: center;
            overflow: auto; width: 100%; padding: 3.5rem 1rem 1rem;
        }
        .modal-img-container img.fit {
            max-width: 100%; max-height: calc(100vh - 4.5rem); object-fit: contain;
        }
        .modal-img-container img.full {
            max-width: none; max-height: none;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🖼️ Image Uploader — S3 Demo</h1>

        {% for cat, msg in messages %}
        <div class="flash {{ cat }}">{{ msg }}</div>
        {% endfor %}

        <div class="card">
            <h2>Uploader une image</h2><br>
            <form class="upload-form" action="/upload" method="post" enctype="multipart/form-data">
                <input type="file" name="image" accept="image/*" required>
                <button type="submit">Envoyer vers S3</button>
            </form>
        </div>

        <h2 style="margin-bottom:1rem;">Images stockées dans S3</h2>

        {% if images is none %}
        <div class="card no-creds">
            <h3>⚠️ Pas de credentials AWS</h3>
            <p>L'instance EC2 n'a pas de rôle IAM attaché.</p>
            <p>L'application ne peut pas accéder au bucket S3.</p>
            <p style="margin-top:1rem;">
                → Passez à la <strong>Phase 2</strong> pour ajouter les politiques d'accès IAM.
            </p>
        </div>
        {% elif images|length == 0 %}
        <div class="card" style="text-align:center; color:#999; padding:2rem;">
            Aucune image pour le moment. Uploadez-en une !
        </div>
        {% else %}
        <div class="image-grid">
            {% for img in images %}
            <div class="image-card">
                <img src="{{ img.view_url }}" alt="{{ img.filename }}"
                     data-view="{{ img.view_url }}"
                     data-download="{{ img.download_url }}"
                     data-filename="{{ img.filename }}">
                <div class="info">
                    <p>{{ img.filename }}</p>
                    <a href="{{ img.download_url }}">⬇ Télécharger</a>
                </div>
            </div>
            {% endfor %}
        </div>
        {% endif %}
    </div>

    <!-- Modale fullscreen -->
    <div class="modal-overlay" id="modal">
        <div class="modal-toolbar">
            <button id="btnZoom">🔍 Taille réelle</button>
            <a id="btnDownload" href="#" class="" style="text-decoration:none;">
                <button>⬇ Télécharger</button>
            </a>
            <button class="btn-close">✕</button>
        </div>
        <div class="modal-img-container" id="modalContainer">
            <img id="modalImg" class="fit" src="" alt="">
        </div>
    </div>

    <script>
    (function() {
        var modal = document.getElementById("modal");
        var modalImg = document.getElementById("modalImg");
        var modalContainer = document.getElementById("modalContainer");
        var btnZoom = document.getElementById("btnZoom");
        var btnDownload = document.getElementById("btnDownload");
        var isFit = true;
        var LABEL_FIT = "\\uD83D\\uDD0D Taille r\\u00E9elle";
        var LABEL_FULL = "\\uD83D\\uDD0D Ajuster \\u00E0 l\\u2019\\u00E9cran";

        // Ouvrir la modale au clic sur une image de la grille
        document.querySelectorAll(".image-card img[data-view]").forEach(function(img) {
            img.addEventListener("click", function() {
                modalImg.src = this.getAttribute("data-view");
                modalImg.alt = this.getAttribute("data-filename");
                btnDownload.href = this.getAttribute("data-download");
                isFit = true;
                modalImg.className = "fit";
                btnZoom.textContent = LABEL_FIT;
                modal.classList.add("active");
                document.body.style.overflow = "hidden";
            });
        });

        // Fermer la modale
        function doClose() {
            modal.classList.remove("active");
            document.body.style.overflow = "";
            modalImg.src = "";
        }

        modal.addEventListener("click", function(e) {
            if (e.target === modal || e.target === modalContainer) doClose();
        });

        document.querySelector(".btn-close").addEventListener("click", doClose);

        document.addEventListener("keydown", function(e) {
            if (e.key === "Escape") doClose();
        });

        // Basculer taille reelle / ajustee
        btnZoom.addEventListener("click", function() {
            isFit = !isFit;
            modalImg.className = isFit ? "fit" : "full";
            btnZoom.textContent = isFit ? LABEL_FIT : LABEL_FULL;
        });
    })();
    </script>
</body>
</html>
"""

@app.route("/")
def index():
    messages = []
    # Récupérer les messages flash
    with app.test_request_context():
        for cat, msg in []:
            messages.append((cat, msg))

    images = list_images()
    return render_template_string(TEMPLATE, images=images, messages=get_flashed_messages(with_categories=True))

@app.route("/upload", methods=["POST"])
def upload():
    file = request.files.get("image")
    if not file or file.filename == "":
        flash("Aucun fichier sélectionné.", "error")
        return redirect(url_for("index"))

    # Nom unique pour éviter les collisions
    ext = os.path.splitext(file.filename)[1]
    unique_name = f"{uuid.uuid4().hex}{ext}"
    s3_key = f"uploads/{unique_name}"

    try:
        s3 = get_s3_client()
        s3.upload_fileobj(
            file,
            S3_BUCKET,
            s3_key,
            ExtraArgs={"ContentType": file.content_type},
        )
        flash(f"Image '{file.filename}' uploadée avec succès !", "success")
    except NoCredentialsError:
        flash(
            "Erreur : pas de credentials AWS. L'instance EC2 n'a pas de rôle IAM. "
            "Ajoutez un Instance Profile avec les permissions S3 (Phase 2).",
            "error",
        )
    except ClientError as e:
        error_code = e.response["Error"]["Code"]
        flash(f"Erreur S3 ({error_code}) : {e.response['Error']['Message']}", "error")

    return redirect(url_for("index"))

from flask import get_flashed_messages

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)
APPEOF

# --- Service systemd pour lancer l'app au démarrage ------------------------
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

# --- Démarrage du service ---------------------------------------------------
systemctl daemon-reload
systemctl enable image-uploader
systemctl start image-uploader

echo "=== user_data.sh terminé avec succès ==="
