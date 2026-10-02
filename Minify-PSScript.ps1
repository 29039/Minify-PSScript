<#
.SYNOPSIS
    Minify-PSScript a script which reduces the file size of a PowerShell script without changing functionality

.CREDITS
    Made by github.com/29039 with AI Assistance

.DESCRIPTION
    Applies a sequence of minify passes to a PowerShell script.
    Passes can be skipped individually via a -No* switch for debugging.

    Pipeline order:
      1   Strip comments                        -NoCommentStrip
      2   Merge backtick continuations          -NoBacktick
      3   Trim lines, drop blanks               -NoLineCleanup
      4   Collapse runs of spaces               -NoSpaceCollapse
      5   Whitespace around punctuation         -NoPunctuationSpacing
      6   Whitespace around arithmetic ops      -NoOperatorSpacing
      7   Whitespace around pipe                -NoPipeSpacing
      8   Whitespace between keyword and (      -NoKeywordSpacing
      9   Common parameter aliases              -NoParamAlias
      10  Rename functions and variables        -NoFuncRename / -NoVarRename
      11  Merge closing braces / keywords       -NoBraceMerge
      12  Join lines after ( and before )       -NoParenJoin
      13  Final whitespace tidy                 (always runs)
      14  Compress .NET TypeDefinitions         -NoTypeDefMinify

.VERSION
    0.01

.PARAMETER Path
    Source PowerShell script. Must parse without errors.

.PARAMETER OutPath
    Destination file. Written as ANSI (Windows-1252).

.PARAMETER VarRenameLetters
    Letters (case-insensitive) whose first-letter-matching variables are
    eligible for renaming. Default: all letters.

.PARAMETER ExcludeVars
    Variable names to leave unrenamed (with or without $, wildcards allowed).
    Use for script parameters, API/user-editable variables, e.g. Path, Out*.

.PARAMETER ExcludeFuncs
    Function names to leave unrenamed (wildcards allowed).

.PARAMETER ShowDiag
    Print a per-pass summary.

.PARAMETER ShowOutput
    Print the final minified text to the console.

.EXAMPLE
    .\Minify-PSScript.ps1 .\script.ps1 .\script.min.ps1

.EXAMPLE
    # Skip renames of Functions and only rename variables starting with A, to help isolate bugs
    .\Minify-PSScript.ps1 .\script.ps1 .\script.min.ps1 -NoFuncRename -VarRenameLetters A -ShowDiag

.EXAMPLE
    # Keep -Path / -OutPath and one function readable
    .\Minify-PSScript.ps1 .\script.ps1 .\script.min.ps1 -ExcludeVars Path,OutPath -ExcludeFuncs Invoke-Api
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position=0)][string]$Path,
    [Parameter(Mandatory, Position=1)][string]$OutPath,

    [switch]$NoCommentStrip,
    [switch]$NoBacktick,
    [switch]$NoLineCleanup,
    [switch]$NoSpaceCollapse,
    [switch]$NoPunctuationSpacing,
    [switch]$NoOperatorSpacing,
    [switch]$NoPipeSpacing,
    [switch]$NoKeywordSpacing,
    [switch]$NoParamAlias,
    [switch]$NoFuncRename,
    [switch]$NoVarRename,
    [switch]$NoBraceMerge,
    [switch]$NoParenJoin,
    [switch]$NoTypeDefMinify,

    [string[]]$VarRenameLetters = @(),
    [string[]]$ExcludeVars = @(),
    [string[]]$ExcludeFuncs = @(),

    [switch]$ShowDiag,
    [switch]$ShowOutput
)

# ============================================================
# Helper functions.
# Defined at script level so scriptblocks
# passed to Invoke-TextPass can resolve them at execution time.
# ============================================================

# Tracks string-literal ranges so whitespace passes don't touch them.
$script:StringRanges = [System.Collections.Generic.List[object]]::new()
$script:ShowDiagFlag = $false

function Update-StringRanges {
    param([string]$Text, [switch]$IncludeComments)
    $script:StringRanges.Clear()
    $kinds = 'StringLiteral','StringExpandable','HereStringLiteral','HereStringExpandable'
    if ($IncludeComments) { $kinds += 'Comment' }
    $tt = $null; $ee = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput(
        $Text, [ref]$tt, [ref]$ee)
    foreach ($t in $tt) {
        if ($null -eq $t) { continue }
        if ($t.Kind -in $kinds) {
            $script:StringRanges.Add([pscustomobject]@{
                Start = $t.Extent.StartOffset
                End   = $t.Extent.EndOffset
            })
        }
    }
}

function Test-InString {
    param([int]$Position)
    foreach ($sr in $script:StringRanges) {
        if ($Position -ge $sr.Start -and $Position -lt $sr.End) { return $true }
    }
    return $false
}

# Generic single-pass text rewriter.
# $Predicate is invoked with ($text, $i, $sb). It must return either:
#   $null                                  -> emit current char, advance 1
#   [pscustomobject]@{Consumed=N;Emit=$s}  -> emit $s, advance N

function Invoke-TextPass {
    param([string]$Text, [scriptblock]$Predicate)
    $sb = [System.Text.StringBuilder]::new()
    $i = 0; $len = $Text.Length
    while ($i -lt $len) {
        $r = & $Predicate $Text $i $sb
        if ($null -ne $r -and $r.Consumed -gt 0) {
            if ($r.Emit) { [void]$sb.Append($r.Emit) }
            $i += $r.Consumed
        } else {
            [void]$sb.Append($Text[$i])
            $i++
        }
    }
    return $sb.ToString()
}

# Applies (Start, Length, Text) edits in reverse offset order.
# Edits are deduplicated by Start offset (first wins).
function Invoke-Edits {
    param([string]$Text, [System.Collections.Generic.List[object]]$Edits)
    $sorted = $Edits | Sort-Object Start -Descending
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    $sb = [System.Text.StringBuilder]::new($Text)
    foreach ($e in $sorted) {
        if ($seen.Contains($e.Start)) { continue }
        [void]$seen.Add($e.Start)
        [void]$sb.Remove($e.Start, $e.Length)
        [void]$sb.Insert($e.Start, $e.Text)
    }
    return $sb.ToString()
}

function Write-Diag {
    param([string]$Message)
    if ($script:ShowDiagFlag) { Write-Host $Message }
}

# Applies all punctuation-adjacent whitespace compressions in one call.
# Used by both Step 5 and the post-rename safety sweep (Step 13).

function Invoke-PunctuationSpacing {
    param([string]$Text, [switch]$Quiet)

    # --- before: } , ; ---
    Update-StringRanges $Text
    $script:pCountBefore = 0
    $Text = Invoke-TextPass -Text $Text -Predicate {
        param($t, $i, $sb)
        if ($t[$i] -ne ' ') { return $null }
        if (Test-InString $i) { return $null }
        $j = $i + 1
        while ($j -lt $t.Length -and $t[$j] -eq ' ') { $j++ }
        if ($j -ge $t.Length) { return $null }
        if ($t[$j] -in '}', ',', ';') {
            $script:pCountBefore++
            return [pscustomobject]@{ Consumed = $j - $i; Emit = '' }
        }
        return $null
    }

    # --- after: { , ; ---
    Update-StringRanges $Text
    $script:pCountAfter = 0
    $Text = Invoke-TextPass -Text $Text -Predicate {
        param($t, $i, $sb)
        $ch = $t[$i]
        if ($ch -notin '{', ',', ';') { return $null }
        if (Test-InString $i) { return $null }
        $j = $i + 1
        while ($j -lt $t.Length -and $t[$j] -eq ' ') { $j++ }
        if ($j -gt $i + 1) {
            $script:pCountAfter++
            return [pscustomobject]@{ Consumed = $j - $i; Emit = $ch }
        }
        return $null
    }

    # --- space before { when prev is word/)]/}/quote ---
    Update-StringRanges $Text
    $script:pCountBracePre = 0
    $Text = Invoke-TextPass -Text $Text -Predicate {
        param($t, $i, $sb)
        if ($t[$i] -ne ' ') { return $null }
        if (Test-InString $i) { return $null }
        $j = $i + 1
        while ($j -lt $t.Length -and $t[$j] -eq ' ') { $j++ }
        if ($j -ge $t.Length -or $t[$j] -ne '{') { return $null }
        $prev = if ($sb.Length -gt 0) { $sb[$sb.Length-1] } else { '' }
        if ($prev -notmatch '[A-Za-z0-9_\)\]\}"'']') { return $null }
        $script:pCountBracePre++
        return [pscustomobject]@{ Consumed = $j - $i; Emit = '' }
    }

    # --- '=' assignment ---
    Update-StringRanges $Text
    $script:pCountEq = 0
    $Text = Invoke-TextPass -Text $Text -Predicate {
        param($t, $i, $sb)
        if ($t[$i] -ne '=') { return $null }
        if (Test-InString $i) { return $null }
        $j = $sb.Length - 1
        while ($j -ge 0 -and $sb[$j] -eq ' ') { $j-- }
        $prev = if ($j -ge 0) { $sb[$j] } else { '' }
        if ($prev -match '[-+*/%<>!=]') { return $null }
        $nextNext = if ($i + 1 -lt $t.Length) { $t[$i + 1] } else { '' }
        if ($nextNext -eq '=') { return $null }
        while ($sb.Length -gt 0 -and $sb[$sb.Length-1] -eq ' ') {
            [void]$sb.Remove($sb.Length - 1, 1)
        }
        $k = $i + 1
        while ($k -lt $t.Length -and $t[$k] -eq ' ') { $k++ }
        $script:pCountEq++
        return [pscustomobject]@{ Consumed = $k - $i; Emit = '=' }
    }

    if (-not $Quiet) {
        Write-Diag "  [punct] before },;: $script:pCountBefore  after {,;: $script:pCountAfter  before {: $script:pCountBracePre  assignments: $script:pCountEq"
    }
    return $Text
}

# Name without $ or scope prefix: '$script:foo' -> 'foo'
function Get-BareName {
    param([string]$Name)
    if ($Name -match '^\$?[a-zA-Z]+:(.+)$') { return $Matches[1] }
    return $Name.TrimStart('$')
}

# True if $Name matches any wildcard pattern (leading $ on patterns ignored).
function Test-NameMatch {
    param([string]$Name, [string[]]$Patterns)
    foreach ($p in $Patterns) { if ($Name -like $p.TrimStart('$')) { return $true } }
    return $false
}

# ============================================================
# Main
# ============================================================

$script:ShowDiagFlag = $ShowDiag.IsPresent

# ------------------------------------------------------------
# Reserved names, never renamed and never used as generated short names.
# Functions/commands: aliases and language keywords.
# Variables: PowerShell automatic and preference variables.
# ------------------------------------------------------------
$reservedFuncs = [System.Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase)
@(
    'CFS','ac','asnp','cat','cd','chdir','clc','clear','clhy','cli','clp','cls','clv',
    'cnsn','compare','copy','cp','cpi','cpp','curl','cvpa','dbp','del','diff','dir',
    'dnsn','ebp','echo','epal','epcsv','epsn','erase','etsn','exsn','fc','fhx','fl',
    'foreach','ft','fw','gal','gbp','gc','gci','gcm','gcs','gdr','ghy','gi','gjb','gl',
    'gm','gmo','gp','gps','gpv','group','gsn','gsnp','gsv','gu','gv','gwmi','h','history',
    'icm','iex','ihy','ii','ipal','ipcsv','ipmo','ipsn','irm','ise','iwmi','iwr','kill',
    'lp','ls','man','md','measure','mi','mount','move','mp','mv','nal','ndr','ni','nmo',
    'npssc','nsn','nv','ogv','oh','popd','ps','pushd','pwd','r','rbp','rcjb','rcsn','rd',
    'rdr','ren','ri','rjb','rm','rmdir','rmo','rni','rnp','rp','rsn','rsnp','rujb','rv',
    'rvpa','rwmi','sajb','sal','saps','sasv','sbp','sc','select','set','shcm','si','sl',
    'sleep','sls','sort','sp','spjb','spps','spsv','start','sujb','sv','swmi','tee','trcm',
    'type','wget','where','wjb','write',
    'if','else','elseif','while','for','do','until','switch','function','filter',
    'return','break','continue','try','catch','finally','throw','trap','param',
    'begin','process','end','class','enum','using','in','workflow','exit'
) | ForEach-Object { [void]$reservedFuncs.Add($_) }

$reservedVars = [System.Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase)
@(
    '_','null','true','false','args','input','error','host','home','pid','pwd','ofs','env',
    'this','foreach','switch','event','sender','matches','profile','LASTEXITCODE',
    'PSItem','PSCmdlet','PSCommandPath','PSScriptRoot','PSVersionTable','PSHOME',
    'PSBoundParameters','PSCulture','PSUICulture','PSEdition','PSDefaultParameterValues',
    'MyInvocation','ExecutionContext','StackTrace','ShellId','OutputEncoding',
    'ErrorActionPreference','WarningPreference','InformationPreference',
    'VerbosePreference','DebugPreference','ProgressPreference','ConfirmPreference',
    'WhatIfPreference'
) | ForEach-Object { [void]$reservedVars.Add($_) }

# ------------------------------------------------------------
# Setup
# ------------------------------------------------------------
$Path = (Resolve-Path -LiteralPath $Path).Path
if (Test-Path -LiteralPath $OutPath) {
    $OutPath = (Resolve-Path -LiteralPath $OutPath).Path
} else {
    $OutPath = [System.IO.Path]::GetFullPath(
        (Join-Path (Get-Location).Path $OutPath))
}

$code = Get-Content -Path $Path -Raw

$parsedTokens = $null; $parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseInput(
    $code, [ref]$parsedTokens, [ref]$parseErrors)
if ($parseErrors.Count) {
    throw "Source has syntax errors: $($parseErrors[0].Message)"
}

# ------------------------------------------------------------
# Step 1: Strip comments
# ------------------------------------------------------------
if (-not $NoCommentStrip) {
    $edits = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $parsedTokens) {
        if ($null -eq $t) { continue }
        if ($t.Kind -eq 'Comment') {
            $edits.Add([pscustomobject]@{
                Start  = $t.Extent.StartOffset
                Length = $t.Extent.EndOffset - $t.Extent.StartOffset
                Text   = ''
            })
        }
    }
    $code = Invoke-Edits $code $edits
    Write-Diag "[1] Comments removed: $($edits.Count)"
} else { Write-Diag "[1] skipped" }

# ------------------------------------------------------------
# Step 2: Merge backtick line continuations
# ------------------------------------------------------------
if (-not $NoBacktick) {
    Update-StringRanges $code
    $script:merged = 0
    $code = Invoke-TextPass -Text $code -Predicate {
        param($text, $i, $sb)
        if ($text[$i] -ne '`') { return $null }
        if (Test-InString $i) { return $null }
        $j = $i + 1
        while ($j -lt $text.Length -and $text[$j] -in ' ', "`t") { $j++ }
        if ($j -ge $text.Length) { return $null }
        if ($text[$j] -notin "`r", "`n") { return $null }
        $script:merged++
        $k = $j
        if ($k -lt $text.Length -and $text[$k] -eq "`r") { $k++ }
        if ($k -lt $text.Length -and $text[$k] -eq "`n") { $k++ }
        while ($k -lt $text.Length -and $text[$k] -in ' ', "`t") { $k++ }
        $sep = if ($sb.Length -gt 0 -and $sb[$sb.Length - 1] -ne ' ') { ' ' } else { '' }
        return [pscustomobject]@{ Consumed = $k - $i; Emit = $sep }
    }
    Write-Diag "[2] Backtick continuations merged: $script:merged"
} else { Write-Diag "[2] skipped" }

# ------------------------------------------------------------
# Step 3: Trim lines, drop blanks
# ------------------------------------------------------------
if (-not $NoLineCleanup) {
    $lines = $code -split "`r?`n"
    $kept = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        $t = $line.Trim()
        if ($t -ne '') { $kept.Add($t) }
    }
    $code = $kept -join "`n"
    Write-Diag "[3] Lines kept: $($kept.Count)"
} else { Write-Diag "[3] skipped" }

# ------------------------------------------------------------
# Step 4: Collapse runs of spaces
# ------------------------------------------------------------
if (-not $NoSpaceCollapse) {
    Update-StringRanges $code
    $code = Invoke-TextPass -Text $code -Predicate {
        param($text, $i, $sb)
        $ch = $text[$i]
        if ($ch -ne ' ' -and $ch -ne "`t") { return $null }
        if (Test-InString $i) { return $null }
        $j = $i
        while ($j -lt $text.Length -and $text[$j] -in ' ', "`t") { $j++ }
        return [pscustomobject]@{ Consumed = $j - $i; Emit = ' ' }
    }
    Write-Diag "[4] Space collapse done"
} else { Write-Diag "[4] skipped" }

# ------------------------------------------------------------
# Step 5: Whitespace around punctuation ( { } , ; = )
# ------------------------------------------------------------
if (-not $NoPunctuationSpacing) {
    $code = Invoke-PunctuationSpacing $code
} else { Write-Diag "[5] skipped" }

# ------------------------------------------------------------
# Step 6: Whitespace around arithmetic operators
# ------------------------------------------------------------
if (-not $NoOperatorSpacing) {
    Update-StringRanges $code
    $script:stripped = 0
    $code = Invoke-TextPass -Text $code -Predicate {
        param($t, $i, $sb)
        if ($t[$i] -ne ' ') { return $null }
        if (Test-InString $i) { return $null }
        $j = $i + 1
        while ($j -lt $t.Length -and $t[$j] -eq ' ') { $j++ }
        if ($j -ge $t.Length) { return $null }
        if ($t[$j] -notmatch '[+\-*/%]') { return $null }
        $op = $t[$j]
        $k = $j + 1
        if ($k -ge $t.Length -or $t[$k] -ne ' ') { return $null }
        $script:stripped++
        $m = $k + 1
        while ($m -lt $t.Length -and $t[$m] -eq ' ') { $m++ }
        return [pscustomobject]@{ Consumed = $m - $i; Emit = $op }
    }
    Write-Diag "[6] Arithmetic operator spaces stripped: $script:stripped"
} else { Write-Diag "[6] skipped" }

# ------------------------------------------------------------
# Step 7: Whitespace around pipe
# ------------------------------------------------------------
if (-not $NoPipeSpacing) {
    Update-StringRanges $code
    $code = Invoke-TextPass -Text $code -Predicate {
        param($t, $i, $sb)
        if ($t[$i] -eq ' ' -and -not (Test-InString $i)) {
            $j = $i + 1
            while ($j -lt $t.Length -and $t[$j] -eq ' ') { $j++ }
            if ($j -lt $t.Length -and $t[$j] -eq '|') {
                return [pscustomobject]@{ Consumed = $j - $i; Emit = '' }
            }
        }
        if ($t[$i] -eq '|' -and -not (Test-InString $i)) {
            $j = $i + 1
            while ($j -lt $t.Length -and $t[$j] -eq ' ') { $j++ }
            if ($j -gt $i + 1) {
                return [pscustomobject]@{ Consumed = $j - $i; Emit = '|' }
            }
        }
        return $null
    }
    Write-Diag "[7] Pipe spaces done"
} else { Write-Diag "[7] skipped" }

# ------------------------------------------------------------
# Step 8: Whitespace between keyword and (
# ------------------------------------------------------------
if (-not $NoKeywordSpacing) {
    Update-StringRanges $code
    $keywords = @('if','elseif','while','foreach','for','switch','until')
    $unaryKeywords = @('-bnot','-not')

    $code = Invoke-TextPass -Text $code -Predicate {
        param($t, $i, $sb)
        if ($t[$i] -match '[A-Za-z_]' -and -not (Test-InString $i)) {
            foreach ($kw in $keywords) {
                if ($i + $kw.Length -gt $t.Length) { continue }
                if ($t.Substring($i, $kw.Length) -ne $kw) { continue }
                $prevOk = ($i -eq 0) -or ($t[$i-1] -notmatch '[A-Za-z0-9_]')
                if (-not $prevOk) { continue }
                $after = if ($i + $kw.Length -lt $t.Length) { $t[$i + $kw.Length] } else { '' }
                if ($after -ne ' ' -and $after -ne '(') { continue }
                $j = $i + $kw.Length
                while ($j -lt $t.Length -and $t[$j] -eq ' ') { $j++ }
                if ($j -ge $t.Length -or $t[$j] -ne '(') { continue }
                return [pscustomobject]@{ Consumed = $j - $i; Emit = $kw }
            }
        }
        if ($t[$i] -eq '-' -and -not (Test-InString $i)) {
            foreach ($kw in $unaryKeywords) {
                if ($i + $kw.Length -gt $t.Length) { continue }
                if ($t.Substring($i, $kw.Length) -ne $kw) { continue }
                $prevOk = ($i -eq 0) -or ($t[$i-1] -notmatch '[A-Za-z0-9_]')
                if (-not $prevOk) { continue }
                $j = $i + $kw.Length
                while ($j -lt $t.Length -and $t[$j] -eq ' ') { $j++ }
                if ($j -ge $t.Length -or $t[$j] -ne '(') { continue }
                return [pscustomobject]@{ Consumed = $j - $i; Emit = $kw }
            }
        }
        return $null
    }
    Write-Diag "[8] Keyword-paren spacing done"
} else { Write-Diag "[8] skipped" }

# ------------------------------------------------------------
# Step 9: Common parameter aliases
# ------------------------------------------------------------
if (-not $NoParamAlias) {
    $paramAlias = @{
        ErrorAction       = @{ Alias='ea';   Enum=@{ SilentlyContinue=0; Stop=1; Continue=2; Inquire=3; Ignore=4; Break=5 } }
        WarningAction     = @{ Alias='wa';   Enum=@{ SilentlyContinue=0; Stop=1; Continue=2; Inquire=3; Break=5 } }
        InformationAction = @{ Alias='infa'; Enum=@{ SilentlyContinue=0; Stop=1; Continue=2; Inquire=3; Ignore=4; Break=5 } }
    }

    $t = $null; $e = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$t, [ref]$e)

    $userFuncs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        ForEach-Object { if ($_.Name) { [void]$userFuncs.Add($_.Name) } }

    $edits = [System.Collections.Generic.List[object]]::new()
    $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($cmd in $cmds) {
        $cn = $cmd.GetCommandName()
        if ($cn -and $userFuncs.Contains($cn)) { continue }
        $elements = $cmd.CommandElements
        for ($ei = 0; $ei -lt $elements.Count; $ei++) {
            $el = $elements[$ei]
            if ($el -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            if (-not $paramAlias.ContainsKey($el.ParameterName)) { continue }
            $info = $paramAlias[$el.ParameterName]
            $argAst = $el.Argument
            if (-not $argAst -and $ei + 1 -lt $elements.Count) {
                $next = $elements[$ei + 1]
                if ($next -isnot [System.Management.Automation.Language.CommandParameterAst] -and
                    $next -isnot [System.Management.Automation.Language.CommandAst]) {
                    $argAst = $next
                }
            }
            $edits.Add([pscustomobject]@{
                Start  = $el.Extent.StartOffset
                Length = $el.Extent.EndOffset - $el.Extent.StartOffset
                Text   = "-$($info.Alias)"
            })
            if ($argAst -and $info.Enum) {
                $argVal = $argAst.Extent.Text.Trim("'`"")
                if ($info.Enum.ContainsKey($argVal)) {
                    $edits.Add([pscustomobject]@{
                        Start  = $argAst.Extent.StartOffset
                        Length = $argAst.Extent.EndOffset - $argAst.Extent.StartOffset
                        Text   = [string]$info.Enum[$argVal]
                    })
                }
            }
        }
    }
    $code = Invoke-Edits $code $edits
    Write-Diag "[9] Param alias edits: $($edits.Count)"
} else { Write-Diag "[9] skipped" }

# ------------------------------------------------------------
# Step 10: Rename functions and variables
# ------------------------------------------------------------
if (-not $NoFuncRename -or -not $NoVarRename) {
    $t = $null; $e = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$t, [ref]$e)

    # Collect user-defined function names ($allFuncs: all; $userFuncs: those to rename)
    $allFuncs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        ForEach-Object { if ($_.Name) { [void]$allFuncs.Add($_.Name) } }
    $userFuncs = [System.Collections.Generic.HashSet[string]]::new()
    if (-not $NoFuncRename) {
        foreach ($f in $allFuncs) {
            if (-not $reservedFuncs.Contains($f) -and -not (Test-NameMatch $f $ExcludeFuncs)) {
                [void]$userFuncs.Add($f)
            }
        }
    }

    # Collect user-defined variable names
    $userVars = [System.Collections.Generic.HashSet[string]]::new()
    if (-not $NoVarRename) {
        $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) |
            ForEach-Object {
                if ($_.Left -is [System.Management.Automation.Language.VariableExpressionAst]) {
                    [void]$userVars.Add($_.Left.Extent.Text)
                }
            }
        $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] }, $true) |
            ForEach-Object { [void]$userVars.Add('$' + $_.Name.VariablePath.UserPath) }
        $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true) |
            ForEach-Object {
                if ($_.Variable -is [System.Management.Automation.Language.VariableExpressionAst]) {
                    [void]$userVars.Add($_.Variable.Extent.Text)
                }
            }
    }

    # Drop reserved, drive-qualified ($env:X etc.) and user-excluded variables
    $userVars = [System.Collections.Generic.HashSet[string]]::new([string[]]@($userVars | Where-Object {
        $bare = Get-BareName $_
        ($_ -notmatch '^\$[a-zA-Z]+:' -or $_ -match '^\$(script|global|local|private):') -and
        -not $reservedVars.Contains($bare) -and
        -not (Test-NameMatch $bare $ExcludeVars)
    }))

    # Filter variables by letter restriction
    if ($VarRenameLetters.Count -gt 0) {
        $allowed = [System.Collections.Generic.HashSet[char]]::new()
        foreach ($l in $VarRenameLetters) {
            if ($l -match '^[A-Za-z]$') {
                [void]$allowed.Add([char]::ToUpperInvariant([char]$l))
            }
        }
        $filtered = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($v in $userVars) {
            $bare = $v
            if ($bare -match '^\$[a-zA-Z]+:(.+)$') { $bare = $Matches[1] }
            else { $bare = $bare.TrimStart('$') }
            if ($bare.Length -eq 0) { continue }
            $first = [char]::ToUpperInvariant($bare[0])
            if ($allowed.Contains($first)) { [void]$filtered.Add($v) }
        }
        $userVars = $filtered
    }

    # Collision-avoidance set
    $blocked = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($tok in $t) {
        if ($null -eq $tok) { continue }
        if ($tok.Kind -eq 'Variable') {
            if (-not $userVars.Contains($tok.Text)) { [void]$blocked.Add($tok.Text) }
        }
    }

    # Short-name generator
    $script:nameCounter = 0
    function Get-NextShortName {
        param($Reserved)
        while ($true) {
            $n = $script:nameCounter
            $script:nameCounter++
            $name = ''
            $x = $n
            do {
                $name = [char]([int](97 + ($x % 26))) + $name
                $x = [math]::Floor($x / 26) - 1
            } while ($x -ge 0)
            if ($Reserved.Contains($name)) { continue }
            if ($blocked.Contains('$' + $name)) { continue }
            if ($blocked.Contains($name)) { continue }
            return $name
        }
    }

    # Build rename maps
    $funcRename = @{}
    foreach ($f in ($userFuncs | Sort-Object)) { $funcRename[$f] = Get-NextShortName $reservedFuncs }

    $varRename = @{}
    foreach ($v in ($userVars | Sort-Object)) {
        if ($v -match '^(\$[a-zA-Z]+):(.+)$') {
            $varRename[$v] = $Matches[1] + ':' + (Get-NextShortName $reservedVars)
        } else {
            $varRename[$v] = '$' + (Get-NextShortName $reservedVars)
        }
    }

    if ($ShowDiag) {
        Write-Host "[10] Function mappings ($($funcRename.Count)):"
        foreach ($k in ($funcRename.Keys | Sort-Object)) {
            Write-Host ("     {0} -> {1}" -f $k, $funcRename[$k])
        }
        Write-Host "[10] Variable mappings ($($varRename.Count)):"
        foreach ($k in ($varRename.Keys | Sort-Object)) {
            Write-Host ("     {0} -> {1}" -f $k, $varRename[$k])
        }
    }

    $edits = [System.Collections.Generic.List[object]]::new()

    # (a) Function name tokens
    foreach ($tok in $t) {
        if ($null -eq $tok) { continue }
        if ($tok.Kind -in 'Comment','StringLiteral','StringExpandable',
                           'HereStringLiteral','HereStringExpandable') { continue }
        if ($funcRename.ContainsKey($tok.Text)) {
            $edits.Add([pscustomobject]@{
                Start  = $tok.Extent.StartOffset
                Length = $tok.Extent.EndOffset - $tok.Extent.StartOffset
                Text   = $funcRename[$tok.Text]
            })
        }
    }

    # (b) Variable tokens
    foreach ($tok in $t) {
        if ($null -eq $tok) { continue }
        if ($tok.Kind -eq 'Variable' -and $varRename.ContainsKey($tok.Text)) {
            $edits.Add([pscustomobject]@{
                Start  = $tok.Extent.StartOffset
                Length = $tok.Extent.EndOffset - $tok.Extent.StartOffset
                Text   = $varRename[$tok.Text]
            })
        }
    }

    # (c) Variables inside expandable strings
    $expandables = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
    }, $true)
    foreach ($es in $expandables) {
        $nested = $es.FindAll({
            param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst]
        }, $true)
        foreach ($nv in $nested) {
            $raw = $nv.Extent.Text
            $isBraced = $raw.StartsWith('${') -and $raw.EndsWith('}')

            if ($isBraced) {
                $inner = $raw.Substring(2, $raw.Length - 3)
                if ($inner -match '^([a-zA-Z]+):(.+)$') {
                    $lookupKey = '$' + $Matches[1] + ':' + $Matches[2]
                    $scopePart = $Matches[1]
                } else {
                    $lookupKey = '$' + $inner
                    $scopePart = ''
                }
            } else {
                $lookupKey = $raw
                $scopePart = ''
                if ($raw -match '^\$([a-zA-Z]+):') { $scopePart = $Matches[1] }
            }

            if (-not $varRename.ContainsKey($lookupKey)) { continue }
            $target = $varRename[$lookupKey]
            $bareTarget = $target
            if ($bareTarget -match '^\$[a-zA-Z]+:(.+)$') { $bareTarget = $Matches[1] }
            else { $bareTarget = $bareTarget.TrimStart('$') }

            $emitted = if ($isBraced) {
                if ($scopePart) { '${' + $scopePart + ':' + $bareTarget + '}' }
                else            { '${' + $bareTarget + '}' }
            } else { $target }

            $edits.Add([pscustomobject]@{
                Start  = $nv.Extent.StartOffset
                Length = $nv.Extent.EndOffset - $nv.Extent.StartOffset
                Text   = $emitted
            })
        }
    }

    # (d) Function parameter names at call sites of user-defined functions
    $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($cmd in $cmds) {
        $cn = $cmd.GetCommandName()
        if (-not $cn -or -not $allFuncs.Contains($cn)) { continue }
        foreach ($el in $cmd.CommandElements) {
            if ($el -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            $varName = '$' + $el.ParameterName
            if (-not $varRename.ContainsKey($varName)) { continue }
            $new = $varRename[$varName]
            if ($new -match '^\$[a-zA-Z]+:(.+)$') { $new = $Matches[1] } else { $new = $new.TrimStart('$') }
            $edits.Add([pscustomobject]@{
                Start  = $el.Extent.StartOffset
                Length = $el.Extent.EndOffset - $el.Extent.StartOffset
                Text   = '-' + $new
            })
        }
    }

    $code = Invoke-Edits $code $edits

    # Safety net: any leftover ${Name} the AST walker missed
    foreach ($k in @($varRename.Keys)) {
        if ($k -match '^\$[a-zA-Z]+:') { continue }
        $bare = $k.TrimStart('$')
        $target = $varRename[$k].TrimStart('$')
        $pattern = '\$\{\s*' + [regex]::Escape($bare) + '\s*\}'
        $code = [regex]::Replace($code, $pattern, '${' + $target + '}')
    }

    Write-Diag "[10] Rename edits applied: $($edits.Count)"
} else {
    Write-Diag "[10] skipped (both func and var renames disabled)"
}

# ------------------------------------------------------------
# Step 11: Merge closing braces and keyword continuations
# ------------------------------------------------------------
if (-not $NoBraceMerge) {
    $contKeywords = @('catch','else','elseif','finally','until')

    Update-StringRanges $code
    $code = Invoke-TextPass -Text $code -Predicate {
        param($t, $i, $sb)
        if ($t[$i] -ne '}') { return $null }
        if (Test-InString $i) { return $null }
        $j = $i + 1
        while ($j -lt $t.Length -and $t[$j] -eq ' ') { $j++ }
        if ($j -eq $i + 1) { return $null }
        foreach ($kw in $contKeywords) {
            if ($j + $kw.Length -gt $t.Length) { continue }
            if ($t.Substring($j, $kw.Length) -ne $kw) { continue }
            $after = if ($j + $kw.Length -lt $t.Length) { $t[$j + $kw.Length] } else { '' }
            if ($after -match '[\s{(]' -or $after -eq '') {
                return [pscustomobject]@{ Consumed = $j - $i; Emit = '}' }
            }
        }
        return $null
    }

    # Multi-line: continuation-keyword lines merged onto previous }
    $lines = $code -split "`n"
    $merged = [System.Collections.Generic.List[string]]::new()
    foreach ($ln in $lines) {
        $trim = $ln.Trim()
        $isCont = $false
        foreach ($kw in $contKeywords) {
            if ($trim -match ('^' + [regex]::Escape($kw) + '\b')) {
                $isCont = $true; break
            }
        }
        if ($isCont -and $merged.Count -gt 0 -and
            $merged[$merged.Count - 1].TrimEnd().EndsWith('}')) {
            $merged[$merged.Count - 1] = $merged[$merged.Count - 1].TrimEnd() + $trim
            continue
        }
        if ($trim -eq '}' -and $merged.Count -gt 0 -and
            $merged[$merged.Count - 1].TrimEnd().EndsWith('}')) {
            $merged[$merged.Count - 1] = $merged[$merged.Count - 1].TrimEnd() + '}'
            continue
        }
        $merged.Add($ln)
    }
    $code = $merged -join "`n"
    Write-Diag "[11] Close-brace / keyword merges done"
} else { Write-Diag "[11] skipped" }

# ------------------------------------------------------------
# Step 12: Join lines ending with ( and lines starting with )
# Strings and comments are left alone.
# ------------------------------------------------------------
if (-not $NoParenJoin) {
    Update-StringRanges $code -IncludeComments
    $script:joined = 0
    $code = Invoke-TextPass -Text $code -Predicate {
        param($t, $i, $sb)
        if ($t[$i] -ne "`n" -or $i -eq 0 -or (Test-InString $i)) { return $null }
        $j = $i + 1
        while ($j -lt $t.Length -and $t[$j] -in ' ', "`t") { $j++ }
        if ($j -ge $t.Length -or (Test-InString ($i - 1))) { return $null }
        if ($t[$i - 1] -ne '(' -and ($t[$j] -ne ')' -or (Test-InString $j))) { return $null }
        $script:joined++
        return [pscustomobject]@{ Consumed = $j - $i; Emit = '' }
    }
    Write-Diag "[12] Lines joined around ( and ): $script:joined"
} else { Write-Diag "[12] skipped" }

# ------------------------------------------------------------
# Step 13: Final whitespace tidy
# ------------------------------------------------------------
if (-not $NoPunctuationSpacing) {
    $code = Invoke-PunctuationSpacing $code -Quiet
}

$lines = $code -split "`n"
$finalOut = [System.Collections.Generic.List[string]]::new()
foreach ($ln in $lines) {
    $trim = $ln.Trim()
    if ($trim -eq '') { continue }
    $trim = $trim -replace '  +', ' '
    $finalOut.Add($trim)
}
$code = $finalOut -join "`n"
Write-Diag "[13] Final whitespace tidy done"

# ------------------------------------------------------------
# Step 14: Compress .NET TypeDefinition blocks (runs last)
# ------------------------------------------------------------
if (-not $NoTypeDefMinify) {
    # Re-token the current text
    $tdTokens = $null; $tdErrs = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput(
        $code, [ref]$tdTokens, [ref]$tdErrs)

    # Find all here-string tokens
    $hereStringTokens = @()
    foreach ($t in $tdTokens) {
        if ($null -eq $t) { continue }
        if ($t.Kind -in 'HereStringLiteral','HereStringExpandable') {
            $hereStringTokens += $t
        }
    }
    Write-Diag "[14] Here-string tokens found: $($hereStringTokens.Count)"

    $edits = [System.Collections.Generic.List[object]]::new()
    foreach ($hs in $hereStringTokens) {
        $body = $hs.Extent.Text
        if ($body -notmatch '\b(class|struct|interface|enum)\b') { continue }

        if ($ShowDiag) {
            $preview = $body.Substring(0, [Math]::Min(60, $body.Length)) -replace "`r?`n", '\n'
            Write-Diag "     token at $($hs.Extent.StartOffset): $preview..."
        }

        $optBody = $body
        $optBody = $optBody -replace '\}\s*\r?\n\s*\}', '}}'
        $optBody = $optBody -replace '(?<![A-Za-z0-9_])(if|while|for|foreach|switch|catch|using|lock|fixed)\s+\(', '$1('
        $optBody = $optBody -replace '\)\s+\{', '){'
        $optBody = $optBody -replace ';[ \t]+', ';'
        $optBody = $optBody -replace '[ \t]*\?[ \t]*', '?'
        $optBody = $optBody -replace '[ \t]*:[ \t]*', ':'
        $optBody = $optBody -replace '[ \t]+\{', '{'
        $optBody = $optBody -replace '[ \t]*==[ \t]*', '=='
        $optBody = $optBody -replace '[ \t]*!=[ \t]*', '!='
        $optBody = $optBody -replace '[ \t]*=[ \t]*', '='
        $optBody = $optBody -replace ',[ \t]+', ','

        $edits.Add([pscustomobject]@{
            Start  = $hs.Extent.StartOffset
            Length = $hs.Extent.EndOffset - $hs.Extent.StartOffset
            Text   = $optBody
        })
    }
    $code = Invoke-Edits $code $edits
    Write-Diag "[14] TypeDefinition tokens minified: $($edits.Count)"
} else { Write-Diag "[14] skipped" }

# ------------------------------------------------------------
# Output
# ------------------------------------------------------------
if ($ShowOutput) {
    Write-Host ""
    Write-Host "===== FINAL OUTPUT ====="
    Write-Host $code
    Write-Host "===== END OUTPUT ====="
    Write-Host ""
}

$ansi = [System.Text.Encoding]::GetEncoding(1252)
$bytes = $ansi.GetBytes($code)
if ($ansi.GetString($bytes) -ne $code) {
    Write-Warning "Some characters cannot be encoded in Windows-1252; they were replaced."
}
[System.IO.File]::WriteAllBytes($OutPath, $bytes)

[pscustomobject]@{
    InputBytes  = (Get-Item $Path).Length
    OutputBytes = (Get-Item $OutPath).Length
    Result      = $code
}