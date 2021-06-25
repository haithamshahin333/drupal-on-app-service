#!/bin/bash -e

# Create a resource group for the Drupal workload
echo "Creating resource group '$RG_NAME' in region '$LOCATION'."
az group create --name $RG_NAME --location $LOCATION --output none

# Create ACR instance for container image
echo "Create ACR '$ACR_NAME' in region '$LOCATION'."
az acr create --resource-group $RG_NAME --name $ACR_NAME --sku $ACR_SKU --output none

# Push bitnami image to ACR
echo "Pushing image to '$ACR_NAME'."
az acr login --name $ACR_NAME
docker pull bitnami/drupal-nginx:8-debian-10
docker tag bitnami/drupal-nginx:8-debian-10 ${ACR_NAME}.azurecr.io/drupal-nginx:v1
docker push ${ACR_NAME}.azurecr.io/drupal-nginx:v1

# Create storage account and file share
echo "Creating storage account '$STG_ACCT_NAME'."
az storage account create --name $STG_ACCT_NAME \
    --resource-group $RG_NAME --sku PREMIUM_LRS \
    --kind FileStorage --output none

echo "Creating file share '$FILESHARE_NAME'."
az storage share create --name $FILESHARE_NAME \
    --account-name $STG_ACCT_NAME --only-show-errors --output none 

# Create a MariaDB Server
echo "Creating Azure Database for MariaDB server '$DB_SERVER_NAME'."
az mariadb server create --name $DB_SERVER_NAME \
    --location $LOCATION --resource-group $RG_NAME \
    --sku-name $DB_SERVER_SKU --ssl-enforcement Disabled \
    --version 10.3 --admin-user $DB_ADMIN_NAME \
    --admin-password $DB_ADMIN_PASSWORD --output none

# Enable Azure services (ie: Web App) to connect to the server.
echo "Configuring firewall on '$DB_SERVER_NAME' to allow access from Azure Services"
az mariadb server firewall-rule create --name AllowAllWindowsAzureIps \
    --resource-group $RG_NAME --server-name $DB_SERVER_NAME \
    --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0 --output none

# Create a blank DB for Drupal
# Drupal's initialization process expects it to already exist and be empty.
echo "Creating database '$DB_NAME' on server '$DB_SERVER_NAME'."
az mariadb db create --name $DB_NAME --server-name $DB_SERVER_NAME \
    --resource-group $RG_NAME --output none

# Create an App Service Plan
echo "Creating App Service Plan '$ASP_NAME'."
az appservice plan create --name $ASP_NAME --resource-group $RG_NAME \
    --sku $ASP_SKU --is-linux --output none

# Create a Web App for Containers using an existing image.
# You have to do this first because BYOS get's configured "AFTER"
# a web app is created, causing problems when Drupal is trying to initialize.
echo "Creating Web App for Containers '$WEB_APP_NAME'."
az webapp create --name $WEB_APP_NAME --resource-group $RG_NAME --plan $ASP_NAME --deployment-container-image-name nginx --output none

echo "Configure container logging '$WEB_APP_NAME'."
az webapp log config --name $WEB_APP_NAME \
    --resource-group $RG_NAME \
    --docker-container-logging filesystem \
    --output none

# Link the storage account to the web app
echo "Linking file share '$FILESHARE_NAME' to web app '$WEB_APP_NAME'."
ACCESS_KEY=$(az storage account keys list --resource-group $RG_NAME --account-name $STG_ACCT_NAME --query '[0].value' --output tsv)
az webapp config storage-account add --custom-id $FILESHARE_NAME \
    --resource-group $RG_NAME --name $WEB_APP_NAME \
    --account-name $STG_ACCT_NAME --storage-type AzureFiles \
    --share-name $FILESHARE_NAME --mount-path "/bitnami/drupal" \
    --access-key $ACCESS_KEY --output none

# Configure Environment Variable Configs for Bitnami Drupal Container
echo "Creating App Setttings to web app '$WEB_APP_NAME'."
az webapp config appsettings set --resource-group $RG_NAME --name $WEB_APP_NAME \
    --settings DRUPAL_DATABASE_HOST=${DB_SERVER_NAME}.mariadb.database.azure.com DRUPAL_DATABASE_PORT_NUMBER=3306 DRUPAL_DATABASE_USER=$DB_ADMIN_NAME DRUPAL_DATABASE_PASSWORD=$DB_ADMIN_PASSWORD DRUPAL_DATABASE_NAME=$DB_NAME \
    --output none

echo "Creating App Setttings to web app '$WEB_APP_NAME'."
az webapp config appsettings set --resource-group $RG_NAME --name $WEB_APP_NAME \
    --settings WEBSITES_PORT=8080 --output none

# echo "enabling managed identity for web app."
# assign role of ACR Pull to the managed identity
# https://github.com/Azure/app-service-linux-docs/blob/master/HowTo/use_system-assigned_managed_identities.md
echo "Giving App Service permission to pull from ACR."
export PRINCIPAL_ID=$(az webapp identity assign --resource-group $RG_NAME --name $WEB_APP_NAME --query principalId --output tsv)
export WEBAPP_CONFIG=$(az webapp show -g $RG_NAME -n $WEB_APP_NAME --query id --output tsv)"/config/web"
export ACR_ID=$(az acr show -g $RG_NAME -n $ACR_NAME --query id --output tsv)
az resource update --ids $WEBAPP_CONFIG --set properties.acrUseManagedIdentityCreds=True -o none
az role assignment create --assignee $PRINCIPAL_ID --scope $ACR_ID --role "AcrPull" -o none

# Now, update the web app to use the docker-compose file instead.
echo "Udating Web App '$WEB_APP_NAME' to use docker compose config."
az webapp config container set --name $WEB_APP_NAME --resource-group $RG_NAME \
    --docker-custom-image-name ${ACR_NAME}.azurecr.io/drupal-nginx:v1 \
    --docker-registry-server-url https://${ACR_NAME}.azurecr.io \
    --output none

echo "Restarting app to trigger pull."
az webapp restart --name $WEB_APP_NAME --resource-group $RG_NAME