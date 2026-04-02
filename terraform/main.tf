###############################################################################
# Provider
###############################################################################
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

###############################################################################
# Récupérer l'AMI Amazon Linux 2023 la plus récente
###############################################################################
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

###############################################################################
# Réseau — VPC dédié (pas de VPC par défaut dans ce compte)
###############################################################################
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "image-uploader-vpc"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true

  tags = {
    Name = "image-uploader-public-subnet"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "image-uploader-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "image-uploader-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

###############################################################################
# Security Group — Phase 1 (sans restriction fine)
#
# Ouvre les ports nécessaires pour accéder à l'app et administrer la VM.
# En Phase 2, on pourra restreindre les sources IP.
###############################################################################
resource "aws_security_group" "app_sg" {
  name        = "image-uploader-sg"
  description = "Autorise HTTP (80) et SSH (22) en entree"
  vpc_id      = aws_vpc.main.id

  # SSH
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # À restreindre en production
  }

  # HTTP
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Sortie — tout autorisé (nécessaire pour pip install, accès S3, etc.)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "image-uploader-sg"
  }
}

###############################################################################
# PHASE 2 — Politiques d'accès IAM
#
# Pour qu'une instance EC2 puisse accéder à S3, il faut 3 éléments :
#
#   1. IAM ROLE         = une identité que l'EC2 peut "assumer"
#   2. IAM POLICY       = les permissions (quelles actions sur quelles ressources)
#   3. INSTANCE PROFILE = le lien entre le rôle et l'instance EC2
#
# Sans ces 3 éléments, boto3 sur l'EC2 ne trouve aucun credential
# et lève l'erreur NoCredentialsError.
###############################################################################

# ---------------------------------------------------------------------------
# 1. IAM ROLE — "Qui peut assumer ce rôle ?"
#
# La "Trust Policy" (assume_role_policy) définit QUI a le droit d'utiliser
# ce rôle. Ici, on autorise uniquement le service EC2.
#
# Quand l'EC2 démarre, elle contacte le metadata service (169.254.169.254)
# pour obtenir des credentials temporaires via STS (Security Token Service).
# Ces credentials sont renouvelées automatiquement par AWS.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "ec2_s3_role" {
  name = "image-uploader-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          # Seul le service EC2 peut assumer ce rôle.
          # Un utilisateur IAM ou un autre service AWS ne le pourrait pas.
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "image-uploader-ec2-role"
  }
}

# ---------------------------------------------------------------------------
# 2. IAM POLICY — "Quelles actions sont autorisées, sur quelles ressources ?"
#
# On applique le PRINCIPE DU MOINDRE PRIVILÈGE :
#   - Seulement les actions nécessaires (Put, Get, List)
#   - Seulement sur NOTRE bucket (pas tous les buckets du compte)
#
# Deux types de Resource :
#   - arn:aws:s3:::BUCKET       → pour les opérations au niveau du bucket (ListBucket)
#   - arn:aws:s3:::BUCKET/*     → pour les opérations sur les objets (Get/PutObject)
# ---------------------------------------------------------------------------
resource "aws_iam_policy" "s3_access" {
  name        = "image-uploader-s3-policy"
  description = "Permet a l'EC2 de lire, ecrire, supprimer et lister les objets dans le bucket images"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowListBucket"
        Effect = "Allow"
        Action = [
          # Lister le contenu du bucket (nécessaire pour list_objects_v2)
          "s3:ListBucket"
        ]
        # Ressource = le bucket lui-même (pas les objets)
        Resource = aws_s3_bucket.images.arn
      },
      {
        Sid    = "AllowObjectOperations"
        Effect = "Allow"
        Action = [
          # Lire un objet (nécessaire pour generate_presigned_url + download)
          "s3:GetObject",
          # Écrire un objet (nécessaire pour upload_fileobj)
          "s3:PutObject",
          # Supprimer un objet
          "s3:DeleteObject"
        ]
        # Ressource = tous les objets DANS le bucket (le /* est important)
        Resource = "${aws_s3_bucket.images.arn}/*"
      }
    ]
  })
}

# Attacher la policy au rôle
resource "aws_iam_role_policy_attachment" "s3_attach" {
  role       = aws_iam_role.ec2_s3_role.name
  policy_arn = aws_iam_policy.s3_access.arn
}

# ---------------------------------------------------------------------------
# 3. INSTANCE PROFILE — "Le lien entre le rôle IAM et l'instance EC2"
#
# Une instance EC2 ne référence pas directement un IAM Role.
# Elle utilise un Instance Profile, qui est un conteneur pour le rôle.
#
# C'est grâce à l'Instance Profile que boto3 peut récupérer les credentials
# temporaires via le metadata service de l'instance.
# ---------------------------------------------------------------------------
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "image-uploader-ec2-profile"
  role = aws_iam_role.ec2_s3_role.name
}

###############################################################################
# Déploiement de l'application via S3
#
# Le code applicatif (app.py + template HTML) est uploadé dans le bucket S3
# sous le préfixe deploy/. Le user_data.sh télécharge ces fichiers au boot.
# Cela évite la limite de 16 Ko du user_data EC2.
###############################################################################
resource "aws_s3_object" "app_py" {
  bucket = aws_s3_bucket.images.id
  key    = "deploy/app.py"
  source = "${path.module}/../app/app.py"
  etag   = filemd5("${path.module}/../app/app.py")
}

resource "aws_s3_object" "index_html" {
  bucket = aws_s3_bucket.images.id
  key    = "deploy/templates/index.html"
  source = "${path.module}/../app/templates/index.html"
  etag   = filemd5("${path.module}/../app/templates/index.html")
}

###############################################################################
# EC2 Instance — Phase 2 (avec Instance Profile)
#
# Le user_data télécharge l'app depuis S3 au premier boot.
# depends_on garantit que les fichiers sont dans S3 avant le boot.
###############################################################################
resource "aws_instance" "app_server" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  user_data = templatefile("${path.module}/user_data.sh", {
    bucket_name = var.bucket_name
    aws_region  = var.aws_region
  })

  depends_on = [
    aws_s3_object.app_py,
    aws_s3_object.index_html,
  ]

  tags = {
    Name = "image-uploader-ec2"
  }
}

###############################################################################
# S3 Bucket
###############################################################################
resource "aws_s3_bucket" "images" {
  bucket = var.bucket_name

  tags = {
    Name = "image-uploader-bucket"
  }
}

# Bloquer explicitement tout accès public au bucket
resource "aws_s3_bucket_public_access_block" "images_block" {
  bucket = aws_s3_bucket.images.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# 4. BUCKET POLICY (optionnelle) — "Qui peut accéder au bucket ?"
#
# La différence avec la IAM Policy :
#   - IAM Policy  = attachée à un rôle/user → "que peut faire CE rôle ?"
#   - Bucket Policy = attachée au bucket   → "qui peut toucher CE bucket ?"
#
# Les deux sont évaluées ensemble par AWS. L'accès n'est accordé que si
# les deux autorisent l'action (sauf si l'une d'elles a un Deny explicite,
# qui l'emporte toujours).
#
# Cette Bucket Policy restreint l'accès au bucket UNIQUEMENT au rôle IAM
# de notre EC2. Même un admin IAM avec des droits S3 larges ne pourrait
# pas accéder à ce bucket s'il n'utilise pas ce rôle spécifique.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket_policy" "images_policy" {
  bucket = aws_s3_bucket.images.id

  # Dépend du block public access pour éviter un conflit de création
  depends_on = [aws_s3_bucket_public_access_block.images_block]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEC2RoleOnly"
        Effect = "Allow"
        Principal = {
          # Seul notre rôle IAM (via l'instance EC2) peut accéder au bucket
          AWS = aws_iam_role.ec2_s3_role.arn
        }
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.images.arn,
          "${aws_s3_bucket.images.arn}/*"
        ]
      }
    ]
  })
}
