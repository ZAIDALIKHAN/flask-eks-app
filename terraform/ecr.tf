resource "aws_ecr_repository" "flask_app" {
  name                 = "${var.project_name}/flask-app"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  # Enable image scanning on every push
  image_scanning_configuration {
    scan_on_push = true
  }

  # Encryption
  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name = "${var.project_name}-flask-app-ecr"
  }
}

# Lifecycle policy — keep only last 10 images (cost saving)
resource "aws_ecr_lifecycle_policy" "flask_app" {
  repository = aws_ecr_repository.flask_app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = {
        type = "expire"
      }
    }]
  })
}
