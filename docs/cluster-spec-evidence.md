# Cluster spec evidence (Project 4)

Run these after `make tf-apply`, then paste the output under each heading. **Never paste secret values.**
`C=africair-<team>-staging`.

**Kubernetes version:** the newest version in *standard* support, from
`aws eks describe-cluster-versions --status STANDARD_SUPPORT`. 1.33 left standard support 14 months
after its May 2025 release. The cluster also sets `upgrade_policy.support_type = STANDARD`, so it can
never silently fall into paid extended support.

## Cluster

```bash
aws eks describe-cluster --name $C --query 'cluster.{version:version,endpointPublic:resourcesVpcConfig.endpointPublicAccess,endpointPrivate:resourcesVpcConfig.endpointPrivateAccess,publicCidrs:resourcesVpcConfig.publicAccessCidrs,auth:accessConfig.authenticationMode,encryption:encryptionConfig,logging:logging.clusterLogging,support:upgradePolicy.supportType}'
aws logs describe-log-groups --log-group-name-prefix /aws/eks/$C --query 'logGroups[].[logGroupName,retentionInDays]'
aws kms describe-key --key-id alias/$C-eks --query 'KeyMetadata.[KeyManager,KeyState]'; aws kms get-key-rotation-status --key-id alias/$C-eks
aws eks list-access-entries --cluster-name $C
aws eks list-associated-access-policies --cluster-name $C --principal-arn <ci-role-arn>   # AmazonEKSEditPolicy, namespace africair-staging
```

Expected: the chosen version, public+private endpoint with only the team CIDRs, `API`, `secrets`
encrypted with the customer key (rotation enabled), the logs `api`, `audit`, `authenticator` with
7-day retention, `STANDARD`.

## Node group

```bash
aws eks describe-nodegroup --cluster-name $C --nodegroup-name general \
  --query 'nodegroup.{ami:amiType,types:instanceTypes,scaling:scalingConfig,labels:labels,lt:launchTemplate}'
aws ec2 describe-launch-template-versions --launch-template-id <lt-id> --versions '$Latest' \
  --query 'LaunchTemplateVersions[0].LaunchTemplateData.{imds:MetadataOptions,disk:BlockDeviceMappings}'
kubectl get nodes -L workload -o wide
kubectl get node -o jsonpath='{.items[0].status.allocatable.pods}'   # ~110 with prefix delegation (35 without)
```

Expected: `AL2023_x86_64_STANDARD`, `t3.large`, 2/2/4, `workload=general`, `HttpTokens=required`,
`HttpPutResponseHopLimit=1`, a 30 GiB encrypted gp3 volume, private IPs.

## Add-ons and storage

```bash
aws eks list-addons --cluster-name $C
aws eks describe-addon --cluster-name $C --addon-name vpc-cni --query 'addon.configurationValues'
aws eks list-pod-identity-associations --cluster-name $C --query 'associations[].[namespace,serviceAccount]'
kubectl get storageclass
```

Expected: `aws-ebs-csi-driver`, `coredns`, `eks-pod-identity-agent`, `kube-proxy`, `metrics-server` and
`vpc-cni` (`ENABLE_PREFIX_DELEGATION=true`, `enableNetworkPolicy=true`). Associations for
`external-secrets/external-secrets`, `kube-system/aws-load-balancer-controller`,
`kube-system/ebs-csi-controller-sa` and `africair-staging/africair-backup`. `gp3 (default)` with
`WaitForFirstConsumer`.

## RDS

```bash
aws rds describe-db-instances --db-instance-identifier $C --query 'DBInstances[0].{engine:EngineVersion,class:DBInstanceClass,storage:[AllocatedStorage,StorageType,StorageEncrypted],public:PubliclyAccessible,multiAz:MultiAZ,backup:BackupRetentionPeriod,deletionProtection:DeletionProtection,secret:MasterUserSecret.SecretArn,sgs:VpcSecurityGroups[].VpcSecurityGroupId}'
aws ec2 describe-security-group-rules --filters Name=group-id,Values=<rds-sg> --query 'SecurityGroupRules[?!IsEgress].[FromPort,ReferencedGroupInfo.GroupId,CidrIpv4]'
aws rds describe-db-parameters --db-parameter-group-name $C-pg16 --query "Parameters[?ParameterName=='rds.force_ssl'].ParameterValue"
aws ssm get-parameters-by-path --path /africair/staging/db --query 'Parameters[].Name'
```

Expected: 16.x (latest minor), `db.t4g.micro`, 20 GiB gp3 encrypted, `false` public, single-AZ,
7 days, the secret **ARN** only, one rule (5432 from the cluster SG, no CIDR), `force_ssl = 1`, three
parameters.
