Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Compute -ErrorAction Stop

$runbookPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'ShutdownVMTag.ps1'

Describe 'ShutdownVMTag runbook' {
    BeforeEach {
        $parameters = @{
            SubscriptionId = '00000000-0000-0000-0000-000000000001'
            TagName        = 'AutoShutdown'
            TagValue       = 'Enabled'
        }
        $testAzureContext = New-Object Microsoft.Azure.Commands.Profile.Models.Core.PSAzureContext
        $vms = @(
            [pscustomobject]@{ Name = 'matching'; ResourceGroupName = 'rg-dev'; Id = '/vm/matching'; Tags = @{ autoshutdown = 'Enabled' } }
            [pscustomobject]@{ Name = 'wrong-case'; ResourceGroupName = 'rg-dev'; Id = '/vm/wrong-case'; Tags = @{ AutoShutdown = 'enabled' } }
            [pscustomobject]@{ Name = 'wrong-value'; ResourceGroupName = 'rg-dev'; Id = '/vm/wrong-value'; Tags = @{ AutoShutdown = 'Disabled' } }
            [pscustomobject]@{ Name = 'untagged'; ResourceGroupName = 'rg-dev'; Id = '/vm/untagged'; Tags = $null }
        )

        Mock Disable-AzContextAutosave {}
        Mock Connect-AzAccount { [pscustomobject]@{ Context = $testAzureContext } }
        Mock Set-AzContext { $testAzureContext }
        Mock Get-AzVM { $vms }
        Mock Stop-AzVM {}
        Mock Start-AzVM {}
    }

    It 'previews by default and matches tag names case-insensitively but values exactly' {
        $output = & $runbookPath @parameters

        ($output -join "`n") | Should Match 'Found 1 VM'
        ($output -join "`n") | Should Match '\[Preview\].*matching'
        Assert-MockCalled Stop-AzVM -Times 0 -Exactly -Scope It
    }

    It 'uses managed identity and an explicit context for subscription-wide discovery and stop' {
        & $runbookPath @parameters -DryRun $false

        Assert-MockCalled Disable-AzContextAutosave -Times 1 -Exactly -Scope It -ParameterFilter { $Scope -eq 'Process' }
        Assert-MockCalled Connect-AzAccount -Times 1 -Exactly -Scope It -ParameterFilter {
            $Identity -and $Subscription -eq $parameters.SubscriptionId
        }
        Assert-MockCalled Set-AzContext -Times 1 -Exactly -Scope It -ParameterFilter {
            $Subscription -eq $parameters.SubscriptionId -and $null -ne $DefaultProfile
        }
        Assert-MockCalled Get-AzVM -Times 1 -Exactly -Scope It -ParameterFilter {
            -not $ResourceGroupName -and $null -ne $DefaultProfile
        }
        Assert-MockCalled Stop-AzVM -Times 1 -Exactly -Scope It -ParameterFilter {
            $Name -eq 'matching' -and $ResourceGroupName -eq 'rg-dev' -and
            $Force -and -not $StayProvisioned -and $null -ne $DefaultProfile
        }
    }

    It 'restricts discovery to the requested resource group' {
        & $runbookPath @parameters -ResourceGroupName 'rg-dev'

        Assert-MockCalled Get-AzVM -Times 1 -Exactly -Scope It -ParameterFilter { $ResourceGroupName -eq 'rg-dev' }
    }

    It 'treats wildcard characters in tag values literally' {
        $parameters.TagValue = '*'
        $output = & $runbookPath @parameters -DryRun $false

        ($output -join "`n") | Should Match 'Found 0 VM'
        Assert-MockCalled Stop-AzVM -Times 0 -Exactly -Scope It
    }

    It 'handles an empty subscription without stopping anything' {
        $vms = @()
        $output = & $runbookPath @parameters -DryRun $false

        ($output -join "`n") | Should Match 'Found 0 VM'
        Assert-MockCalled Stop-AzVM -Times 0 -Exactly -Scope It
    }

    It 'continues after a stop failure but fails the job overall' {
        Mock Get-AzVM {
            @(
                [pscustomobject]@{ Name = 'matching'; ResourceGroupName = 'rg-dev'; Id = '/vm/matching'; Tags = @{ AutoShutdown = 'Enabled' } }
                [pscustomobject]@{ Name = 'second'; ResourceGroupName = 'rg-dev'; Id = '/vm/second'; Tags = @{ AutoShutdown = 'Enabled' } }
            )
        }
        Mock Stop-AzVM {
            if ($Name -eq 'matching') { throw 'Stop denied' }
        }

        { & $runbookPath @parameters -DryRun $false } | Should Throw 'Failed to stop and deallocate 1 VM(s)'
        Assert-MockCalled Stop-AzVM -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'second' }
    }

    It 'does not discover or stop VMs when authentication fails' {
        Mock Connect-AzAccount { throw 'Identity unavailable' }

        { & $runbookPath @parameters -DryRun $false } | Should Throw 'Identity unavailable'
        Assert-MockCalled Get-AzVM -Times 0 -Exactly -Scope It
        Assert-MockCalled Stop-AzVM -Times 0 -Exactly -Scope It
    }

    It 'starts only matching VMs when Start is explicitly requested' {
        & $runbookPath @parameters -Action Start -DryRun $false

        Assert-MockCalled Start-AzVM -Times 1 -Exactly -Scope It -ParameterFilter {
            $Name -eq 'matching' -and $ResourceGroupName -eq 'rg-dev' -and $null -ne $DefaultProfile
        }
        Assert-MockCalled Stop-AzVM -Times 0 -Exactly -Scope It
    }

    It 'previews startup without starting or stopping VMs' {
        $output = & $runbookPath @parameters -Action Start

        ($output -join "`n") | Should Match '\[Preview\] Would start VM'
        Assert-MockCalled Start-AzVM -Times 0 -Exactly -Scope It
        Assert-MockCalled Stop-AzVM -Times 0 -Exactly -Scope It
    }

    It 'fails the job when startup fails' {
        Mock Start-AzVM { throw 'Start denied' }

        { & $runbookPath @parameters -Action Start -DryRun $false } | Should Throw 'Failed to start 1 VM(s)'
    }

    It 'rejects unsupported actions before calling Azure' {
        { & $runbookPath @parameters -Action Restart } | Should Throw

        Assert-MockCalled Connect-AzAccount -Times 0 -Exactly -Scope It
    }
}
