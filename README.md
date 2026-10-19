# Tagged VM weekday start/stop scheduler

Deploy Azure Automation and two Consumption Logic Apps to start and stop existing
Azure VMs selected by a tag.

**Single-subscription deployment is the default.** Keep the Automation account,
Logic Apps and VMs in one subscription by omitting `-VmSubscriptionId`. Different
**All resource groups in the VM subscription are searched by default**; only VMs
with the configured tag name and value are selected. Omit `-VmResourceGroupName`
for this subscription-wide behavior. Cross-subscription
deployment is optional and requires both subscriptions to be in the same Entra tenant.

> These instructions do not move or modify an existing deployment just by being
> saved. Running the deployment commands creates or updates Azure resources.
> `DryRun` controls VM power operations, not infrastructure provisioning.

## Contents

- [What is deployed](#what-is-deployed)
- [Prerequisites and permissions](#prerequisites-and-permissions)
- [Single-subscription setup](#single-subscription-setup)
- [Test without changing VM power state](#test-without-changing-vm-power-state)
- [Enable the live schedule](#enable-the-live-schedule)
- [Pause the schedule](#pause-the-schedule)
- [Optional cross-subscription setup](#optional-cross-subscription-setup)
- [Optional resource-group filter](#optional-resource-group-filter)
- [Deployment parameters](#deployment-parameters)
- [Use an existing Automation account](#use-an-existing-automation-account)
- [Monitoring and troubleshooting](#monitoring-and-troubleshooting)
- [Local tests](#local-tests)

## What is deployed

| Component | Purpose |
|---|---|
| Resource group | Hosts the scheduling resources. |
| Automation account | Runs PowerShell using its system-assigned managed identity. |
| `PowerShell-74` runtime | PowerShell 7.4 with the documented Az 12.3.0 package bundle. |
| `ShutdownVMTag` runbook | Uses `Action=Start` or `Action=Stop` against tagged VMs. |
| `tagged-vms-start` Logic App | Submits a Start runbook job. |
| `tagged-vms-stop` Logic App | Submits a Stop runbook job. |
| Role assignments | Allow the Logic Apps to submit jobs and the account to manage VMs. |

The names of the resource group and account are parameters. Change `NamePrefix`
to change the Logic App names.

The default schedule is:

| Days | UK local time | Operation |
|---|---|---|
| Monday-Friday | 08:00 | Start matching VMs. |
| Monday-Friday | 19:00 | Stop and deallocate matching VMs. |
| Saturday-Sunday | No runs | Leave VMs off after Friday's shutdown. |

`GMT Standard Time` automatically adjusts between GMT and BST. The Azure region
does not change this time zone. Times are defined in
[`infra\vm-schedule.json`](infra/vm-schedule.json), not deployment parameters.

This is **scheduled operation, not continuous enforcement**. A VM manually started
over the weekend will not be stopped again until the next scheduled shutdown.
Friday's shutdown must succeed. There is no public-holiday calendar. Startup begins
at 08:00; the guest OS and applications may become ready later. Trigger execution
can also be slightly late.

No VMs, VM resource groups, webhook secrets or stored passwords are created.
VMs must exist already. The deployment script does not add VM tags automatically.
Deallocation stops VM compute charges, but disks and other resources may still
incur charges. Logic Apps and Automation also have their own usage charges.

### Repository files

- [`Deploy-VmSchedule.ps1`](Deploy-VmSchedule.ps1): complete infrastructure deployment.
- [`ShutdownVMTag.ps1`](ShutdownVMTag.ps1): shared morning-start/evening-stop runbook.
- [`infra\vm-schedule.json`](infra/vm-schedule.json): Logic Apps-only ARM template.
- [`Tests`](Tests): mocked deployment, runbook and schedule tests.
- [`LogicApp-Setup.txt`](LogicApp-Setup.txt): short entry point to this guide.

## Prerequisites and permissions

Use Windows PowerShell 5.1 or PowerShell 7.4 on Windows for the deployment commands.
The Automation runbook itself uses a PowerShell 7.4 runtime in Azure.

You need:

1. An Azure subscription containing the existing VMs to schedule.
2. A region supporting Azure Automation PowerShell 7.4 and Consumption Logic Apps.
3. An identity allowed to create resource groups and the scheduling resources.
4. Permission to create role assignments at the hosting account/runbook and target
   VM subscription scope (or VM group when explicitly restricted). Contributor alone is **not** sufficient. Owner, or
   equivalent deployment permissions plus appropriately scoped RBAC administration
   permissions, is required. Role-assignment conditions can restrict these grants.
5. Permission to register resource providers in the hosting subscription.
6. Permission to update VM tags if you are adding the selection tag.

The deployment creates these runtime permissions:

| Identity | Role | Scope |
|---|---|---|
| Automation account | Virtual Machine Contributor | Target VM subscription by default; VM group if explicitly restricted |
| Start Logic App | Automation Job Operator | Automation account |
| Stop Logic App | Automation Job Operator | Automation account |
| Start Logic App | Automation Runbook Operator | `ShutdownVMTag` runbook |
| Stop Logic App | Automation Runbook Operator | `ShutdownVMTag` runbook |

The Logic Apps call the Azure Resource Manager Automation jobs API using their
own identities. The runbook uses the Automation account identity to manage VMs.
These are separate identities. Allow several minutes for new role assignments
to propagate before testing.

Subscription-wide deployment grants the account identity VM-management permissions
across that subscription. RBAC is not limited by the selection tag: the runbook
applies that filter. Review all matches before enabling live operations.

## Single-subscription setup

### 1. Open the solution and install modules

Keep the deployment script, runbook and `infra` directory together. Open PowerShell
in the directory containing them:

```powershell
Set-Location 'C:\path\to\ShutdownVMTag'

Install-Module Az.Accounts, Az.Resources, Az.Automation, Az.Compute `
    -Repository PSGallery -Scope CurrentUser
```

Review any installation prompts. Az.Compute is used by the inspection commands
and local runbook tests; the deployment script requires the other three modules.
You do not need to install Pester merely to deploy.

### 2. Set your values and sign in

Replace the placeholders and names. Use dedicated scheduling resource names rather
than an unrelated account. VMs can be spread across any groups in the subscription.

```powershell
$ErrorActionPreference = 'Stop'

$tenantId = '<your-Entra-tenant-ID>'
$subscriptionId = '<your-subscription-ID>'
$location = 'swedencentral'
$resourceGroupName = 'rg-vm-schedule'
$automationAccountName = 'aa-vm-schedule'
$tagName = 'AutoShutdown'
$tagValue = 'Enabled'
$namePrefix = 'tagged-vms'

Connect-AzAccount -Tenant $tenantId -Subscription $subscriptionId
$context = Set-AzContext -TenantId $tenantId `
    -SubscriptionId $subscriptionId -Scope Process
$vmContext = $context

Get-AzSubscription -TenantId $tenantId |
    Select-Object Name, Id, State
Get-AzResourceGroup -DefaultProfile $vmContext |
    Select-Object ResourceGroupName, Location
```

`$resourceGroupName` identifies only where the scheduler is hosted, not which VM
groups are searched. Use an existing hosting group's current location if you reuse it.

### 3. Register the hosting resource providers

```powershell
foreach ($provider in @('Microsoft.Automation', 'Microsoft.Logic')) {
    Register-AzResourceProvider -ProviderNamespace $provider `
        -DefaultProfile $context |
        Select-Object ProviderNamespace, RegistrationState
}
```

Registration can take several minutes. Check again until both show `Registered`:

```powershell
foreach ($provider in @('Microsoft.Automation', 'Microsoft.Logic')) {
    Get-AzResourceProvider -ProviderNamespace $provider -DefaultProfile $context |
        Select-Object -First 1 ProviderNamespace, RegistrationState
}
```

The deployment script does not register these providers automatically. Check
organizational policies before deployment; required tags, allowed locations or
resource restrictions may need administrator input. Do not bypass those policies.

### 4. Inspect and tag the intended VMs

List VMs across all groups in the target subscription:

```powershell
Get-AzVM -DefaultProfile $vmContext |
    Select-Object Name, ResourceGroupName, Tags
```

Add the tag only to VMs that should follow the schedule. This example changes one
VM's metadata and preserves its other tags:

```powershell
$vmName = '<VM-to-include>'
$vmGroupToTag = '<that-VMs-resource-group>'
$vm = Get-AzVM -ResourceGroupName $vmGroupToTag `
    -Name $vmName -DefaultProfile $vmContext

Update-AzTag -ResourceId $vm.Id -Tag @{ $tagName = $tagValue } `
    -Operation Merge -DefaultProfile $vmContext
```

Repeat for each intended VM. Tags must be on the **VM itself**, not just its
resource group. Tag names are case-insensitive; values are literal,
case-sensitive matches. `Enabled` does not match `enabled`. Wildcards are not
expanded. Every matching VM across the selected subscription will be affected,
including matching VMs added to new resource groups after deployment.

### 5. Choose a future first-run boundary

The recurrence start time must be a future **UK local** date/time in
`yyyy-MM-ddTHH:mm:ss` format, without a `Z` or UTC offset, more than five minutes
ahead. Missing/repeated UK daylight-saving hours are rejected.

This example uses tomorrow at 07:00 UK time, before the morning startup:

```powershell
$ukTimeZone = [System.TimeZoneInfo]::FindSystemTimeZoneById('GMT Standard Time')
$ukNow = [System.TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $ukTimeZone)
$scheduleStartTime = $ukNow.Date.AddDays(1).AddHours(7).ToString('yyyy-MM-ddTHH:mm:ss')
```

The start time is a lower boundary, not an extra scheduled operation. If tomorrow
is a weekend, the next eligible run is Monday. Supply a different future local
time if you want a different activation date.

### 6. Deploy disabled and preview-only

Build a reusable parameter set. **Do not pass `VmSubscriptionId` for this
single-subscription deployment**: it defaults to `SubscriptionId`.
Also omit `VmResourceGroupName` to search all groups.

```powershell
$deployment = @{
    SubscriptionId        = $subscriptionId
    ResourceGroupName     = $resourceGroupName
    Location              = $location
    AutomationAccountName = $automationAccountName
    NamePrefix            = $namePrefix
    TagName               = $tagName
    TagValue              = $tagValue
    ScheduleStartTime     = $scheduleStartTime
    DryRun                = $true
    WorkflowState         = 'Disabled'
}

.\Deploy-VmSchedule.ps1 @deployment
```

The script creates/updates the hosting group and account, creates the runtime,
imports and publishes the runbook, verifies its published source and runtime,
validates/deploys the Logic Apps, and assigns the roles listed above.

It uses a PATCH when linking the runbook runtime so imported script content is
preserved. It stops with an error if published content differs from the local source.

Both Logic Apps are disabled at this point. No VM power operation is requested
by the deployment script, even if the VMs are already running.

## Test without changing VM power state

### 1. Submit Start and Stop preview jobs

These jobs can run while the Logic Apps remain disabled. Do not execute
`ShutdownVMTag.ps1` directly on your workstation: it uses `Connect-AzAccount
-Identity`, intended for the Automation account.

```powershell
$previewJobs = foreach ($action in @('Start', 'Stop')) {
    $runbookParameters = @{
        SubscriptionId    = $subscriptionId
        TagName           = $tagName
        TagValue          = $tagValue
        Action            = $action
        DryRun            = $true
    }

    $job = Start-AzAutomationRunbook -ResourceGroupName $resourceGroupName `
        -AutomationAccountName $automationAccountName -Name 'ShutdownVMTag' `
        -Parameters $runbookParameters -DefaultProfile $context

    [pscustomobject]@{ Action = $action; JobId = $job.JobId }
}

$previewJobs
```

Check job status; repeat this check until both complete, or inspect the jobs in
Azure Portal > Automation account > Jobs:

```powershell
foreach ($job in $previewJobs) {
    Get-AzAutomationJob -ResourceGroupName $resourceGroupName `
        -AutomationAccountName $automationAccountName -Id $job.JobId `
        -DefaultProfile $context |
        Select-Object JobId, Status, Exception
}
```

`Failed`, `Suspended` or `Stopped` is not success. Inspect job errors before
continuing. First execution can take several minutes.

### 2. Inspect the output and power state

```powershell
foreach ($job in $previewJobs) {
    Get-AzAutomationJobOutput -ResourceGroupName $resourceGroupName `
        -AutomationAccountName $automationAccountName -Id $job.JobId `
        -Stream Any -DefaultProfile $context |
        Select-Object Type, Summary
}

Get-AzVM -Status -DefaultProfile $vmContext |
    Select-Object Name, PowerState
```

Confirm the count and VM names are exactly what you intended. For each match,
Start output should include `[Preview] Would start VM`, and Stop output should
include `[Preview] Would stop and deallocate VM`. Both must report `DryRun = True`.
No preview should change a VM's power state.

No matches is a valid no-op, not evidence the tag selection is correct.
Correct missing tags, values, permissions or scope and repeat the preview.

### 3. Optional: test the Logic App identity and HTTP path

Runbook preview tests verify the Automation identity and VM selection, but do not
exercise the Logic App identity. To test the complete submission path:

1. Keep `DryRun=true`.
2. Recompute a future `ScheduleStartTime`, set `$deployment.WorkflowState =
   'Enabled'`, and rerun the deployment with `$deployment.DryRun = $true`.
3. In each Logic App's portal Overview, use **Run trigger** to submit a preview.
4. Inspect Run history > `Create_Automation_job`. Record the job ID from
   `Job_id` or the workflow output `automationJobId`.
5. Find that job in Automation Jobs and verify preview output as above.
6. Disable both Logic Apps again if you are not ready to activate live operation.

While enabled in preview mode, scheduled occurrences only submit preview jobs.
Never switch `DryRun` off merely to test the HTTP connection.

## Enable the live schedule

This step authorizes actual start/stop operations on every matching VM.
Only do it after the previews are correct and role assignments have propagated.

Recompute a future first-run boundary, then deploy the **same names**:

```powershell
$ukNow = [System.TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $ukTimeZone)
$deployment.ScheduleStartTime = $ukNow.Date.AddDays(1).AddHours(7).ToString('yyyy-MM-ddTHH:mm:ss')
$deployment.DryRun = $false
$deployment.WorkflowState = 'Enabled'

.\Deploy-VmSchedule.ps1 @deployment
```

The first eligible scheduled operation is at or after that boundary. This
example does not start/stop VMs immediately and will normally begin with the
next weekday 08:00 startup.

Verify each Logic App in the portal:

- State is **Enabled**.
- Start recurrence is Monday-Friday, 08:00, `GMT Standard Time`.
- Stop recurrence is Monday-Friday, 19:00, `GMT Standard Time`.
- Workflow parameter `jobParameters` contains the intended VM subscription,
  tag, action and `DryRun = "false"`. For all-group targeting there must be
  **no `ResourceGroupName` property** in those job parameters.

Disable older Automation schedules or other conflicting start/stop mechanisms.
Monitor the first real jobs to confirm successful completion.

**Do not just enable an old workflow whose start boundary has elapsed.**
Recurrence triggers can fire immediately on enable. Redeploy with a future
boundary and the intended `DryRun` setting instead.

## Pause the schedule

Disable **both** Logic Apps in their portal Overview pages. Leave the Automation
account and identities in place if you intend to resume.

Disabling a Logic App does not cancel an Automation job already submitted and
does not start or stop a VM. Inspect Automation Jobs separately. Do not terminate
jobs without understanding their current operation.

To resume, repeat the live activation step with a new future boundary. To return
to a disabled preview configuration, redeploy with `DryRun=$true`,
`WorkflowState='Disabled'`, and a new future boundary.

Redeployments temporarily disable both workflows while configuration and
permissions are updated. Avoid redeployment during a scheduled event or active
runbook job. Changing resource names creates a different set of resources rather
than moving the old ones; disable the old schedulers to prevent duplicate runs.

## Optional cross-subscription setup

Skip this section when everything is in one subscription.

Keep `$subscriptionId` as the hosting subscription. After creating the base
variables and `$deployment` parameter set above, select the VM subscription:

```powershell
$vmSubscriptionId = '<subscription-containing-the-VMs>'
$vmContext = Set-AzContext -TenantId $tenantId `
    -SubscriptionId $vmSubscriptionId -Scope Process

Get-AzVM -DefaultProfile $vmContext |
    Select-Object Name, ResourceGroupName, Tags

$deployment.VmSubscriptionId = $vmSubscriptionId
.\Deploy-VmSchedule.ps1 @deployment
```

For a new setup, apply this override **before your first deployment**. Keep
`DryRun=$true` and `WorkflowState='Disabled'` during initial testing.
Both subscriptions must belong to `$tenantId`; cross-tenant operation is not
supported. You need role-assignment permissions in the VM subscription as
well as deployment/RBAC permissions in the hosting subscription.

The account and Logic Apps stay in the hosting subscription. VM discovery,
runbook parameters and the account identity's VM role target the other subscription.
Use `$vmContext` for VM inspection/tagging. In preview job parameters, replace
`SubscriptionId = $subscriptionId` with `SubscriptionId = $vmSubscriptionId`.

To return a parameter set to the single-subscription default before deploying:

```powershell
$deployment.Remove('VmSubscriptionId')
$vmContext = $context
```

This changes the target for that deployment; it does not move VMs or scheduling
resources. Previous VM role assignments are not automatically removed when you
change targets. Review and remove obsolete grants through IAM when appropriate.

## Optional resource-group filter

Skip this section to keep subscription-wide targeting. To deliberately restrict
discovery and the new VM permission grant to one existing group:

```powershell
$deployment.VmResourceGroupName = 'rg-dev-vms'
.\Deploy-VmSchedule.ps1 @deployment
```

Keep a future `ScheduleStartTime` and preview-only settings while testing.
For this restricted deployment, also include `ResourceGroupName = 'rg-dev-vms'`
in the preview runbook parameter hashtable.

To switch an old parameter set from group-restricted to subscription-wide:

```powershell
$deployment.Remove('VmResourceGroupName')
```

Then redeploy with a future boundary and test the wider set of matches.
Do not pass an empty group argument to the script: omit it instead. The script
sends an empty group value to the ARM template, which omits `ResourceGroupName`
from the runbook job parameters.

Existing Azure deployments do not change when local files are updated. Redeploy
the same names to update scope and permissions. Previous role assignments are
not removed automatically. When narrowing scope again, review and remove any
old subscription-wide grants through IAM; a narrower grant does not revoke them.

## Deployment parameters

| Parameter | Required/default | Meaning |
|---|---|---|
| `SubscriptionId` | Required | Subscription hosting the scheduling resources. |
| `ResourceGroupName` | Required | Hosting group, created if absent. |
| `Location` | Required | Hosting region; must match an existing hosting group's location. |
| `AutomationAccountName` | Required | Dedicated account name, created or updated. |
| `VmResourceGroupName` | Optional; omitted by default | Omit to search all groups and grant VM permissions at subscription scope. Supply an existing group to restrict both. |
| `VmSubscriptionId` | Defaults to `SubscriptionId` | Omit for a single-subscription setup. |
| `ScheduleStartTime` | Required | Future UK-local boundary, no offset, more than five minutes ahead. |
| `NamePrefix` | `tagged-vms` | Names the `<prefix>-start` and `<prefix>-stop` Logic Apps. |
| `TagName` | `AutoShutdown` | Case-insensitive VM tag key. |
| `TagValue` | `Enabled` | Case-sensitive, literal VM tag value. |
| `DryRun` | `$true` | Preview VM actions when true; infrastructure is still deployed. |
| `WorkflowState` | `Disabled` | Whether to enable recurrence after deployment and role assignment. |

Each deployment covers one VM subscription, searching all its groups by default.
Use separate account/group/prefix names for independent deployments with different
tag/subscription selections: the script
updates a fixed runbook name and runtime within each account.

## Use an existing Automation account

The full deployment script updates an existing account with the supplied name.
Use it only for an account dedicated to this solution. Its configuration and
`ShutdownVMTag` runbook are updated; it is not an account migration tool.

For manual setup without the full script:

1. Enable the existing account's system-assigned managed identity.
2. Create/select a PowerShell 7.4 runtime with Az.Accounts and Az.Compute
   (the Az package bundle includes them).
3. Import [`ShutdownVMTag.ps1`](ShutdownVMTag.ps1), associate that runtime and publish.
4. Assign Virtual Machine Contributor to the account identity on the VM subscription
   (or only on the VM group if intentionally restricted).
5. In Azure Portal, open **Deploy a custom template**, load
   [`infra\vm-schedule.json`](infra/vm-schedule.json), and deploy into the **same
   resource group and subscription as the Automation account**.
6. Set `automationAccountName`, `runbookName`, tag parameters
   and a future `scheduleStartTime`. Leave `vmResourceGroupName` empty to search
   all groups. For a single subscription, leave
   `vmSubscriptionId` at its default. Keep `dryRun="true"` and
   `workflowState="Disabled"`.
7. Grant each Logic App identity Automation Job Operator at the account and
   Automation Runbook Operator at the runbook.
8. Follow the preview tests and live activation steps above. Use template
   redeployment to change workflow parameters if you chose manual setup.

The raw ARM template creates **only the two Logic Apps**, not the account,
runbook, runtime or role assignments. Its Boolean-like `dryRun` parameter is a
string because Automation's job API uses serialized parameter values.

## Monitoring and troubleshooting

A successful Logic App run means the job was **submitted**, not that VM
startup/shutdown completed. Inspect the corresponding Automation job.
Configure Azure Monitor alerts for failed Logic App runs and
failed/suspended/stopped Automation jobs. Alert rules are not deployed here.

| Symptom | Check/action |
|---|---|
| `Connect-AzAccount`/MFA error | Sign in interactively to the intended tenant and subscription. Do not put credentials in the runbook. |
| Missing deployment cmdlets/modules | Install the prerequisites above, then start a fresh PowerShell session if module versions conflict. |
| Resource provider not registered | Register Microsoft.Automation and Microsoft.Logic in the hosting subscription and wait for `Registered`. |
| Location/policy validation failure | Check regional support and policy details. If the group exists, use its current location; get administrator approval for policy requirements. |
| Authorization failure creating roles | Contributor is insufficient. Check role-assignment permissions/conditions at both scopes and allow propagation time. |
| Logic App HTTP 403 | Check its own Automation Job Operator and Automation Runbook Operator assignments, not just the account identity's VM permissions. |
| Runbook identity cannot discover/control VMs | Check the account identity's VM role on the correct subscription/group. |
| Runtime/module import error | Check the runbook is linked to PowerShell-74 and Az.Accounts/Az.Compute are available. |
| Published content mismatch | Stop and inspect the source/import/runtime association. Do not enable schedules with an empty or wrong script. |
| No matching VMs | Check VM-level tags, exact value casing, target subscription and group. |
| Workflow does not run | Check Enabled state, future start boundary, weekday schedule, UK time zone and Run history. |
| VM remains on after Friday | Inspect the Friday Automation job; confirm the tag still exists and no other process starts the VM. |
| VM is not ready at 08:00 | 08:00 is the start-operation time, not an application readiness guarantee. |

The runbook attempts all matching VMs and fails the job if any requested power
operation fails. Preview matches alone do not prove start/stop permission or
successful live power operations; monitor the first approved live runs.

## Local tests

Tests use Pester 3.4-compatible syntax and mock Azure writes. Run under Windows
PowerShell with Pester 3.4 and the prerequisite modules available:

```powershell
Import-Module Pester -RequiredVersion 3.4.0

$result = Invoke-Pester -Script .\Tests\Deploy-VmSchedule.Tests.ps1,`
    .\Tests\ShutdownVMTag.Tests.ps1,.\Tests\VmSchedule.Tests.ps1 -PassThru

if ($result.FailedCount -gt 0) {
    throw "$($result.FailedCount) test(s) failed."
}
```

Tests cover subscription-wide scope and permissions, optional group restrictions,
single-subscription defaults, explicit same-subscription targeting,
cross-subscription routing, safe deployment defaults, published-content checks,
tag matching, Start/Stop behavior, failure handling, and weekday UK schedules.
They do not provision Azure resources or substitute for deployed preview checks.

## References

- [Logic Apps recurrence schedules](https://learn.microsoft.com/en-us/azure/connectors/connectors-native-recurrence)
- [Automation job creation API](https://learn.microsoft.com/en-us/rest/api/automation/job/create?view=rest-automation-2024-10-23)
- [Automation runtime environments](https://learn.microsoft.com/en-us/azure/automation/manage-runtime-environment)
- [Azure Automation RBAC](https://learn.microsoft.com/en-us/azure/automation/automation-role-based-access-control)
