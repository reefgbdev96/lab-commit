# PostgreSQL reachable only from pods carrying the db-client security group and
# from the jump box. The master password is created and rotated by Secrets
# Manager; the application logs in with IAM tokens and holds no password at all.
resource "aws_security_group" "db" {
  name        = var.name
  description = "PostgreSQL: db-client pods and the jump box only"
  vpc_id      = var.vpc_id
}

# Attached to backend pods through a SecurityGroupPolicy: only they reach the database.
resource "aws_security_group" "client" {
  name        = "${var.name}-client"
  description = "Grants PostgreSQL access to the pods that carry it"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_egress_rule" "client_to_db" {
  security_group_id            = aws_security_group.client.id
  description                  = "PostgreSQL to the database"
  referenced_security_group_id = aws_security_group.db.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "postgres" {
  for_each = merge({ client = aws_security_group.client.id }, var.extra_allowed_security_group_ids)

  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from ${each.key}"
  referenced_security_group_id = each.value
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

module "db" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 7.2.2"

  identifier = var.name

  engine               = "postgres"
  engine_version       = var.engine_version
  family               = "postgres${var.engine_version}"
  major_engine_version = var.engine_version
  instance_class       = var.instance_class
  allocated_storage    = var.allocated_storage
  storage_type         = "gp3"

  db_name  = var.database_name
  username = var.username

  manage_master_user_password         = true
  iam_database_authentication_enabled = true

  # A subnet group spanning two AZs is mandatory even for a single-AZ instance.
  create_db_subnet_group = true
  subnet_ids             = var.private_subnet_ids
  vpc_security_group_ids = [aws_security_group.db.id]

  publicly_accessible = false
  storage_encrypted   = true
  multi_az            = var.multi_az

  backup_retention_period = var.backup_retention_days
  skip_final_snapshot     = var.skip_final_snapshot
  deletion_protection     = var.deletion_protection
}
