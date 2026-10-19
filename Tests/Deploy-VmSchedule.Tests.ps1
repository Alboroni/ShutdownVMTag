Import-Module Az.Accounts, Az.Resources, Az.Automation -ErrorAction Stop

$deploymentPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Deploy-VmSchedule.ps1'

# Static signatures keep Az dynamic parameter discovery from contacting Azure.
function Test-AzResourceGroupDeployment {
    [CmdletBinding()]
    param($ResourceGroupName, $TemplateFile, $TemplateParameterObject, $DefaultProfile)
    throw 'Test-AzResourceGroupDeployment must be mocked.'
}

function New-AzResourceGroupDeployment {
    [CmdletBinding()]
    param($Name, $ResourceGroupName, $TemplateFile, $TemplateParameterObject, $DefaultProfile)
    throw 'New-AzResourceGroupDeployment must be mocked.'
}

Describe 'VM scheduler deployment' {
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
        $testHostContext.Tenant = New-Object Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureTenant
        $testHostContext.Tenant.Id = '00000000-0000-0000-0000-000000000003'
        $testHostContext.Subscription = New-Object Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureSubscription
        $testHostContext.Subscription.Id = '00000000-0000-0000-0000-000000000001'
        $testVmContext = New-Object Microsoft.Azure.Commands.Profile.Models.Core.PSAzureContext
        $testVmContext.Subscription = New-Object Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureSubscription
        $testVmContext.Subscription.Id = '00000000-0000-0000-0000-000000000002'

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
        Mock Invoke-AzRestMethod {
            [pscustomobject]@{
                StatusCode = 200
                Content = Get-Content -LiteralPath (Join-Path (Split-Path $deploymentPath -Parent) 'ShutdownVMTag.ps1') -Raw
            }
        } -ParameterFilter { $Method -eq 'GET' -and $Path -like '*/content?api-version=*' }
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
            $Name -eq 'rg-vms' -and
            $DefaultProfile.DefaultContext.Subscription.Id -eq '00000000-0000-0000-0000-000000000002'
        }
        Assert-MockCalled New-AzRoleAssignment -Times 1 -Exactly -Scope It -ParameterFilter {
            $RoleDefinitionName -eq 'Virtual Machine Contributor' -and
            $Scope -eq '/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/rg-vms' -and
            $DefaultProfile.DefaultContext.Subscription.Id -eq '00000000-0000-0000-0000-000000000002'
        }
    }

    It 'defaults the VM subscription to the deployment subscription when omitted' {
        $deploymentArguments.Remove('VmSubscriptionId')

        & $deploymentPath @deploymentArguments

        Assert-MockCalled Get-AzResourceGroup -Times 1 -Exactly -Scope It -ParameterFilter {
            $Name -eq 'rg-vms' -and
            $DefaultProfile.DefaultContext.Subscription.Id -eq '00000000-0000-0000-0000-000000000001'
        }
        Assert-MockCalled New-AzRoleAssignment -Times 1 -Exactly -Scope It -ParameterFilter {
            $RoleDefinitionName -eq 'Virtual Machine Contributor' -and
            $Scope -eq '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-vms' -and
            $DefaultProfile.DefaultContext.Subscription.Id -eq '00000000-0000-0000-0000-000000000001'
        }
        Assert-MockCalled New-AzResourceGroupDeployment -Times 1 -Exactly -Scope It -ParameterFilter {
            $ResourceGroupName -eq 'rg-scheduler' -and
            $TemplateParameterObject.vmSubscriptionId -eq '00000000-0000-0000-0000-000000000001' -and
            $TemplateParameterObject.vmResourceGroupName -eq 'rg-vms'
        }
    }

    It 'also accepts an explicit same-subscription VM target' {
        $deploymentArguments.VmSubscriptionId = $deploymentArguments.SubscriptionId

        & $deploymentPath @deploymentArguments

        Assert-MockCalled New-AzRoleAssignment -Times 1 -Exactly -Scope It -ParameterFilter {
            $RoleDefinitionName -eq 'Virtual Machine Contributor' -and
            $Scope -eq '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-vms'
        }
        Assert-MockCalled New-AzResourceGroupDeployment -Times 1 -Exactly -Scope It -ParameterFilter {
            $TemplateParameterObject.vmSubscriptionId -eq '00000000-0000-0000-0000-000000000001'
        }
    }

    It 'targets every resource group in the VM subscription when the group is omitted' {
        $deploymentArguments.Remove('VmResourceGroupName')

        & $deploymentPath @deploymentArguments

        Assert-MockCalled Get-AzResourceGroup -Times 0 -Exactly -Scope It
        Assert-MockCalled New-AzRoleAssignment -Times 1 -Exactly -Scope It -ParameterFilter {
            $RoleDefinitionName -eq 'Virtual Machine Contributor' -and
            $Scope -eq '/subscriptions/00000000-0000-0000-0000-000000000002' -and
            $DefaultProfile.DefaultContext.Subscription.Id -eq '00000000-0000-0000-0000-000000000002'
        }
        Assert-MockCalled New-AzResourceGroupDeployment -Times 1 -Exactly -Scope It -ParameterFilter {
            $TemplateParameterObject.vmSubscriptionId -eq '00000000-0000-0000-0000-000000000002' -and
            $TemplateParameterObject.vmResourceGroupName -ceq ''
        }
    }

    It 'defaults to all groups in the hosting subscription when both VM overrides are omitted' {
        $deploymentArguments.Remove('VmResourceGroupName')
        $deploymentArguments.Remove('VmSubscriptionId')

        & $deploymentPath @deploymentArguments

        Assert-MockCalled Get-AzResourceGroup -Times 0 -Exactly -Scope It
        Assert-MockCalled New-AzRoleAssignment -Times 1 -Exactly -Scope It -ParameterFilter {
            $RoleDefinitionName -eq 'Virtual Machine Contributor' -and
            $Scope -eq '/subscriptions/00000000-0000-0000-0000-000000000001'
        }
        Assert-MockCalled New-AzResourceGroupDeployment -Times 1 -Exactly -Scope It -ParameterFilter {
            $TemplateParameterObject.vmSubscriptionId -eq '00000000-0000-0000-0000-000000000001' -and
            $TemplateParameterObject.vmResourceGroupName -ceq ''
        }
    }

    It 'rejects an explicitly empty group instead of silently widening the scope' {
        $deploymentArguments.VmResourceGroupName = ''

        { & $deploymentPath @deploymentArguments } | Should Throw
        Assert-MockCalled New-AzResourceGroup -Times 0 -Exactly -Scope It
        Assert-MockCalled New-AzRoleAssignment -Times 0 -Exactly -Scope It
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
        Assert-MockCalled Invoke-AzRestMethod -Times 1 -Exactly -Scope It -ParameterFilter {
            $Method -eq 'PATCH' -and $Path -like '*/runbooks/ShutdownVMTag?api-version=*'
        }
        Assert-MockCalled Invoke-AzRestMethod -Times 0 -Exactly -Scope It -ParameterFilter {
            $Method -eq 'PUT' -and $Path -like '*/runbooks/ShutdownVMTag?api-version=*'
        }
    }

    It 'rejects an elapsed start time before creating resources' {
        $deploymentArguments.ScheduleStartTime = '2000-01-01T00:00:00'
        { & $deploymentPath @deploymentArguments } | Should Throw 'five minutes in the future'

        Assert-MockCalled New-AzResourceGroup -Times 0 -Exactly -Scope It
        Assert-MockCalled Invoke-AzRestMethod -Times 0 -Exactly -Scope It
    }

    It 'does not deploy schedulers when the published script is empty' {
        Mock Invoke-AzRestMethod {
            [pscustomobject]@{ StatusCode = 200; Content = '' }
        } -ParameterFilter { $Method -eq 'GET' -and $Path -like '*/content?api-version=*' }

        { & $deploymentPath @deploymentArguments } | Should Throw 'Published runbook content does not match'
        Assert-MockCalled New-AzResourceGroupDeployment -Times 0 -Exactly -Scope It
    }
}
