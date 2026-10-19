$templatePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'infra\vm-schedule.json'
$template = Get-Content -LiteralPath $templatePath -Raw | ConvertFrom-Json
$workflow = $template.resources[0]
$definition = $workflow.properties.definition

Describe 'VM schedule ARM template' {
    It 'creates separate start and stop workflows' {
        $workflow.type | Should Be 'Microsoft.Logic/workflows'
        $workflow.copy.count | Should Be 2
        $template.variables.schedules[0].action | Should Be 'Start'
        $template.variables.schedules[0].hour | Should Be 8
        $template.variables.schedules[1].action | Should Be 'Stop'
        $template.variables.schedules[1].hour | Should Be 19
    }

    It 'runs every week on exactly Monday through Friday in UK local time' {
        $recurrence = $definition.triggers.Weekday_schedule.recurrence
        $recurrence.frequency | Should Be 'Week'
        $recurrence.interval | Should Be 1
        $recurrence.timeZone | Should Be 'GMT Standard Time'
        ($recurrence.schedule.weekDays -join ',') | Should Be 'Monday,Tuesday,Wednesday,Thursday,Friday'
        $recurrence.schedule.minutes.Count | Should Be 1
        $recurrence.schedule.minutes[0] | Should Be 0
        $recurrence.schedule.hours[0] | Should Be "[variables('schedules')[copyIndex()].hour]"
    }

    It 'requires an explicit first-run date to prevent immediate initial execution' {
        $definition.triggers.Weekday_schedule.recurrence.startTime | Should Be "[parameters('scheduleStartTime')]"
        ($template.parameters.scheduleStartTime.PSObject.Properties.Name -contains 'defaultValue') | Should Be $false
    }

    It 'defaults to disabled workflows and preview-only VM operations' {
        $template.parameters.workflowState.defaultValue | Should Be 'Disabled'
        $template.parameters.dryRun.defaultValue | Should Be 'true'
    }

    It 'uses managed identity with the ARM audience rather than a webhook secret' {
        $workflow.identity.type | Should Be 'SystemAssigned'
        $action = $definition.actions.Create_Automation_job
        $action.inputs.authentication.type | Should Be 'ManagedServiceIdentity'
        $action.inputs.authentication.audience | Should Be 'https://management.azure.com/'
        $action.inputs.method | Should Be 'PUT'
        $action.inputs.uri | Should Match '/jobs/'
        $action.inputs.uri | Should Match 'api-version=2024-10-23'
    }

    It 'reuses a stable job ID across retries and exposes it for job monitoring' {
        $definition.actions.Job_id.inputs | Should Be '@guid()'
        $definition.actions.Create_Automation_job.inputs.uri | Should Match "outputs\('Job_id'\)"
        $definition.actions.Create_Automation_job.inputs.retryPolicy.type | Should Be 'exponential'
        $definition.outputs.automationJobId.value | Should Be "@outputs('Job_id')"
    }

    It 'passes the correct action and omits an unspecified resource group' {
        $jobParameters = $workflow.properties.parameters.jobParameters.value
        $jobParameters | Should Match "createObject\('Action', variables\('schedules'\)\[copyIndex\(\)\].action\)"
        $jobParameters | Should Match "if\(empty\(parameters\('vmResourceGroupName'\)\)"
        $template.variables.baseRunbookParameters.DryRun | Should Be "[parameters('dryRun')]"
        $definition.actions.Create_Automation_job.inputs.body.properties.parameters | Should Be "@parameters('jobParameters')"
    }
}
