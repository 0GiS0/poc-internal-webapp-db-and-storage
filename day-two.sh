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