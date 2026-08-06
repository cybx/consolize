<#
Static checks over every PowerShell script in the repo, for the failure modes
that only surface at run time and therefore reach the user first.

  1. Parse errors.
  2. Parameter / local variable collisions. PowerShell variable names are case
     insensitive, so a local $items IS the [string[]]$Items parameter, and
     assigning a dictionary to it coerces the whole thing into a one element
     string array. This is what broke bootstrap-gaming.ps1 mid-run.
  3. String concatenation with a bare + inside a command call, which PowerShell
     parses as extra positional arguments.
  4. Calls to sibling scripts passing parameters those scripts do not declare.
  5. Functions used before they are defined at script scope.
  6. Eight digit hex literals with the top bit set and no L suffix. PowerShell
     reads those as a 32 bit pattern, so 0xFFFFFFFF is Int32 -1 and 0x80000000
     is Int32 -2147483648. Arithmetic then goes negative and silently produces
     a wrong number rather than an error. This broke the CRC that generates
     Steam's shortcut ids.

Run it before committing:  pwsh -File scripts/check-scripts.ps1
#>
param([string]$Root)
$ErrorActionPreference = 'Stop'

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$problems = 0
$scripts = Get-ChildItem $Root -Recurse -Filter *.ps1 |
    Where-Object { $_.FullName -notlike '*\scripts\check-scripts.ps1' }

function Report {
    param([string]$File, [int]$Line, [string]$Rule, [string]$Message)
    $script:problems++
    Write-Host ("  [{0}] {1}:{2}" -f $Rule, (Split-Path $File -Leaf), $Line) -ForegroundColor Red
    Write-Host ("      {0}" -f $Message)
}

Write-Host "Checking $($scripts.Count) scripts under $Root" -ForegroundColor Cyan
Write-Host ''

foreach ($file in $scripts) {
    $errors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)

    if ($errors.Count -gt 0) {
        foreach ($e in $errors) { Report $file.FullName $e.Extent.StartLineNumber 'parse' $e.Message }
        continue
    }

    # --- 6. hex literals that turn negative ---------------------------------
    foreach ($token in $tokens) {
        if ($token.Kind -ne [System.Management.Automation.Language.TokenKind]::Number) { continue }
        if ($token.Text -match '^0[xX][89a-fA-F][0-9a-fA-F]{7}$') {
            $signed = [int]$token.Value
            $unsigned = [BitConverter]::ToUInt32([BitConverter]::GetBytes($signed), 0)
            Report $file.FullName $token.Extent.StartLineNumber 'hexliteral' (
                "$($token.Text) is Int32 $signed, not $unsigned. " +
                "Write $($token.Text)L to get the unsigned value.")
        }
    }

    # --- 2. parameter / local variable collisions ---------------------------
    $paramNames = @()
    if ($ast.ParamBlock) {
        $paramNames = @($ast.ParamBlock.Parameters | ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name.VariablePath.UserPath
                HasType = [bool]($_.Attributes | Where-Object { $_ -is [System.Management.Automation.Language.TypeConstraintAst] })
            }
        })
    }

    if ($paramNames.Count -gt 0) {
        $assignments = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [System.Management.Automation.Language.VariableExpressionAst]
        }, $true)

        foreach ($assignment in $assignments) {
            $target = $assignment.Left.VariablePath.UserPath
            $match = $paramNames | Where-Object { $_.Name -ieq $target } | Select-Object -First 1
            if (-not $match) { continue }
            # assigning to the parameter itself is fine when the case matches and
            # the value is a plain scalar; flag the dangerous shape instead
            if ($match.Name -cne $target -or $assignment.Right.Extent.Text -match '^\s*(\[ordered\])?@\{') {
                Report $file.FullName $assignment.Extent.StartLineNumber 'param-collision' `
                    ("`$$target collides with the parameter `$$($match.Name)" +
                     $(if ($match.HasType) { ' (typed, so the value is silently coerced)' } else { '' }))
            }
        }
    }

    # --- 3. bare + concatenation inside a command call -----------------------
    $commands = $ast.FindAll({
        param($node) $node -is [System.Management.Automation.Language.CommandAst]
    }, $true)

    foreach ($command in $commands) {
        foreach ($element in $command.CommandElements) {
            if ($element -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                $element.Value -eq '+' -and
                $element.StringConstantType -eq 'BareWord') {
                Report $file.FullName $element.Extent.StartLineNumber 'bare-plus' `
                    'a bare + inside a command call becomes a positional argument, not concatenation'
            }
        }
    }

    # --- 5. functions used before definition --------------------------------
    $definitions = @{}
    foreach ($fn in $ast.FindAll({
        param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true)) {
        if (-not $definitions.ContainsKey($fn.Name)) { $definitions[$fn.Name] = $fn.Extent.StartLineNumber }
    }

    foreach ($command in $commands) {
        $name = $command.GetCommandName()
        if (-not $name -or -not $definitions.ContainsKey($name)) { continue }
        if ($command.Extent.StartLineNumber -lt $definitions[$name]) {
            Report $file.FullName $command.Extent.StartLineNumber 'use-before-define' `
                "'$name' is called before it is defined (line $($definitions[$name]))"
        }
    }
}

# --- 4. cross script parameter contracts ------------------------------------
Write-Host 'Checking calls between scripts...'
$declared = @{}
foreach ($file in $scripts) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
    $names = @()
    if ($ast.ParamBlock) {
        $names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        # aliases count as declared names too
        foreach ($p in $ast.ParamBlock.Parameters) {
            foreach ($attr in $p.Attributes) {
                if ($attr -is [System.Management.Automation.Language.AttributeAst] -and $attr.TypeName.Name -eq 'Alias') {
                    foreach ($arg in $attr.PositionalArguments) {
                        if ($arg -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $names += $arg.Value }
                    }
                }
            }
        }
    }
    $declared[$file.Name] = $names
}

$common = @('Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable',
            'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable',
            'WhatIf', 'Confirm')

# Walk the AST rather than the text: only a real invocation carries parameters,
# so "Write-Host '.\foo.ps1 -Restore' -ForegroundColor Red" is correctly read as
# a Write-Host call, not as foo.ps1 receiving -ForegroundColor.
foreach ($file in $scripts) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)

    foreach ($command in $ast.FindAll({
        param($node) $node -is [System.Management.Automation.Language.CommandAst]
    }, $true)) {
        if ($command.CommandElements.Count -eq 0) { continue }

        # the invoked thing is the first element, whatever shape it takes:
        # a bare path, a quoted path, or (Join-Path $here 'x.ps1')
        $invoked = $command.CommandElements[0].Extent.Text
        $match = [regex]::Match($invoked, '([\w-]+\.ps1)')
        if (-not $match.Success) { continue }

        $target = $match.Groups[1].Value
        if (-not $declared.ContainsKey($target)) { continue }

        foreach ($element in $command.CommandElements) {
            if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            $name = $element.ParameterName
            if ($name -in $common) { continue }
            if ($declared[$target] -notcontains $name) {
                Report $file.FullName $element.Extent.StartLineNumber 'unknown-parameter' `
                    "$target does not declare -$name"
            }
        }
    }
}

Write-Host ''
if ($problems -eq 0) {
    Write-Host 'All checks passed.' -ForegroundColor Green
    exit 0
}
Write-Host "$problems problem(s) found." -ForegroundColor Red
exit 1
