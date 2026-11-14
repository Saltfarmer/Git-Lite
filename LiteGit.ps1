<#
  LiteGit - a tiny, friendly window for Git.
  Five jobs:  Save (commit) - Upload (push) - Get updates (pull / clone) - New project (init) - History (log)

  Needs : Git for Windows  ->  https://git-scm.com/download/win
  Optional: GitHub CLI "gh" (https://cli.github.com, then run "gh auth login" once)
            -> lets LiteGit create the GitHub repository for you.
  Start : double-click "Start LiteGit.bat"
          or: powershell -STA -ExecutionPolicy Bypass -File LiteGit.ps1
#>

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
try {
    Add-Type -Namespace LiteGitNative -Name Win -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
    [void][LiteGitNative.Win]::SetProcessDPIAware()
} catch {}
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------- basics
$gfx = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $script:S = $gfx.DpiX / 96.0; $gfx.Dispose()
function px([double]$n) { [int][Math]::Round($n * $script:S) }
function Pad([int]$l, [int]$t, [int]$r, [int]$b) { New-Object System.Windows.Forms.Padding($l, $t, $r, $b) }
function Pt([int]$x, [int]$y) { New-Object System.Drawing.Point($x, $y) }
function RS([string]$type, [single]$v = 0) { New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]$type, $v) }
function CS([string]$type, [single]$v = 0) { New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]$type, $v) }
function Hex([string]$h) { [System.Drawing.ColorTranslator]::FromHtml($h) }

$gitCmd = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $gitCmd) {
    [void][System.Windows.Forms.MessageBox]::Show("LiteGit needs Git, which isn't installed yet.`n`nThe download page will open now. Install it (the default options are fine), then start LiteGit again.", 'LiteGit', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    Start-Process 'https://git-scm.com/download/win'
    return
}
$script:GitExe = $gitCmd.Source

# Palette: Nusantara / Cakrawala / Mentari blues + complementary amber
$C = @{
    Navy  = (Hex '#042A61'); Blue  = (Hex '#0857C3'); Sky   = (Hex '#307FE2'); Sun   = (Hex '#71C5E8'); Ice = (Hex '#D6EFFB')
    Side  = (Hex '#F3F7FC'); Hover = (Hex '#E6F0FB'); Ink   = (Hex '#16233A'); Muted = (Hex '#5B6B82')
    Amber = (Hex '#C37408'); Red   = (Hex '#C32A08'); Teal  = (Hex '#078F7E')
    LogBg = (Hex '#0A1B36'); LogFg = (Hex '#D6EFFB'); White = [System.Drawing.Color]::White
}
$families = @((New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name })
$UiFont = 'Segoe UI'; foreach ($n in 'Inter', 'Aptos', 'Montserrat') { if ($families -contains $n) { $UiFont = $n; break } }
$MonoFont = if ($families -contains 'Cascadia Mono') { 'Cascadia Mono' } else { 'Consolas' }
function F([single]$size = 10, [switch]$Bold, [string]$Name = $UiFont) {
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    New-Object System.Drawing.Font($Name, $size, $style)
}
$Utf8 = New-Object System.Text.UTF8Encoding($false)

# ---------------------------------------------------------------- settings
$SettingsDir = Join-Path $env:APPDATA 'LiteGit'
$SettingsFile = Join-Path $SettingsDir 'settings.json'
function Get-Recent {
    try { if (Test-Path $SettingsFile) { return @((Get-Content $SettingsFile -Raw | ConvertFrom-Json).Recent | Where-Object { $_ }) } } catch {}
    @()
}
function Add-Recent([string]$path) {
    $list = @($path) + @(Get-Recent | Where-Object { $_ -ne $path }) | Select-Object -First 8
    try {
        [void](New-Item -ItemType Directory -Force -Path $SettingsDir)
        [IO.File]::WriteAllText($SettingsFile, (ConvertTo-Json @{ Recent = @($list) }), $Utf8)
    } catch {}
}

# ---------------------------------------------------------------- running git
function Quote-Arg([string]$a) {
    if ($a -eq '') { return '""' }
    if ($a -notmatch '[\s"]') { return $a }
    $sb = New-Object System.Text.StringBuilder; [void]$sb.Append('"'); $bs = 0
    foreach ($ch in $a.ToCharArray()) {
        if ($ch -eq '\') { $bs++; continue }
        if ($ch -eq '"') { [void]$sb.Append('\' * ($bs * 2 + 1)); [void]$sb.Append('"'); $bs = 0; continue }
        if ($bs) { [void]$sb.Append('\' * $bs); $bs = 0 }
        [void]$sb.Append($ch)
    }
    [void]$sb.Append('\' * ($bs * 2)); [void]$sb.Append('"')
    $sb.ToString()
}

function Invoke-Exe([string]$Exe, [string[]]$ArgList, [string]$Dir, [switch]$Quiet, [string]$Show) {
    if (-not $Dir) { $Dir = $script:Repo }
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { $Dir = [Environment]::GetFolderPath('UserProfile') }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = (@($ArgList) | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi.WorkingDirectory = $Dir
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Utf8; $psi.StandardErrorEncoding = $Utf8
    $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'   # never hang waiting for typed input
    $psi.EnvironmentVariables['GIT_MERGE_AUTOEDIT'] = 'no'   # never open a text editor
    if (-not $Quiet) { Write-Log ('> ' + $Show) 'cmd' }
    try { $p = [System.Diagnostics.Process]::Start($psi) }
    catch { if (-not $Quiet) { Write-Log $_.Exception.Message 'err' }; return [pscustomobject]@{ Ok = $false; Code = -1; Out = ''; Err = $_.Exception.Message } }
    $oT = $p.StandardOutput.ReadToEndAsync(); $eT = $p.StandardError.ReadToEndAsync()
    while (-not $p.WaitForExit(30)) { [System.Windows.Forms.Application]::DoEvents() }
    $p.WaitForExit()
    $r = [pscustomobject]@{ Ok = ($p.ExitCode -eq 0); Code = $p.ExitCode; Out = $oT.Result; Err = $eT.Result }
    if (-not $Quiet) {
        if ($r.Out.Trim()) { Write-Log $r.Out 'out' }
        if ($r.Err.Trim()) { Write-Log $r.Err $(if ($r.Ok) { 'out' } else { 'err' }) }
    }
    $r
}
function Invoke-Git([string[]]$ArgList, [string]$Dir, [switch]$Quiet, [string]$Show) {
    if (-not $Show) { $Show = 'git ' + ((@($ArgList) | ForEach-Object { Quote-Arg $_ }) -join ' ') }
    $full = @('-c', 'core.quotepath=false', '-c', 'color.ui=never') + $ArgList
    Invoke-Exe $script:GitExe $full $Dir -Quiet:$Quiet -Show $Show
}
function Test-GhReady {
    if ($null -eq $script:GhReady) {
        $gh = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $script:GhExe = if ($gh) { $gh.Source } else { $null }
        $script:GhReady = [bool]($script:GhExe -and (Invoke-Exe $script:GhExe @('auth', 'status') -Quiet).Ok)
    }
    $script:GhReady
}

# ---------------------------------------------------------------- repo state
function Test-Repo { [bool]($script:Repo -and (Test-Path -LiteralPath $script:Repo)) }
function Has-Commits { (Invoke-Git @('rev-parse', '-q', '--verify', 'HEAD') -Quiet).Ok }
function Has-Upstream { (Invoke-Git @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}') -Quiet).Ok }
function Get-Branch { $r = Invoke-Git @('symbolic-ref', '--short', '-q', 'HEAD') -Quiet; if ($r.Ok) { $r.Out.Trim() } else { '' } }
function Get-Remote { $r = Invoke-Git @('remote', 'get-url', 'origin') -Quiet; if ($r.Ok) { $r.Out.Trim() } else { '' } }
function Get-AheadCount {
    if (Has-Upstream) { return [int](Invoke-Git @('rev-list', '--count', '@{u}..HEAD') -Quiet).Out.Trim() }
    if (Has-Commits) { return [int](Invoke-Git @('rev-list', '--count', 'HEAD') -Quiet).Out.Trim() }
    0
}
function Get-Changes {
    $r = Invoke-Git @('status', '--porcelain=v1', '-z', '-uall') -Quiet
    $items = @(); $t = $r.Out -split "`0"; $i = 0
    while ($i -lt $t.Count) {
        $e = $t[$i]; $i++
        if ($e.Length -lt 4) { continue }
        $xy = $e.Substring(0, 2); $x = $xy[0]; $y = $xy[1]; $path = $e.Substring(3); $old = $null
        if ($x -eq 'R' -or $x -eq 'C') { $old = $t[$i]; $i++ }
        $label = if ($x -eq 'U' -or $y -eq 'U' -or $xy -eq 'AA' -or $xy -eq 'DD') { 'Conflict' }
                 elseif ($xy -eq '??' -or $x -eq 'A') { 'New' }
                 elseif ($x -eq 'D' -or $y -eq 'D') { 'Deleted' }
                 elseif ($x -eq 'R') { 'Renamed' }
                 else { 'Changed' }
        $items += [pscustomobject]@{ Path = $path; Old = $old; Label = $label }
    }
    , $items
}

# ---------------------------------------------------------------- feedback
function Msg([string]$text, [string]$icon = 'Information', [string]$buttons = 'OK') {
    [System.Windows.Forms.MessageBox]::Show($form, $text, 'LiteGit', [System.Windows.Forms.MessageBoxButtons]$buttons, [System.Windows.Forms.MessageBoxIcon]$icon)
}
function Show-Warn($t) { [void](Msg $t 'Warning') }
function Show-Error($t) { [void](Msg $t 'Error') }
function Ask($t) { (Msg $t 'Question' 'YesNo') -eq [System.Windows.Forms.DialogResult]::Yes }

function Flash([string]$text, [string]$kind = 'ok') {
    switch ($kind) {
        'ok'   { $banner.BackColor = (Hex '#DDF5F1'); $banner.ForeColor = (Hex '#05584D') }
        'info' { $banner.BackColor = $C.Ice;          $banner.ForeColor = $C.Navy }
        'warn' { $banner.BackColor = (Hex '#FBEBD9'); $banner.ForeColor = (Hex '#7A4605') }
    }
    $banner.Text = $text; $banner.Visible = $true
    $bannerTimer.Stop(); $bannerTimer.Start()
}
function Write-Log([string]$text, [string]$kind = 'out') {
    $logBox.SelectionStart = $logBox.TextLength; $logBox.SelectionLength = 0
    $logBox.SelectionColor = switch ($kind) { 'cmd' { $C.Sun } 'err' { (Hex '#FF9A7A') } 'ok' { (Hex '#7EE3D2') } default { $C.LogFg } }
    $logBox.AppendText($text.TrimEnd() + "`r`n")
    $logBox.ScrollToCaret()
}
function Get-Friendly($r) {
    $e = "$($r.Err)`n$($r.Out)"
    $m = switch -Regex ($e) {
        'unrelated histories' { "This project and the one on GitHub started separately, so Git won't combine them automatically."; break }
        'non-fast-forward|fetch first|\[rejected\]' { "GitHub has newer changes that you don't have yet.`n`nClick 'Get updates' first, then upload again."; break }
        'Authentication failed|could not read Username|terminal prompts disabled|Permission denied|returned error: 403' { "GitHub didn't accept your sign-in.`n`nA GitHub sign-in window should appear when you upload. If it doesn't, reinstall Git for Windows and keep 'Git Credential Manager' ticked."; break }
        'Repository not found|does not appear to be a git repository' { "LiteGit couldn't find that repository on GitHub.`n`nCheck the link, and that your GitHub account has access to it."; break }
        'Could not resolve host|Failed to connect|timed out|unable to access' { "Couldn't reach GitHub. Check your internet connection and try again."; break }
        'would be overwritten|commit your changes or stash' { "Some of your unsaved edits touch the same files as the update.`n`nSave your changes first (Save changes), then try again."; break }
        'CONFLICT|Automatic merge failed|unmerged|fix conflicts' { "You and GitHub both changed the same lines.`n`nFiles marked 'Conflict' in Save changes need a decision: open each one, keep the text you want between the <<<<<<< and >>>>>>> markers (and delete the markers), then Save."; break }
        'nothing to commit' { "There's nothing new to save."; break }
        default { $raw = ("$($r.Err)".Trim() + ' ' + "$($r.Out)".Trim()).Trim(); if ($raw.Length -gt 600) { $raw = $raw.Substring(0, 600) + '...' }; "Git said:`n`n$raw" }
    }
    $m + "`n`n(Full details are in the Activity panel at the bottom.)"
}
function Do-Action([scriptblock]$Body) {
    if ($script:Busy) { return }
    $script:Busy = $true; $mid.Enabled = $false; $hdrBtns.Enabled = $false; $form.UseWaitCursor = $true
    try { & $Body } catch { Show-Error ("Something went wrong:`n`n" + $_.Exception.Message) }
    finally { $script:Busy = $false; $mid.Enabled = $true; $hdrBtns.Enabled = $true; $form.UseWaitCursor = $false }
}
function Do-Quiet([scriptblock]$Body) {   # background refresh: no greyed-out UI
    if ($script:Busy) { return }
    $script:Busy = $true
    try { & $Body } catch {} finally { $script:Busy = $false }
}

# ---------------------------------------------------------------- UI helpers
function NewC([string]$type, [hashtable]$p = @{}) {
    $c = New-Object ("System.Windows.Forms.$type")
    foreach ($k in $p.Keys) { $c.$k = $p[$k] }
    $c
}
function New-Label([string]$text, [single]$size = 10, [switch]$Bold, $Color = $C.Ink, [int]$Wrap = 0) {
    $l = NewC Label @{ Text = $text; AutoSize = $true; Font = (F $size -Bold:$Bold); ForeColor = $Color; Margin = (Pad 0 0 0 (px 6)) }
    if ($Wrap) { $l.MaximumSize = New-Object System.Drawing.Size((px $Wrap), 0) }
    $l
}
function New-Button([string]$text, [string]$kind = 'primary') {
    $b = NewC Button @{ Text = $text; FlatStyle = 'Flat'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; Font = (F 10 -Bold:($kind -ne 'secondary'))
        Cursor = [System.Windows.Forms.Cursors]::Hand; Padding = (Pad (px 14) (px 6) (px 14) (px 6)); Margin = (Pad 0 (px 4) (px 10) (px 4)); UseVisualStyleBackColor = $false }
    switch ($kind) {
        'primary'   { $b.BackColor = $C.Blue; $b.ForeColor = $C.White; $b.FlatAppearance.BorderSize = 0; $b.FlatAppearance.MouseOverBackColor = $C.Sky; $b.FlatAppearance.MouseDownBackColor = $C.Navy }
        'header'    { $b.BackColor = $C.Blue; $b.ForeColor = $C.White; $b.FlatAppearance.BorderSize = 0; $b.FlatAppearance.MouseOverBackColor = $C.Sky; $b.Font = (F 9.5 -Bold); $b.Margin = (Pad (px 8) 0 0 0) }
        'secondary' { $b.BackColor = $C.White; $b.ForeColor = $C.Blue; $b.FlatAppearance.BorderColor = $C.Sky; $b.FlatAppearance.BorderSize = 1; $b.FlatAppearance.MouseOverBackColor = $C.Hover }
    }
    $b
}
function New-Flow([int]$top = 6) { NewC FlowLayoutPanel @{ AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; WrapContents = $false; Margin = (Pad 0 (px $top) 0 (px 6)) } }
function Add-Row($tlp, $ctl, [switch]$Fill) {
    $i = $tlp.RowCount; $tlp.RowCount = $i + 1
    [void]$tlp.RowStyles.Add($(if ($Fill) { RS Percent 100 } else { RS AutoSize }))
    $tlp.Controls.Add($ctl, 0, $i)
}
function Pick-Folder([string]$desc, [string]$start) {
    $d = NewC FolderBrowserDialog @{ Description = $desc; ShowNewFolderButton = $true }
    if ($start -and (Test-Path -LiteralPath $start)) { $d.SelectedPath = $start }
    if ($d.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { return $d.SelectedPath }
    $null
}
function Show-InputForm([string]$Title, [string]$Prompt, [string[]]$Labels, [string[]]$Defaults = @(), [string]$LinkText, [string]$LinkUrl) {
    $f = NewC Form @{ Text = $Title; FormBorderStyle = 'FixedDialog'; StartPosition = 'CenterParent'; MinimizeBox = $false; MaximizeBox = $false; ShowInTaskbar = $false
        AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; Font = (F 10); BackColor = $C.White; Padding = (Pad 0 0 (px 20) (px 14)) }
    $t = NewC TableLayoutPanel @{ AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; ColumnCount = 1; Location = (Pt (px 20) (px 16)) }
    Add-Row $t (New-Label $Prompt 10 -Wrap 470 -Color $C.Ink)
    $boxes = @()
    for ($i = 0; $i -lt $Labels.Count; $i++) {
        Add-Row $t (New-Label $Labels[$i] 9.5 -Bold -Color $C.Navy)
        $tb = NewC TextBox @{ Width = (px 470); Font = (F 10.5); Margin = (Pad 0 0 0 (px 10)) }
        if ($i -lt $Defaults.Count -and $Defaults[$i]) { $tb.Text = $Defaults[$i] }
        Add-Row $t $tb; $boxes += $tb
    }
    if ($LinkText) {
        $ll = NewC LinkLabel @{ Text = $LinkText; AutoSize = $true; Tag = $LinkUrl; LinkColor = $C.Blue; Font = (F 10 -Bold) }
        $ll.Add_LinkClicked({ Start-Process $this.Tag })
        Add-Row $t $ll
    }
    $fl = New-Flow 12; $fl.FlowDirection = 'RightToLeft'; $fl.Anchor = 'Right'
    $ok = New-Button 'OK'; $ok.DialogResult = 'OK'
    $cn = New-Button 'Cancel' 'secondary'; $cn.DialogResult = 'Cancel'
    $fl.Controls.Add($ok); $fl.Controls.Add($cn)
    Add-Row $t $fl
    $f.Controls.Add($t); $f.AcceptButton = $ok; $f.CancelButton = $cn
    $res = $f.ShowDialog($form)
    $vals = @($boxes | ForEach-Object { $_.Text.Trim() })
    $f.Dispose()
    if ($res -eq [System.Windows.Forms.DialogResult]::OK) { return , $vals }
    $null
}
function Show-TextWindow([string]$title, [string]$text) {
    $f = NewC Form @{ Text = $title; StartPosition = 'CenterParent'; ShowInTaskbar = $false; BackColor = $C.White; Size = (New-Object System.Drawing.Size((px 780), (px 540))) }
    $tb = NewC RichTextBox @{ Dock = 'Fill'; ReadOnly = $true; BorderStyle = 'None'; Font = (F 10 -Name $MonoFont); Text = $text; DetectUrls = $false }
    $tb.BackColor = $C.White
    $wrap = NewC Panel @{ Dock = 'Fill'; Padding = (Pad (px 16) (px 12) (px 16) (px 12)) }
    $wrap.Controls.Add($tb); $f.Controls.Add($wrap)
    [void]$f.ShowDialog($form); $f.Dispose()
}

# ---------------------------------------------------------------- git actions
function Ensure-Identity {
    $n = (Invoke-Git @('config', 'user.name') -Quiet).Out.Trim()
    $e = (Invoke-Git @('config', 'user.email') -Quiet).Out.Trim()
    if ($n -and $e) { return $true }
    while ($true) {
        $v = Show-InputForm 'One-time setup' "Git labels every snapshot with who made it.`nUse the same email as your GitHub account." @('Your name', 'Your email') @($n, $e)
        if (-not $v) { return $false }
        if ($v[0] -and $v[1] -match '@') { break }
        Show-Warn 'Please fill in both your name and a valid email.'
    }
    $null = Invoke-Git @('config', '--global', 'user.name', $v[0])
    $null = Invoke-Git @('config', '--global', 'user.email', $v[1])
    $true
}

function Open-Repo([string]$path, [switch]$Silent) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return }
    $r = Invoke-Git @('rev-parse', '--show-toplevel') -Dir $path -Quiet
    if ($r.Ok) { $top = $r.Out.Trim() -replace '/', '\' }
    else {
        if ($Silent) { return }
        $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
        if ($full -eq [IO.Path]::GetPathRoot($full).TrimEnd('\') -or $full -eq [Environment]::GetFolderPath('UserProfile').TrimEnd('\')) {
            Show-Warn "Please pick a specific project folder, not a whole drive or your entire user folder."; return
        }
        if (-not (Ask "'$(Split-Path $full -Leaf)' isn't a Git project yet.`n`nSet it up now so you can save versions of it? Your files won't be changed.")) { return }
        $r = Invoke-Git @('init') -Dir $full
        if (-not $r.Ok) { Show-Error (Get-Friendly $r); return }
        $null = Invoke-Git @('symbolic-ref', 'HEAD', 'refs/heads/main') -Dir $full
        $top = $full
    }
    $script:Repo = $top; $script:Unchecked = @{}
    Add-Recent $top
    Refresh-All
    if (-not $Silent) { Flash "Opened '$(Split-Path $top -Leaf)'." 'info' }
}

function Do-Commit {
    $msg = $txtMsg.Text.Trim()
    $picked = @($lvFiles.CheckedItems | ForEach-Object { $_.Tag })
    if ($picked.Count -eq 0) { Show-Warn 'Tick at least one file to save.'; return }
    if (-not $msg) { Show-Warn "Write a short note about what you changed (for example: 'Fix typo on home page')."; [void]$txtMsg.Focus(); return }
    if (@($picked | Where-Object { $_.Label -eq 'Conflict' }).Count -and -not (Ask "Some ticked files are marked 'Conflict'.`n`nHave you opened them and removed the <<<<<<< / >>>>>>> markers?")) { return }
    if (-not (Ensure-Identity)) { return }

    if ($picked.Count -eq $lvFiles.Items.Count) { $r = Invoke-Git @('add', '-A') }
    else {
        $null = Invoke-Git @('reset', '-q') -Quiet
        $paths = foreach ($p in $picked) { $p.Path; if ($p.Old) { $p.Old } }
        $tmp = [IO.Path]::GetTempFileName()
        [IO.File]::WriteAllText($tmp, ($paths -join "`0"), $Utf8)
        $r = Invoke-Git @('--literal-pathspecs', 'add', '-A', "--pathspec-from-file=$tmp", '--pathspec-file-nul') -Show ('git add ' + (($paths | ForEach-Object { Quote-Arg $_ }) -join ' '))
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
    if (-not $r.Ok) { Show-Error (Get-Friendly $r); Refresh-All; return }

    $mf = [IO.Path]::GetTempFileName(); [IO.File]::WriteAllText($mf, $msg, $Utf8)
    $r = Invoke-Git @('commit', '-F', $mf) -Show ('git commit -m ' + (Quote-Arg $msg))
    Remove-Item -LiteralPath $mf -ErrorAction SilentlyContinue
    if (-not $r.Ok) { Show-Error (Get-Friendly $r); Refresh-All; return }

    $txtMsg.Text = ''; $script:Unchecked = @{}
    Write-Log 'Saved.' 'ok'
    Refresh-All
    if ($chkUpAfter.Checked) { Do-Push }
    else { Flash "Saved! Your snapshot is stored on this computer. Click 'Upload' to send it to GitHub." }
}

function Set-Remote {
    $cur = Get-Remote
    if (-not $cur -and (Test-GhReady)) {
        $ch = Msg "This project isn't linked to GitHub yet.`n`nYes  =  create a new private repository on GitHub for me`nNo   =  I'll paste the link of an existing one" 'Question' 'YesNoCancel'
        if ($ch -eq [System.Windows.Forms.DialogResult]::Cancel) { return $false }
        if ($ch -eq [System.Windows.Forms.DialogResult]::Yes) {
            $name = (Split-Path $script:Repo -Leaf) -replace '[^A-Za-z0-9._-]+', '-'
            $ga = @('repo', 'create', $name, '--private', '--source', $script:Repo, '--remote', 'origin')
            $r = Invoke-Exe $script:GhExe $ga -Show ('gh ' + (($ga | ForEach-Object { Quote-Arg $_ }) -join ' '))
            if (-not $r.Ok) { Show-Error ("GitHub couldn't create the repository:`n`n" + $r.Err.Trim()) }
            return $r.Ok
        }
    }
    $v = Show-InputForm 'Link to GitHub' "Paste the link of your GitHub repository.`nIt looks like:  https://github.com/your-name/project.git`n`nNo repository yet? Click the link below, create an EMPTY one (don't add a README), then copy its link back here." @('Repository link') @($cur) 'Create one on GitHub  ->' 'https://github.com/new'
    if (-not $v -or -not $v[0]) { return $false }
    $url = $v[0]
    $r = if ($cur) { Invoke-Git @('remote', 'set-url', 'origin', $url) } else { Invoke-Git @('remote', 'add', 'origin', $url) }
    if (-not $r.Ok) { Show-Error (Get-Friendly $r) }
    $r.Ok
}

function Do-Push {
    if (-not (Has-Commits)) { Show-Warn "Nothing to upload yet - save your changes first (Save changes)."; return }
    $branch = Get-Branch
    if (-not $branch) { Show-Warn "LiteGit can't tell which branch you're on. Open the project in a terminal to fix this."; return }
    if (-not (Get-Remote)) { if (-not (Set-Remote)) { Refresh-All; return } }
    $r = if (Has-Upstream) { Invoke-Git @('push') } else { Invoke-Git @('push', '-u', 'origin', $branch) }
    Refresh-All
    if ($r.Ok) { Write-Log 'Uploaded.' 'ok'; Flash 'Uploaded! GitHub now has your latest snapshots.' }
    else { Show-Error (Get-Friendly $r) }
}

function Do-Pull {
    if (-not (Get-Remote)) { Show-Warn "This project isn't linked to GitHub yet, so there's nothing to download.`n`nUse Upload to link it."; return }
    if (-not (Ensure-Identity)) { return }
    $branch = Get-Branch
    if (-not $branch) { Show-Warn "LiteGit can't tell which branch you're on. Open the project in a terminal to fix this."; return }
    $up = Has-Upstream
    $ga = @('pull', '--no-rebase', '--no-edit')
    if (-not $up) {
        $ls = Invoke-Git @('ls-remote', '--heads', 'origin', $branch)
        if (-not $ls.Ok) { Show-Error (Get-Friendly $ls); return }
        if (-not $ls.Out.Trim()) { Flash "GitHub doesn't have anything for '$branch' yet - nothing to download. Upload first." 'info'; return }
        $ga += @('origin', $branch)
    }
    $r = Invoke-Git $ga
    if (-not $r.Ok -and "$($r.Err)$($r.Out)" -match 'unrelated histories') {
        if (Ask "Your project and the GitHub one started separately (for example, GitHub created a README).`n`nCombine them? Nothing will be deleted.") {
            $r = Invoke-Git ($ga + '--allow-unrelated-histories')
        } else { return }
    }
    if ($r.Ok -and -not $up) { $null = Invoke-Git @('branch', "--set-upstream-to=origin/$branch") -Quiet }
    Refresh-All
    if (-not $r.Ok) { Show-Error (Get-Friendly $r); return }
    if ($r.Out -match 'Already up to date') { Flash 'You already have the latest version.' 'info' }
    else { Write-Log 'Updated.' 'ok'; Flash 'Got the latest changes from GitHub.' }
}

function Do-Clone {
    $url = $cboClone.Text.Trim()
    if (-not $url) { Show-Warn "Paste a GitHub link first.`n`nOn GitHub, open the repository, click the green 'Code' button and copy the HTTPS link."; return }
    $parent = Pick-Folder 'Where should the project folder be created?' ([Environment]::GetFolderPath('MyDocuments'))
    if (-not $parent) { return }
    $name = ($url.TrimEnd('/') -split '[/:]')[-1] -replace '\.git$', ''
    $dest = Join-Path $parent $name
    if (Test-Path -LiteralPath $dest) { Show-Warn "A folder named '$name' already exists there. Pick another place."; return }
    $r = Invoke-Git @('clone', $url, $dest) -Dir $parent
    if (-not $r.Ok) { Show-Error (Get-Friendly $r); return }
    Open-Repo $dest -Silent
    Flash "Downloaded '$name' to $dest"
    Show-Page 'history'
}

function Do-LoadMyRepos {
    if (-not (Test-GhReady)) { return }
    $r = Invoke-Exe $script:GhExe @('repo', 'list', '--limit', '200', '--json', 'url', '--jq', '.[].url') -Show 'gh repo list'
    if (-not $r.Ok) { Show-Error $r.Err; return }
    $cboClone.Items.Clear()
    foreach ($u in ($r.Out -split "`r?`n" | Where-Object { $_ })) { [void]$cboClone.Items.Add("$u.git") }
    if ($cboClone.Items.Count) { $cboClone.DroppedDown = $true }
}

function Do-Create {
    $name = $txtName.Text.Trim(); $loc = $txtLoc.Text.Trim()
    if (-not $name) { Show-Warn 'Give your project a name.'; return }
    if ($name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { Show-Warn 'The name has characters Windows does not allow in folder names (like  \ / : * ? " < > | ).'; return }
    if (-not $loc -or -not (Test-Path -LiteralPath $loc)) { Show-Warn 'Choose where to create the project (Browse...).'; return }
    $dir = Join-Path $loc $name
    if (Test-Path -LiteralPath (Join-Path $dir '.git')) { Show-Warn "'$name' is already a Git project - opening it."; Open-Repo $dir -Silent; Show-Page 'save'; return }
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir) }
    $r = Invoke-Git @('init') -Dir $dir
    if (-not $r.Ok) { Show-Error (Get-Friendly $r); return }
    $null = Invoke-Git @('symbolic-ref', 'HEAD', 'refs/heads/main') -Dir $dir
    $script:Repo = $dir
    if ($chkReadme.Checked) {
        $rp = Join-Path $dir 'README.md'
        if (-not (Test-Path -LiteralPath $rp)) { [IO.File]::WriteAllText($rp, "# $name`r`n`r`nCreated with LiteGit.`r`n", $Utf8) }
        if (Ensure-Identity) { $null = Invoke-Git @('add', '-A'); $null = Invoke-Git @('commit', '-m', 'First snapshot') }
    }
    $note = ''
    if ($chkGh.Checked -and (Test-GhReady)) {
        $ga = @('repo', 'create', ($name -replace '[^A-Za-z0-9._-]+', '-'), $(if ($rbPublic.Checked) { '--public' } else { '--private' }), '--source', $dir, '--remote', 'origin')
        if (Has-Commits) { $ga += '--push' }
        $r = Invoke-Exe $script:GhExe $ga $dir -Show ('gh ' + (($ga | ForEach-Object { Quote-Arg $_ }) -join ' '))
        $note = if ($r.Ok) { ' and on GitHub' } else { Show-Error ("Your project was created on this computer, but GitHub said:`n`n" + $r.Err.Trim()); '' }
    }
    $txtName.Text = ''
    Open-Repo $dir -Silent
    Show-Page 'save'
    Flash "Project '$name' created$note. Put your files in $dir, then come back here to save them."
}

function Show-CommitDetails($hash) {
    $r = Invoke-Git @('show', '--stat', '--date=format:%d %b %Y  %H:%M', '--format=Snapshot  %h%nBy        %an <%ae>%nWhen      %ad%n%n%B%nFiles in this snapshot:', $hash) -Quiet
    Show-TextWindow 'Snapshot details' $r.Out
}

# ---------------------------------------------------------------- refresh
function Set-NavCaption([string]$key, [string]$text, [bool]$alert = $false) {
    $script:Nav[$key].Caption.Text = $text
    $script:Nav[$key].Caption.ForeColor = if ($alert) { $C.Amber } else { $C.Muted }
}
function Refresh-All {
    if ($script:Refreshing) { return }
    $script:Refreshing = $true
    try {
        if (Test-Repo) {
            $script:Changes = @(Get-Changes)
            $script:Branch = Get-Branch
            $script:Ahead = Get-AheadCount
            $b = if ($script:Branch) { $script:Branch } else { '(none)' }
            $lblInfo.Text = "$(Split-Path $script:Repo -Leaf)      branch: $b"
            $tip.SetToolTip($lblInfo, $script:Repo)
            $n = $script:Changes.Count
            if ($n) { Set-NavCaption 'save' "$n unsaved change$(if ($n -ne 1) { 's' })" $true } else { Set-NavCaption 'save' 'everything saved' }
            if ($script:Ahead) { Set-NavCaption 'upload' "$($script:Ahead) waiting to upload" $true } else { Set-NavCaption 'upload' 'push' }
            $btnShow.Enabled = $true
        } else {
            $script:Changes = @(); $script:Ahead = 0
            $lblInfo.Text = 'No project open'
            foreach ($k in 'save', 'upload') { Set-NavCaption $k $script:Nav[$k].Default }
            $btnShow.Enabled = $false
        }
        Refresh-Page $script:Shown
    } finally { $script:Refreshing = $false }
}
function Refresh-Page([string]$key) {
    switch ($key) {
        'save'    { Fill-Changes }
        'upload'  { Fill-Upload }
        'history' { Fill-History }
        'pull'    { Fill-Pull }
        'new'     { Fill-New }
    }
}
function Fill-Changes {
    $script:Filling = $true
    $lvFiles.BeginUpdate(); $lvFiles.Items.Clear()
    foreach ($ch in $script:Changes) {
        $txt = if ($ch.Old) { "$($ch.Old)  ->  $($ch.Path)" } else { $ch.Path }
        $it = New-Object System.Windows.Forms.ListViewItem($txt)
        $it.UseItemStyleForSubItems = $false
        $sub = $it.SubItems.Add($ch.Label)
        $sub.ForeColor = switch ($ch.Label) { 'New' { $C.Teal } 'Deleted' { $C.Red } 'Conflict' { $C.Amber } default { $C.Blue } }
        $sub.Font = (F 9.5 -Bold)
        $it.Tag = $ch
        $it.Checked = -not $script:Unchecked.ContainsKey($ch.Path)
        [void]$lvFiles.Items.Add($it)
    }
    $lvFiles.EndUpdate(); $script:Filling = $false
    $has = $script:Changes.Count -gt 0
    $lvFiles.Visible = $has; $emptySave.Visible = -not $has
    $btnSave.Enabled = $has; $selRow.Visible = $has
    Update-SaveCount
}
function Update-SaveCount { $lblSel.Text = "$($lvFiles.CheckedItems.Count) of $($lvFiles.Items.Count) files ticked" }
function Fill-Upload {
    $remote = Get-Remote
    if (-not (Has-Commits)) { $lblUp.Text = 'Nothing saved yet.'; $lblUp.ForeColor = $C.Muted; $btnPush.Enabled = $false }
    elseif ($script:Ahead -gt 0) { $lblUp.Text = "$($script:Ahead) saved snapshot$(if ($script:Ahead -ne 1) { 's are' } else { ' is' }) waiting to be uploaded."; $lblUp.ForeColor = $C.Amber; $btnPush.Enabled = $true }
    else { $lblUp.Text = 'Everything is uploaded.'; $lblUp.ForeColor = $C.Teal; $btnPush.Enabled = $true }
    $lblRemote.Text = if ($remote) { "Linked to:  $remote" } else { "Not linked to GitHub yet - LiteGit will ask for the link the first time you upload." }
    $btnLink.Text = if ($remote) { 'Change GitHub link...' } else { 'Link to GitHub...' }
    $n = $script:Changes.Count
    $lblUnsaved.Visible = $n -gt 0
    $lblUnsaved.Text = "Heads-up: you have $n unsaved change$(if ($n -ne 1) { 's' }). Only saved snapshots get uploaded - go to 'Save changes' first."
}
function Fill-Pull {
    $ok = Test-Repo
    $remote = if ($ok) { Get-Remote } else { '' }
    $btnPull.Enabled = [bool]$remote
    $lblPullInfo.Text = if (-not $ok) { 'Open a project first (top right).' } elseif ($remote) { "From:  $remote" } else { "This project isn't linked to GitHub yet. Link it from 'Upload'." }
    $btnMyRepos.Visible = [bool](Get-Command gh -ErrorAction SilentlyContinue)
}
function Fill-New {
    if (-not $txtLoc.Text) { $txtLoc.Text = [Environment]::GetFolderPath('MyDocuments') }
    $ready = Test-GhReady
    $chkGh.Enabled = $ready; $rbPrivate.Enabled = $ready; $rbPublic.Enabled = $ready
    if (-not $ready) { $chkGh.Checked = $false }
    $lblGhHint.Text = if ($ready) { 'Uses GitHub CLI - you are signed in.' } else { "Optional: install GitHub CLI (cli.github.com) and run 'gh auth login' once to enable this. You can always link GitHub later from 'Upload'." }
}
function Fill-History {
    $lvHist.BeginUpdate(); $lvHist.Items.Clear()
    $any = Has-Commits
    if ($any) {
        $notUp = @{}; $all = -not (Has-Upstream)
        if (-not $all) { foreach ($h in ((Invoke-Git @('rev-list', '@{u}..HEAD') -Quiet).Out -split "`r?`n")) { if ($h) { $notUp[$h] = $true } } }
        $rsep = [char]0x1e
        $r = Invoke-Git @('log', '-n', '300', '--date=format:%d %b %Y  %H:%M', '--pretty=format:%H%x1f%h%x1f%ad%x1f%ar%x1f%an%x1f%s%x1e') -Quiet
        foreach ($rec in $r.Out.Split($rsep)) {
            $rec = $rec.Trim("`r", "`n"); if (-not $rec) { continue }
            $f = $rec.Split([char]0x1f)
            $up = -not ($all -or $notUp.ContainsKey($f[0]))
            $it = New-Object System.Windows.Forms.ListViewItem($(if ($up) { 'Yes' } else { 'Not yet' }))
            $it.UseItemStyleForSubItems = $false
            $it.ForeColor = if ($up) { $C.Teal } else { $C.Amber }
            $it.Font = (F 9.5 -Bold)
            [void]$it.SubItems.Add("$($f[3])")
            [void]$it.SubItems.Add($f[4]); [void]$it.SubItems.Add($f[5]); [void]$it.SubItems.Add($f[1])
            $it.ToolTipText = $f[2]
            $it.Tag = $f[0]
            [void]$lvHist.Items.Add($it)
        }
    }
    $lvHist.EndUpdate()
    $lvHist.Visible = $any; $emptyHist.Visible = -not $any
}

# ---------------------------------------------------------------- window
$form = NewC Form @{ Text = 'LiteGit'; StartPosition = 'CenterScreen'; BackColor = $C.White; Font = (F 10); KeyPreview = $true }
$form.Size = New-Object System.Drawing.Size((px 1080), (px 760))
$form.MinimumSize = New-Object System.Drawing.Size((px 880), (px 620))
$tip = New-Object System.Windows.Forms.ToolTip
$bannerTimer = NewC Timer @{ Interval = 9000 }
$bannerTimer.Add_Tick({ $banner.Visible = $false; $bannerTimer.Stop() })

$root = NewC TableLayoutPanel @{ Dock = 'Fill'; ColumnCount = 1; RowCount = 3; Margin = (Pad 0 0 0 0) }
[void]$root.ColumnStyles.Add((CS Percent 100))
[void]$root.RowStyles.Add((RS Absolute (px 70)))
[void]$root.RowStyles.Add((RS Percent 100))
[void]$root.RowStyles.Add((RS Absolute (px 150)))
$form.Controls.Add($root)

# header
$header = NewC TableLayoutPanel @{ Dock = 'Fill'; BackColor = $C.Navy; ColumnCount = 3; RowCount = 1; Margin = (Pad 0 0 0 0); Padding = (Pad (px 22) 0 (px 16) 0) }
[void]$header.ColumnStyles.Add((CS AutoSize)); [void]$header.ColumnStyles.Add((CS Percent 100)); [void]$header.ColumnStyles.Add((CS AutoSize))
[void]$header.RowStyles.Add((RS Percent 100))
$brand = NewC FlowLayoutPanel @{ AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; FlowDirection = 'TopDown'; WrapContents = $false; Anchor = 'Left'; Margin = (Pad 0 0 0 0) }
$brand.Controls.Add((NewC Label @{ Text = 'LiteGit'; AutoSize = $true; Font = (F 17 -Bold); ForeColor = $C.White; Margin = (Pad 0 0 0 0) }))
$brand.Controls.Add((NewC Label @{ Text = 'Git, minus the jargon'; AutoSize = $true; Font = (F 8.5); ForeColor = $C.Sun; Margin = (Pad (px 2) 0 0 0) }))
$header.Controls.Add($brand, 0, 0)
$lblInfo = NewC Label @{ Dock = 'Fill'; TextAlign = 'MiddleLeft'; ForeColor = $C.Ice; Font = (F 10.5 -Bold); Padding = (Pad (px 30) 0 0 0); AutoEllipsis = $true }
$header.Controls.Add($lblInfo, 1, 0)
$hdrBtns = NewC FlowLayoutPanel @{ AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; WrapContents = $false; Anchor = 'Right'; Margin = (Pad 0 0 0 0) }
$btnOpen = New-Button 'Open project...' 'header'
$btnRecent = New-Button ('Recent ' + [char]0x25BE) 'header'
$btnShow = New-Button 'Show files' 'header'
$hdrBtns.Controls.AddRange([System.Windows.Forms.Control[]]@($btnOpen, $btnRecent, $btnShow))
$header.Controls.Add($hdrBtns, 2, 0)
$root.Controls.Add($header, 0, 0)
$tip.SetToolTip($btnOpen, 'Choose a folder on your computer to work with')
$tip.SetToolTip($btnShow, 'Open this project folder in File Explorer')

# middle: sidebar + content
$mid = NewC TableLayoutPanel @{ Dock = 'Fill'; ColumnCount = 2; RowCount = 1; Margin = (Pad 0 0 0 0) }
[void]$mid.ColumnStyles.Add((CS Absolute (px 228))); [void]$mid.ColumnStyles.Add((CS Percent 100))
[void]$mid.RowStyles.Add((RS Percent 100))
$root.Controls.Add($mid, 0, 1)

$side = NewC FlowLayoutPanel @{ Dock = 'Fill'; FlowDirection = 'TopDown'; WrapContents = $false; BackColor = $C.Side; Padding = (Pad (px 12) (px 16) (px 12) (px 12)); Margin = (Pad 0 0 0 0) }
$mid.Controls.Add($side, 0, 0)

$script:Nav = [ordered]@{}
function New-Nav([string]$key, [string]$title, [string]$caption) {
    $pn = NewC Panel @{ Width = (px 202); Height = (px 58); Margin = (Pad 0 0 0 (px 6)); BackColor = $C.Side; Cursor = [System.Windows.Forms.Cursors]::Hand; Tag = $key }
    $bar = NewC Panel @{ Dock = 'Left'; Width = (px 4); BackColor = $C.Side; Tag = $key }
    $t = NewC Label @{ Text = $title; AutoSize = $true; Font = (F 11 -Bold); ForeColor = $C.Navy; Location = (Pt (px 16) (px 9)); Tag = $key; BackColor = [System.Drawing.Color]::Transparent }
    $s = NewC Label @{ Text = $caption; AutoSize = $true; Font = (F 8.5); ForeColor = $C.Muted; Location = (Pt (px 16) (px 32)); Tag = $key; BackColor = [System.Drawing.Color]::Transparent }
    $pn.Controls.AddRange([System.Windows.Forms.Control[]]@($bar, $t, $s))
    foreach ($c in @($pn, $bar, $t, $s)) {
        $c.Add_Click({ Show-Page $this.Tag })
        $c.Add_MouseEnter({ if ($this.Tag -ne $script:Current) { $script:Nav[$this.Tag].Panel.BackColor = $C.Hover } })
        $c.Add_MouseLeave({ if ($this.Tag -ne $script:Current) { $script:Nav[$this.Tag].Panel.BackColor = $C.Side } })
    }
    $script:Nav[$key] = @{ Panel = $pn; Bar = $bar; Caption = $s; Default = $caption }
    $side.Controls.Add($pn)
}
New-Nav 'welcome' 'Start here'    'what all this means'
New-Nav 'save'    'Save changes'  'commit'
New-Nav 'upload'  'Upload'        'push'
New-Nav 'pull'    'Get updates'   'pull / clone'
New-Nav 'new'     'New project'   'create repo'
New-Nav 'history' 'History'       'log'

$content = NewC TableLayoutPanel @{ Dock = 'Fill'; ColumnCount = 1; RowCount = 2; Padding = (Pad (px 34) (px 22) (px 34) (px 14)); Margin = (Pad 0 0 0 0); BackColor = $C.White }
[void]$content.ColumnStyles.Add((CS Percent 100))
[void]$content.RowStyles.Add((RS AutoSize)); [void]$content.RowStyles.Add((RS Percent 100))
$banner = NewC Label @{ AutoSize = $true; Anchor = 'Left, Right'; Visible = $false; Font = (F 10 -Bold); Padding = (Pad (px 12) (px 9) (px 12) (px 9)); Margin = (Pad 0 0 0 (px 12)); Cursor = [System.Windows.Forms.Cursors]::Hand }
$banner.Add_Click({ $banner.Visible = $false })
$content.Controls.Add($banner, 0, 0)
$pageHost = NewC Panel @{ Dock = 'Fill'; Margin = (Pad 0 0 0 0) }
$content.Controls.Add($pageHost, 0, 1)
$mid.Controls.Add($content, 1, 0)

$script:Pages = @{}
function New-Page([string]$key, [string]$title, [string]$desc) {
    $p = NewC TableLayoutPanel @{ Dock = 'Fill'; ColumnCount = 1; Visible = $false; AutoScroll = $true; BackColor = $C.White }
    [void]$p.ColumnStyles.Add((CS Percent 100))
    Add-Row $p (New-Label $title 19 -Bold -Color $C.Navy)
    if ($desc) { $d = New-Label $desc 10.5 -Color $C.Muted -Wrap 720; $d.Margin = (Pad 0 0 0 (px 14)); Add-Row $p $d }
    $pageHost.Controls.Add($p)
    $script:Pages[$key] = $p
    $p
}
function Add-Filler($p) { Add-Row $p (NewC Panel @{ Height = 1; Margin = (Pad 0 0 0 0) }) -Fill }
function New-Section([string]$t) { $l = New-Label $t 12 -Bold -Color $C.Blue; $l.Margin = (Pad 0 (px 14) 0 (px 4)); $l }

# --- Start here
$pg = New-Page 'welcome' 'Welcome to LiteGit' 'Git keeps every version of a project folder, so you can always go back. GitHub is a website that stores a copy online. Five words are all you need:'
$terms = @(
    @('Project  (repository)', 'A folder whose history Git keeps track of.'),
    @('Save  (commit)', 'Take a snapshot of your files with a short note. Stays on your computer.'),
    @('Upload  (push)', 'Send your saved snapshots to GitHub.'),
    @('Get updates  (pull)', 'Bring the newest snapshots from GitHub to this computer.'),
    @('History  (log)', 'The list of every snapshot: who, when and what.')
)
foreach ($t in $terms) {
    $row = New-Flow 2
    $a = New-Label $t[0] 10.5 -Bold -Color $C.Navy; $a.Width = (px 210); $a.AutoSize = $false; $a.Height = (px 24)
    $row.Controls.Add($a); $row.Controls.Add((New-Label $t[1] 10.5 -Color $C.Ink))
    Add-Row $pg $row
}
Add-Row $pg (New-Section 'Get started')
$row = New-Flow
$bW1 = New-Button 'Open a folder'; $bW2 = New-Button 'Start a new project' 'secondary'; $bW3 = New-Button 'Download from GitHub' 'secondary'
$row.Controls.AddRange([System.Windows.Forms.Control[]]@($bW1, $bW2, $bW3)); Add-Row $pg $row
Add-Row $pg (New-Label "Your daily loop:   edit files  ->  Save changes  ->  Upload.   Working on another computer?  Get updates first." 10 -Color $C.Muted -Wrap 720)
Add-Filler $pg

# --- Save changes
$pg = New-Page 'save' 'Save changes' "Tick the files to include, write a short note about what you changed, then click Save. This makes a snapshot on your computer - use 'Upload' to send it to GitHub."
$selRow = New-Flow 0
$lnkAll = NewC LinkLabel @{ Text = 'Tick all'; AutoSize = $true; LinkColor = $C.Blue; Margin = (Pad 0 0 (px 14) 0) }
$lnkNone = NewC LinkLabel @{ Text = 'Untick all'; AutoSize = $true; LinkColor = $C.Blue; Margin = (Pad 0 0 (px 20) 0) }
$lblSel = New-Label '' 9.5 -Color $C.Muted; $lblSel.Margin = (Pad 0 0 0 0)
$selRow.Controls.AddRange([System.Windows.Forms.Control[]]@($lnkAll, $lnkNone, $lblSel)); Add-Row $pg $selRow
$listHost = NewC Panel @{ Dock = 'Fill'; Margin = (Pad 0 (px 4) 0 (px 10)); MinimumSize = (New-Object System.Drawing.Size(0, (px 120))) }
$lvFiles = NewC ListView @{ Dock = 'Fill'; View = 'Details'; CheckBoxes = $true; FullRowSelect = $true; HeaderStyle = 'Nonclickable'; BorderStyle = 'FixedSingle'; Font = (F 10); GridLines = $false }
[void]$lvFiles.Columns.Add('File', (px 500)); [void]$lvFiles.Columns.Add('What happened', (px 150))
$emptySave = NewC Label @{ Dock = 'Fill'; TextAlign = 'MiddleCenter'; Font = (F 12); ForeColor = $C.Muted; BackColor = $C.Side; Visible = $false
    Text = "Nothing changed since your last save.`n`nEdit, add or delete files in your project folder ('Show files' at the top) and they'll appear here." }
$listHost.Controls.Add($lvFiles); $listHost.Controls.Add($emptySave)
Add-Row $pg $listHost -Fill
Add-Row $pg (New-Label 'What did you change?' 10 -Bold -Color $C.Navy)
$txtMsg = NewC TextBox @{ Multiline = $true; Height = (px 58); Anchor = 'Left, Right'; Font = (F 10.5); ScrollBars = 'Vertical'; Margin = (Pad 0 0 0 (px 6)) }
$tip.SetToolTip($txtMsg, 'Example: "Add contact page"  -  Ctrl+Enter to save')
Add-Row $pg $txtMsg
$row = New-Flow
$btnSave = New-Button 'Save snapshot'
$chkUpAfter = NewC CheckBox @{ Text = 'Upload to GitHub right after'; AutoSize = $true; Font = (F 10); Margin = (Pad (px 6) (px 10) 0 0) }
$row.Controls.Add($btnSave); $row.Controls.Add($chkUpAfter); Add-Row $pg $row

# --- Upload
$pg = New-Page 'upload' 'Upload' 'Your saved snapshots live only on this computer until you upload them to GitHub. Upload when you want a backup or want others to see your work.'
$lblUp = New-Label '' 15 -Bold -Color $C.Ink; $lblUp.Margin = (Pad 0 (px 6) 0 (px 8)); Add-Row $pg $lblUp
$lblRemote = New-Label '' 10 -Color $C.Muted -Wrap 720; Add-Row $pg $lblRemote
$row = New-Flow 10
$btnPush = New-Button 'Upload now'; $btnLink = New-Button 'Link to GitHub...' 'secondary'
$row.Controls.Add($btnPush); $row.Controls.Add($btnLink); Add-Row $pg $row
$lblUnsaved = New-Label '' 10 -Color $C.Amber -Wrap 720; $lblUnsaved.Margin = (Pad 0 (px 12) 0 0); Add-Row $pg $lblUnsaved
Add-Row $pg (New-Label "The first upload may open a GitHub sign-in window. That's normal - sign in once and Windows remembers it." 9.5 -Color $C.Muted -Wrap 720)
Add-Filler $pg

# --- Get updates
$pg = New-Page 'pull' 'Get updates' ''
Add-Row $pg (New-Section 'Update this project')
Add-Row $pg (New-Label 'Bring the newest snapshots from GitHub to this computer - for example after working on another PC, or when a teammate uploaded something.' 10.5 -Color $C.Muted -Wrap 720)
$lblPullInfo = New-Label '' 10 -Color $C.Ink -Wrap 720; Add-Row $pg $lblPullInfo
$row = New-Flow; $btnPull = New-Button 'Get latest changes'; $row.Controls.Add($btnPull); Add-Row $pg $row
Add-Row $pg (New-Section 'Download a project from GitHub')
Add-Row $pg (New-Label "On GitHub, open the repository, click the green 'Code' button and copy the HTTPS link. Paste it here." 10.5 -Color $C.Muted -Wrap 720)
$cboClone = NewC ComboBox @{ DropDownStyle = 'DropDown'; Width = (px 600); Font = (F 10.5); Margin = (Pad 0 (px 4) 0 (px 4)) }
Add-Row $pg $cboClone
$row = New-Flow; $btnClone = New-Button 'Download...'; $btnMyRepos = New-Button 'Show my GitHub repos' 'secondary'
$row.Controls.Add($btnClone); $row.Controls.Add($btnMyRepos); Add-Row $pg $row
Add-Filler $pg

# --- New project
$pg = New-Page 'new' 'New project' "Creates a new folder that Git keeps track of. Already have a folder full of files? Use 'Open project...' at the top instead - LiteGit will offer to set it up."
Add-Row $pg (New-Label 'Project name' 10 -Bold -Color $C.Navy)
$txtName = NewC TextBox @{ Width = (px 420); Font = (F 10.5); Margin = (Pad 0 0 0 (px 12)) }; Add-Row $pg $txtName
Add-Row $pg (New-Label 'Create it inside' 10 -Bold -Color $C.Navy)
$row = New-Flow 0
$txtLoc = NewC TextBox @{ Width = (px 420); Font = (F 10.5); Margin = (Pad 0 (px 6) (px 8) 0) }
$btnBrowse = New-Button 'Browse...' 'secondary'
$row.Controls.Add($txtLoc); $row.Controls.Add($btnBrowse); Add-Row $pg $row
$chkReadme = NewC CheckBox @{ Text = 'Add a README file (a short description page)'; AutoSize = $true; Checked = $true; Font = (F 10); Margin = (Pad 0 (px 14) 0 (px 4)) }; Add-Row $pg $chkReadme
$chkGh = NewC CheckBox @{ Text = 'Also create it on GitHub'; AutoSize = $true; Font = (F 10); Margin = (Pad 0 (px 4) 0 (px 2)) }; Add-Row $pg $chkGh
$row = New-Flow 0; $row.Margin = (Pad (px 22) 0 0 0)
$rbPrivate = NewC RadioButton @{ Text = 'Private (only you)'; AutoSize = $true; Checked = $true; Font = (F 10) }
$rbPublic = NewC RadioButton @{ Text = 'Public (anyone can see)'; AutoSize = $true; Font = (F 10); Margin = (Pad (px 16) (px 3) 0 0) }
$row.Controls.Add($rbPrivate); $row.Controls.Add($rbPublic); Add-Row $pg $row
$lblGhHint = New-Label '' 9.5 -Color $C.Muted -Wrap 700; $lblGhHint.Margin = (Pad (px 22) (px 2) 0 (px 10)); Add-Row $pg $lblGhHint
$row = New-Flow; $btnCreate = New-Button 'Create project'; $row.Controls.Add($btnCreate); Add-Row $pg $row
Add-Filler $pg

# --- History
$pg = New-Page 'history' 'History' 'Every snapshot of this project, newest first. Double-click one to see exactly which files it changed.'
$histHost = NewC Panel @{ Dock = 'Fill'; Margin = (Pad 0 (px 4) 0 0) }
$lvHist = NewC ListView @{ Dock = 'Fill'; View = 'Details'; FullRowSelect = $true; HeaderStyle = 'Nonclickable'; BorderStyle = 'FixedSingle'; Font = (F 10); ShowItemToolTips = $true }
foreach ($col in @(@('On GitHub?', 96), @('When', 130), @('Who', 140), @('Note', 360), @('ID', 80))) { [void]$lvHist.Columns.Add($col[0], (px $col[1])) }
$emptyHist = NewC Label @{ Dock = 'Fill'; TextAlign = 'MiddleCenter'; Font = (F 12); ForeColor = $C.Muted; BackColor = $C.Side; Visible = $false; Text = "No snapshots yet.`n`nMake your first one in 'Save changes'." }
$histHost.Controls.Add($lvHist); $histHost.Controls.Add($emptyHist)
Add-Row $pg $histHost -Fill

# log panel
$logWrap = NewC TableLayoutPanel @{ Dock = 'Fill'; BackColor = $C.LogBg; ColumnCount = 1; RowCount = 2; Padding = (Pad (px 18) (px 8) (px 18) (px 8)); Margin = (Pad 0 0 0 0) }
[void]$logWrap.ColumnStyles.Add((CS Percent 100))
[void]$logWrap.RowStyles.Add((RS AutoSize)); [void]$logWrap.RowStyles.Add((RS Percent 100))
$logWrap.Controls.Add((NewC Label @{ Text = 'ACTIVITY  -  the real Git commands LiteGit runs for you'; AutoSize = $true; Font = (F 8.5 -Bold); ForeColor = $C.Sun; Margin = (Pad 0 0 0 (px 4)) }), 0, 0)
$logBox = NewC RichTextBox @{ Dock = 'Fill'; ReadOnly = $true; BorderStyle = 'None'; Font = (F 9.5 -Name $MonoFont); DetectUrls = $false }
$logBox.BackColor = $C.LogBg; $logBox.ForeColor = $C.LogFg
$logWrap.Controls.Add($logBox, 0, 1)
$root.Controls.Add($logWrap, 0, 2)

# ---------------------------------------------------------------- navigation
function Show-Page([string]$key) {
    $target = $key
    if (@('save', 'upload', 'history') -contains $key -and -not (Test-Repo)) {
        $target = 'welcome'
        Flash 'Open a project first - or start a new one.' 'info'
    }
    foreach ($k in @($script:Pages.Keys)) { $script:Pages[$k].Visible = ($k -eq $target) }
    $script:Current = $key; $script:Shown = $target
    foreach ($k in @($script:Nav.Keys)) {
        $sel = ($k -eq $key)
        $script:Nav[$k].Panel.BackColor = if ($sel) { $C.Ice } else { $C.Side }
        $script:Nav[$k].Bar.BackColor = if ($sel) { $C.Blue } else { $C.Side }
    }
    if (-not $script:Busy) { Do-Quiet { Refresh-Page $target } } else { Refresh-Page $target }
}

# ---------------------------------------------------------------- events
$btnOpen.Add_Click({ Do-Action { $p = Pick-Folder 'Choose your project folder' $script:Repo; if ($p) { Open-Repo $p; if (Test-Repo) { Show-Page 'save' } } } })
$btnRecent.Add_Click({
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $menu.Font = (F 10)
    $rec = @(Get-Recent | Where-Object { Test-Path -LiteralPath $_ })
    if (-not $rec.Count) { $mi = $menu.Items.Add('(no recent projects yet)'); $mi.Enabled = $false }
    foreach ($r in $rec) {
        $mi = $menu.Items.Add("$(Split-Path $r -Leaf)     $r")
        $mi.Tag = $r
        $mi.Add_Click({ $t = $this.Tag; Do-Action { Open-Repo $t -Silent; Show-Page 'save'; Flash "Opened '$(Split-Path $t -Leaf)'." 'info' } })
    }
    $menu.Show($btnRecent, (Pt 0 $btnRecent.Height))
})
$btnShow.Add_Click({ if (Test-Repo) { Start-Process explorer.exe -ArgumentList ('"' + $script:Repo + '"') } })

$bW1.Add_Click({ $btnOpen.PerformClick() })
$bW2.Add_Click({ Show-Page 'new' })
$bW3.Add_Click({ Show-Page 'pull'; $cboClone.Focus() })

$lnkAll.Add_LinkClicked({ foreach ($i in $lvFiles.Items) { $i.Checked = $true } })
$lnkNone.Add_LinkClicked({ foreach ($i in $lvFiles.Items) { $i.Checked = $false } })
$lvFiles.Add_ItemChecked({
    if ($script:Filling) { return }
    $p = $_.Item.Tag.Path
    if ($_.Item.Checked) { [void]$script:Unchecked.Remove($p) } else { $script:Unchecked[$p] = $true }
    Update-SaveCount
})
$lvFiles.Add_Resize({ $lvFiles.Columns[0].Width = [Math]::Max((px 200), $lvFiles.ClientSize.Width - $lvFiles.Columns[1].Width - 4) })
$lvHist.Add_Resize({
    $other = 0; foreach ($i in 0, 1, 2, 4) { $other += $lvHist.Columns[$i].Width }
    $lvHist.Columns[3].Width = [Math]::Max((px 160), $lvHist.ClientSize.Width - $other - 4)
})
$lvHist.Add_DoubleClick({ if ($lvHist.SelectedItems.Count) { $h = $lvHist.SelectedItems[0].Tag; Do-Action { Show-CommitDetails $h } } })
$txtMsg.Add_KeyDown({ if ($_.Control -and $_.KeyCode -eq 'Enter') { $_.SuppressKeyPress = $true; $btnSave.PerformClick() } })

$btnSave.Add_Click({ Do-Action { Do-Commit } })
$btnPush.Add_Click({ Do-Action { Do-Push } })
$btnLink.Add_Click({ Do-Action { if (Set-Remote) { Flash 'Linked to GitHub.' }; Refresh-All } })
$btnPull.Add_Click({ Do-Action { Do-Pull } })
$btnClone.Add_Click({ Do-Action { Do-Clone } })
$btnMyRepos.Add_Click({
    Do-Action {
        if (Test-GhReady) { Do-LoadMyRepos }
        else { Show-Warn "GitHub CLI is installed but not signed in.`n`nOpen PowerShell, run:  gh auth login`nthen try again."; $script:GhReady = $null }
    }
})
$btnBrowse.Add_Click({ $p = Pick-Folder 'Where should the new project folder go?' $txtLoc.Text; if ($p) { $txtLoc.Text = $p } })
$chkGh.Add_CheckedChanged({ $rbPrivate.Enabled = $chkGh.Checked; $rbPublic.Enabled = $chkGh.Checked })
$btnCreate.Add_Click({ Do-Action { Do-Create } })

$form.Add_KeyDown({ if ($_.KeyCode -eq 'F5') { Do-Quiet { Refresh-All } } })
$form.Add_Activated({ if ($script:Ready) { Do-Quiet { Refresh-All } } })
$form.Add_Shown({
    Do-Action {
        $script:Unchecked = @{}
        $last = @(Get-Recent | Where-Object { Test-Path -LiteralPath $_ }) | Select-Object -First 1
        if ($last) { Open-Repo $last -Silent }
        Write-Log "LiteGit ready - using $(((Invoke-Git @('--version') -Quiet).Out).Trim())" 'ok'
    }
    if (Test-Repo) { Show-Page 'save' } else { Show-Page 'welcome' }
    $script:Ready = $true
})

$script:Unchecked = @{}; $script:Changes = @(); $script:Ahead = 0; $script:Shown = 'welcome'; $script:Current = 'welcome'
Refresh-All
[void]$form.ShowDialog()
$form.Dispose()
