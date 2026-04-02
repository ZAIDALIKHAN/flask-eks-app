output "vpc_id" {
  value = aws_vpc.main.id
}

output "eks_cluster_name" {
  value = aws_eks_cluster.main.name
}

output "eks_cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}

output "ecr_repository_url" {
  value = aws_ecr_repository.flask_app.repository_url
}

output "rds_primary_endpoint" {
  value     = aws_db_instance.main.address
  sensitive = true
}


output "secrets_manager_arn" {
  value = aws_secretsmanager_secret.db_credentials.arn
}

output "jenkins_public_ip" {
  value = aws_instance.jenkins.public_ip
}

output "jenkins_url" {
  value = "http://${aws_instance.jenkins.public_ip}:8080"
}

output "flask_app_role_arn" {
  value = aws_iam_role.flask_app.arn
}

output "lbc_role_arn" {
  value = aws_iam_role.lbc.arn
}

output "cloudwatch_dashboard_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${var.project_name}-dashboard"
}
