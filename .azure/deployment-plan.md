# Tagged VM schedule deployment

Status: Deployed - Disabled / DryRun

## 1. Recipe

- Type: Azure PowerShell with ARM JSON (`Deploy-VmSchedule.ps1`).
- Existing local runbook and Logic Apps template; no application build or containers.
- No azd environment is needed for this ARM/PowerShell deployment.

## 2. Approved Azure context

- Tenant: ad60fce4-22bd-4f48-b2e3-95735fb28bf7.
- Hosting subscription: Connectivity-Prod, 7134501b-6bb4-4690-ae24-6e7fe0cb6d4f.
- New resource group: rg-vm-schedule.
- Location: swedencentral.
- New Automation account: aa-vm-schedule.
- Runtime: PowerShell 7.4 with the documented Az 12.3.0 bundle.
- Shared published runbook: ShutdownVMTag.
- Logic Apps: tagged-vms-start and tagged-vms-stop.
- VM subscription: Online-1, 0a565637-bd68-47eb-9551-b4694f56f7b5.
- VM resource group: VM-RG.
- Approved VM tag change: add AutoShutdown=Enabled to vmdepender, preserving other tags.

## 3. Behavior and safety

- Monday-Friday startup at 08:00, shutdown/deallocation at 19:00.
- Time zone: GMT Standard Time, preserving UK GMT/BST changes.
- No scheduled runs on weekends; not continuous enforcement.
- User selected deployment DISABLED with DryRun=true.
- Verification may submit preview Start and Stop Automation jobs. Do not start or stop VMs.
- A future UK-local scheduleStartTime will be chosen immediately before deployment.
- No webhook secrets or credentials in source.
- Resource creation, resource-group-scoped VM permissions, and Logic App permissions were approved.

## 4. Implementation

- [x] Support explicit VM subscription in deployment script, same tenant.
- [x] Obtain user's subscription, region, tag change, and preview-mode approval.
- [x] Check existing names, providers, permissions, policies and regional support.
- [x] All validation checks pass.
  - [x] PowerShell parsing and targeted Pester tests.
  - [x] ARM subscription-scope validation and what-if for the target resource group and nested resources.
  - [x] Azure policy review and provider/region checks.
  - [x] Static RBAC review.
- [x] Deploy resource group, runtime, runbook, Logic Apps and RBAC.
- [x] Apply approved VM tag without replacing other tags.
- [x] Verify live resources and permissions.
- [x] Run Start and Stop preview jobs and confirm no VM state change.

## 5. Role assignment verification

- Automation account identity: Virtual Machine Contributor at Online-1/VM-RG.
- Each Logic App identity: Automation Job Operator at aa-vm-schedule.
- Each Logic App identity: Automation Runbook Operator at the ShutdownVMTag runbook.
- Deployment identity needs resource creation and role-assignment rights in both selected scopes.
- Status: Verified statically and against live Azure role assignments for all three identities.

## 6. Deployment constraints

- Existing resources with the proposed names must be checked before provisioning.
- Any new deployment errors must be surfaced; do not enable live schedules.
- Changes are additive; do not delete existing resources or alter unrelated VMs.
- No actual start/stop test is approved.

## 7. Validation proof

- Validation completed 2026-10-19 at 10:07 UK local time.
- `Invoke-Pester -Script .\Tests\Deploy-VmSchedule.Tests.ps1,.\Tests\ShutdownVMTag.Tests.ps1,.\Tests\VmSchedule.Tests.ps1 -PassThru`: 21 passed, 0 failed. Tests mock Azure writes.
- `System.Management.Automation.Language.Parser.ParseFile` on all PowerShell source/tests: passed.
- `git diff --check`: passed.
- `Test-AzSubscriptionDeployment` with exact hosting subscription, new resource group and nested account/runtime/runbook metadata plus the actual Logic Apps template: passed.
- `Get-AzSubscriptionDeploymentWhatIfResult`: Succeeded; six Create changes (RG, account, runtime, runbook, two Logic Apps), no modifications or deletions.
- New hosting resource group does not exist; no existing-name conflicts in that scope.
- Both Microsoft.Automation and Microsoft.Logic support Sweden Central; required providers registered successfully.
- Effective permissions at hosting subscription and target VM group include all management actions without exclusions.
- Inherited governance deny initiative and classic-resource block reviewed; no applicable denial found for the planned resources. ARM server-side validation and what-if passed under the actual inherited policy assignments.
- Initial VM state: vmdepender is deallocated.
- Static RBAC: VM operations scoped only to Online-1/VM-RG; Logic App job submission scoped to the account, runbook read scoped to the specific runbook.
- Azure validation workflow script has a .NET Framework enum TryParse incompatibility on Windows PowerShell 5.1. Its steps were executed with an in-memory Enum.Parse compatibility adapter; no installed skill files were changed.
- No separate binary/container build applies to this PowerShell/ARM-only solution.
- Post-deployment verification identified an empty runbook caused by a full PUT when associating the runtime after import. Changed to Microsoft's documented PATCH runtime association, republished, and verified the published source matches the local source.
- Added a deployment content-verification safeguard and regression test that prevents scheduler deployment when published content is empty.
- Final regression suite at 2026-10-19 10:16 UK local time: 22 passed, 0 failed. Whitespace check passed.

## 8. Deployment results

- Completed and verified on 2026-10-19, 10:16 UK local time.
- Hosting resource group: rg-vm-schedule, Connectivity-Prod, Sweden Central.
- Automation account aa-vm-schedule with system-assigned managed identity.
- PowerShell-74 runtime: PowerShell 7.4 with Az 12.3.0.
- ShutdownVMTag: Published, correct runtime, published source matches local script.
- tagged-vms-start: Disabled, DryRun=true, 08:00 Monday-Friday, GMT Standard Time.
- tagged-vms-stop: Disabled, DryRun=true, 19:00 Monday-Friday, GMT Standard Time.
- Configured future recurrence boundary: 2026-10-26T00:00:00 UK local time.
- VM vmdepender in Online-1/VM-RG tagged with AutoShutdown=Enabled using a merge.
- Start preview job: 8e9d3d64-671c-4c9d-ae09-a0c45b30e54d, Completed.
- Stop preview job: 91597aa9-d86e-41c1-9b37-635423461907, Completed.
- Both preview jobs used the same string-valued parameters as the Logic App HTTP requests, selected exactly one VM and logged preview-only actions.
- vmdepender remains deallocated; no actual start/stop operation was run.
- Logic Apps were not enabled or manually triggered. Their managed identities' account/runbook role assignments were verified live, but end-to-end scheduled trigger execution is intentionally untested while disabled.
- Required providers Microsoft.Automation and Microsoft.Logic registered.
- Installed missing local deployment modules Az.Resources and Az.Automation for the current user.
- To activate later, redeploy the same names with a future scheduleStartTime, DryRun=false and WorkflowState=Enabled, after explicit user approval.
