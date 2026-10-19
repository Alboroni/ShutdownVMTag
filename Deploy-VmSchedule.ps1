#Requires -Modules Az.Accounts, Az.Resources, Az.Automation
<#
.SYNOPSIS
Creates a resource group, Automation account, runbook and weekday VM schedulers.
.DESCRIPTION
Run from your workstation or Cloud Shell after Connect-AzAccount.
Creates Azure resources and RBAC assignments only when you execute this script.
Requires resource deployment and role-assignment rights on the deployment
subscription and target VM resource group. Targets existing VMs, not new VMs.
VmSubscriptionId can select a different VM subscription in the same Entra tenant.
Defaults to disabled Logic Apps and preview-only VM operations.
.EXAMPLE
.\Deploy-VmSchedule.ps1 -SubscriptionId '00000000-0000-0000-0000-000000000001' -ResourceGroupName 'rg-vm-schedule' -Location 'uksouth' -AutomationAccountName 'aa-vm-schedule' -VmResourceGroupName 'rg-dev-vms' -ScheduleStartTime '2026-11-02T00:00:00'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [guid] $SubscriptionId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-zA-Z0-9_.()-]+$')]
    [string] $ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $Location,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9-]{4,48}[a-zA-Z0-9]$')]
    [string] $AutomationAccountName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $VmResourceGroupName,

    [guid] $VmSubscriptionId = $SubscriptionId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$')]
    [string] $ScheduleStartTime,

    [ValidateLength(1, 60)]
    [ValidatePattern('^[a-zA-Z0-9-]+$')]
    [string] $NamePrefix = 'tagged-vms',

    [ValidateNotNullOrEmpty()]
    [string] $TagName = 'AutoShutdown',

    [ValidateNotNullOrEmpty()]
    [string] $TagValue = 'Enabled',

    [bool] $DryRun = $true,

    [ValidateSet('Disabled', 'Enabled')]
    [string] $WorkflowState = 'Disabled'
)

$ErrorActionPreference = 'Stop'
$ukTimeZone = [System.TimeZoneInfo]::FindSystemTimeZoneById('GMT Standard Time')
$localStart = [datetime]::ParseExact($ScheduleStartTime, 'yyyy-MM-ddTHH:mm:ss', [cultureinfo]::InvariantCulture)
if ($ukTimeZone.IsInvalidTime($localStart) -or $ukTimeZone.IsAmbiguousTime($localStart)) {
    throw 'ScheduleStartTime must not fall in a missing or repeated UK daylight-saving hour.'
}
if ([System.TimeZoneInfo]::ConvertTimeToUtc($localStart, $ukTimeZone) -le [datetime]::UtcNow.AddMinutes(5)) {
    throw 'ScheduleStartTime must be more than five minutes in the future, in UK local time.'
}

$currentContext = Get-AzContext -ErrorAction Stop
if ($null -eq $currentContext) {
    throw 'Sign in with Connect-AzAccount before running the deployment.'
}
$context = Set-AzContext -SubscriptionId $SubscriptionId.ToString() -TenantId $currentContext.Tenant.Id -Scope Process -ErrorAction Stop
$vmContext = Set-AzContext -SubscriptionId $VmSubscriptionId.ToString() -TenantId $context.Tenant.Id -Scope Process -ErrorAction Stop
$subscriptionScope = "/subscriptions/$SubscriptionId"
$vmScope = "/subscriptions/$VmSubscriptionId/resourceGroups/$VmResourceGroupName"
$vmGroup = Get-AzResourceGroup -Name $VmResourceGroupName -DefaultProfile $vmContext -ErrorAction Stop
if ($null -eq $vmGroup) {
    throw "Target VM resource group '$VmResourceGroupName' was not found."
}

$templatePath = Join-Path $PSScriptRoot 'infra\vm-schedule.json'
$runbookPath = Join-Path $PSScriptRoot 'ShutdownVMTag.ps1'
if (-not (Test-Path -LiteralPath $templatePath) -or -not (Test-Path -LiteralPath $runbookPath)) {
    throw 'Keep this deployment script alongside ShutdownVMTag.ps1 and infra\vm-schedule.json.'
}

function Invoke-AutomationRequest {
    param(
        [string] $Path,
        [string] $Method,
        [hashtable] $Body
    )

    $arguments = @{
        Path           = "${Path}?api-version=2024-10-23"
        Method         = $Method
        DefaultProfile = $context
        ErrorAction    = 'Stop'
    }
    if ($null -ne $Body) {
        $arguments.Payload = ConvertTo-Json -InputObject $Body -Depth 20
    }
    $response = Invoke-AzRestMethod @arguments
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        throw "Automation request failed ($($response.StatusCode)): $($response.Content)"
    }
    return $response
}

function Grant-ManagedIdentityRole {
    param(
        [string] $PrincipalId,
        [string] $RoleName,
        [string] $Scope,
        [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer] $Profile = $context
    )

    $existing = @(Get-AzRoleAssignment -ObjectId $PrincipalId -RoleDefinitionName $RoleName -Scope $Scope -DefaultProfile $Profile -ErrorAction Stop |
        Where-Object { $_.Scope -eq $Scope })
    if ($existing.Count -eq 0) {
        New-AzRoleAssignment -ObjectId $PrincipalId -ObjectType ServicePrincipal -RoleDefinitionName $RoleName -Scope $Scope -DefaultProfile $Profile -ErrorAction Stop | Out-Null
    }
}

Write-Output "Creating/updating resource group '$ResourceGroupName'."
New-AzResourceGroup -Name $ResourceGroupName -Location $Location -DefaultProfile $context -Force -ErrorAction Stop | Out-Null
$accountPath = "$subscriptionScope/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName"
$runbookName = 'ShutdownVMTag'
$runtimeName = 'PowerShell-74'
$runbookId = "$accountPath/runbooks/$runbookName"

Write-Output "Creating/updating Automation account '$AutomationAccountName' and PowerShell 7.4 runtime."
$accountResponse = Invoke-AutomationRequest -Path $accountPath -Method PUT -Body @{
    location = $Location
    identity = @{ type = 'SystemAssigned' }
    properties = @{ sku = @{ name = 'Basic' } }
}
$account = $accountResponse.Content | ConvertFrom-Json
if (-not $account.identity.principalId) {
    throw 'Automation account creation did not return a managed identity principal ID.'
}
Invoke-AutomationRequest -Path "$accountPath/runtimeEnvironments/$runtimeName" -Method PUT -Body @{
    name = $runtimeName
    properties = @{
        runtime = @{ language = 'PowerShell'; version = '7.4' }
        defaultPackages = @{ Az = '12.3.0' }
    }
} | Out-Null

Write-Output 'Importing the shared start/stop runbook.'
Import-AzAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $runbookName -Path $runbookPath -Type PowerShell -Force -DefaultProfile $context -ErrorAction Stop | Out-Null
Invoke-AutomationRequest -Path $runbookId -Method PUT -Body @{
    location = $Location
    properties = @{
        runbookType = 'PowerShell'
        runtimeEnvironment = $runtimeName
        logProgress = $false
        logVerbose = $false
        description = 'Start or stop tagged VMs using managed identity.'
    }
} | Out-Null
Publish-AzAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $runbookName -DefaultProfile $context -ErrorAction Stop | Out-Null
$published = (Invoke-AutomationRequest -Path $runbookId -Method GET).Content | ConvertFrom-Json
if ($published.properties.state -ne 'Published' -or $published.properties.runtimeEnvironment -ne $runtimeName) {
    throw 'Runbook publication/runtime verification failed. Schedulers have not been enabled.'
}

Grant-ManagedIdentityRole -PrincipalId $account.identity.principalId -RoleName 'Virtual Machine Contributor' -Scope $vmScope -Profile $vmContext

$deploymentParameters = @{
    namePrefix = $NamePrefix
    location = $Location
    automationAccountName = $AutomationAccountName
    runbookName = $runbookName
    vmSubscriptionId = $VmSubscriptionId.ToString()
    vmResourceGroupName = $VmResourceGroupName
    tagName = $TagName
    tagValue = $TagValue
    scheduleStartTime = $ScheduleStartTime
    dryRun = $DryRun.ToString().ToLowerInvariant()
    workflowState = 'Disabled'
}
Write-Output 'Validating and deploying disabled Logic Apps before assigning permissions.'
$validation = @(Test-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -TemplateFile $templatePath -TemplateParameterObject $deploymentParameters -DefaultProfile $context -ErrorAction Stop)
if ($validation.Count -gt 0) {
    throw "Logic App template validation failed: $($validation | Out-String)"
}
New-AzResourceGroupDeployment -Name "$NamePrefix-schedule" -ResourceGroupName $ResourceGroupName -TemplateFile $templatePath -TemplateParameterObject $deploymentParameters -DefaultProfile $context -ErrorAction Stop | Out-Null

foreach ($suffix in @('start', 'stop')) {
    $workflowId = "$subscriptionScope/resourceGroups/$ResourceGroupName/providers/Microsoft.Logic/workflows/$NamePrefix-$suffix"
    $workflow = Get-AzResource -ResourceId $workflowId -ExpandProperties -DefaultProfile $context -ErrorAction Stop
    if (-not $workflow.Identity.PrincipalId) {
        throw "Logic App '$NamePrefix-$suffix' has no managed identity."
    }
    Grant-ManagedIdentityRole -PrincipalId $workflow.Identity.PrincipalId -RoleName 'Automation Job Operator' -Scope $accountPath
    Grant-ManagedIdentityRole -PrincipalId $workflow.Identity.PrincipalId -RoleName 'Automation Runbook Operator' -Scope $runbookId
}

if ($WorkflowState -eq 'Enabled') {
    if ([System.TimeZoneInfo]::ConvertTimeToUtc($localStart, $ukTimeZone) -le [datetime]::UtcNow) {
        throw 'ScheduleStartTime elapsed during deployment. Workflows remain disabled; rerun with a future start time.'
    }
    Write-Warning 'Enabling schedules. RBAC propagation can take several minutes; monitor initial Automation jobs.'
    $deploymentParameters.workflowState = 'Enabled'
    New-AzResourceGroupDeployment -Name "$NamePrefix-schedule" -ResourceGroupName $ResourceGroupName -TemplateFile $templatePath -TemplateParameterObject $deploymentParameters -DefaultProfile $context -ErrorAction Stop | Out-Null
}

Write-Output "Deployment complete. WorkflowState = $WorkflowState; DryRun = $DryRun."
Write-Output "UK weekdays: start 08:00, stop/deallocate 19:00. Target: '$VmResourceGroupName', tag '$TagName' = '$TagValue'."
Write-Output 'Test both workflows with DryRun=true and check Automation job output before enabling live operations.'
