
az cloud set --name AzureCommercial

az login

az group create --name "Student01-Rg" --location "USGovVirginia"
az deployment group create -g "Student01-Rg" -f "./bicep/main.bicep" -p "./bicep/main.bicepparam"

az group create --name "AzLD-Rg" --location "southcentralus"
az deployment group create -g "AzLD-Rg" -f "./bicep/main.bicep" -p "./bicep/main.bicepparam"

az group create --name "Student02-Rg" --location "eastus2"
az deployment group create -g "Student02-Rg" -f "./bicep/main.bicep" -p "./bicep/main.bicepparam"

$SP = Get-AzADServicePrincipal -DisplayName LocalBoxSPN | Select-Object -Property *

$SP.additionalProperties

New-AzADSpCredential -ObjectId 20851970-8db1-4af8-a049-745165b0a8b6
Connect-AzAccount

az ad sp list --display-name "Microsoft.AzureStackHCI Resource Provider"
