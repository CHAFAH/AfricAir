#!/usr/bin/env bash
set -Eeuo pipefail
# CI deploy to an EC2 container host through SSM Run Command (no SSH, no keys).
# Usage: scripts/ci/deploy-ec2.sh <staging|production> <image-tag>
# Needs AWS credentials (OIDC role) allowed to put to the deploy bucket and send commands to the host.
# Env: AWS_REGION, DEPLOY_BUCKET (default africair-deploy-<account>), PROJECT_TAG (default africair).
# Prints the host's public URL on the last line.
trap 'echo "deploy-ec2.sh: error on line $LINENO" >&2' ERR

ENVIRONMENT=${1:?usage: deploy-ec2.sh <staging|production> <image-tag>}
TAG=${2:?usage: deploy-ec2.sh <staging|production> <image-tag>}
[[ $ENVIRONMENT =~ ^(staging|production)$ ]] || { echo "unknown environment $ENVIRONMENT" >&2; exit 1; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BUCKET=${DEPLOY_BUCKET:-africair-deploy-$ACCOUNT}

instance=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=${PROJECT_TAG:-africair}" "Name=tag:Role,Values=container-host" \
            "Name=tag:Env,Values=$ENVIRONMENT" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,PublicDnsName]' --output text | head -n1)
read -r INSTANCE_ID PUBLIC_DNS <<<"$instance"
[[ -n ${INSTANCE_ID:-} ]] || { echo "no running $ENVIRONMENT container host" >&2; exit 1; }

# The bundle is addressed by tag, so a rollback can always fetch the exact files it ran with.
prefix="s3://$BUCKET/$ENVIRONMENT/$TAG"
aws s3 cp --only-show-errors "$ROOT/deploy/ec2/compose.yaml" "$prefix/compose.yaml"
aws s3 cp --only-show-errors "$ROOT/deploy/ec2/deploy.sh" "$prefix/deploy.sh"
aws s3 cp --only-show-errors "$ROOT/deploy/ec2/config/$ENVIRONMENT.env" "$prefix/config/$ENVIRONMENT.env"

commands=$(jq -nc --arg prefix "$prefix" --arg env "$ENVIRONMENT" --arg tag "$TAG" '[
  "set -euo pipefail",
  "b=$(mktemp -d)",
  ("aws s3 cp --recursive --only-show-errors " + $prefix + " \"$b\""),
  ("bash \"$b/deploy.sh\" " + $env + " " + $tag + " \"$b\"")
]')
command_id=$(aws ssm send-command --instance-ids "$INSTANCE_ID" --document-name AWS-RunShellScript \
  --comment "africair $ENVIRONMENT $TAG" --timeout-seconds 600 \
  --parameters "$(jq -nc --argjson c "$commands" '{commands: $c, executionTimeout: ["600"]}')" \
  --query Command.CommandId --output text)
echo "SSM command $command_id on $INSTANCE_ID" >&2

status=InProgress
for _ in $(seq 120); do
  status=$(aws ssm get-command-invocation --command-id "$command_id" --instance-id "$INSTANCE_ID" \
    --query Status --output text 2>/dev/null || echo Pending)
  [[ $status =~ ^(Pending|InProgress|Delayed)$ ]] || break
  sleep 5
done
aws ssm get-command-invocation --command-id "$command_id" --instance-id "$INSTANCE_ID" \
  --query '[StandardOutputContent, StandardErrorContent]' --output text >&2 || true
[[ $status == Success ]] || { echo "deploy failed: SSM status $status" >&2; exit 1; }
echo "http://$PUBLIC_DNS"
