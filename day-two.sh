# Variables
RESOURCE_GROUP="internal-web"
LOCATION="francecentral"

# 1. Create App Service Plan
APP_SERVICE_PLAN="PremiumPlan"

az appservice plan create \
--name $APP_SERVICE_PLAN \
--resource-group $RESOURCE_GROUP \
--location $LOCATION \
--sku P1V2

# 2. Create Web App
WEBAPP_NAME="gisweb"

az webapp create \
--name $WEBAPP_NAME \
--resource-group $RESOURCE_GROUP \
--plan $APP_SERVICE_PLAN

# 3. Create a new subnet in the VNET
VNET_NAME="vnet"
WEB_APP_SUBNET_NAME="webapps"
WEB_APP_SUBNET_CIDR=10.10.4.0/24

az network vnet subnet create \
--name $WEB_APP_SUBNET_NAME \
--resource-group $RESOURCE_GROUP \
--vnet-name $VNET_NAME \
--address-prefixes $WEB_APP_SUBNET_CIDR \
--disable-private-endpoint-network-policies true

# 4. Create private endpoint for the web app
WEBAPP_ID=$(az webapp show --name $WEBAPP_NAME --resource-group $RESOURCE_GROUP --query id --output tsv)

az network private-endpoint create \
--name $WEBAPP_NAME-private-endpoint \
--resource-group $RESOURCE_GROUP \
--location $LOCATION \
--vnet-name $VNET_NAME \
--subnet $WEB_APP_SUBNET_NAME \
--connection-name "webapp-connection" \
--private-connection-resource-id $WEBAPP_ID \
--group-id sites

# 5. Create Private DNS Zone
az network private-dns zone create \
--name privatelink.azurewebsites.net \
--resource-group $RESOURCE_GROUP

# 6. Link between my VNET and the Private DNS Zone
az network private-dns link vnet create \
--name "${VNET_NAME}-link" \
--resource-group $RESOURCE_GROUP \
--registration-enabled false \
--virtual-network $VNET_NAME \
--zone-name privatelink.azurewebsites.net

# 7. Create a DNS zone group
az network private-endpoint dns-zone-group create \
--name "webapp-group" \
--resource-group $RESOURCE_GROUP \
--endpoint-name $WEBAPP_NAME-private-endpoint \
--private-dns-zone privatelink.azurewebsites.net \
--zone-name privatelink.azurewebsites.net

# 8. Try to access from the Internet and the jumpbox using Bastion

# 9. Create subnet for the App Gateway
APP_GW_NAME="app-gw"
APP_GW_SUBNET_CIDR=10.10.5.0/24

# Create a subnet for the application gateway
az network vnet subnet create \
--name $APP_GW_NAME-subnet \
--resource-group $RESOURCE_GROUP \
--vnet-name $VNET_NAME \
--address-prefixes $APP_GW_SUBNET_CIDR

# Create a public IP for the application gateway
az network public-ip create \
--resource-group $RESOURCE_GROUP \
--name $APP_GW_NAME-public-ip \
--sku Standard --location $LOCATION

# 10. Create the application gateway
az network application-gateway create \
--name $APP_GW_NAME \
--resource-group $RESOURCE_GROUP \
--location $LOCATION \
--public-ip-address $APP_GW_NAME-public-ip \
--vnet-name $VNET_NAME \
--subnet $APP_GW_NAME-subnet \
--sku Standard_v2

# 11. Configure App Gw to access the web app
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

# 12. Test that we can access the web app from the Internet via App Gw

# Get the public IP address of the application gateway
APP_GW_PUBLIC_IP=$(az network public-ip show \
--resource-group $RESOURCE_GROUP \
--name $APP_GW_NAME-public-ip \
--query ipAddress \
--output tsv)

curl http://$APP_GW_PUBLIC_IP

# 13. Deploy via Azure DevOps
# Two options: 
# self-hosted agent
# onedeploy extension: https://www.returngis.net/2022/02/desplegar-codigo-en-un-app-service-con-private-endpoint-desde-fuera-de-su-red/

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
--name dotnetapp2.zip \
--file dotnetapp.zip --overwrite

# Create a sas token
STORAGE_ACCOUNT_KEY=$(az storage account keys list --account-name $STORAGE_ACCOUNT_NAME --resource-group $RESOURCE_GROUP --query "[0].value" --output tsv)
end=`date -v+30M '+%Y-%m-%dT%H:%MZ'`

SAS=$(az storage account generate-sas --permissions rl --account-name $STORAGE_ACCOUNT_NAME --account-key $STORAGE_ACCOUNT_KEY --services b --resource-types co --expiry $end -o tsv)

ZIP_URL="https://$STORAGE_ACCOUNT_NAME.blob.core.windows.net/packages/dotnetapp2.zip?$SAS"

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

# Add connection string and settings for the web app
az webapp config connection-string set \
--name $WEBAPP_NAME \
--resource-group $RESOURCE_GROUP \
--settings ConnectionString \
--connection-string-type SQLAzure \
--settings "MyDbConnection=Server=tcp:internalsqlsvr.database.windows.net,1433;Initial Catalog=tododb;Persist Security Info=False;User ID=sqladmin;Password=P@ssw0rd;MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"

####################################################
#### WARNING: this communication won't work ########
####################################################

# Outbound Traffic
# Set up calls to app dependencies like databases.

# Create a subnet
WEB_APP_OUTBOUND_SUBNET="$WEB_APP_SUBNET_NAME-outbound"
WEB_APP_OUTBOUND_SUBNET_CIDR=10.10.6.0/27

# Create a subnet for the outbound traffic
az network vnet subnet create \
--name $WEB_APP_OUTBOUND_SUBNET \
--resource-group $RESOURCE_GROUP \
--vnet-name $VNET_NAME \
--address-prefixes $WEB_APP_OUTBOUND_SUBNET_CIDR


# Create a vnet integration for the outbound traffic
az webapp vnet-integration add \
--name $WEBAPP_NAME \
--resource-group $RESOURCE_GROUP \
--subnet $WEB_APP_OUTBOUND_SUBNET \
--vnet $VNET_NAME

# You need to restart the web app to take effect
az webapp restart --name $WEBAPP_NAME --resource-group $RESOURCE_GROUP


# Add app setting environment variable
az webapp config appsettings set \
--name $WEBAPP_NAME \
--resource-group $RESOURCE_GROUP \
--settings "ASPNETCORE_ENVIRONMENT=Development"