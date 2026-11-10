resource "aws_db_instance" "postgres" {
  identifier     = "${var.prefijo}-rds"
  engine         = "postgres"
  engine_version = "17"
  instance_class = "db.t4g.micro"

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "taller"
  username = "taller_admin"

  # RDS genera la contraseña y la guarda en Secrets Manager.
  # No se escribe "password": así no queda en el código ni en el estado.
  manage_master_user_password = true

  # Red
  db_subnet_group_name   = aws_db_subnet_group.rds.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = false

  # Ajustes para bajo costo y eliminación limpia
  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true
}
