# `aws-fallback-vpc` — dedicated AWS VPC for Graviton fallback workers

Minimal, **billing-isolated** AWS network for the BuildBarn ondemand Graviton
(arm64) fallback fleet. See [`../../aws-graviton-fallback.md`](../../aws-graviton-fallback.md)
for the why and the full picture. This lives in the buildfarm repo on purpose —
it is NOT in `percona-cd-platform`, so the RBE cluster owns its own AWS
footprint and cost line.

## What it creates (eu-central-1)

- A dedicated VPC `10.111.0.0/16` (non-overlapping with the WireGuard tunnel
  `10.99.0.0/16` and Hetzner `10.30.246.0/24`).
- One public subnet + Internet Gateway + route table. **No NAT gateway** —
  ephemeral egress-only workers get a public IP, which is far cheaper for a
  churny short-lived fleet.
- An egress-only security group (no inbound — the WireGuard tunnel is
  worker-initiated outbound).
- Everything tagged `iit-billing-tag=psmdb-worker` + `PerconaKeep=True`, so
  cost is attributable and the percona-dev-admin cleanup Lambdas spare the
  instances.

## Apply

Works with **Terraform or OpenTofu** (`tofu` is a drop-in — `tofu init/plan/apply`).
On Apple Silicon prefer OpenTofu or a native-arm64 Terraform: the Homebrew x86
`terraform` runs the AWS provider under Rosetta, where it can spin at 100% CPU
and hang. Quick check: `file "$(which terraform)"` should say `arm64`.

**Run apply with an ADMIN/operator identity**, NOT the narrow
`bb-ondemand-scaler` user. That user can only RunInstances/Terminate/Describe —
it deliberately CANNOT create VPC resources or read the SSM AMI parameter, so
`apply` under it fails with `AccessDeniedException`. The scaler user's key
belongs only in `compose/.env` (scaler runtime), never in the provisioning
shell. Note AWS env vars override `--profile`/`AWS_PROFILE`, so if your
`cluster.env` exported the scaler key, clear it for this command:

```bash
cd IaC/buildbarn/ondemand/aws-fallback-vpc
tofu init        # or: terraform init
# provision with the admin profile, shadowing any scaler key from cluster.env:
env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY AWS_PROFILE=<admin> tofu plan
# expect: Plan: 6 to add, 0 to change, 0 to destroy
env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY AWS_PROFILE=<admin> tofu apply
```

Then feed the outputs into `compose/.env` on the central:

```bash
terraform output -raw env_lines    # AWS_SUBNET_ID / AWS_SECURITY_GROUP_IDS / AWS_AMI_ID
```

(`AWS_AMI_ID` is resolved live from Canonical's Ubuntu arm64 SSM parameter —
pin the value rather than re-resolving on every scaler run.)

## Validation on every central deploy

`../scripts/create-central.sh` runs `check_aws_fallback_vpc` on every run
(non-fatal):

- picks the IaC binary as `$TF_BIN` → `tofu` → `terraform` (OpenTofu first so
  it uses the native-arch binary on Apple Silicon, not the Rosetta x86
  `terraform`);
- always `validate`s this config;
- if AWS creds are in the environment, `plan -detailed-exitcode` to report
  whether the VPC is applied and in sync (warns on drift / not-applied);
- skips cleanly when neither binary is installed or no creds are present (a
  Hetzner-only bootstrap is never blocked by this).

## Scaler IAM user

The scaler runs on Hetzner (no AWS instance profile / OIDC), so it needs a
narrow IAM **user** with a long-lived access key — not a role (nothing could
assume one). Policy: [`iam-scaler-policy.json`](iam-scaler-policy.json) —
region-locked to eu-central-1, only the `*g.2xlarge` types in
`aws.instance_types`, mandatory `iit-billing-tag=psmdb-worker`, terminate own
workers only.

Attach it as a **customer-managed policy** (6144-byte limit). Do NOT use
`put-user-policy` — an inline user policy is capped at 2048 bytes and this
policy is ~2.1 KB:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
sed "s/ACCOUNT_ID/${ACCOUNT_ID}/g" iam-scaler-policy.json > /tmp/iam-scaler-policy.json

aws iam create-user --user-name bb-ondemand-scaler \
  --tags Key=iit-billing-tag,Value=psmdb-worker Key=project,Value=psmdb-buildbarn
aws iam create-policy --policy-name bb-ondemand-scaler-ec2 \
  --policy-document file:///tmp/iam-scaler-policy.json
aws iam attach-user-policy --user-name bb-ondemand-scaler \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/bb-ondemand-scaler-ec2"

# Access key → AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY in cluster.env:
aws iam create-access-key --user-name bb-ondemand-scaler \
  --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text
```

Keep two things in lockstep or RunInstances gets IAM-denied: the policy's
`ec2:InstanceType` list == `aws.instance_types` in `ondemand-pools.yaml`, and
the `iit-billing-tag` value == `aws.billing_tag`.

## Notes

- State is **local** (no backend block) for the PoC. Promote to the team S3
  backend if this graduates.
- The IAM user above is provisioned out-of-band from this VPC config; its
  policy mirrors `percona-cd-platform/terraform/iam-gha-percona-server-ec2-fallback.tf`
  (but as a user, not an OIDC role).
