# RDS Subnet Group (must span 2 AZs)
resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

# Security Group for RDS
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "RDS security group - only allow from EKS nodes"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from EKS nodes only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_nodes.id, aws_eks_cluster.main.vpc_config[0].cluster_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-rds-sg"
  }
}

# RDS Primary Instance — free tier compatible
resource "aws_db_instance" "main" {
  identifier = "${var.project_name}-postgres"

  engine         = "postgres"
  engine_version = "16.3"
  instance_class = var.rds_instance_class  # db.t3.micro = free tier

  db_name  = var.rds_db_name
  username = var.rds_username
  password = var.rds_password

  # Storage — free tier gives 20GB gp2
  allocated_storage     = 20
  max_allocated_storage = 20       # disable autoscaling to stay in free tier
  storage_type          = "gp2"
  storage_encrypted     = true

  # Network
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  # Backups — free tier supports up to 7 days, keeping at 1 to save space
  backup_retention_period = 1
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  # Enhanced monitoring OFF — costs extra, not free tier
  # In prod: set monitoring_interval = 60 and add monitoring_role_arn
  monitoring_interval = 0

  # Multi-AZ OFF — not free tier eligible
  multi_az = false

  skip_final_snapshot = true
  deletion_protection = false

  tags = {
    Name = "${var.project_name}-postgres-primary"
  }
}

# Read Replica — NOT free tier, comment this out if budget is tight
# Keeping it here so you can explain the concept in the interview
# Uncomment when you want to demo DR
# resource "aws_db_instance" "replica" {
#   identifier          = "${var.project_name}-postgres-replica"
#   replicate_source_db = aws_db_instance.main.identifier
#   instance_class      = var.rds_instance_class
#   storage_type        = "gp2"
#   availability_zone   = data.aws_availability_zones.available.names[1]
#   publicly_accessible    = false
#   vpc_security_group_ids = [aws_security_group.rds.id]
#   monitoring_interval    = 0
#   skip_final_snapshot    = true
#   deletion_protection    = false
#   tags = { Name = "${var.project_name}-postgres-replica" }
# }

# Store DB credentials in Secrets Manager
resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "${var.project_name}/db-credentials"
  description             = "Flask app RDS credentials"
  recovery_window_in_days = 0  # instant delete (use 7 in real prod)

  tags = {
    Name = "${var.project_name}-db-secret"
  }
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = var.rds_username
    password = var.rds_password
    host     = aws_db_instance.main.address
    port     = 5432
    dbname   = var.rds_db_name
  })
}
