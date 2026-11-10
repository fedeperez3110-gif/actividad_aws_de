# --- Grupo de seguridad de la EC2 ---
resource "aws_security_group" "ec2" {
  name        = "${var.prefijo}-sg-ec2"
  description = "Grupo de seguridad de la instancia EC2 del punto 2"
  vpc_id      = data.aws_vpc.default.id
}

# La EC2 puede salir a internet (por ejemplo, para instalar actualizaciones)
resource "aws_vpc_security_group_egress_rule" "ec2_salida" {
  security_group_id = aws_security_group.ec2.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- Grupo de seguridad de RDS ---
resource "aws_security_group" "rds" {
  name        = "${var.prefijo}-sg-rds"
  description = "Grupo de seguridad de RDS PostgreSQL del punto 2"
  vpc_id      = data.aws_vpc.default.id
}

# RDS solo acepta conexiones al puerto 5432 desde instancias con el grupo de la EC2
resource "aws_vpc_security_group_ingress_rule" "rds_desde_ec2" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = aws_security_group.ec2.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

# --- Subredes donde puede vivir RDS ---
resource "aws_db_subnet_group" "rds" {
  name       = "${var.prefijo}-subnets"
  subnet_ids = data.aws_subnets.default.ids
}
