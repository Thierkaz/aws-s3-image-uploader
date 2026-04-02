# Image Uploader — Demo S3 + EC2

Application web qui permet d'uploader des images vers un bucket S3 depuis un navigateur.
L'infrastructure est provisionnée avec Terraform (EC2 + S3).

## Prérequis

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.0
- [AWS CLI](https://aws.amazon.com/cli/) configuré (`aws configure`)
- Une paire de clés SSH créée dans AWS EC2 (pour accéder à l'instance)

## Structure du projet

```
s3-image-uploader/
├── terraform/
│   ├── main.tf          # Provider, Security Group, EC2, S3
│   ├── variables.tf     # Variables configurables
│   ├── outputs.tf       # IP publique, nom du bucket, URL
│   └── user_data.sh     # Script de bootstrap EC2
├── app/
│   ├── app.py           # Application Flask (copie locale)
│   ├── templates/
│   │   └── index.html   # Template HTML
│   └── requirements.txt # Dépendances Python
└── README.md
```

## Phase 1 — Déploiement (sans politiques IAM)

### 1. Initialiser et déployer l'infrastructure

```bash
cd terraform

terraform init
terraform plan -var="key_name=VOTRE_CLE_SSH" -var="bucket_name=mon-bucket-unique-12345"
terraform apply -var="key_name=VOTRE_CLE_SSH" -var="bucket_name=mon-bucket-unique-12345"
```

> **Note :** Le nom du bucket S3 doit être **globalement unique** sur AWS.

### 2. Accéder à l'application

Terraform affichera l'URL de l'application dans les outputs :

```
app_url = "http://<IP_PUBLIQUE>"
```

Ouvrez cette URL dans votre navigateur. L'application sera accessible après 2-3 minutes
(temps de boot + installation des paquets).

### Politiques IAM créées

1. **IAM Role** (`aws_iam_role`)
   - Trust Policy : autorise le service `ec2.amazonaws.com` à assumer ce rôle
   - C'est le mécanisme qui permet à une instance EC2 d'obtenir des credentials temporaires

2. **IAM Policy** (`aws_iam_policy`)
   - Permissions S3 restreintes au bucket :
     - `s3:PutObject` — uploader des fichiers
     - `s3:GetObject` — lire/télécharger des fichiers
     - `s3:ListBucket` — lister le contenu du bucket
   - Principe du moindre privilège : uniquement les actions nécessaires

3. **Instance Profile** (`aws_iam_instance_profile`)
   - Lie le rôle IAM à l'instance EC2
   - boto3 récupère automatiquement les credentials via le metadata service

4. **Bucket Policy** (optionnelle)
   - Restreint l'accès au bucket depuis le rôle IAM uniquement

## Nettoyage

```bash
cd terraform
terraform destroy -var="key_name=VOTRE_CLE_SSH" -var="bucket_name=mon-bucket-unique-12345"
```

## Comment ça marche

1. L'utilisateur choisit une image et clique sur "Envoyer vers S3"
2. Flask reçoit le fichier et l'uploade vers S3 via `boto3.upload_fileobj()`
3. L'image est stockée sous `uploads/<uuid>.<ext>` dans le bucket
4. Pour l'affichage, Flask génère une **URL présignée** (presigned URL) qui :
   - Donne un accès temporaire (1h) à l'objet S3
   - Ne nécessite pas de rendre le bucket public
5. Un lien de téléchargement utilise une URL présignée avec `Content-Disposition: attachment`
