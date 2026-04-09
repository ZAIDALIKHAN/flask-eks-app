#!/bin/bash
set -e

# ── Colors ────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# ─────────────────────────────────────────────────────────────
# STEP 1: Fetch Terraform outputs
# ─────────────────────────────────────────────────────────────
log "Fetching values from Terraform outputs..."
ECR_URL=$(cd terraform && terraform output -raw ecr_repository_url)
ROLE_ARN=$(cd terraform && terraform output -raw flask_app_role_arn)
CLUSTER=$(cd terraform && terraform output -raw eks_cluster_name)
VPC_ID=$(cd terraform && terraform output -raw vpc_id)
LBC_ROLE_ARN=$(cd terraform && terraform output -raw lbc_role_arn)
REGION="us-east-1"
PROJECT="flask-eks"

log "ECR:     $ECR_URL"
log "Role:    $ROLE_ARN"
log "Cluster: $CLUSTER"
log "VPC:     $VPC_ID"

# ─────────────────────────────────────────────────────────────
# STEP 2: Update kubeconfig
# ─────────────────────────────────────────────────────────────
log "Updating kubeconfig..."
aws eks update-kubeconfig --region $REGION --name $CLUSTER

# ─────────────────────────────────────────────────────────────
# STEP 3: Add Helm repos
# ─────────────────────────────────────────────────────────────
log "Adding Helm repos..."
helm repo add eks https://aws.github.io/eks-charts
helm repo add aws-observability https://aws-observability.github.io/helm-charts
helm repo update
log "Helm repos updated!"

# ─────────────────────────────────────────────────────────────
# STEP 4: Install AWS Load Balancer Controller
# ─────────────────────────────────────────────────────────────
log "Installing AWS Load Balancer Controller..."
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$LBC_ROLE_ARN \
  --set region=$REGION \
  --set vpcId=$VPC_ID

# Wait for LBC to be fully ready before deploying flask app
# Without this the LBC webhook isn't up and helm install fails with
# "no endpoints available for service aws-load-balancer-webhook-service"
log "Waiting for AWS Load Balancer Controller to be ready..."
kubectl rollout status deployment aws-load-balancer-controller \
  -n kube-system --timeout=120s
log "LBC is ready!"

# ─────────────────────────────────────────────────────────────
# STEP 5: Install CloudWatch Observability (CW Agent + Fluent Bit)
#
# amazon-cloudwatch-observability chart installs two DaemonSets:
#
# CloudWatch Agent (one pod per node):
#   - Collects node/pod/container CPU, memory, disk, network metrics
#   - Sends to CloudWatch namespace: ContainerInsights
#   - Powers EKS Node CPU dashboard widget + node-cpu-high alarm
#
# Fluent Bit (one pod per node):
#   - Tails /var/log/containers/ on each node
#   - Parses JSON logs from flask app
#   - Ships all pod logs to CloudWatch log group: /eks/flask-eks/flask-app
#   - Powers Flask App Logs dashboard widget
# ─────────────────────────────────────────────────────────────
log "Installing CloudWatch Observability (CW Agent + Fluent Bit)..."
kubectl create namespace amazon-cloudwatch --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install amazon-cloudwatch-observability \
  aws-observability/amazon-cloudwatch-observability \
  -n amazon-cloudwatch \
  --set clusterName=$CLUSTER \
  --set region=$REGION

log "Waiting for CloudWatch Agent DaemonSet to be ready..."
kubectl rollout status daemonset cloudwatch-agent \
  -n amazon-cloudwatch --timeout=120s
log "CloudWatch Agent is ready! Metrics flowing to ContainerInsights."

log "Waiting for Fluent Bit DaemonSet to be ready..."
kubectl rollout status daemonset fluent-bit \
  -n amazon-cloudwatch --timeout=120s
log "Fluent Bit is ready! Logs flowing to /eks/${PROJECT}/flask-app"

# ─────────────────────────────────────────────────────────────
# STEP 6: Deploy Flask app
# ─────────────────────────────────────────────────────────────
log "Deploying Flask app..."
kubectl create namespace flask-app --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install flask-app ./helm/flask-app \
  --namespace flask-app \
  --set image.repository=$ECR_URL \
  --set image.tag=latest \
  --set serviceAccount.roleArn=$ROLE_ARN

log "Waiting for Flask app to be ready..."
kubectl rollout status deployment flask-app \
  -n flask-app --timeout=120s
log "Flask app is ready!"

# ─────────────────────────────────────────────────────────────
# STEP 7: Print summary
# ─────────────────────────────────────────────────────────────
ALB=$(kubectl get ingress flask-app -n flask-app \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending...")

echo ""
echo "=================================================="
log "Deployment complete! Summary:"
echo "=================================================="
echo ""
echo "  Flask App URL:  http://$ALB/books"
echo "  Health Live:    http://$ALB/health/live"
echo "  Health Ready:   http://$ALB/health/ready"
echo ""
echo "  CloudWatch Dashboard:"
echo "  https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards:name=${PROJECT}-dashboard"
echo ""
echo "  Log Groups:"
echo "  /aws/eks/${CLUSTER}/cluster      (EKS control plane logs)"
echo "  /eks/${PROJECT}/flask-app         (Flask app logs via Fluent Bit)"
echo ""
echo "  Helm Releases:"
kubectl get helmrelease -A 2>/dev/null || helm list -A
echo ""
echo "=================================================="

# Watch ingress if ALB not yet assigned
if [ "$ALB" = "pending..." ]; then
  log "Waiting for ALB address to be assigned..."
  kubectl get ingress -n flask-app -w
fi
