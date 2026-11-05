#!/bin/bash
# Level B helper: one throwaway VM per OS.
#   ec2_vm.sh launch <os-matrix.json> <arch> <os id> <jenkins tag>  -> prints "INSTANCE_ID IP USER LIFECYCLE AMI REGION"
#   ec2_vm.sh ami <os-matrix.json> <arch> <os id>                   -> "ID REGION AMI DATE NAME", read-only
#   ec2_vm.sh terminate <region> <instance id>
#   ec2_vm.sh lost <region> <instance id>     -> exit 0 if AWS reclaimed it (spot interruption)
#   ec2_vm.sh sweep <os-matrix.json> <jenkins tag>  -> terminate whatever this build left, in every matrix region
#
# subnet/SG/key per region: .networks in the matrix (the molecule ones)
# spot over several types first, then on-demand
#
# iit-billing-tag must be set at launch: the account's EC2 cleanup lambda kills untagged
# instances after 10 min. A category value is never reaped, so leaks are ours to clean:
# self-shutdown after MAX_MINUTES + sweep in the job's post. No PerconaKeep on volumes on purpose.
#
# env: BILLING_TAG (default jenkins-psmdb-worker), FORCE_ON_DEMAND (0/1), MAX_MINUTES (default 90), JOB_NAME
set -euo pipefail
TYPES_x86_64="c7i.large c6i.large m7i.large m6i.large"
TYPES_aarch64="c7g.large c6g.large m7g.large m6g.large"

os_field()  { jq -r --arg a "$ARCH" --arg i "$ID" ".[\$a][] | select(.id==\$i) | $1" "$MATRIX"; }
net_field() { jq -r --arg r "$1" ".networks[\$r].$2 // empty" "$MATRIX"; }

resolve_ami() { # region
    local r=$1 ssm owner name k v filters=()
    ssm=$(os_field '.ami.ssm // empty')
    # public SSM parameter first, if the key may read it; otherwise owner+name below
    if [ -n "$ssm" ] && aws ssm get-parameter --region "$r" --name "$ssm" --query Parameter.Value --output text 2>/dev/null; then
        return
    fi
    owner=$(os_field '.ami.owner')
    name=$(os_field '.ami.name // empty')
    [ -z "$name" ] || filters+=("Name=name,Values=$name")
    while IFS=$'\t' read -r k v; do
        filters+=("Name=tag:$k,Values=$v")
    done < <(os_field '.ami.tags // {} | to_entries[] | [.key, .value] | @tsv')
    aws ec2 describe-images --region "$r" --owners "$owner" \
        --filters "${filters[@]}" "Name=architecture,Values=$ARCH" "Name=state,Values=available" \
        --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text
}

run() { # ami type market -> instance id
    local market=() root size tags
    read -r root size < <(aws ec2 describe-images --region "$R" --image-ids "$1" \
        --query 'Images[0].[RootDeviceName, BlockDeviceMappings[0].Ebs.VolumeSize]' --output text)
    [ "$size" -ge 20 ] 2>/dev/null || size=20
    [ "$3" = spot ] && market=(--instance-market-options 'MarketType=spot,SpotOptions={SpotInstanceType=one-time,InstanceInterruptionBehavior=terminate}')
    tags="[{Key=Name,Value=oscheck-$NAME},{Key=iit-billing-tag,Value=${BILLING_TAG:-jenkins-psmdb-worker}},{Key=job-name,Value=${JOB_NAME:-manual}},{Key=jenkins-build,Value=$NAME}]"
    aws ec2 run-instances --region "$R" --image-id "$1" --instance-type "$2" ${market[@]+"${market[@]}"} \
        --subnet-id "$SUBNET" --security-group-ids "$SG" --key-name "$KEY" \
        --instance-initiated-shutdown-behavior terminate \
        --block-device-mappings "DeviceName=$root,Ebs={VolumeSize=$size,VolumeType=gp3,DeleteOnTermination=true}" \
        --user-data "#!/bin/sh
shutdown -h +${MAX_MINUTES:-90}" \
        --tag-specifications "ResourceType=instance,Tags=$tags" "ResourceType=volume,Tags=$tags" \
        --query 'Instances[0].InstanceId' --output text 2>"$ERR"
}

case $1 in
launch)
    MATRIX=$2 ARCH=$3 ID=$4 NAME=$5-$4
    user=$(os_field '.user')
    R=$(os_field '.ami.region // empty')
    [ -n "$R" ] || R=$(jq -r '.networks | keys_unsorted[0]' "$MATRIX")
    SUBNET=$(net_field "$R" subnet) KEY=$(net_field "$R" key_name) connect=$(net_field "$R" connect)
    [ -n "$SUBNET" ] || { echo "no network for region $R in $MATRIX" >&2; exit 1; }
    SG=$(aws ec2 describe-security-groups --region "$R" --filters "Name=group-name,Values=$(net_field "$R" sg_name)" \
        --query 'SecurityGroups[0].GroupId' --output text)
    [[ $SG == sg-* ]] || { echo "security group $(net_field "$R" sg_name) not found in $R" >&2; exit 1; }
    ami=$(resolve_ami "$R")
    [[ $ami == ami-* ]] || { echo "no AMI for $ID in $R" >&2; exit 1; }
    ERR=$(mktemp)
    types_var=TYPES_$ARCH; iid=""; life=""
    if [ "${FORCE_ON_DEMAND:-0}" != 1 ]; then
        for t in ${!types_var}; do
            if iid=$(run "$ami" "$t" spot); then life=spot; break; fi
            echo "spot $t: $(tail -1 "$ERR")" >&2
        done
    fi
    if [ -z "$life" ]; then
        for t in ${!types_var}; do
            if iid=$(run "$ami" "$t" on-demand); then life=on-demand; break; fi
            echo "on-demand $t: $(tail -1 "$ERR")" >&2
        done
    fi
    rm -f "$ERR"
    [ -n "$life" ] || { echo "could not launch $ID" >&2; exit 1; }
    aws ec2 wait instance-running --region "$R" --instance-ids "$iid"
    # private: the agent is in the same VPC (psmdb.cd, us-west-2); public: VM in another region
    [ "$connect" = public ] && q=PublicIpAddress || q=PrivateIpAddress
    ip=$(aws ec2 describe-instances --region "$R" --instance-ids "$iid" --query "Reservations[0].Instances[0].$q" --output text)
    echo "$iid $ip $user $life $ami $R"
    ;;
ami)
    # read-only: which AMI a launch would take now
    MATRIX=$2 ARCH=$3 ID=$4
    R=$(os_field '.ami.region // empty')
    [ -n "$R" ] || R=$(jq -r '.networks | keys_unsorted[0]' "$MATRIX")
    ami=$(resolve_ami "$R")
    echo "$ID $R $ami $(aws ec2 describe-images --region "$R" --image-ids "$ami" --query 'Images[0].[CreationDate,Name]' --output text)"
    ;;
terminate)
    aws ec2 terminate-instances --region "$2" --instance-ids "$3" >/dev/null
    ;;
lost)
    st=$(aws ec2 describe-instances --region "$2" --instance-ids "$3" \
        --query 'Reservations[0].Instances[0].StateReason.Code' --output text 2>/dev/null || true)
    [ "$st" = "Server.SpotInstanceTermination" ]
    ;;
sweep)
    for r in $(jq -r '.networks | keys[]' "$2"); do
        ids=$(aws ec2 describe-instances --region "$r" \
            --filters "Name=tag:jenkins-build,Values=$3-*" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
            --query 'Reservations[].Instances[].InstanceId' --output text || true)
        [ -z "$ids" ] || aws ec2 terminate-instances --region "$r" --instance-ids $ids >/dev/null
    done
    ;;
*) echo "usage: $0 launch|terminate|lost|sweep ..." >&2; exit 2 ;;
esac
