
az login
az group create --name "Student01-Rg" --location "eastus2"
az deployment group create -g "Student01-Rg" -f "./bicep/main.bicep" -p "./bicep/main.bicepparam"
