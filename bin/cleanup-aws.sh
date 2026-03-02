#!/usr/bin/env bash
# cleanup-aws.sh — Emergency cleanup when Terraform state is lost.
# Finds all AWS resources by cluster tag and deletes them interactively.
#
# Usage:
#   ./bin/cleanup-aws.sh <cluster-name> [region]
#
# Example:
#   ./bin/cleanup-aws.sh mke4k-lab-7d5e eu-central-1
set -euo pipefail

C="${1:-}"
export AWS_REGION="${2:-eu-central-1}"

if [[ -z "$C" ]]; then
    echo "Usage: $0 <cluster-name> [region]"
    echo "  e.g. $0 mke4k-lab-7d5e eu-central-1"
    exit 1
fi

confirm() {
    local msg="$1"
    echo ""
    echo "$msg"
    read -rp "Proceed? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

echo "=== Finding resources for cluster: $C  (region: $AWS_REGION) ==="

echo ""
echo "--- EC2 Instances ---"
aws ec2 describe-instances \
  --filters "Name=tag:Cluster,Values=$C" "Name=instance-state-name,Values=running,stopped" \
  --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`].Value|[0],PrivateIpAddress,State.Name]' \
  --output table

echo ""
echo "--- Load Balancers ---"
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?starts_with(LoadBalancerName,'$C')].[LoadBalancerName,DNSName,State.Code]" \
  --output table

echo ""
echo "--- Target Groups ---"
aws elbv2 describe-target-groups \
  --query "TargetGroups[?starts_with(TargetGroupName,'$C')].[TargetGroupName,Port,Protocol]" \
  --output table

echo ""
echo "--- VPC ---"
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Cluster,Values=$C" --query 'Vpcs[0].VpcId' --output text)
if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
    echo "VPC: $VPC_ID"
    aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
      --query 'Subnets[].[SubnetId,CidrBlock,Tags[?Key==`Name`].Value|[0]]' --output table
    aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" \
      --query "SecurityGroups[?GroupName!='default'].[GroupId,GroupName]" --output table
else
    echo "No VPC found"
fi

echo ""
echo "--- IAM ---"
aws iam list-instance-profiles \
  --query "InstanceProfiles[?InstanceProfileName=='${C}-ccm-profile'].InstanceProfileName" --output text
aws iam list-roles \
  --query "Roles[?RoleName=='${C}-ccm-role'].RoleName" --output text
aws iam list-policies \
  --query "Policies[?PolicyName=='${C}-ccm-policy'].PolicyName" --output text

echo ""
echo "--- Key Pair ---"
aws ec2 describe-key-pairs --key-names "${C}-key" \
  --query 'KeyPairs[].KeyName' --output text 2>/dev/null || echo "(not found)"

# =========================================================================
#  Deletions — each step requires confirmation
# =========================================================================

IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:Cluster,Values=$C" "Name=instance-state-name,Values=running,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [[ -n "$IDS" ]] && confirm "Terminate EC2 instances: $IDS ?"; then
    aws ec2 terminate-instances --instance-ids $IDS
    echo "Waiting for instances to terminate..."
    aws ec2 wait instance-terminated --instance-ids $IDS
    echo "Done."
fi

LB_ARNS=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?starts_with(LoadBalancerName,'$C')].LoadBalancerArn" --output text)
if [[ -n "$LB_ARNS" ]] && confirm "Delete load balancers + listeners?"; then
    for LB_ARN in $LB_ARNS; do
        for L in $(aws elbv2 describe-listeners --load-balancer-arn "$LB_ARN" \
          --query 'Listeners[].ListenerArn' --output text); do
            aws elbv2 delete-listener --listener-arn "$L"
        done
        aws elbv2 delete-load-balancer --load-balancer-arn "$LB_ARN"
    done
    echo "Waiting for NLBs to drain..."
    while aws elbv2 describe-load-balancers \
      --query "LoadBalancers[?starts_with(LoadBalancerName,'$C')].LoadBalancerArn" --output text | grep -q .; do
        sleep 5
    done
    echo "Done."
fi

TG_ARNS=$(aws elbv2 describe-target-groups \
  --query "TargetGroups[?starts_with(TargetGroupName,'$C')].TargetGroupArn" --output text)
if [[ -n "$TG_ARNS" ]] && confirm "Delete target groups?"; then
    for TG in $TG_ARNS; do
        aws elbv2 delete-target-group --target-group-arn "$TG"
    done
    echo "Done."
fi

if confirm "Delete key pair ${C}-key ?"; then
    aws ec2 delete-key-pair --key-name "${C}-key" 2>/dev/null || true
    echo "Done."
fi

if confirm "Delete IAM resources (profile, role, policy)?"; then
    aws iam remove-role-from-instance-profile \
      --instance-profile-name "${C}-ccm-profile" --role-name "${C}-ccm-role" 2>/dev/null || true
    aws iam delete-instance-profile \
      --instance-profile-name "${C}-ccm-profile" 2>/dev/null || true
    POLICY_ARN=$(aws iam list-policies \
      --query "Policies[?PolicyName=='${C}-ccm-policy'].Arn" --output text)
    if [[ -n "$POLICY_ARN" ]]; then
        aws iam detach-role-policy --role-name "${C}-ccm-role" --policy-arn "$POLICY_ARN"
        aws iam delete-policy --policy-arn "$POLICY_ARN"
    fi
    aws iam delete-role --role-name "${C}-ccm-role" 2>/dev/null || true
    echo "Done."
fi

if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]] && confirm "Delete VPC $VPC_ID (subnets, routes, IGW, security groups)?"; then
    echo "Removing security group rules..."
    for SG in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" \
      --query "SecurityGroups[?GroupName!='default'].GroupId" --output text); do
        aws ec2 revoke-security-group-ingress --group-id "$SG" \
          --ip-permissions "$(aws ec2 describe-security-groups --group-ids "$SG" \
            --query 'SecurityGroups[0].IpPermissions' --output json)" 2>/dev/null || true
        aws ec2 revoke-security-group-egress --group-id "$SG" \
          --ip-permissions "$(aws ec2 describe-security-groups --group-ids "$SG" \
            --query 'SecurityGroups[0].IpPermissionsEgress' --output json)" 2>/dev/null || true
    done
    echo "Deleting security groups..."
    for SG in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" \
      --query "SecurityGroups[?GroupName!='default'].GroupId" --output text); do
        aws ec2 delete-security-group --group-id "$SG"
    done
    echo "Deleting subnets..."
    for SUB in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
      --query 'Subnets[].SubnetId' --output text); do
        aws ec2 delete-subnet --subnet-id "$SUB"
    done
    echo "Deleting route tables..."
    for RT in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
      --query "RouteTables[?Associations[0].Main!=\`true\`].RouteTableId" --output text); do
        for ASSOC in $(aws ec2 describe-route-tables --route-table-ids "$RT" \
          --query 'RouteTables[0].Associations[].RouteTableAssociationId' --output text); do
            aws ec2 disassociate-route-table --association-id "$ASSOC"
        done
        aws ec2 delete-route-table --route-table-id "$RT"
    done
    echo "Deleting internet gateway..."
    for IGW in $(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
      --query 'InternetGateways[].InternetGatewayId' --output text); do
        aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID"
        aws ec2 delete-internet-gateway --internet-gateway-id "$IGW"
    done
    echo "Deleting VPC..."
    aws ec2 delete-vpc --vpc-id "$VPC_ID"
    echo "Done."
fi

echo ""
echo "=== Cleanup complete ==="
