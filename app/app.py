import os
import uuid
from flask import (
    Flask, request, redirect, url_for,
    render_template, flash, get_flashed_messages, jsonify,
)
import boto3
from botocore.config import Config
from botocore.exceptions import ClientError, NoCredentialsError

app = Flask(__name__)
app.secret_key = "dev-secret-key-change-in-prod"

S3_BUCKET = os.environ.get("S3_BUCKET_NAME", "demo-image-uploader-bucket")
AWS_REGION = os.environ.get("AWS_REGION", "eu-west-3")


def get_s3_client():
    """Cree un client S3.
    - signature_version s3v4 pour les presigned URLs avec credentials STS
    - Les credentials viennent de l'Instance Profile (metadata service)"""
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
            view_url = s3.generate_presigned_url(
                "get_object",
                Params={"Bucket": S3_BUCKET, "Key": key},
                ExpiresIn=3600,
            )
            download_url = s3.generate_presigned_url(
                "get_object",
                Params={"Bucket": S3_BUCKET, "Key": key},
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
        flash("Aucun fichier selectionne.", "error")
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
        flash(f"Image '{file.filename}' uploadee avec succes !", "success")
    except NoCredentialsError:
        flash(
            "Erreur : pas de credentials AWS. "
            "Ajoutez un Instance Profile avec les permissions S3.",
            "error",
        )
    except ClientError as e:
        error_code = e.response["Error"]["Code"]
        flash(
            f"Erreur S3 ({error_code}) : {e.response['Error']['Message']}",
            "error",
        )

    return redirect(url_for("index"))


@app.route("/api/image-url")
def api_image_url():
    """Retourne une presigned URL pour une image (chargement async du slider)."""
    key = request.args.get("key", "")
    if not key:
        return jsonify({"error": "Missing key"}), 400
    try:
        s3 = get_s3_client()
        view_url = s3.generate_presigned_url(
            "get_object",
            Params={"Bucket": S3_BUCKET, "Key": key},
            ExpiresIn=3600,
        )
        download_url = s3.generate_presigned_url(
            "get_object",
            Params={"Bucket": S3_BUCKET, "Key": key},
            ExpiresIn=3600,
        )
        return jsonify({
            "view_url": view_url,
            "download_url": download_url,
            "filename": os.path.basename(key),
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/image", methods=["DELETE"])
def api_delete_image():
    """Supprime une image du bucket S3."""
    key = request.args.get("key", "")
    if not key or not key.startswith("uploads/"):
        return jsonify({"error": "Invalid key"}), 400
    try:
        s3 = get_s3_client()
        s3.delete_object(Bucket=S3_BUCKET, Key=key)
        return jsonify({"success": True, "key": key})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)
