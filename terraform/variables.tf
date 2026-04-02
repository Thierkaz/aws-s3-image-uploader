variable "aws_profile" {
  description = "Nom du profil AWS CLI à utiliser (SSO)"
  type        = string
  default     = "devops-coursera"
}

variable "aws_region" {
  description = "Région AWS"
  type        = string
  default     = "eu-west-3" # Paris
}

variable "instance_type" {
  description = "Type d'instance EC2"
  type        = string
  default     = "t2.micro"
}

variable "key_name" {
  description = "Nom de la paire de clés SSH pour accéder à l'instance EC2"
  type        = string
}

variable "bucket_name" {
  description = "Nom du bucket S3 (doit être globalement unique)"
  type        = string
  default     = "demo-image-uploader-bucket"
}
