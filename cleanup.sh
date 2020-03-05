# 1. delete EC2 instances
# 2. detach policy
# 3. delete cluster
echo "Detach AmazonSSMManagedInstanceCore policy ..."
aws iam detach-role-policy \
   --role-name $(cat INSTANCE_ROLE_NAME) \
   --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

eksctl delete cluster --name bottlerocket