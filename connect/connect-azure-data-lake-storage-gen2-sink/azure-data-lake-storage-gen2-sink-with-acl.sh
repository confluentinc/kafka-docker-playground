#!/bin/bash
set -e

# This script uses ACLs (Access Control Lists) instead of RBAC roles to grant
# the Service Principal access only to the specific 'topics/subfolder' path
# in Azure Data Lake Storage Gen2.
#
# WARNING: Do not enable 'set -x' as it may expose secrets (passwords, storage keys)

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

if connect_cp_version_greater_than_8 && [ ! -z "$CONNECTOR_TAG" ] && ! version_gt $CONNECTOR_TAG "1.5.99"
then
     logwarn "minimal supported connector version is 1.6.0 for CP 8.0"
     logwarn "see https://docs.confluent.io/platform/current/connect/supported-connector-version-8.1.html#supported-connector-versions-in-cp-8-1"
     exit 111
fi

login_and_maybe_set_azure_subscription

# Use different naming to avoid conflicts with the non-ACL version of this script
AZURE_NAME=pg${USER}dlacl${GITHUB_RUN_NUMBER}${TAG_BASE}
AZURE_NAME=${AZURE_NAME//[-._]/}
if [ ${#AZURE_NAME} -gt 24 ]; then
  AZURE_NAME=${AZURE_NAME:0:24}
fi
AZURE_RESOURCE_GROUP=$AZURE_NAME
AZURE_DATALAKE_ACCOUNT_NAME=$AZURE_NAME
AZURE_AD_APP_NAME=pg${USER}acl
AZURE_REGION=${AZURE_REGION:-centralus}

set +e
az group delete --name $AZURE_RESOURCE_GROUP --yes
set -e

log "Add the CLI extension for Azure Data Lake Gen 2"
az extension add --name storage-preview

log "Creating resource $AZURE_RESOURCE_GROUP in $AZURE_REGION"
az group create \
    --name $AZURE_RESOURCE_GROUP \
    --location $AZURE_REGION \
    --tags owner_email=$AZ_USER cflt_managed_by=user cflt_managed_id="$USER"

function cleanup_cloud_resources {
    set +e
    log "Deleting resource group $AZURE_RESOURCE_GROUP"
    check_if_continue
    az group delete --name $AZURE_RESOURCE_GROUP --yes --no-wait
    
    # Optionally clean up Azure AD App (uncomment if desired)
    # log "Deleting Azure AD App $AZURE_AD_APP_NAME"
    # az ad app delete --id $AZURE_DATALAKE_CLIENT_ID 2>/dev/null
}
trap cleanup_cloud_resources EXIT

AZURE_RESOURCE_GROUP_ID=$(az group show --name $AZURE_RESOURCE_GROUP | jq -r '.id')

set +e
log "Registering active directory App $AZURE_AD_APP_NAME, it might fail if already exist"
AZURE_DATALAKE_CLIENT_ID=$(az ad app create --display-name "$AZURE_AD_APP_NAME" --is-fallback-public-client false --sign-in-audience AzureADandPersonalMicrosoftAccount --query appId -o tsv)
if [ $? != 0 ]
then
    log "Failed to create Azure AD App. Attempting to delete existing app and recreate."
    EXISTING_APP_ID=$(az ad app list --display-name "$AZURE_AD_APP_NAME" --query "[0].appId" -o tsv)
    if [ ! -z "$EXISTING_APP_ID" ]
    then
        az ad app delete --id "$EXISTING_APP_ID"
        AZURE_DATALAKE_CLIENT_ID=$(az ad app create --display-name "$AZURE_AD_APP_NAME" --is-fallback-public-client false --sign-in-audience AzureADandPersonalMicrosoftAccount --query appId -o tsv)
    fi
fi
AZURE_DATALAKE_CLIENT_PASSWORD=$(az ad app credential reset --id $AZURE_DATALAKE_CLIENT_ID | jq -r '.password')
set -e

if [ "$AZURE_DATALAKE_CLIENT_PASSWORD" == "" ]
then
  logerror "password could not be retrieved"
  if [ -z "$GITHUB_RUN_NUMBER" ]
  then
    # Suppress output to avoid logging secrets
    az ad app credential reset --id $AZURE_DATALAKE_CLIENT_ID > /dev/null 2>&1
    logerror "Attempted credential reset. Please re-run the script."
  fi
  exit 1
fi

log "Getting Service Principal associated to the App $AZURE_DATALAKE_CLIENT_ID"
set +e
SERVICE_PRINCIPAL_ID=$(az ad sp show --id $AZURE_DATALAKE_CLIENT_ID | jq -r '.id')
if [ $? != 0 ] || [ "$SERVICE_PRINCIPAL_ID" == "" ]
then
  log "Service Principal does not appear to exist...Creating Service Principal associated to the App $AZURE_DATALAKE_CLIENT_ID" 
  SERVICE_PRINCIPAL_ID=$(az ad sp create --id $AZURE_DATALAKE_CLIENT_ID | jq -r '.id')
  if [ $? != 0 ]
  then
    logerror "❌ Could not get or create Service Principal associated to the App $AZURE_DATALAKE_CLIENT_ID"
    exit 1
  fi
fi
set -e

tenantId=$(az account list --query "[?isDefault].tenantId" | jq -r '.[0]')
AZURE_DATALAKE_TOKEN_ENDPOINT="https://login.microsoftonline.com/$tenantId/oauth2/token"

log "Creating data lake $AZURE_DATALAKE_ACCOUNT_NAME in resource $AZURE_RESOURCE_GROUP"
az storage account create \
    --name $AZURE_DATALAKE_ACCOUNT_NAME \
    --resource-group $AZURE_RESOURCE_GROUP \
    --location $AZURE_REGION \
    --sku Standard_LRS \
    --kind StorageV2 \
    --hns true \
    --tags cflt_managed_by=user cflt_managed_id="$USER"

sleep 20

# Get storage account key for ACL operations
log "Getting storage account key"
STORAGE_ACCOUNT_KEY=$(az storage account keys list \
    --account-name $AZURE_DATALAKE_ACCOUNT_NAME \
    --resource-group $AZURE_RESOURCE_GROUP \
    --query "[0].value" -o tsv)

if [ -z "$STORAGE_ACCOUNT_KEY" ]; then
    logerror "Failed to retrieve storage account key"
    exit 1
fi
log "Storage account key retrieved successfully"

# Create the 'topics' filesystem (container)
log "Creating 'topics' filesystem"
az storage fs create \
    --name topics \
    --account-name $AZURE_DATALAKE_ACCOUNT_NAME \
    --account-key "$STORAGE_ACCOUNT_KEY"

# Create the 'subfolder' directory inside 'topics' filesystem
log "Creating 'subfolder' directory inside 'topics' filesystem"
az storage fs directory create \
    --name subfolder \
    --file-system topics \
    --account-name $AZURE_DATALAKE_ACCOUNT_NAME \
    --account-key "$STORAGE_ACCOUNT_KEY"

# Set ACL on the filesystem root (/) with execute permission only
# This allows the Service Principal to traverse to the subfolder
log "Setting ACL on filesystem root for traversal (execute only)"
az storage fs access set \
    --acl "user:${SERVICE_PRINCIPAL_ID}:--x" \
    --path "/" \
    --file-system topics \
    --account-name $AZURE_DATALAKE_ACCOUNT_NAME \
    --account-key "$STORAGE_ACCOUNT_KEY"

# Set ACL on 'subfolder' directory with full rwx permissions
log "Setting ACL on 'subfolder' directory for Service Principal $SERVICE_PRINCIPAL_ID"
az storage fs access set \
    --acl "user:${SERVICE_PRINCIPAL_ID}:rwx" \
    --path "subfolder" \
    --file-system topics \
    --account-name $AZURE_DATALAKE_ACCOUNT_NAME \
    --account-key "$STORAGE_ACCOUNT_KEY"

# Set default ACL on 'subfolder' so new subdirectories/files inherit permissions
# This is critical for the connector to create topic directories and partition subdirectories
log "Setting default ACL on 'subfolder' for inheritance"
az storage fs access set \
    --acl "default:user:${SERVICE_PRINCIPAL_ID}:rwx" \
    --path "subfolder" \
    --file-system topics \
    --account-name $AZURE_DATALAKE_ACCOUNT_NAME \
    --account-key "$STORAGE_ACCOUNT_KEY"

log "ACLs configured successfully. Service Principal has access only to topics/subfolder path."

# Verify ACLs
log "Verifying ACL on filesystem root"
az storage fs access show \
    --path "/" \
    --file-system topics \
    --account-name $AZURE_DATALAKE_ACCOUNT_NAME \
    --account-key "$STORAGE_ACCOUNT_KEY"

log "Verifying ACL on subfolder"
az storage fs access show \
    --path "subfolder" \
    --file-system topics \
    --account-name $AZURE_DATALAKE_ACCOUNT_NAME \
    --account-key "$STORAGE_ACCOUNT_KEY"

sleep 10

# generate data file for externalizing secrets (using different file to avoid conflicts)
sed -e "s|:AZURE_DATALAKE_CLIENT_ID:|$AZURE_DATALAKE_CLIENT_ID|g" \
    -e "s|:AZURE_DATALAKE_CLIENT_PASSWORD:|$AZURE_DATALAKE_CLIENT_PASSWORD|g" \
    -e "s|:AZURE_DATALAKE_ACCOUNT_NAME:|$AZURE_DATALAKE_ACCOUNT_NAME|g" \
    -e "s|:AZURE_DATALAKE_TOKEN_ENDPOINT:|$AZURE_DATALAKE_TOKEN_ENDPOINT|g" \
    ../../connect/connect-azure-data-lake-storage-gen2-sink/data.template > ../../connect/connect-azure-data-lake-storage-gen2-sink/data-acl

PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.acl.yml"

log "Creating Data Lake Storage Gen2 Sink connector (ACL version)"
playground connector create-or-update --connector azure-datalake-gen2-sink-acl  << EOF
{
    "connector.class": "io.confluent.connect.azure.datalake.gen2.AzureDataLakeGen2SinkConnector",
    "tasks.max": "1",
    "topics": "datalake_topic_acl",
    "topics.dir": "topics/subfolder",
    "flush.size": "3",
    "azure.datalake.gen2.client.id": "\${file:/data-acl:AZURE_DATALAKE_CLIENT_ID}",
    "azure.datalake.gen2.client.key": "\${file:/data-acl:AZURE_DATALAKE_CLIENT_PASSWORD}",
    "azure.datalake.gen2.account.name": "\${file:/data-acl:AZURE_DATALAKE_ACCOUNT_NAME}",
    "azure.datalake.gen2.token.endpoint": "\${file:/data-acl:AZURE_DATALAKE_TOKEN_ENDPOINT}",
    "format.class": "io.confluent.connect.azure.storage.format.avro.AvroFormat",
    "confluent.license": "",
    "confluent.topic.bootstrap.servers": "broker:9092",
    "confluent.topic.replication.factor": "1"
}
EOF


playground topic produce -t datalake_topic_acl --nb-messages 10 --forced-value '{"f1":"value%g"}' << 'EOF'
{
  "type": "record",
  "name": "myrecord",
  "fields": [
    {
      "name": "f1",
      "type": "string"
    }
  ]
}
EOF

sleep 20

log "Listing ${AZURE_DATALAKE_ACCOUNT_NAME} in Azure Data Lake"
az storage fs file list --account-name "${AZURE_DATALAKE_ACCOUNT_NAME}" --file-system topics --account-key "$STORAGE_ACCOUNT_KEY"

log "Getting one of the avro files locally and displaying content with avro-tools"
az storage blob download \
    --container-name topics \
    --name subfolder/datalake_topic_acl/partition=0/datalake_topic_acl+0+0000000000.avro \
    --file /tmp/datalake_topic_acl+0+0000000000.avro \
    --account-name "${AZURE_DATALAKE_ACCOUNT_NAME}" \
    --account-key "$STORAGE_ACCOUNT_KEY"

playground tools read-avro-file --file /tmp/datalake_topic_acl+0+0000000000.avro

