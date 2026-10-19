<#
.SYNOPSIS
Starts or stops and deallocates Azure VMs with a matching tag.

.DESCRIPTION
Azure Automation PowerShell runbook using the Automation account's system-assigned
managed identity. Only VMs in the specified subscription (and optional resource
group) are considered. Tag names are case-insensitive; values are case-sensitive,
literal matches. Tags must be on the VM itself, not just its resource group.

Action defaults to Stop for compatibility. Use Action = Start to start VMs.
DryRun defaults to true. Set it to false to change matching VMs.
Deallocation releases compute capacity; disks and other resources can still incur
charges. The runbook processes all matches and fails the job if any operation fails.

SETUP
1. Enable the Automation account's system-assigned managed identity.
2. Grant that identity Virtual Machine Contributor on the target resource group
   or subscription. The identity needs read access across the selected scope.
3. Add Az.Accounts and Az.Compute to the Automation runtime environment.
4. Import this script as a PowerShell runbook, test it with DryRun = true, publish
   it, then call it with SubscriptionId, TagName, TagValue, Action and DryRun = false.
   Use a PowerShell 7.4 runtime with compatible Az module versions.
   See LogicApp-Setup.txt for the weekday Logic Apps scheduler.

.PARAMETER SubscriptionId
Explicit subscription to search; the runbook never searches other subscriptions.

.PARAMETER TagName
Name of the VM tag, for example AutoShutdown.

.PARAMETER TagValue
Exact, case-sensitive value of the VM tag, for example Enabled.

.PARAMETER ResourceGroupName
Optional resource group restriction. If omitted, searches the whole subscription.

.PARAMETER DryRun
When true (the default), reports matches without changing VMs.

.PARAMETER Action
Stop (the default) stops and deallocates VMs. Start powers on matching VMs.

.EXAMPLE
.\ShutdownVMTag.ps1 -SubscriptionId '00000000-0000-0000-0000-000000000000' -TagName 'AutoShutdown' -TagValue 'Enabled'

Previews matching VMs without changing their state.

.EXAMPLE
.\ShutdownVMTag.ps1 -SubscriptionId '00000000-0000-0000-0000-000000000000' -TagName 'AutoShutdown' -TagValue 'Enabled' -ResourceGroupName 'rg-dev' -DryRun $false

Stops and deallocates matching VMs in rg-dev using managed identity.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [guid] $SubscriptionId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $TagName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $TagValue,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $ResourceGroupName,

    [Parameter()]
    [bool] $DryRun = $true,

    [Parameter()]
    [ValidateSet('Start', 'Stop')]
    [string] $Action = 'Stop'
)

$ErrorActionPreference = 'Stop'

# Automation sandboxes can reuse contexts from other jobs.
Disable-AzContextAutosave -Scope Process -ErrorAction Stop | Out-Null
$login = Connect-AzAccount -Identity -Subscription $SubscriptionId.ToString() -ErrorAction Stop
$context = Set-AzContext -SubscriptionId $SubscriptionId.ToString() -DefaultProfile $login.Context -ErrorAction Stop

$getVmParameters = @{
    DefaultProfile = $context
    ErrorAction    = 'Stop'
}
if ($PSBoundParameters.ContainsKey('ResourceGroupName')) {
    $getVmParameters.ResourceGroupName = $ResourceGroupName
}

$matchingVms = @(Get-AzVM @getVmParameters | Where-Object {
    $vm = $_
    $matchingTags = @(
        if ($null -ne $vm.Tags) {
            $vm.Tags.GetEnumerator() | Where-Object {
                [string]::Equals($_.Key, $TagName, [System.StringComparison]::OrdinalIgnoreCase) -and
                [string]::Equals($_.Value, $TagValue, [System.StringComparison]::Ordinal)
            }
        }
    )
    $matchingTags.Count -gt 0
})

Write-Output "Found $($matchingVms.Count) VM(s) matching tag '$TagName' = '$TagValue'. Action = $Action. DryRun = $DryRun."

$operation = if ($Action -eq 'Start') { 'start' } else { 'stop and deallocate' }

$failedVmIds = @()
foreach ($vm in $matchingVms) {
    if ($DryRun) {
        Write-Output "[Preview] Would $operation VM '$($vm.Name)' in resource group '$($vm.ResourceGroupName)' ($($vm.Id))."
        continue
    }

    try {
        Write-Output "Performing '$operation' on VM '$($vm.Name)' in resource group '$($vm.ResourceGroupName)'."
        if ($Action -eq 'Start') {
            Start-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -DefaultProfile $context -ErrorAction Stop | Out-Null
        }
        else {
            Stop-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Force -DefaultProfile $context -ErrorAction Stop | Out-Null
        }
        Write-Output "Successfully completed '$operation' for VM '$($vm.Name)'."
    }
    catch {
        $failedVmIds += $vm.Id
        Write-Warning "Failed to $operation VM '$($vm.Name)' ($($vm.Id)): $($_.Exception.Message)"
    }
}

if ($failedVmIds.Count -gt 0) {
    throw "Failed to $operation $($failedVmIds.Count) VM(s): $($failedVmIds -join ', '). See preceding warnings."
}