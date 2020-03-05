echo "Download xq processor ..."
mkdir -p ~/.local/bin || true

FILE="$HOME/.local/bin/xq"
if [ ! -f "$FILE" ]; then
  wget -O $FILE https://github.com/chanwit/xq/releases/download/v0.1.0/xq
  chmod +x $FILE
fi

~/.local/bin/xq -V
kubectl version
aws --version

echo "Creating EKS control plane ..."
eksctl create cluster --region us-west-2 --nodes=0 --name bottlerocket --node-ami=auto

echo "Applying AWS CNI ..."
kubectl apply -f aws-k8s-cni.yaml

echo "Generate userdata ..."
eksctl get cluster --region us-west-2 --name bottlerocket -o json \
| xq --json '[0].with{"[settings.kubernetes]\napi-server=\"${Endpoint}\"\ncluster-certificate=\"${CertificateAuthority.Data}\"\ncluster-name=\"bottlerocket\""}' -o raw > userdata.toml


echo "Obtain a private subnet ..."
aws ec2 describe-subnets \
   --subnet-ids $(eksctl get cluster --region us-west-2 --name bottlerocket -o json | xq --json '.ResourcesVpcConfig.SubnetIds.flatten().join(" ")' -o raw) \
   --region us-west-2 \
   --query "Subnets[].[SubnetId, Tags[?Key=='aws:cloudformation:logical-id'].Value]" \
| xq --json '.flatten()' \
| xq --json '[x.findIndexOf{it.contains("Private")}-1]' -o raw > SUBNET_ID

echo "Get Instance Role Name ..."
eksctl get iamidentitymapping --region us-west-2 --cluster bottlerocket -o json \
| xq --json '[0].rolearn.split(/\//)[1]' -o raw > INSTANCE_ROLE_NAME

echo "Attach AmazonSSMManagedInstanceCore policy ..."
aws iam attach-role-policy \
   --role-name $(cat INSTANCE_ROLE_NAME) \
   --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

echo "Get Profile Role Name ..."
aws iam list-instance-profiles-for-role \
  --role-name $(cat INSTANCE_ROLE_NAME) \
  --query "InstanceProfiles[*].InstanceProfileName" --output text > INSTANCE_PROFILE_NAME

echo "Patch Kubeproxy command ..."
kubectl get -n kube-system daemonset kube-proxy -o json \
| xq --json '.tap{spec.template.spec.containers[0].command=["kube-proxy","--v=2","--config=/var/lib/kube-proxy-config/config","--conntrack-max-per-core=0","--conntrack-min=0"]}' \
| kubectl apply -f-

echo "Get SharedNode and NodeGroup Security Group IDs ..."
aws ec2 describe-security-groups --filters 'Name=tag:Name,Values=*bottlerocket*' \
  --query "SecurityGroups[*].{Name:GroupName,ID:GroupId}" \
| xq --json '.findAll{ it.Name.contains("nodegroup-ng") || it.Name.contains("ClusterSharedNodeSecurityGroup")}.ID.join(" ")' -o raw > SECURITY_GROUP_IDS

echo "Starting Bottlerocket node ..."
aws ec2 run-instances --key-name chanwit \
   --subnet-id $(cat SUBNET_ID) \
   --security-group-ids $(cat SECURITY_GROUP_IDS) \
   --image-id ami-0ba66967c5a0a704a \
   --instance-type c3.large \
   --region us-west-2 \
   --tag-specifications 'ResourceType=instance,Tags=[{Key=kubernetes.io/cluster/bottlerocket,Value=owned}]' \
   --user-data file://userdata.toml \
   --iam-instance-profile Name=$(cat INSTANCE_PROFILE_NAME) | xq --json '.Instances[0].InstanceId' -o raw > INSTANCE_ID

aws ec2 wait instance-running \
    --instance-ids $(cat INSTANCE_ID)

EKSCTL_EXPERIMENTAL=true eksctl enable repo --cluster=bottlerocket \
  --region=us-west-2 \
  --git-url=$(git remote get-url --push origin) \
  --git-email=noreploy+flux@weave.works
