#!/bin/bash

# Script to tag EKS-managed security group for AWS Load Balancer Controller
# Run this after the CloudFormation stack has been successfully created

set -e

# Configuration
CLUSTER_NAME="${1:-federal-ps-eks-cluster}"
REGION="${2:-us-west-1}"

echo "Tagging EKS-managed security group for cluster: $CLUSTER_NAME in region: $REGION"

# Get the EKS cluster's managed security group ID
SECURITY_GROUP_ID=$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$REGION" \
    --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' \
    --output text)

if [ "$SECURITY_GROUP_ID" = "None" ] || [ -z "$SECURITY_GROUP_ID" ]; then
    echo "Error: Could not retrieve security group ID for cluster $CLUSTER_NAME"
    exit 1
fi

echo "Found EKS-managed security group: $SECURITY_GROUP_ID"

# Tag the security group with Load Balancer Controller tag and consistent cflt_* tags
aws ec2 create-tags \
    --region "$REGION" \
    --resources "$SECURITY_GROUP_ID" \
    --tags \
        Key=elbv2.k8s.aws/cluster,Value="$CLUSTER_NAME" \
        Key=cflt_environment,Value=dev \
        Key=cflt_service,Value=federal_ps \
        Key=cflt_keep_until,Value=2050/03/15 \
        Key=cflt_managed_by,Value=terraform \
        Key=cflt_managed_id,Value=github.com/nbargovic/aws-eks-cfk-infra

echo "Successfully tagged security group $SECURITY_GROUP_ID with:"
echo "  - elbv2.k8s.aws/cluster=$CLUSTER_NAME"
echo "  - cflt_environment=dev"
echo "  - cflt_service=federal_ps"
echo "  - cflt_keep_until=2050/03/15"
echo "  - cflt_managed_by=terraform"
echo "  - cflt_managed_id=github.com/nbargovic/aws-eks-cfk-infra"
echo "The AWS Load Balancer Controller can now manage this security group."
