"""
Application Flask — Image Uploader vers S3

Copie locale de référence. L'application est déployée sur EC2
via le script user_data.sh (incluse en heredoc dans le script).
"""

import os
import uuid
from flask import (
    Flask, request, redirect, url_for,
    render_template, flash, get_flashed_messages,
)
import boto3
from botocore.exceptions import ClientError, NoCredentialsError

app = Flask(__name__)
app.secret_key = "dev-secret-key-change-in-prod"

S3_BUCKET = os.environ.get("S3_BUCKET_NAME", "demo-image-uploader-bucket")
AWS_REGION = os.environ.get("AWS_REGION", "eu-west-3")


def get_s3_client():
    """Crée un client S3.
    En Phase 1 (sans rôle IAM), les appels S3 échoueront avec NoCredentialsError.
    En Phase 2 (avec Instance Profile), boto3 récupère automatiquement
    les credentials depuis le metadata service de l'instance EC2."""
    return boto3.client("s3", region_name=AWS_REGION)


def list_images():
    """Liste les images dans le bucket S3 et génère des URLs présignées."""
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
                    "ResponseContentDisposition": (
                        f'attachment; filename="{os.path.basename(key)}"'
                    ),
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
        return None
    except ClientError as e:
        print(f"Erreur S3 list: {e}")
        return None


@app.route("/")
def index():
    images = list_images()
    return render_template(
        "index.html",
        images=images,
        messages=get_flashed_messages(with_categories=True),
    )


@app.route("/upload", methods=["POST"])
def upload():
    file = request.files.get("image")
    if not file or file.filename == "":
        flash("Aucun fichier sélectionné.", "error")
        return redirect(url_for("index"))

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
        flash(
            f"Erreur S3 ({error_code}) : {e.response['Error']['Message']}",
            "error",
        )

    return redirect(url_for("index"))


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80, debug=True)
