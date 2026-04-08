#!/bin/bash
set -e

echo "Fetching values from Terraform outputs..."
ECR_URL=$(cd terraform && terraform output -raw ecr_repository_url)
ROLE_ARN=$(cd terraform && terraform output -raw flask_app_role_arn)
CLUSTER=$(cd terraform && terraform output -raw eks_cluster_name)
VPC_ID=$(cd terraform && terraform output -raw vpc_id)

echo "ECR: $ECR_URL"
echo "Role: $ROLE_ARN"

# Update kubeconfig
aws eks update-kubeconfig --region us-east-1 --name $CLUSTER

# Install/upgrade LBC
helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(cd terraform && terraform output -raw lbc_role_arn) \
  --set region=us-east-1 \
  --set vpcId=$VPC_ID

# Deploy Flask app
kubectl create namespace flask-app --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install flask-app ./helm/flask-app \
  --namespace flask-app \
  --set image.repository=$ECR_URL \
  --set image.tag=latest \
  --set serviceAccount.roleArn=$ROLE_ARN

echo "Done! Waiting for ALB..."
kubectl get ingress -n flask-app -w
