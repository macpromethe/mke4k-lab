"""
mke4k-lab expiry reaper
=======================

One-shot AWS Lambda that tears down every object a lab created, then removes
its own scaffolding. Invoked by an EventBridge Scheduler one-time schedule at
(create time + expiry_days); see expiry.tf.

It mirrors bin/cleanup-aws.sh but runs unattended and non-interactively:
resources are found by the `Cluster=<cluster_name>` tag (EC2, VPC) or by the
`<cluster_name>-*` name convention (NLBs, target groups, key pair, IAM). Every
step is best-effort — a failure in one step is logged and the teardown
continues, so a partial failure still removes as much as possible.

Order matters: instances and load balancers hold ENIs in the VPC subnets, so
they must be gone before the subnets/security groups/VPC can be deleted.
"""

import os
import time
import logging

import boto3
from botocore.exceptions import ClientError

log = logging.getLogger()
log.setLevel(logging.INFO)

CLUSTER = os.environ["CLUSTER_NAME"]
REGION = os.environ.get("REGION") or os.environ["AWS_REGION"]
# DRY_RUN=1/true/yes/on -> enumerate what would be deleted, delete nothing.
DRY_RUN = os.environ.get("DRY_RUN", "").strip().lower() in ("1", "true", "yes", "on")

ec2 = boto3.client("ec2", region_name=REGION)
elb = boto3.client("elbv2", region_name=REGION)
iam = boto3.client("iam")
lam = boto3.client("lambda", region_name=REGION)
sch = boto3.client("scheduler", region_name=REGION)


def _log_err(what, exc):
    log.warning("skip %s: %s", what, exc)


def mutate(desc, fn):
    """Every state-changing AWS call in this module funnels through here.
    Under DRY_RUN it logs what it *would* delete and skips the call, so a
    dry run is guaranteed read-only while still enumerating every target."""
    if DRY_RUN:
        log.info("[DRY-RUN] would delete: %s", desc)
        return
    fn()


# ---------------------------------------------------------------------------
# EC2 instances (by Cluster tag)
# ---------------------------------------------------------------------------
def terminate_instances():
    try:
        resp = ec2.describe_instances(
            Filters=[
                {"Name": "tag:Cluster", "Values": [CLUSTER]},
                {"Name": "instance-state-name",
                 "Values": ["pending", "running", "stopping", "stopped"]},
            ]
        )
    except ClientError as exc:
        _log_err("describe_instances", exc)
        return

    ids = [i["InstanceId"]
           for r in resp["Reservations"] for i in r["Instances"]]
    if not ids:
        log.info("no instances to terminate")
        return

    log.info("terminating instances: %s", ids)
    try:
        mutate("EC2 instances %s" % ids,
               lambda: ec2.terminate_instances(InstanceIds=ids))
        if not DRY_RUN:
            ec2.get_waiter("instance_terminated").wait(
                InstanceIds=ids,
                WaiterConfig={"Delay": 15, "MaxAttempts": 40},  # up to 10 min
            )
            log.info("instances terminated")
    except Exception as exc:  # incl. WaiterError on timeout
        # Not fatal: subnet/SG/VPC deletes below retry on DependencyViolation
        # while any lingering ENIs drain.
        _log_err("terminate_instances", exc)


# ---------------------------------------------------------------------------
# Load balancers + target groups
#
# The ELBv2 describe APIs cannot filter by tag server-side, so we list them and
# then confirm each candidate carries the Cluster=<cluster_name> tag Terraform
# set. Deletion is driven by that tag, never by the name — a name that merely
# starts with the cluster name is NOT sufficient to delete.
# ---------------------------------------------------------------------------
def _cluster_tagged_elbv2(arns):
    """Subset of ELBv2 ARNs (LBs or target groups) tagged Cluster=<CLUSTER>."""
    keep = set()
    for i in range(0, len(arns), 20):  # describe_tags accepts <=20 ARNs
        batch = arns[i:i + 20]
        if not batch:
            continue
        try:
            for d in elb.describe_tags(ResourceArns=batch)["TagDescriptions"]:
                if any(t["Key"] == "Cluster" and t["Value"] == CLUSTER
                       for t in d.get("Tags", [])):
                    keep.add(d["ResourceArn"])
        except ClientError as exc:
            _log_err("describe_tags", exc)
    return keep


def delete_load_balancers():
    try:
        all_lbs = elb.describe_load_balancers()["LoadBalancers"]
    except ClientError as exc:
        _log_err("describe_load_balancers", exc)
        all_lbs = []
    target_arns = _cluster_tagged_elbv2([lb["LoadBalancerArn"] for lb in all_lbs])

    for lb in all_lbs:
        arn = lb["LoadBalancerArn"]
        if arn not in target_arns:
            continue
        name = lb["LoadBalancerName"]
        try:
            if not DRY_RUN:  # listeners are removed with the LB anyway
                for lst in elb.describe_listeners(LoadBalancerArn=arn)["Listeners"]:
                    elb.delete_listener(ListenerArn=lst["ListenerArn"])
            mutate("load balancer %s" % name,
                   lambda a=arn: elb.delete_load_balancer(LoadBalancerArn=a))
        except ClientError as exc:
            _log_err("delete load balancer %s" % name, exc)

    # Wait for the tagged LBs (and their ENIs) to disappear before subnets.
    if not DRY_RUN:
        for _ in range(40):
            try:
                live = {lb["LoadBalancerArn"]
                        for lb in elb.describe_load_balancers()["LoadBalancers"]}
            except ClientError:
                break
            if not (target_arns & live):
                break
            time.sleep(15)

    # Target groups can only be deleted once no listener references them.
    try:
        all_tgs = elb.describe_target_groups()["TargetGroups"]
    except ClientError as exc:
        _log_err("describe_target_groups", exc)
        all_tgs = []
    tg_arns = _cluster_tagged_elbv2([tg["TargetGroupArn"] for tg in all_tgs])
    for tg in all_tgs:
        if tg["TargetGroupArn"] not in tg_arns:
            continue
        try:
            mutate("target group %s" % tg["TargetGroupName"],
                   lambda a=tg["TargetGroupArn"]: elb.delete_target_group(TargetGroupArn=a))
        except ClientError as exc:
            _log_err("delete target group %s" % tg["TargetGroupName"], exc)


# ---------------------------------------------------------------------------
# Key pair
# ---------------------------------------------------------------------------
def delete_key_pair():
    try:
        mutate("key pair %s-key" % CLUSTER,
               lambda: ec2.delete_key_pair(KeyName="%s-key" % CLUSTER))
    except ClientError as exc:
        _log_err("delete_key_pair", exc)


# ---------------------------------------------------------------------------
# CCM IAM (by <cluster>-ccm-* name)
# ---------------------------------------------------------------------------
def _delete_role(role_name):
    """Detach/delete every policy on a role, then delete the role."""
    try:
        for pol in iam.list_attached_role_policies(RoleName=role_name).get(
                "AttachedPolicies", []):
            mutate("detach %s from role %s" % (pol["PolicyArn"], role_name),
                   lambda p=pol["PolicyArn"]: iam.detach_role_policy(
                       RoleName=role_name, PolicyArn=p))
        for name in iam.list_role_policies(RoleName=role_name).get(
                "PolicyNames", []):
            mutate("inline policy %s on role %s" % (name, role_name),
                   lambda n=name: iam.delete_role_policy(
                       RoleName=role_name, PolicyName=n))
        mutate("role %s" % role_name,
               lambda: iam.delete_role(RoleName=role_name))
    except ClientError as exc:
        _log_err("delete role %s" % role_name, exc)


def delete_ccm_iam():
    profile = "%s-ccm-profile" % CLUSTER
    role = "%s-ccm-role" % CLUSTER
    # Only act if the CCM role actually exists (ccm_enabled=false -> nothing).
    try:
        iam.get_role(RoleName=role)
    except ClientError:
        log.info("no CCM IAM (%s) to delete", role)
        return

    try:
        mutate("remove role %s from instance profile %s" % (role, profile),
               lambda: iam.remove_role_from_instance_profile(
                   InstanceProfileName=profile, RoleName=role))
    except ClientError as exc:
        _log_err("remove role from instance profile", exc)
    try:
        mutate("instance profile %s" % profile,
               lambda: iam.delete_instance_profile(InstanceProfileName=profile))
    except ClientError as exc:
        _log_err("delete_instance_profile", exc)

    # Detach + delete the customer-managed CCM policy (must be detached first).
    try:
        acct = boto3.client("sts").get_caller_identity()["Account"]
        policy_arn = "arn:aws:iam::%s:policy/%s-ccm-policy" % (acct, CLUSTER)
        try:
            mutate("detach ccm policy from role %s" % role,
                   lambda: iam.detach_role_policy(RoleName=role, PolicyArn=policy_arn))
        except ClientError:
            pass
        mutate("policy %s-ccm-policy" % CLUSTER,
               lambda: iam.delete_policy(PolicyArn=policy_arn))
    except ClientError as exc:
        _log_err("delete ccm policy", exc)

    _delete_role(role)


# ---------------------------------------------------------------------------
# VPC and its dependencies (by Cluster tag)
# ---------------------------------------------------------------------------
def _retry_dependency(fn, what, attempts=12, delay=15):
    """Retry an action that can transiently fail with DependencyViolation
    while ENIs/attachments from just-deleted resources drain."""
    if DRY_RUN:
        log.info("[DRY-RUN] would delete: %s", what)
        return
    for _ in range(attempts):
        try:
            fn()
            log.info("deleted %s", what)
            return
        except ClientError as exc:
            code = exc.response.get("Error", {}).get("Code", "")
            if code in ("DependencyViolation", "ResourceInUse"):
                time.sleep(delay)
                continue
            _log_err(what, exc)
            return
    log.warning("gave up deleting %s after retries", what)


def delete_vpc():
    try:
        vpcs = ec2.describe_vpcs(
            Filters=[{"Name": "tag:Cluster", "Values": [CLUSTER]}]
        )["Vpcs"]
    except ClientError as exc:
        _log_err("describe_vpcs", exc)
        return
    if not vpcs:
        log.info("no VPC to delete")
        return
    vpc_id = vpcs[0]["VpcId"]
    log.info("deleting VPC %s", vpc_id)
    vpc_filter = [{"Name": "vpc-id", "Values": [vpc_id]}]

    # Internet gateways
    for igw in ec2.describe_internet_gateways(
        Filters=[{"Name": "attachment.vpc-id", "Values": [vpc_id]}]
    ).get("InternetGateways", []):
        igw_id = igw["InternetGatewayId"]
        try:
            mutate("detach internet gateway %s from %s" % (igw_id, vpc_id),
                   lambda: ec2.detach_internet_gateway(
                       InternetGatewayId=igw_id, VpcId=vpc_id))
        except ClientError as exc:
            _log_err("detach igw %s" % igw_id, exc)
        _retry_dependency(
            lambda i=igw_id: ec2.delete_internet_gateway(InternetGatewayId=i),
            "internet gateway %s" % igw_id)

    # Non-main route tables (disassociate first)
    for rt in ec2.describe_route_tables(Filters=vpc_filter).get("RouteTables", []):
        assocs = rt.get("Associations", [])
        if any(a.get("Main") for a in assocs):
            continue
        for a in assocs:
            try:
                mutate("disassociate route table %s" % a["RouteTableAssociationId"],
                       lambda x=a["RouteTableAssociationId"]:
                       ec2.disassociate_route_table(AssociationId=x))
            except ClientError as exc:
                _log_err("disassociate route table", exc)
        _retry_dependency(
            lambda r=rt["RouteTableId"]: ec2.delete_route_table(RouteTableId=r),
            "route table %s" % rt["RouteTableId"])

    # Subnets (need instance/LB ENIs already gone)
    for sub in ec2.describe_subnets(Filters=vpc_filter).get("Subnets", []):
        _retry_dependency(
            lambda s=sub["SubnetId"]: ec2.delete_subnet(SubnetId=s),
            "subnet %s" % sub["SubnetId"])

    # Non-default security groups. Revoke rules first to break inter-SG
    # references (self rules, LB<->node), then delete.
    sgs = [sg for sg in ec2.describe_security_groups(
        Filters=vpc_filter).get("SecurityGroups", [])
        if sg["GroupName"] != "default"]
    for sg in sgs:
        if sg.get("IpPermissions"):
            try:
                mutate("revoke ingress rules on %s" % sg["GroupId"],
                       lambda s=sg: ec2.revoke_security_group_ingress(
                           GroupId=s["GroupId"], IpPermissions=s["IpPermissions"]))
            except ClientError as exc:
                _log_err("revoke ingress %s" % sg["GroupId"], exc)
        if sg.get("IpPermissionsEgress"):
            try:
                mutate("revoke egress rules on %s" % sg["GroupId"],
                       lambda s=sg: ec2.revoke_security_group_egress(
                           GroupId=s["GroupId"], IpPermissions=s["IpPermissionsEgress"]))
            except ClientError as exc:
                _log_err("revoke egress %s" % sg["GroupId"], exc)
    for sg in sgs:
        _retry_dependency(
            lambda g=sg["GroupId"]: ec2.delete_security_group(GroupId=g),
            "security group %s" % sg["GroupId"])

    # Finally the VPC itself
    _retry_dependency(lambda: ec2.delete_vpc(VpcId=vpc_id), "VPC %s" % vpc_id)


# ---------------------------------------------------------------------------
# Self-clean: remove the reaper's own scaffolding (best-effort, last).
# ---------------------------------------------------------------------------
def self_destruct():
    # The EventBridge one-shot schedule that invoked us.
    try:
        mutate("schedule %s-expiry" % CLUSTER,
               lambda: sch.delete_schedule(Name="%s-expiry" % CLUSTER))
    except ClientError as exc:
        _log_err("delete_schedule", exc)

    # Scheduler invoke-role and this Lambda's execution role are inline-policy
    # roles; _delete_role drops the inline policies then the role.
    _delete_role("%s-expiry-sched-role" % CLUSTER)
    _delete_role("%s-reaper-role" % CLUSTER)
    # Delete the function last — the in-flight invocation keeps running.
    try:
        mutate("lambda function %s-reaper" % CLUSTER,
               lambda: lam.delete_function(FunctionName="%s-reaper" % CLUSTER))
    except ClientError as exc:
        _log_err("delete_function", exc)


def handler(event, context):
    # Safety fuse: every deletion below is scoped by this exact cluster name
    # (as a tag value or resource-name component). An empty or absurdly short
    # value could broaden a tag match, so refuse to run rather than risk it.
    if not CLUSTER or len(CLUSTER) < 5:
        raise RuntimeError(
            "refusing to reap: CLUSTER_NAME is empty or too short (%r)" % CLUSTER)

    mode = "DRY-RUN (no deletions)" if DRY_RUN else "LIVE"
    log.info("reaping cluster %s in %s [%s]", CLUSTER, REGION, mode)
    terminate_instances()
    delete_load_balancers()
    delete_key_pair()
    delete_ccm_iam()
    delete_vpc()
    self_destruct()
    log.info("reap complete for %s", CLUSTER)
    return {"cluster": CLUSTER, "status": "reaped"}
