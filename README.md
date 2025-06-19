## Azure Local Operator Training Lab VM Deployment

### Prerequisites

*** Software ***

- PowerShell 7: https://aka.ms/powershell-release?tag=stable
- Azure PowerShell Modules: https://learn.microsoft.com/en-us/powershell/azure/install-azure-powershell?view=azps-14.1.0
- Git: https://git-scm.com/downloads
- Azure CLI: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli?view=azure-cli-latest
- Bicep: https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/install

*** Azure ***

- Sufficient compute capacity (vCPU quotas) for the chosen VM SKU (Standard E32s v5 or v6)
- Owner permissions on your Subscription

*** Deployment ***

1. Create a Service Principal with a Client Secret.
2. Make note of the Service Principal Client ID and Secret.
3. Grant the Service Principal Owner permissions to your subscription.
4. Get the object ID for Azure Local Resource Provider. This object ID for the Azure Local Resource Provide (RP) is unique per Azure tenant.
    - In the Azure portal, search for and go to Microsoft Entra ID.
    - Go to the Overview tab and search for Microsoft.AzureStackHCI Resource Provider.
    - Copy the Object ID and save it for use later on in this lab.
    
    Alternatively, you can use PowerShell to get the object ID of the Azure Local RP service principal. Run the following command in PowerShell:

    ```powershell
    Get-AzADServicePrincipal -DisplayName "Microsoft.AzureStackHCI Resource Provider"
    ```

5. Change Directories to the bicep folder that corisponds to your Azure Environment. 
   Example: 
   - C:\Git\azure-local-operator-training\AzureCommercial\bicep
   - C:\Git\azure-local-operator-training\AzureUSGov\bicep

6. Edit the file main.bicepparam making sure to fill out all the fields.

```powershell
using './main.bicep'

param spnClientId = 'Service Principal Client ID'
param spnClientSecret = 'Service Principal Client Secret'
param spnTenantId = 'Your Azure Tenant ID'
param spnProviderId = 'Your Microsoft.AzureStackHCI Resource Provider ID'
param windowsAdminUsername = 'VM Username'
param windowsAdminPassword = 'VM Password'
```

7. Save the main.bicepparam file.

8. Login to Azure with Azure CLI

    - Azure Commercial

    ```azurecli
    az cloud set --name AzureCloud
    
    az login
    ```
    - Azure US Gov
    
    ```azurecli
    az cloud set --name AzureUSGovernment
    
    az login
    ```
9. Create a Resource Group

```azurecli
az group create --name "Your-Rg" --location "Your Location"
```

10. Start the deployment.

```azurecli
az deployment group create -g "Your-Rg" -f "./main.bicep" -p "./main.bicepparam"
```

11. Wait for the deployment to complete.

12. When the deployment is complete, connect to the LocalBox-Client VM. Wait for the setup scripts to complete.










