# Tagged VM schedule deployment

Status: Approved

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
- [ ] Check existing names, providers, permissions, policies and regional support.
- [ ] All validation checks pass.
  - [ ] PowerShell parsing and targeted Pester tests.
  - [ ] ARM subscription-scope validation and what-if for the target resource group and nested resources.
  - [ ] Azure policy review and provider/region checks.
  - [ ] Static RBAC review.
- [ ] Deploy resource group, runtime, runbook, Logic Apps and RBAC.
- [ ] Apply approved VM tag without replacing other tags.
- [ ] Verify live resources and permissions.
- [ ] Run Start and Stop preview jobs and confirm no VM state change.

## 5. Role assignment verification

- Automation account identity: Virtual Machine Contributor at Online-1/VM-RG.
- Each Logic App identity: Automation Job Operator at aa-vm-schedule.
- Each Logic App identity: Automation Runbook Operator at the ShutdownVMTag runbook.
- Deployment identity needs resource creation and role-assignment rights in both selected scopes.
- Status: Pending validation.

## 6. Deployment constraints

- Existing resources with the proposed names must be checked before provisioning.
- Any new deployment errors must be surfaced; do not enable live schedules.
- Changes are additive; do not delete existing resources or alter unrelated VMs.
- No actual start/stop test is approved.

## 7. Validation proof

Pending. Record actual commands, timestamps and outcomes before setting Validated.

## 8. Deployment results

Pending.
