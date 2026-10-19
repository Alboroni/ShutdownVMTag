Import-Module Az.Accounts, Az.Resources, Az.Automation -ErrorAction Stop

$deploymentPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Deploy-VmSchedule.ps1'

Describe 'Cross-subscription VM scheduler deployment' {
    BeforeEach {
        $deploymentArguments = @{
            SubscriptionId = '00000000-0000-0000-0000-000000000001'
            VmSubscriptionId = '00000000-0000-0000-0000-000000000002'
            ResourceGroupName = 'rg-scheduler'
            VmResourceGroupName = 'rg-vms'
            Location = 'swedencentral'
            AutomationAccountName = 'aa-scheduler'
            ScheduleStartTime = '2099-01-01T00:00:00'
        }
        $testHostContext = New-Object Microsoft.Azure.Commands.Profile.Models.Core.PSAzureContext
        $testHostContext.Tenant = New-Object Microsoft.Azure.Commands.Profile.Models.Core.PSAzureTenant
        $testHostContext.Tenant.Id = '00000000-0000-0000-0000-000000000003'
        $testVmContext = New-Object Microsoft.Azure.Commands.Profile.Models.Core.PSAzureContext

        Mock Get-AzContext { $testHostContext }
        Mock Set-AzContext { $testHostContext }
        Mock Set-AzContext { $testVmContext } -ParameterFilter {
            $Subscription -eq '00000000-0000-0000-0000-000000000002'
        }
        Mock Get-AzResourceGroup { [pscustomobject]@{ ResourceGroupName = 'rg-vms' } }
        Mock New-AzResourceGroup {}
        Mock Invoke-AzRestMethod {
            [pscustomobject]@{
                StatusCode = 200
                Content = '{"identity":{"principalId":"account-principal"},"properties":{"state":"Published","runtimeEnvironment":"PowerShell-74"}}'
            }
        }
        Mock Import-AzAutomationRunbook {}
        Mock Publish-AzAutomationRunbook {}
        Mock Get-AzRoleAssignment { @() }
        Mock New-AzRoleAssignment {}
        Mock Test-AzResourceGroupDeployment { @() }
        Mock New-AzResourceGroupDeployment {}
        Mock Get-AzResource {
            [pscustomobject]@{ Identity = [pscustomobject]@{ PrincipalId = 'logic-principal' } }
        }
    }

    It 'checks the VM group and assigns VM permissions in the VM subscription' {
        & $deploymentPath @deploymentArguments

        Assert-MockCalled Get-AzResourceGroup -Times 1 -Exactly -Scope It -ParameterFilter {
            $Name -eq 'rg-vms' -and $DefaultProfile -eq $testVmContext
        }
        Assert-MockCalled New-AzRoleAssignment -Times 1 -Exactly -Scope It -ParameterFilter {
            $RoleDefinitionName -eq 'Virtual Machine Contributor' -and
            $Scope -eq '/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/rg-vms' -and
            $DefaultProfile -eq $testVmContext
        }
    }

    It 'deploys disabled preview workflows with the VM subscription passed to the runbook' {
        & $deploymentPath @deploymentArguments

        Assert-MockCalled New-AzResourceGroupDeployment -Times 1 -Exactly -Scope It -ParameterFilter {
            $ResourceGroupName -eq 'rg-scheduler' -and
            $DefaultProfile -eq $testHostContext -and
            $TemplateParameterObject.vmSubscriptionId -eq '00000000-0000-0000-0000-000000000002' -and
            $TemplateParameterObject.vmResourceGroupName -eq 'rg-vms' -and
            $TemplateParameterObject.dryRun -eq 'true' -and
            $TemplateParameterObject.workflowState -eq 'Disabled'
        }
        Assert-MockCalled Import-AzAutomationRunbook -Times 1 -Exactly -Scope It
        Assert-MockCalled Publish-AzAutomationRunbook -Times 1 -Exactly -Scope It
    }

    It 'rejects an elapsed start time before creating resources' {
        $deploymentArguments.ScheduleStartTime = '2000-01-01T00:00:00'
        { & $deploymentPath @deploymentArguments } | Should Throw 'five minutes in the future'

        Assert-MockCalled New-AzResourceGroup -Times 0 -Exactly -Scope It
        Assert-MockCalled Invoke-AzRestMethod -Times 0 -Exactly -Scope It
    }
}
