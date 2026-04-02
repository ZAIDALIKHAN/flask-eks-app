# Get latest Ubuntu 22.04 LTS AMI (more widely available than 24.04)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# Security Group for Jenkins
resource "aws_security_group" "jenkins" {
  name        = "${var.project_name}-jenkins-sg"
  description = "Jenkins security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Jenkins UI - open for lab, restrict in prod"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH - open for lab, restrict in prod"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-jenkins-sg"
  }
}

# Key pair for SSH access
resource "tls_private_key" "jenkins" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "jenkins" {
  key_name   = "${var.project_name}-jenkins-key"
  public_key = tls_private_key.jenkins.public_key_openssh
}

# Save private key locally
resource "local_sensitive_file" "jenkins_key" {
  content         = tls_private_key.jenkins.private_key_pem
  filename        = "${path.module}/jenkins-key.pem"
  file_permission = "0400"
}

# Jenkins EC2
resource "aws_instance" "jenkins" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.jenkins_instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.jenkins.id]
  iam_instance_profile   = aws_iam_instance_profile.jenkins.name
  key_name               = aws_key_pair.jenkins.key_name

  root_block_device {
    volume_size = 20
    volume_type = "gp2"
    encrypted   = true
  }

  user_data = <<-EOF
    #!/bin/bash
    set -e

    apt-get update -y
    apt-get install -y curl wget unzip git

    # Install Java 17
    apt-get install -y openjdk-17-jdk

    # Install Jenkins
    curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | \
      gpg --dearmor -o /usr/share/keyrings/jenkins-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.gpg] \
      https://pkg.jenkins.io/debian-stable binary/" | \
      tee /etc/apt/sources.list.d/jenkins.list
    apt-get update -y
    apt-get install -y jenkins
    systemctl start jenkins
    systemctl enable jenkins

    # Install Docker
    apt-get install -y docker.io
    systemctl start docker
    systemctl enable docker
    usermod -aG docker jenkins
    usermod -aG docker ubuntu

    # Install AWS CLI
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip awscliv2.zip && ./aws/install

    # Install kubectl
    curl -LO "https://dl.k8s.io/release/$(curl -L -s \
      https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl && mv kubectl /usr/local/bin/

    # Install Helm
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

    echo "Jenkins setup complete" > /tmp/jenkins-setup-done
  EOF

  tags = {
    Name = "${var.project_name}-jenkins"
  }
}
