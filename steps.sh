# Variables
RESOURCE_GROUP="private-app-svc"
LOCATION="northeurope"

# 1. Create a resource group
az group create --name $RESOURCE_GROUP --location $LOCATION

# 2. Create App Service Plan
APP_SERVICE_PLAN="PremiumPlan"

az appservice plan create \
--name $APP_SERVICE_PLAN \
--resource-group $RESOURCE_GROUP \
--location $LOCATION \
--sku P1V2

# 3. Create Web App
WEBAPP_NAME="internalweb"

az webapp create \
--name $WEBAPP_NAME \
--resource-group $RESOURCE_GROUP \
--plan $APP_SERVICE_PLAN

# 4. Create a VNET
WEB_APP_VNET_NAME="webapp-vnet"
WEB_APP_VNET_CIDR=10.10.0.0/16
WEB_APP_SUBNET_NAME="webapps"
WEB_APP_SUBNET_CIDR=10.10.1.0/24

az network vnet create \
--name $WEB_APP_VNET_NAME \
--resource-group $RESOURCE_GROUP \
--location $LOCATION \
--address-prefixes $WEB_APP_VNET_CIDR \
--subnet-name $WEB_APP_SUBNET_NAME \
--subnet-prefixes $WEB_APP_SUBNET_CIDR

# 5. You need to update the subnet to disable private endpoint network policies.
az network vnet subnet update \
--name $WEB_APP_SUBNET_NAME \
--resource-group $RESOURCE_GROUP \
--vnet-name $WEB_APP_VNET_NAME \
--disable-private-endpoint-network-policies true

###########################################
########### Private endpoint ##############
###########################################

# 6. Create a Private Endpoint for the Web App
# 6. 1 Get the web app ID
WEBAPP_ID=$(az webapp show --name $WEBAPP_NAME --resource-group $RESOURCE_GROUP --query id --output tsv)

WEB_APP_PRIVATE_ENDPOINT="webapp-private-endpoint"

# 6. 2 Create a Private Endpoint
az network private-endpoint create \
--name $WEB_APP_PRIVATE_ENDPOINT \
--resource-group $RESOURCE_GROUP \
--vnet-name $WEB_APP_VNET_NAME \
--subnet $WEB_APP_SUBNET_NAME \
--connection-name "webapp-connection" \
--private-connection-resource-id $WEBAPP_ID \
--group-id sites

###########################################
########### Private DNS Zone ##############
###########################################

# 7. Create Private DNS Zone
az network private-dns zone create \
--name privatelink.azurewebsites.net \
--resource-group $RESOURCE_GROUP

# 7.1 Link between my VNET and the Private DNS Zone
az network private-dns link vnet create \
--name "${WEB_APP_VNET_NAME}-link" \
--resource-group $RESOURCE_GROUP \
--registration-enabled false \
--virtual-network $WEB_APP_VNET_NAME \
--zone-name privatelink.azurewebsites.net

# 7.2 Create a DNS zone group
az network private-endpoint dns-zone-group create \
--name "webapp-group" \
--resource-group $RESOURCE_GROUP \
--endpoint-name $WEB_APP_PRIVATE_ENDPOINT \
--private-dns-zone privatelink.azurewebsites.net \
--zone-name privatelink.azurewebsites.net

###########################################
################ Jumpbox ##################
###########################################

VM_SUBNET_NAME="vms"
VM_SUBNET_CIDR=10.10.2.0/24
VM_NAME="same-vnet-vm"

# 8. Create a new subnet in the VNET
az network vnet subnet create \
--name $VM_SUBNET_NAME \
--resource-group $RESOURCE_GROUP \
--vnet-name $WEB_APP_VNET_NAME \
--address-prefixes $VM_SUBNET_CIDR

# 9. Create a VM in the new subnet
az vm create \
--name $VM_NAME \
--resource-group $RESOURCE_GROUP \
--vnet-name $WEB_APP_VNET_NAME \
--subnet $VM_SUBNET_NAME \
--image "Win2019Datacenter" \
--admin-username "azureuser" \
--admin-password "P@ssw0rdforMe" \
--nsg-rule NONE

######################################
########## Azure Bastion #############
######################################

# 10. Create a bastion host
BASTION_PUBLIC_IP_NAME="bastion-public-ip"
BASTION_HOST_NAME="bastion-host"
BASTION_SUBNET_CIDR=10.10.3.0/27

# 10.1 Create a subnet for the bastion host
az network vnet subnet create \
--name AzureBastionSubnet \
--resource-group $RESOURCE_GROUP \
--vnet-name $WEB_APP_VNET_NAME \
--address-prefixes $BASTION_SUBNET_CIDR

# 10.2 Create a public IP
az network public-ip create \
--resource-group $RESOURCE_GROUP \
--name $BASTION_PUBLIC_IP_NAME \
--sku Standard --location $LOCATION

# 10.3 Create a bastion host
az network bastion create --name $BASTION_HOST_NAME \
--resource-group $RESOURCE_GROUP \
--location $LOCATION \
--vnet-name $WEB_APP_VNET_NAME \
--public-ip-address $BASTION_PUBLIC_IP_NAME


###############################
##### Application Gateway #####
###############################

APP_GW_NAME="app-gw"
APP_GW_SUBNET_CIDR=10.10.4.0/24


# Create a subnet for the application gateway
az network vnet subnet create \
--name $APP_GW_NAME-subnet \
--resource-group $RESOURCE_GROUP \
--vnet-name $WEB_APP_VNET_NAME \
--address-prefixes $APP_GW_SUBNET_CIDR

# Create a public IP for the application gateway
az network public-ip create \
--resource-group $RESOURCE_GROUP \
--name $APP_GW_NAME-public-ip \
--sku Standard --location $LOCATION

# Create the application gateway
az network application-gateway create \
--name $APP_GW_NAME \
--resource-group $RESOURCE_GROUP \
--location $LOCATION \
--public-ip-address $APP_GW_NAME-public-ip \
--vnet-name $WEB_APP_VNET_NAME \
--subnet $APP_GW_NAME-subnet \
--sku Standard_v2

# Configure App gateway to access the web app

## Add App Service in the existing backend pool
az network application-gateway address-pool update \
-g $RESOURCE_GROUP \
-n appGatewayBackendPool \
--gateway-name $APP_GW_NAME \
--servers "${WEBAPP_NAME}.azurewebsites.net"


# Update HTTP Settings to work with App Service
az network application-gateway http-settings update \
-g $RESOURCE_GROUP \
-n appGatewayBackendHttpSettings \
--gateway-name $APP_GW_NAME \
--host-name-from-backend-pool true

# Get the public IP address of the application gateway
APP_GW_PUBLIC_IP=$(az network public-ip show \
--resource-group $RESOURCE_GROUP \
--name $APP_GW_NAME-public-ip \
--query ipAddress \
--output tsv)

curl http://$APP_GW_PUBLIC_IP

# Restrict access to the web app only from the app gateway

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
STORAGE_SUBNET_CIDR=10.10.5.0/24

# Create a subnet for the storage account
az network vnet subnet create \
--name $STORAGE_SUBNET_NAME \
--resource-group $RESOURCE_GROUP \
--vnet-name $WEB_APP_VNET_NAME \
--address-prefixes $STORAGE_SUBNET_CIDR

# Disable private endpoint network policies
az network vnet subnet update \
--name $STORAGE_SUBNET_NAME \
--resource-group $RESOURCE_GROUP \
--vnet-name $WEB_APP_VNET_NAME \
--disable-private-endpoint-network-policies true


STORAGE_ACCOUNT_ID=$(az storage account show --name $STORAGE_ACCOUNT_NAME --resource-group $RESOURCE_GROUP --query id --output tsv)

# Create a private endpoint for the storage account
az network private-endpoint create \
--name $STORAGE_ACCOUNT_NAME-private-endpoint \
--resource-group $RESOURCE_GROUP \
--vnet-name $WEB_APP_VNET_NAME \
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
--virtual-network $WEB_APP_VNET_NAME \
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

#################################################
##### SQL Database with private endpoint ########
#################################################

SQL_SERVER_NAME="todosqlserver"
SQL_SERVER_ADMIN_USER="sqladmin"
SQL_SERVER_ADMIN_PASSWORD="P@ssw0rd"

LOCATION="swedencentral"

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

az network private-endpoint create \
    --name $SQL_SERVER_NAME-private-endpoint \
    --resource-group $RESOURCE_GROUP \
    --vnet-name $WEB_APP_VNET_NAME --subnet $STORAGE_SUBNET_NAME \
    --private-connection-resource-id $SQL_SERVER_ID \
    --group-id sqlServer \
    --connection-name sql-server-connection  

# Configure private DNS zone for SQL server
SQL_SERVER_PRIVATE_DNS_ZONE="privatelink.database.windows.net"

# Create a DNS private zone
az network private-dns zone create \
    --resource-group $RESOURCE_GROUP \
    --name $SQL_SERVER_PRIVATE_DNS_ZONE

# link between the private zone and the vnet
az network private-dns link vnet create \
    --resource-group $RESOURCE_GROUP \
    --zone-name $SQL_SERVER_PRIVATE_DNS_ZONE \
    --name sql-server-dns-link \
    --virtual-network $WEB_APP_VNET_NAME \
    --registration-enabled false

# Create a dns zone group for the SQL server
az network private-endpoint dns-zone-group create \
   --resource-group $RESOURCE_GROUP \
   --endpoint-name $SQL_SERVER_NAME-private-endpoint \
   --name sql-server-group \
   --private-dns-zone $SQL_SERVER_PRIVATE_DNS_ZONE \
   --zone-name sql

# Create a firewall rule to allow access to the SQL server
# To manage server or database level firewall rules, please enable the public network interface.
az sql server update \
--resource-group $RESOURCE_GROUP \
--name $SQL_SERVER_NAME \
--enable-public-network true

az sql server firewall-rule create \
    --resource-group $RESOURCE_GROUP \
    --server $SQL_SERVER_NAME \
    --name Home \
    --start-ip-address $HOME_IP \
    --end-ip-address $HOME_IP

#################################################
################ Deployment #####################
#################################################

# Create a Storage Account
STORAGE_ACCOUNT_NAME="fordeploys"

az storage account create \
--name $STORAGE_ACCOUNT_NAME \
--resource-group $RESOURCE_GROUP \
--location $LOCATION \
--sku Standard_LRS \
--https-only true \
--allow-blob-public-access false


# Clone a sample code
git clone https://github.com/0GiS0/todo-sample-for-app-svc.git
cd todo-sample-for-app-svc
dotnet build --configuration Release
dotnet publish -c Release -o dotnetapp/
cd dotnetapp
zip -r dotnetapp.zip .

# Create container
az storage container create \
--name packages \
--account-name $STORAGE_ACCOUNT_NAME

#Upload the package
az storage blob upload \
--account-name $STORAGE_ACCOUNT_NAME \
--container-name packages \
--name dotnetapp.zip \
--file dotnetapp.zip

# Create a sas token
STORAGE_ACCOUNT_KEY=$(az storage account keys list --account-name $STORAGE_ACCOUNT_NAME --resource-group $RESOURCE_GROUP --query "[0].value" --output tsv)
end=`date -v+30M '+%Y-%m-%dT%H:%MZ'`

SAS=$(az storage account generate-sas --permissions rl --account-name $STORAGE_ACCOUNT_NAME --account-key $STORAGE_ACCOUNT_KEY --services b --resource-types co --expiry $end -o tsv)

ZIP_URL="https://$STORAGE_ACCOUNT_NAME.blob.core.windows.net/packages/dotnetapp.zip?$SAS"

SUBSCRIPTION_ID=$(az account show --query id --output tsv)

SITE_URI="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Web/sites/${WEBAPP_NAME}/extensions/onedeploy?api-version=2020-12-01"

# Deploy the web app using Kudu
az rest --method PUT \
        --uri $SITE_URI \
        --body '{ 
            "properties": { 
                "packageUri": "'"${ZIP_URL}"'",                
                "type": "zip", 
                "ignorestack": false,
                "clean": true,
                "restart": false
            }
        }'

# Check the status
az rest --method GET --uri $SITE_URI

####################################################
################# GitHub Actions ###################
####################################################

# Create a service principal
az ad sp create-for-rbac --name $WEBAPP_NAME --role contributor  > auth.json
  az ad sp create-for-rbac --name $WEBAPP_NAME --role contributor --scopes /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP --sdk-auth > auth.json

####################################################
############ App Settings configuration ############
####################################################


#Add SQL Database connection string to the app settings
az webapp config connection-string set \
-g $RESOURCE_GROUP -n $WEBAPP_NAME -t SQLAzure \
--settings MyDbConnection="Server=tcp:$SQL_SERVER_NAME.database.windows.net,1433;Initial Catalog=tododb;Persist Security Info=False;User ID=$SQL_SERVER_ADMIN_USER;Password=$SQL_SERVER_ADMIN_PASSWORD;MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"

####################################################
#### WARNING: this communication won't work ########
####################################################

# Outbound Traffic
# Set up calls to app dependencies like databases.

# Create a subnet
# 10. Create a bastion host
WEB_APP_OUTBOUND_SUBNET="$WEB_APP_SUBNET_NAME-outbound"
WEB_APP_OUTBOUND_SUBNET_CIDR=10.10.6.0/27

# 10.1 Create a subnet for the bastion host
az network vnet subnet create \
--name $WEB_APP_OUTBOUND_SUBNET \
--resource-group $RESOURCE_GROUP \
--vnet-name $WEB_APP_VNET_NAME \
--address-prefixes $WEB_APP_OUTBOUND_SUBNET_CIDR


# Outbound traffic internal network
az webapp vnet-integration add \
--name $WEBAPP_NAME \
--resource-group $RESOURCE_GROUP \
--subnet $WEB_APP_OUTBOUND_SUBNET \
--vnet $WEB_APP_VNET_NAME

# You need to restart the web app to take effect
az webapp restart --name $WEBAPP_NAME --resource-group $RESOURCE_GROUP
