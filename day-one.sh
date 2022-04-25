#############################################################
######################## Day 1 ##############################
#############################################################

# Variables
RESOURCE_GROUP="internal-web"
LOCATION="francecentral"

# 1. Create resource group
az group create --name $RESOURCE_GROUP --location $LOCATION

# 2. Create VNET and subnet for the database
VNET_NAME="vnet"
VNET_CIDR=10.10.0.0/16
DB_SUBNET_NAME="db"
SUBNET_CIDR=10.10.1.0/24

# Create vnet and the subnet
az network vnet create \
--name $VNET_NAME \
--resource-group $RESOURCE_GROUP \
--location $LOCATION \
--address-prefixes $VNET_CIDR \
--subnet-name $DB_SUBNET_NAME \
--subnet-prefixes $SUBNET_CIDR

# Disable private endpoint network policies
az network vnet subnet update \
--name $DB_SUBNET_NAME \
--resource-group $RESOURCE_GROUP \
--vnet-name $VNET_NAME \
--disable-private-endpoint-network-policies true

# 3. Create the database
SQL_SERVER_NAME="internalsqlsvr"
SQL_SERVER_ADMIN_USER="sqladmin"
SQL_SERVER_ADMIN_PASSWORD="P@ssw0rd"

# Create the SQL server
az sql server create \
--name $SQL_SERVER_NAME \
--resource-group $RESOURCE_GROUP \
--location $LOCATION \
--admin-user $SQL_SERVER_ADMIN_USER \
--admin-password $SQL_SERVER_ADMIN_PASSWORD \
--enable-public-network false

# Create a database
az sql db create \
    --resource-group $RESOURCE_GROUP  \
    --server $SQL_SERVER_NAME \
    --name adventure \
    --sample-name AdventureWorksLT

# Create a private endpoint for the SQL server
SQL_SERVER_ID=$(az sql server list \
    --resource-group $RESOURCE_GROUP \
    --query '[].[id]' \
    --output tsv)

# 5. Create a private endpoint for the SQL server
az network private-endpoint create \
    --name $SQL_SERVER_NAME-private-endpoint \
    --resource-group $RESOURCE_GROUP \
    --location $LOCATION \
    --vnet-name $VNET_NAME --subnet $DB_SUBNET_NAME \
    --private-connection-resource-id $SQL_SERVER_ID \
    --group-id sqlServer \
    --connection-name sql-server-connection  

# Configure private DNS zone for SQL server
SQL_SERVER_PRIVATE_DNS_ZONE="privatelink.database.windows.net"

# Create a DNS private zone
az network private-dns zone create \
    --resource-group $RESOURCE_GROUP \
    --name $SQL_SERVER_PRIVATE_DNS_ZONE

# 6. Create a dns zone group for the SQL server
az network private-endpoint dns-zone-group create \
   --resource-group $RESOURCE_GROUP \
   --endpoint-name $SQL_SERVER_NAME-private-endpoint \
   --name sql-server-group \
   --private-dns-zone $SQL_SERVER_PRIVATE_DNS_ZONE \
   --zone-name sql

# 7. link between the private zone and the vnet
az network private-dns link vnet create \
    --resource-group $RESOURCE_GROUP \
    --zone-name $SQL_SERVER_PRIVATE_DNS_ZONE \
    --name sql-server-dns-link \
    --virtual-network $VNET_NAME \
    --registration-enabled false

# Check that the SQL server is not accesible from the internet
# Get the connection string
DB_RESOURCE_URI=$(az sql db show --query "id" --resource-group $RESOURCE_GROUP --server $SQL_SERVER_NAME --name adventure --output tsv)
az sql db show-connection-string --client ado.net --ids $DB_RESOURCE_URI

# Azure Data Studio
https://docs.microsoft.com/es-es/sql/azure-data-studio/download-azure-data-studio?view=sql-server-ver15

# 8. Create a firewall rule to allow access to the SQL server
# To manage server or database level firewall rules, please enable the public network interface.
az sql server update \
--resource-group $RESOURCE_GROUP \
--name $SQL_SERVER_NAME \
--enable-public-network true

# Get my public IP
HOME_IP=$(curl -s ipinfo.io/ip)

az sql server firewall-rule create \
    --resource-group $RESOURCE_GROUP \
    --server $SQL_SERVER_NAME \
    --name Home \
    --start-ip-address $HOME_IP \
    --end-ip-address $HOME_IP


# 9. Create a jumpbox for the following tasks
VM_SUBNET_NAME="vms"
VM_SUBNET_CIDR=10.10.2.0/24
VM_NAME="jumpboxvm"

# Create a new subnet in the VNET
az network vnet subnet create \
--name $VM_SUBNET_NAME \
--resource-group $RESOURCE_GROUP \
--vnet-name $VNET_NAME \
--address-prefixes $VM_SUBNET_CIDR

# Create a VM in the new subnet
az vm create \
--name $VM_NAME \
--resource-group $RESOURCE_GROUP \
--location $LOCATION \
--vnet-name $VNET_NAME \
--subnet $VM_SUBNET_NAME \
--image "Win2019Datacenter" \
--admin-username "azureuser" \
--admin-password "P@ssw0rdforMe" \
--nsg-rule NONE

######################################
########## Azure Bastion #############
######################################

# 9.1 Create a bastion host
BASTION_PUBLIC_IP_NAME="bastion-public-ip"
BASTION_HOST_NAME="bastion-host"
BASTION_SUBNET_CIDR=10.10.3.0/27

# 9.2 Create a subnet for the bastion host
az network vnet subnet create \
--name AzureBastionSubnet \
--resource-group $RESOURCE_GROUP \
--vnet-name $VNET_NAME \
--address-prefixes $BASTION_SUBNET_CIDR

# 9.3 Create a public IP
az network public-ip create \
--resource-group $RESOURCE_GROUP \
--name $BASTION_PUBLIC_IP_NAME \
--sku Standard --location $LOCATION

# 9.4 Create a bastion host
az network bastion create --name $BASTION_HOST_NAME \
--resource-group $RESOURCE_GROUP \
--location $LOCATION \
--vnet-name $VNET_NAME \
--public-ip-address $BASTION_PUBLIC_IP_NAME
