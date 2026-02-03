targetScope = 'resourceGroup'

@description('Location for all resources')
param location string = resourceGroup().location

@description('Short customer code used in resource names (lowercase, no spaces). Example: "kunde1"')
param customerCode string

@description('Azure Function App name')
param functionAppName string

@description('Storage account name (globally unique, lowercase letters+numbers, 3-24 chars)')
param storageAccountName string

@description('Release package URL (SAS URL) for WEBSITE_RUN_FROM_PACKAGE')
param packageUrl string

@description('Tenant ID for customer Entra app registration')
param tenantId string

@description('Client ID for customer Entra app registration')
param clientId string

@description('Client secret for customer Entra app registration')
@secure()
param clientSecret string

@description('EasyAuth secret value (stored in app settings as MICROSOFT_PROVIDER_AUTHENTICATION_SECRET)')
@secure()
param easyAuthSecret string

@description('Mail sender UPN (existing user or service account)')
param mailSenderUpn string

@description('Licensing base URL (Atlytix licensing platform)')
param licensingBaseUrl string

@description('Licensing API key')
@secure()
param licensingApiKey string

@description('OpenAI API key')
@secure()
param openAiApiKey string

@description('OpenAI base URL')
param openAiBaseUrl string = 'https://api.openai.com/v1/chat/completions'

@description('OpenAI model')
param openAiModel string = 'gpt-4o-mini'

@description('OpenAI temperature')
param openAiTemperature string = '0.2'

@description('LLM provider name used by the function (e.g. openai, azureopenai).')
param llmProvider string = 'openai'

@description('Optional: mail logo as data URI (e.g. data:image/png;base64,...)')
param mailLogoDataUri string = ''

@description('Optional: subscription lifecycle notification URL for Graph subscriptions. Leave empty to disable.')
param subscriptionLifecycleNotificationUrl string = ''

@description('ClientState secret for Graph subscriptions (recommended).')
@secure()
param clientStateSecret string

@description('Draft table name')
param draftTableName string = 'drafts'

@description('Dedup table name')
param dedupTableName string = 'dedupe'

@description('Draft TTL hours')
param draftTtlHours string = '72'

@description('Dedup TIL minutes')
param dedupTilMinutes string = '4320'

@description('Notify mode')
param draftNotifyMode string = 'email'

// ---------------- Storage ----------------
resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    minimumTlsVersion: 'TLS1_2'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
    publicNetworkAccess: 'Enabled'
  }
}

var storageKey = listKeys(sa.id, sa.apiVersion).keys[0].value
var storageConn = 'DefaultEndpointsProtocol=https;AccountName=${sa.name};AccountKey=${storageKey};EndpointSuffix=core.windows.net'
var contentShare = toLower(replace(functionAppName, '-', ''))

// Public base URL for the function (used for webhook URLs)
var publicBaseUrl = 'https://${functionAppName}.azurewebsites.net'
var subscriptionNotificationUrl = '${publicBaseUrl}/api/GraphTranscriptWebhook'

var subscriptionLifecycleUrl = empty(subscriptionLifecycleNotificationUrl)
  ? subscriptionNotificationUrl
  : subscriptionLifecycleNotificationUrl

// ---------------- App Insights + Log Analytics ----------------
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${functionAppName}-log'
  location: location
  properties: any({
    retentionInDays: 30
    sku: { name: 'PerGB2018' }
  })
}

resource ai 'Microsoft.Insights/components@2020-02-02' = {
  name: '${functionAppName}-ai'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    DisableLocalAuth: false
  }
}

// ---------------- Classic Consumption plan (Y1) ----------------
resource plan 'Microsoft.Web/serverfarms@2022-03-01' = {
  name: '${functionAppName}-plan'
  location: location
  sku: {
    tier: 'Dynamic'
    name: 'Y1'
  }
  properties: {}
}

// ---------------- Function App (Windows, Classic) ----------------
resource func 'Microsoft.Web/sites@2022-03-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,windows'
  properties: {
    serverFarmId: plan.id
    httpsOnly: true

    siteConfig: {
      minTlsVersion: '1.2'
      alwaysOn: false // consumption
      ftpsState: 'Disabled'
    }
  }
}

// ---------------- App Settings ----------------
resource appsettings 'Microsoft.Web/sites/config@2022-03-01' = {
  parent: func
  name: 'appsettings'
  properties: {
    FUNCTIONS_WORKER_RUNTIME: 'dotnet-isolated'
    FUNCTIONS_EXTENSION_VERSION: '~4'
    AzureWebJobsFeatureFlags: 'EnableWorkerIndexing'

    // Storage
    AzureWebJobsStorage: storageConn

    // Required on Windows consumption (stabilitet)
    WEBSITE_CONTENTAZUREFILECONNECTIONSTRING: storageConn
    WEBSITE_CONTENTSHARE: contentShare

    // Run from package
    WEBSITE_RUN_FROM_PACKAGE: packageUrl

    // App Insights
    APPLICATIONINSIGHTS_CONNECTION_STRING: ai.properties.ConnectionString

    // Your app config
    TENANT_ID: tenantId
    CLIENT_ID: clientId
    CLIENT_SECRET: clientSecret

    // EasyAuth AAD provider secret
    AAD_CLIENT_SECRET: clientSecret

    // EasyAuth internal auth secret
    MICROSOFT_PROVIDER_AUTHENTICATION_SECRET: easyAuthSecret

    MAIL_SENDER_UPN: mailSenderUpn

    LICENSING_BASE_URL: licensingBaseUrl
    LICENSING_API_KEY: licensingApiKey

    OPENAI_API_KEY: openAiApiKey
    OPENAI_BASE_URL: openAiBaseUrl
    OPENAI_MODEL: openAiModel
    OPENAI_TEMPERATURE: openAiTemperature

    // LLM selection + mail branding
    LLM_PROVIDER: llmProvider
    MAIL_LOGO_DATA_URI: mailLogoDataUri

    // Public URL (used by functions and external links)
    PUBLIC_BASE_URL: publicBaseUrl

    // Graph subscription config (for SubscriptionsRenewTimer)
    SUBSCRIPTION_NOTIFICATION_URL: subscriptionNotificationUrl
    SUBSCRIPTION_LIFECYCLE_NOTIFICATION_URL: subscriptionLifecycleUrl
    CLIENT_STATE_SECRET: clientStateSecret

    // Production-safe subscription repair behaviour
    AUTO_RECREATE_ON_NOTIFICATIONURL_MISMATCH: 'true'
    AUTO_RECREATE_WHEN_CLIENTSTATE_EMPTY: 'true'
    FORCE_RECREATE_ON_CLIENTSTATE_MISMATCH: 'false'
    SUBSCRIPTION_LOG_MISMATCH_AS_WARNING: 'true'

    // EasyAuth allowlist (matches internal version)
    WEBSITE_AUTH_AAD_ALLOWED_TENANTS: tenantId

    // Tables
    DEPLOYMENT_STORAGE_CONNECTION_STRING: storageConn
    DRAFT_TABLE_NAME: draftTableName
    DEDUP_TABLE_NAME: dedupTableName
    DRAFT_TTL_HOURS: draftTtlHours
    DEDUP_TIL_MINUTES: dedupTilMinutes
    DRAFT_NOTIFY_MODE: draftNotifyMode
  }
}

// ---------------- EasyAuth (authsettingsV2) ----------------
resource auth 'Microsoft.Web/sites/config@2022-03-01' = {
  parent: func
  name: 'authsettingsV2'
  properties: {
    platform: {
      enabled: true
      runtimeVersion: '~1'
    }
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'RedirectToLoginPage'
      redirectToProvider: 'azureactivedirectory'
      excludedPaths: [
        '/api/health'
        '/api/GraphTranscriptWebhook'
      ]
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          openIdIssuer: 'https://login.microsoftonline.com/${tenantId}/v2.0'
          clientId: clientId
          clientSecretSettingName: 'AAD_CLIENT_SECRET'
        }
      }
    }
  }
}

output functionAppHostName string = func.properties.defaultHostName
output storageAccountId string = sa.id
output appInsightsName string = ai.name
