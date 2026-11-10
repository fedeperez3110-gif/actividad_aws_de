output "bucket" {
  value = aws_s3_bucket.datos.bucket
}

output "vpc_id" {
  value = data.aws_vpc.default.id
}

output "subredes" {
  value = data.aws_subnets.default.ids
}

output "ami_id" {
  value = data.aws_ami.amazon_linux.id
}

output "sg_ec2" {
  value = aws_security_group.ec2.id
}

output "sg_rds" {
  value = aws_security_group.rds.id
}

output "ec2_id" {
  value = aws_instance.app.id
}

output "ec2_ip_privada" {
  value = aws_instance.app.private_ip
}

output "rds_endpoint" {
  value = aws_db_instance.postgres.address
}

output "rds_secreto_arn" {
  value = aws_db_instance.postgres.master_user_secret[0].secret_arn
}
