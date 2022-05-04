# Variables
RESOURCE_GROUP="internal-web"
LOCATION="francecentral"
VNET_NAME="vnet"

#################################################
##### Storage Account with private endpoint #####
#################################################

STORAGE_ACCOUNT_NAME="internalstore"

# Create the storage account
az storage account create \
--name $STORAGE_ACCOUNT_NAME \
--resource-group $RESOURCE_GROUP \
--location $LOCATION \
--sku Standard_LRS \
--default-action Deny 

STORAGE_SUBNET_NAME="storage-subnet"
STORAGE_SUBNET_CIDR=10.10.7.0/24

# Create a subnet for the storage account
az network vnet subnet create \
--name $STORAGE_SUBNET_NAME \
--resource-group $RESOURCE_GROUP \
--vnet-name $VNET_NAME \
--address-prefixes $STORAGE_SUBNET_CIDR

# Disable private endpoint network policies
az network vnet subnet update \
--name $STORAGE_SUBNET_NAME \
--resource-group $RESOURCE_GROUP \
--vnet-name $VNET_NAME \
--disable-private-endpoint-network-policies true


STORAGE_ACCOUNT_ID=$(az storage account show --name $STORAGE_ACCOUNT_NAME --resource-group $RESOURCE_GROUP --query id --output tsv)

# Create a private endpoint for the storage account
az network private-endpoint create \
--name $STORAGE_ACCOUNT_NAME-private-endpoint \
--resource-group $RESOURCE_GROUP \
--location $LOCATION \
--vnet-name $VNET_NAME \
--subnet $STORAGE_SUBNET_NAME \
--connection-name "storage-connection" \
--private-connection-resource-id $STORAGE_ACCOUNT_ID \
--group-id blob


BLOB_PRIVATE_DNS_ZONE="privatelink.blob.core.windows.net"

# Create a DNS private zone
az network private-dns zone create \
--resource-group $RESOURCE_GROUP \
--name $BLOB_PRIVATE_DNS_ZONE

#link the private zone to the vnet
az network private-dns link vnet create \
--name "blob_private_dns" \
--resource-group $RESOURCE_GROUP \
--zone-name $BLOB_PRIVATE_DNS_ZONE \
--virtual-network $VNET_NAME \
--registration-enabled false

# Register the storage account in the private DNS zone
# Get the ID of the azure storage NIC
STORAGE_NIC_ID=$(az network private-endpoint show --name $STORAGE_ACCOUNT_NAME-private-endpoint -g $RESOURCE_GROUP --query 'networkInterfaces[0].id' -o tsv)

# Get the IP of the azure storage NIC
STORAGE_ACCOUNT_PRIVATE_IP=$(az resource show --ids $STORAGE_NIC_ID --query 'properties.ipConfigurations[0].properties.privateIPAddress' --output tsv)

# create a record set for the storage account
az network private-dns record-set a add-record \
--record-set-name $STORAGE_ACCOUNT_NAME \
--resource-group $RESOURCE_GROUP \
--zone-name $BLOB_PRIVATE_DNS_ZONE \
--ipv4-address $STORAGE_ACCOUNT_PRIVATE_IP

# Get my public IP
HOME_IP=$(curl -s ipinfo.io/ip)

# Create a rule to access the storage account from a specific IP
az storage account network-rule add --resource-group $RESOURCE_GROUP --account-name $STORAGE_ACCOUNT_NAME --ip-address $HOME_IP
# List IP rules
az storage account network-rule list --resource-group $RESOURCE_GROUP --account-name $STORAGE_ACCOUNT_NAME --query ipRules

# Use Az Copy to move files to the storage account
