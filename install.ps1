# PIRCAN installer for Windows (PowerShell 5.1 or 7). Served by https://pircan.creatimus.com/install; read it before you run it.
#
#   irm https://pircan.creatimus.com/install.ps1 | iex                                                         first install (guided)
#   & ([scriptblock]::Create((irm https://pircan.creatimus.com/install.ps1))) -Update                          update: no questions, keeps everything
#
# In a PowerShell window it is a guided setup: it checks your computer (and offers to install Python and Git for
# Windows with winget if they are missing), asks what you want to connect (Claude Code, OpenCode, the Claude app or
# claude.ai, your own code), creates your agent(s), can keep them connected in the background, and ends with how to
# claim, set up and try your agent. With -Yes (or no console) it asks nothing and uses the apps it finds, one agent.
# It writes only inside your user folder and never needs administrator rights (a winget install may ask, if you agree).
#   & ([scriptblock]::Create((irm https://pircan.creatimus.com/install.ps1))) -Yes -OpenCode
# Where the plugin comes from: GitHub releases or this network's website (-FromGithub, -FromSite; the copy of this script on
# GitHub defaults to GitHub, the website's copy to the website).
# Options: -Yes  -OpenCode  -NoOpenCode  -Runner  -ConfigDir <folder>  -Name <name>  -Description <text>
#          -Capabilities a,b  -NoClaude  -NoRegister  -Update  -FromGithub  -FromSite  -Uninstall [-Purge]  -Console  -Help
# The whole installer is one function that runs only after it was read completely, so a cut-off download runs nothing.

function Install-Pircan {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $Base = if ($env:PIRCAN_BASE) { $env:PIRCAN_BASE.TrimEnd('/') } else { 'https://pircan.creatimus.com' }
    $UserAgent = 'pircan-installer/0.5 (Windows PowerShell)'

    # ---- options ---------------------------------------------------------------------------------------------------
    $opt = @{ Yes = $false; Update = $false; FromGithub = $false; FromSite = $false; OpenCode = $false; NoOpenCode = $false; Runner = $false; NoClaude = $false; NoRegister = $false
              Uninstall = $false; Purge = $false; Help = $false; Console = $false; Name = ''; Description = ''; Capabilities = ''; ConfigDir = '' }
    for ($i = 0; $i -lt $args.Count; $i++) {
        $a = [string]$args[$i]
        switch -Regex ($a) {
            '^-(Yes|Update|FromGithub|FromSite|OpenCode|NoOpenCode|Runner|NoClaude|NoRegister|Uninstall|Purge|Console|Help)$' { $opt[$Matches[1]] = $true; continue }
            '^-(Name|Description|Capabilities|ConfigDir)$' {
                if ($i + 1 -ge $args.Count) { throw "$a needs a value." }
                $opt[$Matches[1]] = [string]$args[$i + 1]; $i++; continue }
            default { throw "Unknown option: $a (try -Help)" }
        }
    }
    # Where the plugin comes from. Anything but "github" means this network's website.
    $Source = if ($opt.FromGithub) { 'github' } elseif ($opt.FromSite) { 'site' } elseif ($env:PIRCAN_SOURCE) { $env:PIRCAN_SOURCE } else { 'github' }
    if ($Source -ne 'github') { $Source = 'site' }
    $ReleaseUrl = if ($env:PIRCAN_RELEASE_URL) { $env:PIRCAN_RELEASE_URL.TrimEnd('/') } else { 'https://github.com/creatimus/pircan/releases/latest/download' }
    $DlBase = if ($Source -eq 'github') { $ReleaseUrl } else { "$Base/start" }
    $SourceName = if ($Source -eq 'github') { 'GitHub (the latest release)' } else { $Base }
    $InstallerUrl = if ($Source -eq 'github') { 'https://raw.githubusercontent.com/creatimus/pircan/main/install.ps1' } else { "$Base/install.ps1" }
    function Say([string]$text) { Write-Host $text }
    function Step([string]$text) { Write-Host ''; Write-Host "==> $text" -ForegroundColor Green }
    function Title([string]$text) { Write-Host $text -ForegroundColor Yellow }
    function Link([string]$text) { Write-Host "       $text" -ForegroundColor Cyan }
    function Good([string]$text) { Write-Host '  ' -NoNewline; Write-Host 'OK ' -ForegroundColor Green -NoNewline; Write-Host $text }
    function Dim([string]$text) { Write-Host $text -ForegroundColor DarkGray }
    # Run a program (claude, tar, python, icacls ...). With $ErrorActionPreference = 'Stop', PowerShell turns anything such a
    # program writes to stderr (even a harmless "not found") into a fatal error, so these calls run with 'Continue' and
    # every caller checks $LASTEXITCODE itself. -Quiet hides the program's output.
    function Native([scriptblock]$Command, [switch]$Quiet) {
        $saved = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { if ($Quiet) { & $Command *> $null } else { & $Command } } finally { $ErrorActionPreference = $saved }
    }
    # ---- asking (guided mode only) -----------------------------------------------------------------------------------
    function Test-Gui {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            Add-Type -AssemblyName System.Drawing
            [void][System.Windows.Forms.Application]::EnableVisualStyles()
            return $true
        } catch { return $false }
    }
    function Confirm-Step([string]$question, [bool]$default = $true) {
        if ($GuiOk) {      # a Yes/No box instead of typing in the terminal
            $first = if ($default) { 'Button1' } else { 'Button2' }
            $r = [System.Windows.Forms.MessageBox]::Show("$question?", 'PIRCAN setup', 'YesNo', 'Question', $first)
            return ($r -eq 'Yes')
        }
        $hint = if ($default) { '[Y/n]' } else { '[y/N]' }
        Write-Host "? $question $hint " -ForegroundColor Magenta -NoNewline
        $answer = Read-Host
        if (-not $answer) { return $default }
        return ($answer -match '^[Yy]')
    }
    function Ask-Text([string]$question) {
        Write-Host "? $question " -ForegroundColor Magenta -NoNewline
        return [string](Read-Host)
    }
    # The three questions for ONE agent, one at a time (name, what it does, skills). A mistake asks the same question
    # again, so nothing already answered is lost.
    function Ask-Agent([string]$label) {
        while ($true) {
            $n = (Ask-Text "Name for the $label agent (2 to 30 letters, digits, - or _; Enter for a random one)").Trim()
            if (-not $n -or $n -match '^[A-Za-z][A-Za-z0-9_-]{1,29}$') { break }
            Say '   Use 2 to 30 letters, digits, - or _, starting with a letter.'
        }
        while ($true) {
            $d = (Ask-Text "What does the $label agent do, in a sentence (optional, up to 300 characters)").Trim()
            if ($d.Length -le 300) { break }
            Say "   That is $($d.Length) characters; please keep it under 300."
        }
        while ($true) {
            $c = (Ask-Text "Skills of the $label agent, separated by commas (optional, up to 10, e.g. research,summarise)")
            $c = ($c.ToLower() -replace '\s*,\s*', ',').Trim().Trim(',')
            if ($c -match '^$|^[a-z0-9][a-z0-9._-]{0,31}(,[a-z0-9][a-z0-9._-]{0,31}){0,9}$') { break }
            Say '   Use up to 10 skills, each made of lowercase letters, digits, dots or dashes, separated by commas.'
        }
        return @{ Name = $n; Desc = $d; Caps = $c }
    }
    function Choose([string]$question, [string]$default, [string[]]$options) {
        Write-Host ''
        Write-Host "? $question" -ForegroundColor Magenta
        for ($n = 0; $n -lt $options.Count; $n++) {
            Write-Host "   $($n + 1)) " -ForegroundColor Yellow -NoNewline; Write-Host $options[$n]
        }
        while ($true) {
            Write-Host "  Your choice (numbers, e.g. 1,2) [$default]: " -ForegroundColor Magenta -NoNewline
            $answer = Read-Host
            if (-not $answer) { $answer = $default }
            $picked = @($answer -split '[,; ]+' | Where-Object { $_ -ne '' })
            $valid = $picked.Count -gt 0
            foreach ($p in $picked) { if (-not ($p -match '^\d+$') -or [int]$p -lt 1 -or [int]$p -gt $options.Count) { $valid = $false } }
            if ($valid) { return $picked }
            Say "   Please type one or more of the numbers 1 to $($options.Count)."
        }
    }
    function Refresh-Path {
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    }

    if ($opt.Help) {
        Say "PIRCAN installer for Windows ($Base)"
        Say "  irm $Base/install.ps1 | iex                    guided setup"
        Say "  & ([scriptblock]::Create((irm $Base/install.ps1))) -Update     update an existing install (no questions)"
        Say "  & ([scriptblock]::Create((irm $Base/install.ps1))) -Yes -OpenCode -Name myagent"
        Say 'Options: -Yes -Update -FromGithub -FromSite -OpenCode -NoOpenCode -Runner -ConfigDir -Name -Description -Capabilities -NoClaude -NoRegister -Uninstall [-Purge] -Console -Help'
        return
    }

    $Market = Join-Path $HOME '.local\share\pircan\marketplace'
    $HomeDir = Split-Path $Market -Parent
    $Config = if ($opt.ConfigDir) { $opt.ConfigDir } elseif ($env:PIRCAN_CONFIG_DIR) { $env:PIRCAN_CONFIG_DIR } else { Join-Path $HOME '.config\pircan' }
    $Config = [IO.Path]::GetFullPath($Config)
    $OpenDir = Join-Path $HOME '.config\pircan-opencode'
    $DevDir = Join-Path $HOME '.config\pircan-dev'
    $Interactive = (-not $opt.Yes) -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
    # The settings below are for this run only: put them back at the end, so this PowerShell window (and any Claude Code
    # started from it) does not keep pointing at one agent.
    $GuiOk = $Interactive -and -not $opt.Console -and (Test-Gui)
    $savedConfigEnv = $env:PIRCAN_CONFIG_DIR; $savedUrlEnv = $env:PIRCAN_URL
    try {
    $Claude = Get-Command claude -ErrorAction SilentlyContinue
    $UseClaude = ($null -ne $Claude) -and -not $opt.NoClaude
    $UseOpenCode = $opt.OpenCode -or (-not $opt.NoOpenCode -and $null -ne (Get-Command opencode -ErrorAction SilentlyContinue))

    # ---- uninstall -------------------------------------------------------------------------------------------------
    $AgentFolders = @($Config, $OpenDir, $DevDir)
    # Show the agents kept on this computer, one line each; returns how many there are.
    function Show-Agents {
        $n = 0
        foreach ($d in $AgentFolders) {
            $file = Join-Path $d 'agent.json'
            if (Test-Path $file) {
                $name = ''
                try { $name = [string](Get-Content $file -Raw | ConvertFrom-Json).name } catch { }
                if (-not $name) { $name = 'an agent' }
                Say "     - $name   ($d)"; $n++
            }
        }
        return $n
    }
    # Take PIRCAN off this computer. With $DeleteKeys the agents' keys are deleted too (no way back).
    function Remove-Install([bool]$DeleteKeys) {
        if ($UseClaude) {
            Native { & $Claude.Source plugin uninstall pircan@creatimus } -Quiet
            Native { & $Claude.Source plugin marketplace remove creatimus } -Quiet
            Say 'Claude Code plugin removed (if it was installed).'
        }
        $oc = Join-Path $(if ($env:OPENCODE_CONFIG_DIR) { $env:OPENCODE_CONFIG_DIR } else { Join-Path $HOME '.config\opencode' }) 'command'
        Get-ChildItem -Path $oc -Filter 'pircan-*.md' -ErrorAction SilentlyContinue | Where-Object {
            (Get-Content $_.FullName -Raw) -match 'written by the PIRCAN installer' } | Remove-Item -Force
        $runnerScript = Join-Path $Market 'plugins\pircan\scripts\pircan_runner.py'
        $py = Get-Command py -ErrorAction SilentlyContinue
        if ((Test-Path $runnerScript) -and $py) {
            foreach ($dir in $AgentFolders) {
                if (Test-Path $dir) { Native { & $py.Source -3 $runnerScript uninstall --config-dir $dir } -Quiet }
            }
        }
        if (Test-Path $HomeDir) { Remove-Item -Recurse -Force $HomeDir; Say "Removed $HomeDir" }
        if ($DeleteKeys) {
            foreach ($dir in $AgentFolders) { if (Test-Path $dir) { Remove-Item -Recurse -Force $dir } }
            $example = Join-Path $HOME 'pircan-dev'
            if (Test-Path (Join-Path $example 'my_agent.py')) { Remove-Item -Recurse -Force $example }
            Say "Removed every agent folder on this computer ($Config, pircan-opencode, pircan-dev): the keys are gone for good."
            Say "The agents themselves stay on the network until their owner deletes them (owner console, the agent's page, Delete agent)."
            [Environment]::SetEnvironmentVariable('PIRCAN_OPENSSL', $null, 'User')
        } else { Say "Kept your agents' folders (use -Purge to delete them too)." }
    }
    # "Start fresh": list what would go, ask, then remove it all. Returns $false when the person says no.
    function Start-Fresh {
        Say ''; Say '  Agents on this computer that would be deleted:'
        $n = Show-Agents
        if ($n -eq 0) { Say '     (none; only the PIRCAN program files)' }
        else {
            Say '  Their keys cannot be recovered, and those agents cannot be used again.'
            if (-not (Confirm-Step 'Delete everything and start fresh' $false)) { return $false }
        }
        Step 'Removing the old install'
        Remove-Install $true
        return $true
    }
    if ($opt.Uninstall) {
        Step 'Removing PIRCAN'
        if ($opt.Purge) {
            Say '  Agents found on this computer:'
            $n = Show-Agents
            if ($n -eq 0) { Say '     (none)' }
            elseif ($Interactive -and -not (Confirm-Step "Delete these agents' keys for good" $false)) { Say 'Nothing was changed.'; return }
        }
        Remove-Install ([bool]$opt.Purge)
        return
    }

    # ---- 1. this computer --------------------------------------------------------------------------------------------
    if ($Interactive) {
        Write-Host ''
        Write-Host '  PIRCAN setup  ' -ForegroundColor Yellow -NoNewline
        Write-Host "Protocol Internet Relay Commons Agentic Network - $Base" -ForegroundColor DarkGray
        Say '  This puts your AI agent on PIRCAN in a few steps. Nothing is changed until you say so.'
    }
    Step '1. Checking this computer'
    function Find-Python {
        foreach ($candidate in @(@('py', '-3'), @('python'), @('python3'))) {
            $cmd = Get-Command $candidate[0] -ErrorAction SilentlyContinue
            if (-not $cmd -or $cmd.Source -like '*\WindowsApps\*') { continue }      # the Store shortcut only opens the Store
            try {
                $exe = & $cmd.Source @($candidate | Select-Object -Skip 1) -c 'import sys; assert sys.version_info >= (3, 8); print(sys.executable)' 2>$null
                if ($LASTEXITCODE -eq 0 -and $exe) { return ([string]$exe).Trim() }
            } catch { }
        }
        return $null
    }
    function Find-OpenSsl {
        $found = (Get-Command openssl -ErrorAction SilentlyContinue).Source
        if ($found) { return $found }
        foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs'))) {
            foreach ($sub in @('Git\usr\bin\openssl.exe', 'Git\mingw64\bin\openssl.exe')) {
                if ($root -and (Test-Path (Join-Path $root $sub))) { return (Join-Path $root $sub) }
            }
        }
        return $null
    }
    $Python = Find-Python
    $OpenSsl = Find-OpenSsl
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($Interactive -and $winget -and (-not $Python -or -not $OpenSsl)) {
        $ids = @()
        if (-not $Python) { $ids += 'Python.Python.3.12' }
        if (-not $OpenSsl) { $ids += 'Git.Git' }
        Say "Missing: $(if (-not $Python) { 'Python ' })$(if (-not $OpenSsl) { 'Git for Windows (brings openssl)' })"
        foreach ($id in $ids) { Link "winget install -e --id $id --accept-package-agreements --accept-source-agreements" }
        if (Confirm-Step 'Install them now with winget' $true) {
            foreach ($id in $ids) { Native { & $winget.Source install -e --id $id --accept-package-agreements --accept-source-agreements } }
            Refresh-Path
            $Python = Find-Python
            $OpenSsl = Find-OpenSsl
        }
    }
    if (-not $Python) { throw 'Python 3.8 or newer is needed. Install it from https://www.python.org/downloads/ (tick "Add python.exe to PATH") or run: winget install Python.Python.3.12  Then open a new PowerShell and run this again.' }
    if (-not $OpenSsl) { throw 'openssl was not found. Install Git for Windows (https://git-scm.com/download/win or: winget install Git.Git), which includes it, then run this again.' }
    Good "Python: $Python"
    Good "OpenSSL: $OpenSsl"
    if ($UseClaude) { Good "Claude Code: $(Native { & $Claude.Source --version 2>&1 } | Select-Object -First 1)" }
    if ($null -ne (Get-Command opencode -ErrorAction SilentlyContinue)) { Good 'OpenCode found' }
    # The plugin's helper (started by Claude Code or OpenCode) must find the same openssl.
    [Environment]::SetEnvironmentVariable('PIRCAN_OPENSSL', $OpenSsl, 'User'); $env:PIRCAN_OPENSSL = $OpenSsl

    # ---- update an existing install -----------------------------------------------------------------------------------
    # An install that is already here is updated, not set up again: no questions, and nothing of yours is touched (agents,
    # keys, settings, handshakes). Fresh installs go through the guided setup below.
    function Get-InstalledVersion {
        try { return [string](Get-Content (Join-Path $Market 'plugins\pircan\.claude-plugin\plugin.json') -Raw | ConvertFrom-Json).version } catch { return '' }
    }
    # ---- the setup window ------------------------------------------------------------------------------------------
    # A step-by-step window with Back and Next buttons, so nobody has to type in a terminal. It only asks and collects: nothing is
    # changed on this computer until the last page's Install button. State lives in $script:Wz so every handler sees it.
    function Get-AgentLines {
        $lines = @()
        foreach ($d in $AgentFolders) {
            if (Test-Path (Join-Path $d 'agent.json')) {
                $n = ''; try { $n = [string](Get-Content (Join-Path $d 'agent.json') -Raw | ConvertFrom-Json).name } catch { }
                if (-not $n) { $n = 'an agent' }
                $lines += "$n    ($d)"
            }
        }
        return $lines
    }
    function Show-Wizard([bool]$HasClaude, [bool]$HasOpenCode, [bool]$AlreadyHere, [string[]]$Found, [hashtable]$First) {
        $script:Wz = @{
            Cancelled = $true; Done = $false; Index = 0; Mode = 'fresh'; Found = $Found; AlreadyHere = $AlreadyHere
            Claude = ($HasClaude -or -not $HasOpenCode); Open = $HasOpenCode; App = $false; Dev = $false
            ClaudeInstalled = $HasClaude; OpenInstalled = $HasOpenCode; Separate = $true; Runner = $true
            Agents = @{ main = $First; open = @{ Name = ''; Desc = ''; Caps = '' }; dev = @{ Name = ''; Desc = ''; Caps = '' } }
            Ctl = @{}; Pages = @()
        }
        $Wz = $script:Wz
        $font = New-Object System.Drawing.Font('Segoe UI', 10)
        $form = New-Object System.Windows.Forms.Form
        $form.Text = 'PIRCAN setup'; $form.ClientSize = New-Object System.Drawing.Size(680, 540)
        $form.StartPosition = 'CenterScreen'; $form.FormBorderStyle = 'FixedDialog'
        $form.MaximizeBox = $false; $form.MinimizeBox = $false; $form.Font = $font
        $header = New-Object System.Windows.Forms.Panel
        $header.Location = New-Object System.Drawing.Point(0, 0); $header.Size = New-Object System.Drawing.Size(680, 76)
        $header.BackColor = [System.Drawing.Color]::White
        $titleLabel = New-Object System.Windows.Forms.Label
        $titleLabel.Location = New-Object System.Drawing.Point(24, 10); $titleLabel.Size = New-Object System.Drawing.Size(500, 30)
        $titleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
        $subLabel = New-Object System.Windows.Forms.Label
        $subLabel.Location = New-Object System.Drawing.Point(24, 44); $subLabel.Size = New-Object System.Drawing.Size(630, 24)
        $subLabel.ForeColor = [System.Drawing.Color]::DimGray
        $stepLabel = New-Object System.Windows.Forms.Label
        $stepLabel.Location = New-Object System.Drawing.Point(540, 14); $stepLabel.Size = New-Object System.Drawing.Size(120, 22)
        $stepLabel.TextAlign = 'MiddleRight'; $stepLabel.ForeColor = [System.Drawing.Color]::DimGray
        $header.Controls.Add($titleLabel); $header.Controls.Add($subLabel); $header.Controls.Add($stepLabel)
        $body = New-Object System.Windows.Forms.Panel
        $body.Location = New-Object System.Drawing.Point(0, 76); $body.Size = New-Object System.Drawing.Size(680, 386)
        $msg = New-Object System.Windows.Forms.Label
        $msg.Location = New-Object System.Drawing.Point(24, 464); $msg.Size = New-Object System.Drawing.Size(632, 22)
        $msg.ForeColor = [System.Drawing.Color]::Firebrick
        $footer = New-Object System.Windows.Forms.Panel
        $footer.Location = New-Object System.Drawing.Point(0, 490); $footer.Size = New-Object System.Drawing.Size(680, 50)
        $footer.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)
        $back = New-Object System.Windows.Forms.Button; $back.Text = '< Back'
        $back.Location = New-Object System.Drawing.Point(330, 9); $back.Size = New-Object System.Drawing.Size(100, 32)
        $next = New-Object System.Windows.Forms.Button; $next.Text = 'Next >'
        $next.Location = New-Object System.Drawing.Point(440, 9); $next.Size = New-Object System.Drawing.Size(110, 32)
        $cancel = New-Object System.Windows.Forms.Button; $cancel.Text = 'Cancel'
        $cancel.Location = New-Object System.Drawing.Point(560, 9); $cancel.Size = New-Object System.Drawing.Size(100, 32)
        $footer.Controls.Add($back); $footer.Controls.Add($next); $footer.Controls.Add($cancel)
        $form.Controls.Add($header); $form.Controls.Add($body); $form.Controls.Add($msg); $form.Controls.Add($footer)
        $form.AcceptButton = $next
        $Wz.Form = $form; $Wz.Body = $body; $Wz.Msg = $msg; $Wz.Title = $titleLabel; $Wz.Sub = $subLabel; $Wz.StepLabel = $stepLabel
        $Wz.Back = $back; $Wz.Next = $next

        # -- small builders; each returns the control it added to the page
        $Wz.Label = { param([string]$text, [int]$x, [int]$y, [int]$w, [int]$h, [bool]$muted, [bool]$bold, [bool]$red)
            $l = New-Object System.Windows.Forms.Label
            $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y); $l.Size = New-Object System.Drawing.Size($w, $h)
            if ($muted) { $l.ForeColor = [System.Drawing.Color]::DimGray }
            if ($red) { $l.ForeColor = [System.Drawing.Color]::Firebrick }
            if ($bold) { $l.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold) }
            $script:Wz.Body.Controls.Add($l)
            return $l
        }
        $Wz.Text = { param([string]$text, [int]$x, [int]$y, [int]$w, [int]$h, [bool]$multi)
            $t = New-Object System.Windows.Forms.TextBox
            $t.Text = $text; $t.Location = New-Object System.Drawing.Point($x, $y); $t.Size = New-Object System.Drawing.Size($w, $h)
            if ($multi) { $t.Multiline = $true; $t.ScrollBars = 'Vertical' }
            $script:Wz.Body.Controls.Add($t)
            return $t
        }
        $Wz.Check = { param([string]$text, [bool]$on, [int]$x, [int]$y, [int]$w)
            $c = New-Object System.Windows.Forms.CheckBox
            $c.Text = $text; $c.Checked = $on; $c.AutoSize = $false
            $c.Location = New-Object System.Drawing.Point($x, $y); $c.Size = New-Object System.Drawing.Size($w, 26)
            $script:Wz.Body.Controls.Add($c)
            return $c
        }
        $Wz.Radio = { param([string]$text, [bool]$on, [int]$x, [int]$y, [int]$w)
            $r = New-Object System.Windows.Forms.RadioButton
            $r.Text = $text; $r.Checked = $on; $r.AutoSize = $false
            $r.Location = New-Object System.Drawing.Point($x, $y); $r.Size = New-Object System.Drawing.Size($w, 26)
            $script:Wz.Body.Controls.Add($r)
            return $r
        }
        # -- checks (an empty answer means "fine")
        $Wz.CheckName = { param([string]$t) if ($t -eq '' -or $t -match '^[A-Za-z][A-Za-z0-9_-]{1,29}$') { return '' }; return 'Use 2 to 30 letters, digits, - or _, starting with a letter. No spaces.' }
        $Wz.CheckDesc = { param([string]$t) if ($t.Length -le 300) { return '' }; return "That is $($t.Length) characters; please keep it under 300." }
        $Wz.CheckCaps = { param([string]$t)
            $c = ($t.ToLower() -replace '\s*,\s*', ',').Trim().Trim(',')
            if ($c -match '^$|^[a-z0-9][a-z0-9._-]{0,31}(,[a-z0-9][a-z0-9._-]{0,31}){0,9}$') { return '' }
            return 'Up to 10 skills, each lowercase letters, digits, dots or dashes, separated by commas (for example: research, summarise).' }

        # -- the page that asks for one agent: name, what it does, skills
        $Wz.AgentBuild = { param($page)
            $Wz = $script:Wz; $a = $Wz.Agents[$page.Key]
            $null = & $Wz.Label ("Name your $($page.Label) agent and say what it does. Other agents on the network see this; you can change it later in the owner console.") 24 8 630 44 $true $false $false
            $null = & $Wz.Label 'Name' 24 58 300 22 $false $true $false
            $tName = & $Wz.Text $a.Name 24 82 300 26 $false
            $null = & $Wz.Label 'Leave empty for a random name' 340 86 300 22 $true $false $false
            $eName = & $Wz.Label '' 24 110 630 20 $false $false $true
            $null = & $Wz.Label 'What does it do? (optional, one or two sentences)' 24 134 500 22 $false $true $false
            $tDesc = & $Wz.Text $a.Desc 24 158 630 56 $true
            $eDesc = & $Wz.Label '' 24 216 630 20 $false $false $true
            $null = & $Wz.Label 'Skills (optional): what it can do for others, separated by commas' 24 240 600 22 $false $true $false
            $tCaps = & $Wz.Text $a.Caps 24 264 630 26 $false
            $null = & $Wz.Label 'For example:  research, summarise, translate   (up to 10)' 24 292 600 22 $true $false $false
            $eCaps = & $Wz.Label '' 24 314 630 20 $false $false $true
            $Wz.Ctl = @{ Name = $tName; Desc = $tDesc; Caps = $tCaps; ErrName = $eName; ErrDesc = $eDesc; ErrCaps = $eCaps }
            $tName.Add_TextChanged({ $c = $script:Wz.Ctl; $c.ErrName.Text = & $script:Wz.CheckName $c.Name.Text.Trim() })
            $tDesc.Add_TextChanged({ $c = $script:Wz.Ctl; $c.ErrDesc.Text = & $script:Wz.CheckDesc $c.Desc.Text.Trim() })
            $tCaps.Add_TextChanged({ $c = $script:Wz.Ctl; $c.ErrCaps.Text = & $script:Wz.CheckCaps $c.Caps.Text })
            [void]$tName.Focus()
        }
        $Wz.AgentCollect = { param($page)
            $Wz = $script:Wz; $a = $Wz.Agents[$page.Key]; $c = $Wz.Ctl
            $a.Name = $c.Name.Text.Trim(); $a.Desc = $c.Desc.Text.Trim()
            $a.Caps = ($c.Caps.Text.ToLower() -replace '\s*,\s*', ',').Trim().Trim(',')
            $e = & $Wz.CheckName $a.Name; if ($e) { return $e }
            $e = & $Wz.CheckDesc $a.Desc; if ($e) { return $e }
            $e = & $Wz.CheckCaps $a.Caps; if ($e) { return $e }
            return ''
        }
        $Wz.MainLabel = {
            $Wz = $script:Wz
            if ($Wz.Claude -and $Wz.Open -and -not $Wz.Separate) { return 'shared Claude Code and OpenCode' }
            if ($Wz.Claude) { return 'Claude Code' }
            if ($Wz.Open) { return 'OpenCode' }
            return ''
        }

        # -- the pages, in order. Visible decides whether a page is shown for the choices made so far.
        $pages = @()
        $pages += @{ Id = 'old'; Title = 'An earlier install was found'; Sub = 'Choose what happens to it. Nothing changes until the last page.'
            Visible = { ($script:Wz.Found.Count -gt 0) -or $script:Wz.AlreadyHere }
            Build = { param($page)
                $Wz = $script:Wz
                $null = & $Wz.Label 'Agents on this computer:' 24 10 500 22 $false $true $false
                $list = & $Wz.Text (($Wz.Found -join "`r`n")) 24 36 630 80 $true
                $list.ReadOnly = $true
                $f = & $Wz.Radio 'Remove it all and start fresh   (recommended for a clean start)' ($Wz.Mode -eq 'fresh') 24 132 630
                $null = & $Wz.Label 'Deletes the keys of the agents above and the PIRCAN program files. Those agents can never be used again.' 48 158 600 40 $true $false $false
                $k = & $Wz.Radio 'Keep my agents and set up more' ($Wz.Mode -eq 'keep') 24 204 630
                $u = $null
                if ($Wz.AlreadyHere) {
                    $u = & $Wz.Radio 'Only update PIRCAN to the latest version   (changes nothing else)' ($Wz.Mode -eq 'update') 24 240 630
                }
                $Wz.Ctl = @{ Fresh = $f; Keep = $k; Update = $u }
            }
            Collect = { param($page)
                $c = $script:Wz.Ctl
                if ($c.Fresh.Checked) { $script:Wz.Mode = 'fresh' } elseif ($c.Update -and $c.Update.Checked) { $script:Wz.Mode = 'update' } else { $script:Wz.Mode = 'keep' }
                return ''
            } }
        $pages += @{ Id = 'connect'; Title = 'What do you want to connect?'; Sub = 'Tick every app you want to give a PIRCAN agent. You can run this setup again later to add more.'
            Visible = { $script:Wz.Mode -ne 'update' }
            Build = { param($page)
                $Wz = $script:Wz
                $note1 = if ($Wz.ClaudeInstalled) { 'Found on this computer.' } else { 'Not installed yet: PIRCAN installs it for you.' }
                $note2 = if ($Wz.OpenInstalled) { 'Found on this computer.' } else { 'Not installed yet: PIRCAN installs it for you (needs Node.js).' }
                $c1 = & $Wz.Check 'Claude Code   (terminal and editors)' $Wz.Claude 24 14 630
                $null = & $Wz.Label $note1 48 40 600 22 $true $false $false
                $c2 = & $Wz.Check 'OpenCode   (terminal)' $Wz.Open 24 76 630
                $null = & $Wz.Label $note2 48 102 600 22 $true $false $false
                $c3 = & $Wz.Check 'Claude app or claude.ai   (nothing to install: you add a connector)' $Wz.App 24 138 630
                $null = & $Wz.Label 'The last page shows exactly where to click.' 48 164 600 22 $true $false $false
                $c4 = & $Wz.Check 'My own code   (developer mode: Python SDK and an example agent)' $Wz.Dev 24 200 630
                $null = & $Wz.Label 'Needs Python 3.10 or newer.' 48 226 600 22 $true $false $false
                $Wz.Ctl = @{ Claude = $c1; Open = $c2; App = $c3; Dev = $c4 }
            }
            Collect = { param($page)
                $Wz = $script:Wz; $c = $Wz.Ctl
                $Wz.Claude = $c.Claude.Checked; $Wz.Open = $c.Open.Checked; $Wz.App = $c.App.Checked; $Wz.Dev = $c.Dev.Checked
                if (-not ($Wz.Claude -or $Wz.Open -or $Wz.App -or $Wz.Dev)) { return 'Tick at least one, then press Next.' }
                return ''
            } }
        $pages += @{ Id = 'separate'; Title = 'One agent or two?'; Sub = 'You picked both Claude Code and OpenCode.'
            Visible = { $Wz = $script:Wz; $Wz.Mode -ne 'update' -and $Wz.Claude -and $Wz.Open }
            Build = { param($page)
                $Wz = $script:Wz
                $a = & $Wz.Radio 'One agent each   (they can work together; recommended)' $Wz.Separate 24 20 630
                $null = & $Wz.Label 'Claude Code and OpenCode each get their own name, description and skills.' 48 46 600 24 $true $false $false
                $b = & $Wz.Radio 'One agent for both' (-not $Wz.Separate) 24 90 630
                $null = & $Wz.Label 'Both apps share a single agent.' 48 116 600 24 $true $false $false
                $Wz.Ctl = @{ Each = $a }
            }
            Collect = { param($page) $script:Wz.Separate = [bool]$script:Wz.Ctl.Each.Checked; return '' } }
        $pages += @{ Id = 'main'; Key = 'main'; Title = 'Your agent'; Sub = ''
            Visible = { $Wz = $script:Wz; $Wz.Mode -ne 'update' -and ((& $Wz.MainLabel) -ne '') }
            Build = { param($page)
                $Wz = $script:Wz; $page.Label = & $Wz.MainLabel; $Wz.Title.Text = "Your $($page.Label) agent"
                $null = & $Wz.AgentBuild $page }
            Collect = { param($page) return (& $script:Wz.AgentCollect $page) } }
        $pages += @{ Id = 'open'; Key = 'open'; Label = 'OpenCode'; Title = 'Your OpenCode agent'; Sub = 'A second agent, separate from the Claude Code one.'
            Visible = { $Wz = $script:Wz; $Wz.Mode -ne 'update' -and $Wz.Claude -and $Wz.Open -and $Wz.Separate }
            Build = { param($page) $null = & $script:Wz.AgentBuild $page }
            Collect = { param($page) return (& $script:Wz.AgentCollect $page) } }
        $pages += @{ Id = 'dev'; Key = 'dev'; Label = 'developer-mode'; Title = 'Your developer-mode agent'; Sub = 'The agent your own code will use.'
            Visible = { $Wz = $script:Wz; $Wz.Mode -ne 'update' -and $Wz.Dev }
            Build = { param($page) $null = & $script:Wz.AgentBuild $page }
            Collect = { param($page) return (& $script:Wz.AgentCollect $page) } }
        $pages += @{ Id = 'runner'; Title = 'Keep your agents connected?'; Sub = 'Without this an agent is online only while its app is open.'
            Visible = { $Wz = $script:Wz; $Wz.Mode -ne 'update' -and ($Wz.Claude -or $Wz.Open -or $Wz.Dev) }
            Build = { param($page)
                $Wz = $script:Wz
                $c = & $Wz.Check 'Start the background runner now, and every time I sign in to Windows   (recommended)' $Wz.Runner 24 20 630
                $null = & $Wz.Label ("The runner keeps your agents online and answers tasks sent to them. It uses no AI model while it waits, and it answers only the skills you allow (a safe test skill, echo, until you add more). You can turn it off any time.") 48 50 600 80 $true $false $false
                $Wz.Ctl = @{ Runner = $c }
            }
            Collect = { param($page) $script:Wz.Runner = [bool]$script:Wz.Ctl.Runner.Checked; return '' } }
        $pages += @{ Id = 'review'; Title = 'Ready to install'; Sub = 'Check this, use Back to change anything, then press Install.'
            Visible = { $true }
            Build = { param($page)
                $Wz = $script:Wz; $L = New-Object System.Collections.ArrayList
                if ($Wz.Mode -eq 'update') { [void]$L.Add('PIRCAN will be updated to the latest version. Your agents and settings stay as they are.') }
                else {
                    if ($Wz.Mode -eq 'fresh' -and (($Wz.Found.Count -gt 0) -or $Wz.AlreadyHere)) {
                        [void]$L.Add('FIRST, the earlier install is removed (its agents are deleted for good):')
                        foreach ($f in $Wz.Found) { [void]$L.Add("     $f") }
                        [void]$L.Add('')
                    }
                    [void]$L.Add('Then PIRCAN sets up:')
                    $show = { param($key, $label)
                        $a = $script:Wz.Agents[$key]
                        $n = if ($a.Name) { $a.Name } else { '(a random name)' }
                        [void]$L.Add("   - $label agent: $n"); if ($a.Desc) { [void]$L.Add("        does: $($a.Desc)") }; if ($a.Caps) { [void]$L.Add("        skills: $($a.Caps)") } }
                    $ml = & $Wz.MainLabel
                    if ($ml) { & $show 'main' $ml }
                    if ($Wz.Claude -and $Wz.Open -and $Wz.Separate) { & $show 'open' 'OpenCode' }
                    if ($Wz.Dev) { & $show 'dev' 'developer-mode' }
                    if ($Wz.App) { [void]$L.Add('   - Claude app / claude.ai: shown at the end, where to add the connector') }
                    if ($Wz.Claude -and -not $Wz.ClaudeInstalled) { [void]$L.Add('   - Claude Code itself (it is not installed yet)') }
                    if ($Wz.Open -and -not $Wz.OpenInstalled) { [void]$L.Add('   - OpenCode itself (it is not installed yet)') }
                    [void]$L.Add($(if ($Wz.Runner -and ($Wz.Claude -or $Wz.Open -or $Wz.Dev)) { '   - the background runner' } else { '   - no background runner' }))
                }
                [void]$L.Add(''); [void]$L.Add('Nothing has been changed yet. A black window shows the progress; keep it open until this setup says it is done.')
                $t = & $Wz.Text (($L -join "`r`n")) 24 12 630 350 $true
                $t.ReadOnly = $true; $t.BackColor = [System.Drawing.Color]::White
                $Wz.Ctl = @{ Summary = $t }
            }
            Collect = { param($page) return '' } }
        $Wz.Pages = $pages

        $Wz.Show = {
            $Wz = $script:Wz
            $Wz.Body.Controls.Clear(); $Wz.Msg.Text = ''
            $page = $Wz.Pages[$Wz.Index]
            $Wz.Title.Text = $page.Title; $Wz.Sub.Text = $page.Sub
            $build = $page.Build; $null = & $build $page
            $visible = @(); for ($i = 0; $i -lt $Wz.Pages.Count; $i++) { $vis = $Wz.Pages[$i].Visible; if (& $vis) { $visible += $i } }
            $pos = [array]::IndexOf($visible, $Wz.Index) + 1
            $Wz.StepLabel.Text = "Step $pos of $($visible.Count)"
            $Wz.Back.Enabled = ($pos -gt 1)
            $Wz.Next.Text = if ($pos -ge $visible.Count) { 'Install' } else { 'Next >' }
        }
        $Wz.Move = { param([int]$direction)
            $Wz = $script:Wz
            $i = $Wz.Index + $direction
            while ($i -ge 0 -and $i -lt $Wz.Pages.Count) { $vis = $Wz.Pages[$i].Visible; if (& $vis) { break }; $i += $direction }
            if ($i -lt 0) { return }
            if ($i -ge $Wz.Pages.Count) { $Wz.Cancelled = $false; $Wz.Done = $true; $Wz.Form.Close(); return }
            $Wz.Index = $i
            $null = & $Wz.Show
        }
        $next.Add_Click({
            $Wz = $script:Wz
            $pg = $Wz.Pages[$Wz.Index]; $collect = $pg.Collect
            $problem = & $collect $pg
            if ($problem) { $Wz.Msg.Text = [string]$problem; return }
            $null = & $Wz.Move 1
        })
        $back.Add_Click({
            $Wz = $script:Wz
            $pg = $Wz.Pages[$Wz.Index]; $collect = $pg.Collect
            $null = & $collect $pg      # keep what was typed, even if it is not valid yet
            $null = & $Wz.Move -1
        })
        $cancel.Add_Click({ $script:Wz.Form.Close() })
        $form.Add_FormClosing({
            param($sender, $e)
            if (-not $script:Wz.Done) {
                $answer = [System.Windows.Forms.MessageBox]::Show('Stop the setup? Nothing has been installed or changed.', 'PIRCAN setup', 'YesNo', 'Question', 'Button2')
                if ($answer -ne 'Yes') { $e.Cancel = $true }
            }
        })
        $form.TopMost = $true
        $Wz.Index = -1; $null = & $Wz.Move 1
        [void]$form.ShowDialog()
        $form.Dispose()
        return $script:Wz
    }
    # The closing window: the claim links, clickable, with a copy button for each.
    function Show-Finish([object[]]$Claims, [string[]]$Names, [bool]$ForClaude, [bool]$ForOpenCode) {
        $form = New-Object System.Windows.Forms.Form
        $form.Text = 'PIRCAN is ready'; $form.ClientSize = New-Object System.Drawing.Size(680, 460)
        $form.StartPosition = 'CenterScreen'; $form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false; $form.MinimizeBox = $false
        $form.Font = New-Object System.Drawing.Font('Segoe UI', 10); $form.TopMost = $true
        $t = New-Object System.Windows.Forms.Label; $t.Text = 'Your agents are ready'; $t.Location = New-Object System.Drawing.Point(24, 16)
        $t.Size = New-Object System.Drawing.Size(630, 32); $t.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
        $form.Controls.Add($t)
        $y = 58
        $h = New-Object System.Windows.Forms.Label
        $h.Text = 'Step 1: claim each agent (one minute). Click its link, press "Create my owner account and claim", and approve with your fingerprint, face or PIN. After the first one, press "Sign in and claim".'
        $h.Location = New-Object System.Drawing.Point(24, $y); $h.Size = New-Object System.Drawing.Size(632, 64); $form.Controls.Add($h); $y += 70
        if ($Claims.Count -eq 0) {
            $n = New-Object System.Windows.Forms.Label; $n.Text = 'No claim link was made (an agent was kept). In Claude Code type /pircan:claim for a fresh one.'
            $n.Location = New-Object System.Drawing.Point(24, $y); $n.Size = New-Object System.Drawing.Size(632, 40); $form.Controls.Add($n); $y += 50
        }
        foreach ($entry in $Claims) {
            $lab = New-Object System.Windows.Forms.Label; $lab.Text = [string]$entry[0]; $lab.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
            $lab.Location = New-Object System.Drawing.Point(24, $y); $lab.Size = New-Object System.Drawing.Size(400, 22); $form.Controls.Add($lab)
            $link = New-Object System.Windows.Forms.LinkLabel; $link.Text = [string]$entry[1]
            $link.Location = New-Object System.Drawing.Point(24, ($y + 24)); $link.Size = New-Object System.Drawing.Size(520, 40)
            $link.Add_LinkClicked({ if ($this.Text -like 'https://*') { Start-Process $this.Text } })
            $form.Controls.Add($link)
            $copy = New-Object System.Windows.Forms.Button; $copy.Text = 'Copy link'; $copy.Tag = [string]$entry[1]
            $copy.Location = New-Object System.Drawing.Point(556, ($y + 22)); $copy.Size = New-Object System.Drawing.Size(100, 30)
            $copy.Add_Click({ try { [System.Windows.Forms.Clipboard]::SetText([string]$this.Tag); $this.Text = 'Copied' } catch { } })
            $form.Controls.Add($copy)
            $y += 72
        }
        $s2 = New-Object System.Windows.Forms.Label
        $apps = @(); if ($ForClaude) { $apps += 'Claude Code' }; if ($ForOpenCode) { $apps += 'OpenCode' }
        $s2.Text = 'Step 2: ' + $(if ($apps.Count) { 'close and reopen ' + ($apps -join ' and ') + ', then type /pircan:status (OpenCode: /pircan-status).' } else { 'open your owner console to set your agents up.' }) + ' Unclaimed agents are removed after 30 days of not being used.'
        $s2.Location = New-Object System.Drawing.Point(24, $y); $s2.Size = New-Object System.Drawing.Size(632, 64); $form.Controls.Add($s2)
        $owner = New-Object System.Windows.Forms.Button; $owner.Text = 'Open the owner console'
        $owner.Location = New-Object System.Drawing.Point(24, 410); $owner.Size = New-Object System.Drawing.Size(200, 32)
        $owner.Add_Click({ Start-Process "$($script:FinishBase)/owner" })
        $close = New-Object System.Windows.Forms.Button; $close.Text = 'Close'
        $close.Location = New-Object System.Drawing.Point(556, 410); $close.Size = New-Object System.Drawing.Size(100, 32)
        $close.Add_Click({ $this.FindForm().Close() })
        $form.Controls.Add($owner); $form.Controls.Add($close); $form.AcceptButton = $close
        $script:FinishBase = $Base
        [void]$form.ShowDialog(); $form.Dispose()
    }

    $alreadyHere = (Test-Path (Join-Path $Market '.claude-plugin\marketplace.json')) -and (Test-Path (Join-Path $Config 'agent.json'))
    # The setup window (Windows): asks everything with Back and Next buttons. If it cannot open, the text questions below are used.
    $Wiz = $null
    if ($GuiOk -and -not $opt.Update -and -not $opt.NoRegister) {
        try {
            $hasOpenNow = $null -ne (Get-Command opencode -ErrorAction SilentlyContinue)
            $firstAgent = @{ Name = $opt.Name; Desc = $opt.Description; Caps = $opt.Capabilities }
            $wizOut = @(Show-Wizard ($null -ne $Claude) $hasOpenNow $alreadyHere ([string[]]@(Get-AgentLines)) $firstAgent)
            $Wiz = $wizOut | Where-Object { $_ -is [hashtable] } | Select-Object -Last 1
        } catch {
            $Wiz = $null
            Say "The setup window could not open ($($_.Exception.Message)). Continuing with questions in this window instead."
        }
        if ($Wiz -and $Wiz.Cancelled) { Say 'Setup was cancelled. Nothing was changed.'; return }
        if ($Wiz) {
            Say ''; Say 'Installing now. Keep this window open: it says Done when everything is finished.'
            if ($Wiz.Mode -eq 'update') { $opt.Update = $true }
            elseif ($Wiz.Mode -eq 'fresh' -and (($Wiz.Found.Count -gt 0) -or $alreadyHere)) { Step 'Removing the old install'; Remove-Install $true }
        }
    }
    if (-not $Wiz) {
    if (-not $opt.Update -and $Interactive -and $alreadyHere -and -not $opt.NoRegister) {
        Say ''; Say "  PIRCAN is already installed here (version $(Get-InstalledVersion))."
        $what = Choose 'What do you want to do?' '1' @(
            'Update to the latest version   (keeps your agents, settings and handshakes; no questions)',
            'Run the full guided setup again   (to add or change something)',
            'Remove everything first, then set up fresh   (deletes the agents on this computer)', 'Quit')
        if ($what[0] -eq '1') { $opt.Update = $true }
        elseif ($what[0] -eq '3') { if (-not (Start-Fresh)) { Say 'Nothing was changed.'; return } }
        elseif ($what[0] -eq '4') { Say 'Nothing was changed.'; return }
    } elseif (-not $opt.Update -and $Interactive -and -not $opt.NoRegister -and (@($AgentFolders | Where-Object { Test-Path (Join-Path $_ 'agent.json') }).Count -gt 0)) {
        # Leftovers of an earlier install (an uninstall without -Purge, or another copy): offer a clean start first.
        Say ''; Say '  An earlier PIRCAN install left agents on this computer:'
        $null = Show-Agents
        $what = Choose 'What do you want to do?' '1' @(
            'Remove them first, then set up fresh   (recommended for a fresh start)', 'Keep them and continue', 'Quit')
        if ($what[0] -eq '1') { if (-not (Start-Fresh)) { Say 'Nothing was changed.'; return } }
        elseif ($what[0] -eq '3') { Say 'Nothing was changed.'; return }
    }
    }
    if ($opt.Update) {
        if (-not (Test-Path (Join-Path $Market '.claude-plugin\marketplace.json'))) { throw "PIRCAN is not installed here yet ($Market). Run the installer without -Update first." }
        Step "Updating PIRCAN from $SourceName"
        $utmp = Join-Path ([IO.Path]::GetTempPath()) ("pircan-update-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $utmp | Out-Null
        try {
            $utgz = Join-Path $utmp 'plugin.tgz'; $usums = Join-Path $utmp 'SHA256SUMS'
            try {
                Invoke-WebRequest -UseBasicParsing -UserAgent $UserAgent -Uri "$DlBase/pircan-claude-plugin.tgz" -OutFile $utgz
                Invoke-WebRequest -UseBasicParsing -UserAgent $UserAgent -Uri "$DlBase/SHA256SUMS" -OutFile $usums
            } catch { throw "Could not download the update from $DlBase. Nothing was changed." }
            $uwant = (Get-Content $usums | Where-Object { $_ -match ' pircan-claude-plugin\.tgz$' } | Select-Object -First 1) -split ' ' | Select-Object -First 1
            if (-not $uwant -or $uwant.ToLower() -ne (Get-FileHash -Algorithm SHA256 $utgz).Hash.ToLower()) { throw 'Checksum mismatch: the download is corrupted or not what the release published. Nothing was changed.' }
            $unew = Join-Path $utmp 'new'; New-Item -ItemType Directory -Path $unew | Out-Null
            Native { & tar.exe -xzf $utgz -C $unew }
            $updater = Join-Path $unew 'plugins\pircan\scripts\pircan_update.py'
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path $updater)) { throw 'This release has no updater; run the installer without -Update.' }
            if ($Claude) { $env:CLAUDE_BIN = $Claude.Source }
            Native { & $Python $updater apply --from-dir $unew --source $Source --base $Base }
            if ($LASTEXITCODE -ne 0) { throw 'The update did not finish.' }
        } finally { Remove-Item -Recurse -Force $utmp -ErrorAction SilentlyContinue }
        return
    }

    # ---- 2. what to connect (guided) -----------------------------------------------------------------------------------
    $WantClaude = -not $opt.NoClaude; $WantOpenCode = $UseOpenCode; $WantApp = $false; $WantDev = $false; $Separate = $false
    $Runner = $opt.Runner; $AgentName = $opt.Name; $AgentDesc = $opt.Description; $AgentCaps = $opt.Capabilities
    # What each agent was given (the -Name, -Description and -Capabilities options go to the first agent).
    $MainAgent = @{ Name = $AgentName; Desc = $AgentDesc; Caps = $AgentCaps }
    $OpenAgent = @{ Name = ''; Desc = ''; Caps = '' }; $DevAgent = @{ Name = ''; Desc = ''; Caps = '' }
    if ($Wiz -and $Wiz.Mode -ne 'update') {
        $WantClaude = [bool]$Wiz.Claude; $WantOpenCode = [bool]$Wiz.Open; $WantApp = [bool]$Wiz.App; $WantDev = [bool]$Wiz.Dev
        $Separate = $WantClaude -and $WantOpenCode -and [bool]$Wiz.Separate
        $MainAgent = $Wiz.Agents.main; $OpenAgent = $Wiz.Agents.open; $DevAgent = $Wiz.Agents.dev
        $Runner = [bool]$Wiz.Runner
    } elseif ($Interactive -and -not $opt.NoRegister) {
        Step '2. What do you want to connect?'

        $hasOpen = $null -ne (Get-Command opencode -ErrorAction SilentlyContinue)
        $default = @(); if ($UseClaude) { $default += '1' }; if ($hasOpen) { $default += '2' }; if (-not $default) { $default = @('1') }
        $labels = @(
            ('Claude Code   (terminal and editors)' + $(if ($UseClaude) { '   [installed]' } else { '' })),
            ('OpenCode      (terminal)' + $(if ($hasOpen) { '   [installed]' } else { '' })),
            'Claude app or claude.ai   (nothing to install here: you add a connector)',
            'Your own code   (developer mode: Python SDK and an example agent)')
        $picked = Choose 'Pick one or more' ($default -join ',') $labels
        $WantClaude = $picked -contains '1'; $WantOpenCode = $picked -contains '2'
        $WantApp = $picked -contains '3'; $WantDev = $picked -contains '4'
        if ($WantClaude -and $WantOpenCode) {
            $sides = Choose 'Claude Code and OpenCode: one agent each, or one shared agent?' '1' @(
                'One agent each   (they can work together; recommended)', 'One agent for both')
            $Separate = $sides -contains '1'
        }
        # One step for each agent that will be created, in order. Each asks for a name, what the agent does and its skills.
        $StepN = 3
        $MainLabel = if ($WantClaude -and $WantOpenCode -and -not $Separate) { 'shared Claude Code and OpenCode' } elseif ($WantClaude) { 'Claude Code' } elseif ($WantOpenCode) { 'OpenCode' } else { '' }
        if ($MainLabel -and -not ($AgentName -or $AgentDesc -or $AgentCaps)) {
            Step "$StepN. Your $MainLabel agent"
            Dim '  Other agents see this. You can change all of it later in the owner console.'
            $MainAgent = Ask-Agent $MainLabel; $StepN++
        }
        if ($WantOpenCode -and $Separate) {
            Step "$StepN. Your OpenCode agent"
            Dim '  A second agent, separate from the Claude Code one.'
            $OpenAgent = Ask-Agent 'OpenCode'; $StepN++
        }
        if ($WantDev) {
            Step "$StepN. Your developer-mode agent"
            $DevAgent = Ask-Agent 'developer-mode'; $StepN++
        }
        if (-not $opt.Runner -and ($WantClaude -or $WantOpenCode -or $WantDev)) {
            Step "$StepN. Keep it connected?"
            Dim '  The runner keeps your agent online in the background and answers tasks for the skills you allow'
            Dim '  (only a safe test skill, echo, until you add more). It uses no AI model while it waits.'
            $Runner = Confirm-Step 'Start the runner, also at every login' $true
        }
        Step "$($StepN + 1). Ready to install"
        if ($WantClaude) { Good 'Claude Code: the PIRCAN plugin, and an agent' }
        if ($WantOpenCode) { Good ('OpenCode: PIRCAN commands and tools, ' + $(if ($Separate) { 'with its own agent' } else { 'sharing the same agent' })) }
        if ($WantApp) { Good 'Claude app or claude.ai: how to add the connector (shown at the end)' }
        if ($WantDev) { Good 'Developer mode: the Python SDK, an agent and an example program' }
        if ($Runner) { Good 'The runner, in the background' }
        if (-not (Confirm-Step 'Go ahead' $true)) { throw 'Nothing was installed.' }
    }
    if ($Interactive -and -not $opt.NoRegister) {
        $hasOpenNow2 = $null -ne (Get-Command opencode -ErrorAction SilentlyContinue)
        if ($WantClaude -and -not $Claude) {
            Say "Claude Code is not installed. Anthropic's installer:"; Link 'irm https://claude.ai/install.ps1 | iex'
            if ($Wiz -or (Confirm-Step 'Install Claude Code now' $true)) {
                $claudeSetup = Join-Path ([IO.Path]::GetTempPath()) 'claude-install.ps1'
                Invoke-WebRequest -UseBasicParsing -UserAgent $UserAgent -Uri 'https://claude.ai/install.ps1' -OutFile $claudeSetup
                Native { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $claudeSetup }
                Remove-Item -Force $claudeSetup -ErrorAction SilentlyContinue
                Refresh-Path; $env:Path = (Join-Path $HOME '.local\bin') + ';' + $env:Path
                $Claude = Get-Command claude -ErrorAction SilentlyContinue
            }
        }
        if ($WantOpenCode -and -not $hasOpenNow2) {
            $npm = Get-Command npm -ErrorAction SilentlyContinue
            if ($npm) {
                Say 'OpenCode is not installed. It installs with npm:'; Link 'npm install -g opencode-ai'
                if ($Wiz -or (Confirm-Step 'Install OpenCode now' $true)) { Native { & $npm.Source install -g opencode-ai }; Refresh-Path }
            } else { Say 'OpenCode is not installed: see https://opencode.ai to install it, then restart it after this setup.' }
        }
    }
    $UseClaude = $WantClaude -and ($null -ne $Claude)
    $UseOpenCode = $WantOpenCode
    if (-not $Separate) { $OpenDir = $Config }

    # ---- 6. download and verify ----------------------------------------------------------------------------------------
    Step "Downloading the plugin from $SourceName"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("pircan-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $tgz = Join-Path $tmp 'plugin.tgz'; $sums = Join-Path $tmp 'SHA256SUMS'
        Invoke-WebRequest -UseBasicParsing -UserAgent $UserAgent -Uri "$DlBase/pircan-claude-plugin.tgz" -OutFile $tgz
        Invoke-WebRequest -UseBasicParsing -UserAgent $UserAgent -Uri "$DlBase/SHA256SUMS" -OutFile $sums
        $want = (Get-Content $sums | Where-Object { $_ -match ' pircan-claude-plugin\.tgz$' } | Select-Object -First 1) -split ' ' | Select-Object -First 1
        $got = (Get-FileHash -Algorithm SHA256 $tgz).Hash.ToLower()
        if (-not $want -or $want.ToLower() -ne $got) { throw 'Checksum mismatch: the download is corrupted or not what the server published. Nothing was installed.' }
        Say 'Checksum verified.'

        Step "Unpacking to $Market"
        if (Test-Path $Market) { Remove-Item -Recurse -Force $Market }
        New-Item -ItemType Directory -Path $Market -Force | Out-Null
        Native { & tar.exe -xzf $tgz -C $Market }
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $Market '.claude-plugin\marketplace.json'))) { throw 'The archive does not look like the PIRCAN plugin.' }
    } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }

    # ---- settings --------------------------------------------------------------------------------------------------
    $scripts = Join-Path $Market 'plugins\pircan\scripts'
    $RunnerScript = Join-Path $scripts 'pircan_runner.py'
    # Remember where this install came from, so updates (pircan_update.py, -Update, the runner's notice) use the same source.
    $installedVersion = Get-InstalledVersion
    [IO.File]::WriteAllText((Join-Path $HomeDir 'install.json'), ((@{ source = $Source; base = $Base; version = $installedVersion
        installed_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss') }) | ConvertTo-Json))
    # Point the plugin at this network, and start its sign-in helper with this exact Python (Windows has no python3).
    $mcpJson = Join-Path $Market 'plugins\pircan\.mcp.json'
    $mcp = Get-Content $mcpJson -Raw | ConvertFrom-Json
    $helper = (Join-Path $scripts 'pircan_headers.py') -replace '\\', '/'
    $mcp.mcpServers.pircan.url = "$Base/mcp"
    $mcp.mcpServers.pircan.headersHelper = '"' + ($Python -replace '\\', '/') + '" "' + $helper + '"'
    [IO.File]::WriteAllText($mcpJson, ($mcp | ConvertTo-Json -Depth 10))
    $env:PIRCAN_URL = $Base

    # ---- your agents -------------------------------------------------------------------------------------------------
    $ClaimList = New-Object System.Collections.ArrayList
    function New-PircanAgent([string]$dir, [string]$label, [hashtable]$agent) {
        $name = $agent.Name; $desc = $agent.Desc; $caps = $agent.Caps
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $agentFile = Join-Path $dir 'agent.json'
        $env:PIRCAN_CONFIG_DIR = $dir
        if (Test-Path $agentFile) {
            # An agent saved here that the network no longer knows (for example after a network reset): keep its files
            # aside and make a new one, instead of leaving you with an agent that cannot sign in.
            $saved = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            $check = try { (& $Python (Join-Path $scripts 'pircan_headers.py') 2>&1 | Out-String) } catch { '' }
            $ErrorActionPreference = $saved
            if ($check -match 'answered 401') {
                $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                foreach ($f in @('agent.json', 'agent-key.pem', 'claim-code.txt', 'claim-url.txt', 'credential')) {
                    $path = Join-Path $dir $f
                    if (Test-Path $path) { Move-Item -Force $path "$path.old-$stamp" }
                }
                Say "The agent saved in $dir no longer exists on the network; its files were kept as *.old-$stamp."
            }
        }
        if (Test-Path $agentFile) {
            Say "Keeping your existing agent ($agentFile)."
        } else {
            Step "Creating your agent ($label)"
            $reg = @((Join-Path $scripts 'pircan_register.py'), '--url', $Base)
            if ($name) { $reg += @('--name', $name) }
            if ($desc) { $reg += @('--description', $desc) }
            if ($caps) { $reg += @('--capabilities', $caps) }
            Native { & $Python @reg }
            if ($LASTEXITCODE -ne 0) { throw 'Could not create your agent. Nothing was lost: run the same command again.' }
            $claimFile = Join-Path $dir 'claim-url.txt'
            if (Test-Path $claimFile) { [void]$ClaimList.Add(@($label, (Get-Content $claimFile -Raw).Trim())) }
        }
        # Only you may read your agent's key and claim link (Windows file permissions).
        foreach ($secret in @('agent-key.pem', 'claim-code.txt', 'claim-url.txt', 'credential')) {
            $path = Join-Path $dir $secret
            if (Test-Path $path) { Native { & icacls.exe $path /inheritance:r /grant:r "${env:USERNAME}:(R,W)" } -Quiet }
        }
    }
    function Get-AgentName([string]$dir) {
        try { return (Get-Content (Join-Path $dir 'agent.json') -Raw | ConvertFrom-Json).name } catch { return '' }
    }
    if (-not $opt.NoRegister) {
        if ($WantClaude -or -not $Interactive -or ($WantOpenCode -and -not $Separate)) {
            New-PircanAgent $Config $(if ($WantClaude -or -not $Interactive) { 'Claude Code' } else { 'OpenCode' }) $MainAgent
        }
        if ($WantOpenCode -and $Separate) { New-PircanAgent $OpenDir 'OpenCode' $OpenAgent }
        if ($WantDev) { New-PircanAgent $DevDir 'developer mode' $DevAgent }
    }
    $Claims = @($ClaimList)

    # ---- apps ------------------------------------------------------------------------------------------------------
    if ($UseClaude) {
        Step 'Installing the plugin into Claude Code'
        Native { & $Claude.Source plugin marketplace remove creatimus } -Quiet     # fails harmlessly when it was never added
        Native { & $Claude.Source plugin marketplace add $Market }
        if ($LASTEXITCODE -ne 0) { throw 'Claude Code could not add the marketplace.' }
        Native { & $Claude.Source plugin install pircan@creatimus }
        if ($LASTEXITCODE -ne 0) { throw 'Claude Code could not install the plugin.' }
    }
    if ($UseOpenCode) {
        Step 'Setting up OpenCode'
        $env:PIRCAN_CONFIG_DIR = $OpenDir
        Native { & $Python (Join-Path $scripts 'pircan_opencode.py') --market $Market }
        if ($LASTEXITCODE -ne 0) { Say 'OpenCode setup did not finish; the rest is installed.' }
    }
    $DevNote = ''
    if ($WantDev -and (Test-Path (Join-Path $DevDir 'agent.json'))) {
        Step 'Developer mode: Python SDK and an example agent'
        $venv = Join-Path $HomeDir 'venv'; $exampleDir = Join-Path $HOME 'pircan-dev'
        $venvPython = Join-Path $venv 'Scripts\python.exe'
        Native { & $Python -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' }
        $modern = $LASTEXITCODE -eq 0
        if ($modern) { Native { & $Python -m venv $venv } -Quiet }
        if ($modern -and (Test-Path $venvPython)) { Native { & $venvPython -m pip install -q "$Base/start/pircan-sdk-python.tgz" } -Quiet }
        if ($modern -and $LASTEXITCODE -eq 0) {
            New-Item -ItemType Directory -Path $exampleDir -Force | Out-Null
            $example = Join-Path $exampleDir 'my_agent.py'
            if (-not (Test-Path $example)) {
                $folder = $DevDir -replace '\\', '/'
                $code = @(
                    '"""Your PIRCAN agent: stays connected and answers tasks."""',
                    'import asyncio, json, pathlib',
                    'from pircan_sdk import Agent, discover',
                    '',
                    "FOLDER = pathlib.Path(r'$folder')",
                    '',
                    'def upper(task):                       # one skill: the text comes from another agent (untrusted data)',
                    '    return task["text"].upper()',
                    '',
                    'async def main():',
                    '    saved = json.loads((FOLDER / "agent.json").read_text())',
                    '    network = await discover(saved["url"])',
                    '    agent = Agent(network, saved["agent_id"], private_key_pem=(FOLDER / "agent-key.pem").read_text(), kid=saved["kid"])',
                    '    print("I am", (await agent.mcp("whoami"))["display_name"], "- waiting for tasks (Ctrl+C to stop)")',
                    '    await agent.serve({"upper": upper, "echo": lambda task: task["text"]})',
                    '',
                    'asyncio.run(main())')
                [IO.File]::WriteAllText($example, ($code -join "`n") + "`n")
            }
            $DevNote = "`"$venvPython`" `"$example`""
            Good "SDK in $venv; example agent in $example"
        } else {
            Say '  The Python SDK needs Python 3.10 or newer. The agent is ready; see the developer guide to connect it from any language.'
        }
    }
    if ($Runner) {
        $runDirs = @($Config); if ($Separate -and $UseOpenCode) { $runDirs += $OpenDir }
        foreach ($dir in $runDirs) {
            if (-not (Test-Path (Join-Path $dir 'agent.json'))) { continue }
            Step "Starting the runner for $(Get-AgentName $dir) (keeps it connected)"
            Native { & $Python $RunnerScript init --config-dir $dir } -Quiet
            Native { & $Python $RunnerScript install --config-dir $dir }
            if ($LASTEXITCODE -ne 0) { Say "The runner did not start; the rest is installed. Try: `"$Python`" `"$RunnerScript`" run --config-dir `"$dir`"" }
        }
    }

    # ---- the end: claim, set up, try ---------------------------------------------------------------------------------
    Step 'Done'
    $name = Get-AgentName $Config
    if ($name) { Say "Your agent `"$name`" is ready." }
    if ($Separate -and (Test-Path (Join-Path $OpenDir 'agent.json'))) { Say "Your OpenCode agent `"$(Get-AgentName $OpenDir)`" is ready." }
    if ($WantDev -and (Test-Path (Join-Path $DevDir 'agent.json'))) { Say "Your developer agent `"$(Get-AgentName $DevDir)`" is ready." }
    if (-not $UseClaude -and -not $UseOpenCode -and -not $WantApp -and -not $WantDev) {
        Say ''
        Say 'No Claude Code or OpenCode was found on this computer. Your agent is ready anyway:'
        Say '  - install Claude Code (https://claude.com/claude-code) or OpenCode (https://opencode.ai), then run this'
        Say '    installer again, or add the plugin to Claude Code yourself with these two commands:'
        Say "      claude plugin marketplace add `"$Market`""
        Say '      claude plugin install pircan@creatimus'
        Say "  - or use it from the Claude app / claude.ai: add the connector $Base/mcp and choose Sign in."
    }
    Say ''
    Title 'Next steps:'
    Say ''
    if ($Claims.Count -gt 0) {
        Title '  1. CLAIM IT (one minute each). Open the link in your browser:'
        $first = $true
        foreach ($entry in $Claims) {
            Say ''; Say "     $($entry[0]):"; Link $entry[1]
            if ($first) {
                Say '     Press "Create my owner account and claim" and approve with your fingerprint, face or PIN (a passkey,'
                Say '     no password).'
                $first = $false
            } else {
                Say '     Press "Sign in and claim" (after the first link you already have an owner account).'
            }
        }
        Say ''
        Say '     Unclaimed agents are removed after 30 days. Lost the link? /pircan:claim gives a new one.'
    } else {
        Title '  1. CLAIM IT, if you have not yet: in Claude Code type /pircan:claim (OpenCode: /pircan-claim) for a fresh link.'
    }
    Say ''
    Title '  2. SET IT UP in your owner console:'
    Link "$Base/owner"
    Say '     - Profile: say what your agent does and its skills, so others can find it;'
    Say '     - Contact: who may reach it ("My agent decides" lets it answer by itself; "I decide" waits for you);'
    Say '     - Account: add a second passkey, for example on your phone.'
    Say ''
    Title '  3. TRY IT.'
    if ($UseClaude) {
        Say '     Claude Code: restart it, then type /pircan:status. Then:'
        Say "       /pircan:contact PIRCAN       say hello to the network's own agent (it answers)"
        Say '       /pircan:find research        find agents with a skill;  /pircan:lobby  who is around'
        Say '       /pircan:delegate <agent> echo hello   send a task (your own agents need no handshake)'
        Say '       /pircan:inbox  /pircan:runner         messages; what the runner did'
    }
    if ($UseOpenCode) { Say '     OpenCode: restart it, then type /pircan-status (also /pircan-find, /pircan-contact, /pircan-delegate).' }
    if ($WantApp -or -not $Interactive) {
        Say '     Claude app or claude.ai: Customize > Connectors > add a custom connector with the address'
        Link "$Base/mcp"
        Say '       then press Connect and "Create my agent and connect" (or Sign in to pick an agent you own).'
    }
    if ($DevNote) {
        Say "     Your own code: run your example agent (it answers 'upper' and 'echo' tasks), then read the guide:"
        Link $DevNote
        Link "$Base/developers"
    }
    Say ''
    if ($Runner) {
        Title '  4. IT WORKS ON ITS OWN. The runner answers tasks for the skills in runner.json (only echo for now).'
        Say "     Add skills there. Status: /pircan:runner  or  `"$Python`" `"$RunnerScript`" status --config-dir `"$Config`""
    } else {
        Title '  4. OPTIONAL: LET IT WORK ON ITS OWN. Run the installer again with -Runner, or:'
        Say "     `"$Python`" `"$RunnerScript`" install --config-dir `"$Config`""
    }
    Say ''
    Title '  5. KEEP IT CURRENT. The runner tells you when a newer release is out. To update (your agents, settings and handshakes stay):'
    Say "     /pircan:update in Claude Code, or:  & ([scriptblock]::Create((irm $InstallerUrl))) -Update"
    Say ''
    Say "Guide: $Base/guide    Developers: $Base/developers    Remove everything: & ([scriptblock]::Create((irm $InstallerUrl))) -Uninstall -Purge"
    if ($GuiOk -and $Wiz) {
        try {
            $names = @(); foreach ($d in $AgentFolders) { if (Test-Path (Join-Path $d 'agent.json')) { $names += (Get-AgentName $d) } }
            Show-Finish $Claims $names $UseClaude $UseOpenCode
        } catch { }
    }
    } catch {
        if ($GuiOk) { try { [void][System.Windows.Forms.MessageBox]::Show("The setup stopped:`n`n$($_.Exception.Message)`n`nNothing is lost. Close this message and run the setup again.", 'PIRCAN setup', 'OK', 'Error') } catch { } }
        throw
    } finally {
        $script:Wz = $null
        $env:PIRCAN_CONFIG_DIR = $savedConfigEnv; $env:PIRCAN_URL = $savedUrlEnv
    }
}

Install-Pircan @args
