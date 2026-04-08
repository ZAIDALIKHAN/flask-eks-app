# Flask EKS App — Complete Deployment Guide

## Architecture Overview

```
Internet
   │
   ▼
[ALB] ← provisioned by AWS Load Balancer Controller
   │
   ▼
[Ingress] (K8s resource)
   │
   ▼
[Service: ClusterIP]
   │
   ▼
[Flask Pods] ──IRSA──► [IAM Role] ──► [Secrets Manager] ──► [RDS PostgreSQL]
```

---

## Bugs Found & Fixed

### Bug 1 — IRSA Trust Policy: Wrong Namespace (terraform/iam.tf)

**What broke:** Pods crashed with `AccessDenied: Not authorized to perform sts:AssumeRoleWithWebIdentity`

**Why it happened:**
IRSA (IAM Roles for Service Accounts) works by linking a Kubernetes ServiceAccount
to an IAM Role via a trust policy. The trust policy says:
"Only allow this specific ServiceAccount in this specific namespace to assume this role."

The original trust policy had:
```
system:serviceaccount:default:flask-app-sa   ← WRONG namespace
```

But helm deploys to the `flask-app` namespace, so the pod's identity was:
```
system:serviceaccount:flask-app:flask-app-sa ← ACTUAL identity
```

AWS STS compared these two strings — they didn't match — so it denied the request.

**Fix in terraform/iam.tf:**
```hcl
# BEFORE (wrong)
values = ["system:serviceaccount:default:flask-app-sa"]

# AFTER (correct)
values = ["system:serviceaccount:flask-app:flask-app-sa"]
```

---

### Bug 2 — LBC IAM Policy: Missing DescribeListenerAttributes (terraform/iam.tf)

**What broke:** Ingress stayed in `ADDRESS: <empty>` — ALB was never created.
LBC logs showed: `AccessDenied: not authorized to perform elasticloadbalancing:DescribeListenerAttributes`

**Why it happened:**
The `lbc-iam-policy.json` file used was an older version downloaded from AWS docs.
AWS Load Balancer Controller v2.7+ requires `DescribeListenerAttributes` and
`ModifyListenerAttributes` which were not in older policy documents.

**Fix in terraform/iam.tf:**
Removed the `file("lbc-iam-policy.json")` reference and inlined the full
up-to-date policy directly in Terraform including all required permissions.
This means no external file dependency and the policy is always correct.

---

### Bug 3 — Wrong ECR Account ID in values.yaml (helm/flask-app/values.yaml)

**What broke:** Image pull would fail if deployed fresh from git.

**Why it happened:**
```yaml
# BEFORE (wrong account ID — likely a copy-paste from another project)
repository: 708037417213.dkr.ecr.us-east-1.amazonaws.com/flask-eks/flask-app

# AFTER (correct account ID)
repository: 672830962317.dkr.ecr.us-east-1.amazonaws.com/flask-eks/flask-app
```

---

### Bug 4 — Image Tag Mismatch in values.yaml (helm/flask-app/values.yaml)

**What broke:** Even with correct ECR URL, K8s would try to pull `v1.0.0` but
the image was pushed as `latest`, causing `ImagePullBackOff`.

**Fix:**
```yaml
# BEFORE
tag: "v1.0.0"
pullPolicy: IfNotPresent

# AFTER
tag: "latest"
pullPolicy: Always   # Always pull ensures you get the newest image on each deploy
```

---

### Bug 5 — Empty roleArn in values.yaml (helm/flask-app/values.yaml)

**What broke:** ServiceAccount was created without the IRSA annotation,
so even if the trust policy was correct, the pod had no role to assume.

```yaml
# BEFORE (empty — annotation would be blank)
serviceAccount:
  roleArn: ""

# AFTER
serviceAccount:
  roleArn: "arn:aws:iam::672830962317:role/flask-eks-flask-app-role"
```

The annotation `eks.amazonaws.com/role-arn` on the ServiceAccount is what tells
the EKS pod identity webhook to inject AWS credentials into the pod via a
projected service account token. Without this, IRSA doesn't work at all.

---

## How IRSA Works (Full Explanation)

```
Pod starts
  │
  ▼
EKS injects a projected token into the pod
(because ServiceAccount has eks.amazonaws.com/role-arn annotation)
  │
  ▼
App calls boto3 (AWS SDK)
  │
  ▼
boto3 calls STS: AssumeRoleWithWebIdentity
  - Here is my token (from the projected volume)
  - I want to assume role: arn:aws:iam::672830962317:role/flask-eks-flask-app-role
  │
  ▼
STS checks the IAM Role's trust policy:
  - Who is the OIDC issuer? (matches EKS cluster OIDC provider)
  - What is the sub claim? system:serviceaccount:flask-app:flask-app-sa
  - Does it match the Condition in the trust policy? ✅ YES
  │
  ▼
STS returns temporary credentials
  │
  ▼
boto3 uses credentials to call Secrets Manager
  │
  ▼
App gets DB credentials and connects to RDS ✅
```

---

## How AWS Load Balancer Controller Works (Full Explanation)

```
You apply an Ingress resource with annotation:
  kubernetes.io/ingress.class: alb

LBC (running in kube-system) watches for Ingress resources
  │
  ▼
LBC reads the Ingress spec and annotations
  │
  ▼
LBC calls AWS APIs to create:
  - Application Load Balancer (ALB)
  - Target Group (points to pod IPs — because target-type: ip)
  - Listener (port 80)
  - Listener Rules (path routing)
  │
  ▼
LBC updates Ingress .status.loadBalancer.ingress[0].hostname
  = the ALB DNS name
  │
  ▼
kubectl get ingress shows ADDRESS = k8s-xxxx.us-east-1.elb.amazonaws.com
```

LBC uses IRSA (lbc-role) to make these AWS API calls.
If the IAM policy is missing any permission, the ALB creation silently fails.

---

## Prerequisites

- AWS CLI configured with admin access
- terraform >= 1.7
- kubectl
- helm >= 3
- docker

---

## Step-by-Step Deployment (Fresh Clone)

### 1. Clone and enter the repo
```bash
git clone <your-repo-url>
cd flask-eks-app
```

### 2. Deploy infrastructure with Terraform
```bash
cd terraform
terraform init
terraform apply -var="rds_password=YourSecurePassword123!"
```

Wait ~15 minutes for EKS + RDS to provision.

Note the outputs — you'll need:
- `ecr_repository_url`
- `eks_cluster_name`
- `flask_app_role_arn`

### 3. Configure kubectl
```bash
aws eks update-kubeconfig --region us-east-1 --name flask-eks-cluster
kubectl get nodes  # should show 2 Ready nodes
```

### 4. Build and push Docker image
```bash
cd ..  # back to flask-eks-app root

# Authenticate to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  672830962317.dkr.ecr.us-east-1.amazonaws.com

# Build, tag, push
docker build -t flask-eks/flask-app .
docker tag flask-eks/flask-app:latest \
  672830962317.dkr.ecr.us-east-1.amazonaws.com/flask-eks/flask-app:latest
docker push \
  672830962317.dkr.ecr.us-east-1.amazonaws.com/flask-eks/flask-app:latest
```

### 5. Install AWS Load Balancer Controller
```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=flask-eks-cluster \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="arn:aws:iam::672830962317:role/flask-eks-lbc-role" \
  --set region=us-east-1 \
  --set vpcId=<your-vpc-id>

# Verify LBC is running
kubectl get pods -n kube-system | grep aws-load-balancer
```

### 6. Deploy Flask app with Helm
```bash
kubectl create namespace flask-app

helm install flask-app ./helm/flask-app \
  --namespace flask-app \
  --set image.repository=672830962317.dkr.ecr.us-east-1.amazonaws.com/flask-eks/flask-app \
  --set image.tag=latest \
  --set serviceAccount.roleArn=arn:aws:iam::672830962317:role/flask-eks-flask-app-role
```

### 7. Verify deployment
```bash
# Pods should be Running (1/1)
kubectl get pods -n flask-app

# Wait for ALB DNS (takes ~2 min)
kubectl get ingress -n flask-app -w
```

### 8. Test the API
```bash
export ALB=<address-from-ingress>

curl http://$ALB/health/live
curl http://$ALB/health/ready
curl http://$ALB/books

# Create a book
curl -X POST http://$ALB/books \
  -H "Content-Type: application/json" \
  -d '{"title": "Clean Code", "author": "Robert Martin"}'
```

---

## Upgrading the App (After Code Changes)

```bash
# Rebuild and push
docker build -t flask-eks/flask-app .
docker tag flask-eks/flask-app:latest \
  672830962317.dkr.ecr.us-east-1.amazonaws.com/flask-eks/flask-app:latest
docker push \
  672830962317.dkr.ecr.us-east-1.amazonaws.com/flask-eks/flask-app:latest

# Rolling deploy (zero downtime)
kubectl rollout restart deployment flask-app -n flask-app
kubectl rollout status deployment flask-app -n flask-app
```

---

## Teardown
```bash
helm uninstall flask-app -n flask-app
helm uninstall aws-load-balancer-controller -n kube-system
cd terraform && terraform destroy -var="rds_password=YourSecurePassword123!"
```
