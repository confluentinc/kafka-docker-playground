suffix="${args[--suffix]}"
instance_type="${args[--instance-type]}"
ec2_size="${args[--size]}"

username=$(whoami)
if [[ -n "$suffix" ]]
then
    suffix_kebab="${suffix// /-}"
    suffix_kebab=$(echo "$suffix_kebab" | tr '[:upper:]' '[:lower:]')
else
    suffix_kebab=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | fold -w 6 | head -n 1)
fi
name="pg-${username}-${suffix_kebab}"
pem_file="$root_folder/$name.pem"


if [ -z "$AWS_REGION" ]
then
    AWS_REGION=$(aws configure get region | tr '\r' '\n')
    if [ "$AWS_REGION" == "" ]
    then
        logerror "❌ either the file $HOME/.aws/config is not present or environment variables AWS_REGION is not set!"
        exit 1
    fi
fi

# check if instance already exists
res=$(playground ec2 status --instance "$name" --all)
if [ "$res" != "" ]
then
    logerror "❌ ec2 instance $name already exists"
    logerror "use playground ec2 delete --instance $name to delete it"
    exit 1
fi

log "🔐 creating pem file $pem_file (make sure to create backup)"
aws ec2 create-key-pair --key-name "$name" --key-type rsa --key-format pem --query "KeyMaterial" --output text > $pem_file

if ! grep "BEGIN RSA PRIVATE KEY" $pem_file > /dev/null
then
    logerror "❌ failed to create pem file $pem_file"
    cat $pem_file
    exit 1
fi
chmod 400 $pem_file

cloud_formation_yml_file="$root_folder/cloudformation/kafka-docker-playground.yml"
myip=$(dig @resolver4.opendns.com myip.opendns.com +short)
key_name=$(basename $pem_file .pem)

tmp_dir=$(mktemp -d -t pg-XXXXXXXXXX)
if [ -z "$PG_VERBOSE_MODE" ]
then
    trap 'rm -rf $tmp_dir' EXIT
else
    log "🐛📂 not deleting tmp dir $tmp_dir"
fi

cd $tmp_dir
cp "$cloud_formation_yml_file" tmp.yml

log "👷 creating ${instance_type} instance $name in $AWS_REGION region (${ec2_size} Gb)"
log "🌀 cloud formation file used: $cloud_formation_yml_file"
log "🔐 ec2 pem file used: $pem_file"
aws cloudformation create-stack --stack-name $name --template-body "file://tmp.yml" --region ${AWS_REGION} --parameters ParameterKey=InstanceType,ParameterValue=${instance_type} ParameterKey=Ec2RootVolumeSize,ParameterValue=${ec2_size} ParameterKey=KeyName,ParameterValue=${key_name} ParameterKey=InstanceName,ParameterValue=$name ParameterKey=IPAddressRange,ParameterValue=${myip}/32 ParameterKey=SecretsEncryptionPassword,ParameterValue="${SECRETS_ENCRYPTION_PASSWORD}" ParameterKey=LinuxUserName,ParameterValue="${username}"
cd - > /dev/null

wait_for_ec2_instance_to_be_running "$name"

instance="$(playground ec2 status --instance "$name" --all)"
if [ $? != 0 ] || [ -z "$instance" ]
then
    logerror "❌ failed to get instance with name $name"
    playground ec2 status --instance "$name" --all
    exit 1
fi
log "👷 ec2 instance $name is created and accesible via SSH, it will be opened with visual studio code in 3 minutes..."
log "🌀 cloud formation is still in progress (installing docker, etc...) and can be reverted after 10 minutes (i.e removing ec2 instance) in case of issue. You can check progress by checking log file output.log in root folder of ec2 instance"
sleep 180
playground ec2 open --instance "$instance"

wait_for_ec2_cloudformation_to_be_completed "$name"

playground ec2 sync-repro-folder local-to-ec2 --instance "$instance" > /dev/null
log "🎉 ec2 instance $name is ready!"
log "🐚 make sure to use zsh in order to have everything working out of the box"