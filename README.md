# EKS Infrastructure Setup

This CloudFormation template creates a complete Amazon EKS cluster with supporting infrastructure including VPC, subnets, security groups, IAM roles, EBS CSI driver, and AWS Load Balancer Controller IAM setup.

## Prerequisites

1. **Create EC2 Key Pair** (for worker node SSH access):
   ```bash
   # Create key pair and save private key
   aws ec2 create-key-pair \
     --key-name federal-ps-eks-keypair \
     --query 'KeyMaterial' \
     --output text > federal-ps.pem
   
   # Set proper permissions
   chmod 400 federal-ps.pem
   ```

2. **Install eksctl** (needed for OIDC provider setup):
   ```bash
   # macOS
   brew tap weaveworks/tap
   brew install weaveworks/tap/eksctl
   
   # Linux
   curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
   sudo mv /tmp/eksctl /usr/local/bin
   ```

## Deploy Infrastructure (Two-Phase Process)

⚠️ **Important**: This deployment requires two phases due to OIDC provider dependency for IRSA (IAM Roles for Service Accounts).

### Phase 1: Initial Deployment + OIDC Provider

```bash
# 1. Deploy CloudFormation stack (will partially fail - this is expected)
aws cloudformation deploy \
  --template-file eks-infra.yaml \
  --stack-name federal-ps-eks-stack \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-1 \
  --parameter-overrides KeyName=federal-ps

# 2. Create OIDC identity provider (required for IRSA)
eksctl utils associate-iam-oidc-provider \
  --cluster federal-ps-eks-cluster \
  --approve \
  --region us-west-1
```

### Phase 2: Complete Deployment

```bash
# 3. Re-deploy CloudFormation stack (now will succeed completely)
aws cloudformation deploy \
  --template-file eks-infra.yaml \
  --stack-name federal-ps-eks-stack \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-1 \
  --parameter-overrides KeyName=federal-ps
```

### What Happens in Each Phase?

**Phase 1**
- ✅ VPC, subnets, NAT gateway, security groups
- ✅ Basic IAM roles (cluster and node group)
- ✅ EKS cluster creation (with automatic OIDC issuer)
- ❌ IRSA roles fail (EBS CSI, Load Balancer Controller)

**Phase 2**
- ✅ IRSA roles (now OIDC provider exists)
- ✅ EBS CSI driver add-on
- ✅ Complete infrastructure ready

## Connect to Cluster

```bash
aws eks update-kubeconfig --region us-west-1 --name federal-ps-eks-cluster
```

## Apply Admin Access (Required for Node Group)

The `aws-auth` ConfigMap needs to be updated with the correct IAM role ARN for your worker nodes:

```bash
# 1. Get the actual node group IAM role ARN
NODE_ROLE_ARN=$(aws eks describe-nodegroup \
  --cluster-name federal-ps-eks-cluster \
  --nodegroup-name federal-ps-eks-cluster-NodeGroup \
  --region us-west-1 \
  --query 'nodegroup.nodeRole' \
  --output text)

echo "Node Role ARN: $NODE_ROLE_ARN"

# 2. Update the aws-auth-edit.yaml file with the correct role ARN
sed -i.bak "s|rolearn: arn:aws:iam::[0-9]*:role/.*|rolearn: $NODE_ROLE_ARN|" aws-auth-edit.yaml

# 3. Apply the corrected aws-auth ConfigMap
kubectl apply -f aws-auth-edit.yaml -n kube-system

# 4. Verify nodes are ready (may take 1-2 minutes)
kubectl get nodes
```

## Apply Storage Class

```bash
kubectl apply -f gp3-sc.yaml
```

## Install AWS Load Balancer Controller (Helm)

The IAM roles and policies are created by CloudFormation. Install the controller using Helm:

```bash
# Add the EKS charts Helm repository
helm repo add eks https://aws.github.io/eks-charts
helm repo update eks

# Install the AWS Load Balancer Controller
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=federal-ps-eks-cluster \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --version 1.13.0

# Verify installation
kubectl get deployment -n kube-system aws-load-balancer-controller
```

## What's Included

### Infrastructure Components
- **VPC** with public and private subnets across 2 AZs
- **NAT Gateway** for private subnet internet access
- **Security Groups** for EKS cluster and worker nodes
- **IAM Roles** for EKS cluster and worker nodes with proper policies

### EKS Components
- **EKS Cluster** (Kubernetes v1.33)
- **Managed Node Group** using Bottlerocket AMI (FIPS-enabled)
- **OIDC Identity Provider** for IRSA support (created manually via eksctl)

### Add-ons & Controllers
- **EBS CSI Driver** (managed add-on) with IAM role
- **AWS Load Balancer Controller IAM setup** (policy and role)

### Security Features
- **Resource Protection**: Critical resources have DeletionPolicy: Retain
- **IRSA**: IAM Roles for Service Accounts for secure authentication
- **Consistent Tagging**: All resources tagged with environment and management info
- **Auto-tagging**: EKS-managed security group automatically tagged for Load Balancer Controller

### Load Balancer Support
- **Automatic Security Group Tagging**: Lambda function automatically tags EKS-managed security group with `elbv2.k8s.aws/cluster` tag
- **Ready for LoadBalancer Services**: No manual security group configuration needed for Kafka or other LoadBalancer services

## Notes

- EBS CSI driver is installed as a managed EKS add-on
- Load Balancer Controller requires Helm installation after infrastructure deployment
- All IAM roles use IRSA (no stored credentials)
- Resources are protected from accidental deletion
- Two-phase deployment is required due to CloudFormation limitations with OIDC providers
- **EKS Security Group Auto-tagging**: Custom Lambda resource automatically tags the EKS-managed security group for Load Balancer Controller compatibility
- **Important**: Always update `aws-auth-edit.yaml` with the correct IAM role ARN before applying