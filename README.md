# Image Uploader — Demo S3 + EC2

Application web qui permet d'uploader des images vers un bucket S3 depuis un navigateur,
les visualiser dans un slider plein écran et les télécharger.
L'infrastructure est provisionnée avec Terraform (EC2 + S3 + IAM).

## Prérequis

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.0
- [AWS CLI](https://aws.amazon.com/cli/) configuré avec un profil SSO (ex: `aws sso login --profile devops-coursera`)
- Une paire de clés SSH créée dans AWS EC2

## Structure du projet

```
s3-image-uploader/
├── terraform/
│   ├── main.tf          # Provider, VPC, SG, EC2, S3, IAM, déploiement S3
│   ├── variables.tf     # Variables (région, profil SSO, clé SSH, bucket)
│   ├── outputs.tf       # IP publique, nom du bucket, URL de l'app
│   └── user_data.sh     # Bootstrap EC2 (minimal, télécharge l'app depuis S3)
├── app/
│   ├── app.py           # Application Flask + API
│   ├── templates/
│   │   └── index.html   # Template HTML (formulaire, galerie, modale slider)
│   └── requirements.txt # flask, boto3
└── README.md
```

## Déploiement

### Stratégie de déploiement

Le code applicatif (`app/app.py` et `app/templates/index.html`) est **uploadé vers S3**
par Terraform via des ressources `aws_s3_object`, sous le préfixe `deploy/`.

Au premier boot, l'EC2 exécute un `user_data.sh` minimal (~1 Ko) qui :

1. Installe Python, Flask et boto3
2. Télécharge l'app depuis `s3://<bucket>/deploy/` via `aws s3 cp`
3. Lance l'application en service systemd sur le port 80

Cette approche contourne la **limite de 16 Ko** du `user_data` EC2
et sépare proprement le code applicatif de l'infrastructure.

### 1. Se connecter au SSO AWS

```bash
aws sso login --profile nom_du_profile
```

### 2. Déployer

```bash
cd terraform
terraform init
terraform apply -var="key_name=VOTRE_CLE_SSH" -var="bucket_name=mon-bucket-unique-12345"
```

> **Note :** Le nom du bucket S3 doit être **globalement unique** sur AWS.

### 3. Accéder à l'application

Terraform affiche l'URL dans les outputs :

```
app_url = "http://<IP_PUBLIQUE>"
```

L'application est accessible après 2-3 minutes (boot + installation des paquets).

### 4. Redéployer après modification du code

Si vous modifiez `app/app.py` ou `app/templates/index.html`, Terraform détecte
le changement de checksum (`etag`) et met à jour l'objet S3. Il faut ensuite
recréer l'instance pour que le nouveau `user_data` re-télécharge les fichiers :

```bash
terraform taint aws_instance.app_server
terraform apply -var="key_name=VOTRE_CLE_SSH" -var="bucket_name=mon-bucket-unique-12345"
```

## Fonctionnalités de l'application

- **Upload d'images** vers S3 via un formulaire
- **Galerie** affichant les images stockées avec URLs présignées (expiration 1h)
- **Modale plein écran** au clic sur une image, avec :
  - Slider (flèches ‹ › + touches clavier ← →)
  - Chargement asynchrone de l'image suivante via l'API `/api/image-url`
  - Bouton "Taille réelle" / "Ajuster" pour basculer entre les modes d'affichage
  - Téléchargement direct
  - Compteur de position (ex: 2 / 5)

## Politiques d'accès AWS (IAM)

4 couches de sécurité configurent l'accès entre l'EC2 et S3 :

1. **IAM Role** — Trust Policy autorise `ec2.amazonaws.com` à assumer le rôle.
   L'instance obtient des credentials temporaires via le metadata service (169.254.169.254).

2. **IAM Policy** — Permissions S3 restreintes au bucket (principe du moindre privilège) :
   - `s3:PutObject` — upload
   - `s3:GetObject` — lecture / presigned URLs / téléchargement de l'app
   - `s3:ListBucket` — listing

3. **Instance Profile** — Lie le rôle IAM à l'instance EC2.
   boto3 récupère automatiquement les credentials sans clés hardcodées.

4. **Bucket Policy** — Restreint l'accès au bucket au seul rôle IAM de l'EC2.

## Nettoyage

```bash
cd terraform
terraform destroy -var="key_name=VOTRE_CLE_SSH" -var="bucket_name=mon-bucket-unique-12345"
```

> Si le bucket contient des images, videz-le d'abord :
> `aws s3 rm s3://mon-bucket-unique-12345 --recursive --profile devops-coursera`
