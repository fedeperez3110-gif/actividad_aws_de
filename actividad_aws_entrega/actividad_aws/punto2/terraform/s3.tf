resource "aws_s3_bucket" "datos" {
  bucket        = var.nombre_bucket
  force_destroy = true
}
