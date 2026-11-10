# La VPC por defecto que AWS crea en cada región
data "aws_vpc" "default" {
  default = true
}

# Todas las subredes de esa VPC (una por zona de disponibilidad)
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# La imagen más reciente de Amazon Linux 2023 para procesadores x86
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}
