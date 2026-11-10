variable "region" {
  description = "Región de AWS donde se despliega todo"
  type        = string
  default     = "us-east-2"
}

variable "prefijo" {
  description = "Prefijo para nombrar los recursos"
  type        = string
  default     = "fp-taller-p2"
}

variable "nombre_bucket" {
  description = "Nombre del bucket S3 (único en todo el mundo)"
  type        = string
  default     = "fp-taller-p2-tf-20261022"
}
