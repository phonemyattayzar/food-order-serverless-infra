resource "random_password" "db" {
  length           = 28
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}


resource "random_password" "app_secret" {
  length  = 64
  special = false
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.project_name}-${var.environment}-db"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_security_group" "db" {
  name        = "${var.project_name}-${var.environment}-db"
  description = "Allow PostgreSQL only from Lambda security group"
  vpc_id      = aws_vpc.this.id
}

resource "aws_db_instance" "this" {
  identifier                      = "${var.project_name}-${var.environment}-db"
  engine                          = "postgres"
  engine_version                  = var.db_engine_version
  instance_class                  = var.db_instance_class
  allocated_storage               = 20
  max_allocated_storage           = 100
  storage_type                    = "gp3"
  storage_encrypted               = true
  db_name                         = var.db_name
  username                        = var.db_username
  password                        = random_password.db.result
  port                            = 5432
  db_subnet_group_name            = aws_db_subnet_group.this.name
  vpc_security_group_ids          = [aws_security_group.db.id]
  multi_az                        = var.db_multi_az
  publicly_accessible             = false
  backup_retention_period         = var.db_backup_retention_days
  deletion_protection             = var.db_deletion_protection
  skip_final_snapshot             = var.skip_final_snapshot
  final_snapshot_identifier       = "${var.project_name}-${var.environment}-final"
  apply_immediately               = false
  copy_tags_to_snapshot           = true
  enabled_cloudwatch_logs_exports = ["postgresql"]

  lifecycle {
    ignore_changes = [password]
  }
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.project_name}/${var.environment}/database"
  recovery_window_in_days = var.secret_recovery_window_days
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    host       = aws_db_instance.this.address
    port       = 5432
    database   = var.db_name
    username   = var.db_username
    password   = random_password.db.result
    secret_key = random_password.app_secret.result
  })
}

resource "aws_vpc_security_group_ingress_rule" "database_from_lambda" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.lambda.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL from Lambda tasks"
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id
}
