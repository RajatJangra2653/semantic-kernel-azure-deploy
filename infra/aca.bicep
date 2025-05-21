param uniqueId string
param prefix string
param userAssignedIdentityResourceId string
param userAssignedIdentityClientId string
param openAiEndpoint string
param openAiApiKey string
param applicationInsightsConnectionString string
param containerRegistry string = '${prefix}acr${uniqueId}'
param location string = resourceGroup().location
param logAnalyticsWorkspaceName string
param serviceBusNamespaceFqdn string
param cosmosDbEndpoint string
param cosmosDbDatabaseName string
param cosmosDbContainerName string
param uiAppExists bool
param emptyContainerImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsWorkspaceName
}

// see https://azureossd.github.io/2023/01/03/Using-Managed-Identity-and-Bicep-to-pull-images-with-Azure-Container-Apps/
resource containerAppEnv 'Microsoft.App/managedEnvironments@2023-11-02-preview' = {
  name: '${prefix}-containerAppEnv-${uniqueId}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityResourceId}': {}
    }
  }
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsWorkspace.properties.customerId
        sharedKey: logAnalyticsWorkspace.listKeys().primarySharedKey
      }
    }
  }
}

resource daprPubSubUI 'Microsoft.App/managedEnvironments/daprComponents@2024-10-02-preview' = {
  name: 'ui'
  parent: containerAppEnv
  properties: {
    componentType: 'pubsub.azure.servicebus.topics'
    version: 'v1'
    scopes: [
      'ui'
    ]
    metadata: [
      {
        // NOTE we don't wnat Dapr to manage the subscriptions
        name: 'disableEntityManagement '
        value: 'true'
      }
      {
        name: 'consumerID'
        value: 'ui-updates'
      }
      {
        name: 'namespaceName'
        value: serviceBusNamespaceFqdn
      }
      {
        name: 'azureTenantId'
        value: tenant().tenantId
      }
      {
        name: 'azureClientId'
        value: userAssignedIdentityClientId
      }
    ]
  }
}

resource cosmosDaprComponent 'Microsoft.App/managedEnvironments/daprComponents@2024-10-02-preview' = {
  name: 'state'
  parent: containerAppEnv
  properties: {
    componentType: 'state.azure.cosmosdb'
    version: 'v1'
    scopes: [
      'agents'
    ]
    metadata: [
      {
        name: 'url'
        value: cosmosDbEndpoint
      }
      {
        name: 'database'
        value: cosmosDbDatabaseName
      }
      {
        name: 'collection'
        value: cosmosDbContainerName
      }
      {
        name: 'actorStateStore'
        value: 'true'
      }
      {
        name: 'azureTenantId'
        value: tenant().tenantId
      }
      {
        name: 'azureClientId'
        value: userAssignedIdentityClientId
      }
    ]
  }
}

// When azd passes parameters, it will tell if apps were already created
// In this case, we don't overwrite the existing image
// See https://johnnyreilly.com/using-azd-for-faster-incremental-azure-container-app-deployments-in-azure-devops#the-does-your-service-exist-parameter
module fetchLatestImageUI './fetch-container-image.bicep' = {
  name: 'ui-app-image'
  params: {
    exists: uiAppExists
    name: '${prefix}-ui-${uniqueId}'
  }
}

resource uiContainerApp 'Microsoft.App/containerApps@2023-11-02-preview' = {
  name: '${prefix}-ui-${uniqueId}'
  location: location
  tags: {'azd-service-name': 'ui' }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityResourceId}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerAppEnv.id
    configuration: {
      dapr: {
        enabled: true
        appId: 'ui'
        appPort: 80
      }
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 80
        transport: 'auto'
      }
      registries: [
        {
          server: '${containerRegistry}.azurecr.io'
          identity: userAssignedIdentityResourceId
        }
      ]
    }
    template: {
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
      containers: [
        {
          name: 'ui'
          image: uiAppExists ? fetchLatestImageUI.outputs.containers[0].image : emptyContainerImage
          resources: {
            cpu: 1
            memory: '2Gi'
          }
          env: [
            { name: 'AZURE_CLIENT_ID', value: userAssignedIdentityClientId }
            { name: 'APPLICATIONINSIGHTS_CONNECTIONSTRING', value: applicationInsightsConnectionString }
            { name: 'AZURE_OPENAI_WHISPER_ENDPOINT', value: openAiEndpoint }
            { name: 'AZURE_OPENAI_WHISPER_VERSION', value: '2024-02-01' }
            { name: 'AZURE_OPENAI_WHISPER_DEPLOYMENT', value: 'whisper' }
            { name: 'AZURE_OPENAI_WHISPER_KEY', value: '' }
          ]
        }
      ]
    }
  }
}
