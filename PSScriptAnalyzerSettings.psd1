@{
    Severity     = @('Error', 'Warning', 'Information')
    ExcludeRules = @(
        # install.ps1 is an interactive installer; colored console output is intended.
        'PSAvoidUsingWriteHost',
        # Internal helpers of a script, not cmdlets; -WhatIf/-Confirm would add nothing.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
