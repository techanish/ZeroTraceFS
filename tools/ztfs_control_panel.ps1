param(
  [Parameter(Mandatory = $false)]
  [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

function Resolve-ProjectRoot {
  param([string]$ProjectRoot)

  if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
    return (Resolve-Path -LiteralPath $ProjectRoot).Path
  }

  $scriptDir = Split-Path -Parent $PSCommandPath
  return (Resolve-Path -LiteralPath (Join-Path $scriptDir "..")).Path
}

$root = Resolve-ProjectRoot -ProjectRoot $ProjectRoot
$cmdScript = Join-Path $root "tools\ztfs_cmd.ps1"
if (-not (Test-Path -LiteralPath $cmdScript)) {
  throw "Missing command script: $cmdScript"
}

$commandsDir = Join-Path $root ".zerotracefs\commands"
$processedDir = Join-Path $root ".zerotracefs\processed"
$mountDir = Join-Path $root "mount"
$statusFile = Join-Path $root ".zerotracefs\status.json"

if (-not (Test-Path -LiteralPath $commandsDir)) {
  New-Item -ItemType Directory -Path $commandsDir -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $processedDir)) {
  New-Item -ItemType Directory -Path $processedDir -Force | Out-Null
}

function Select-AnyFile {
  param([string]$InitialDirectory)

  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $dlg.Title = "Select file"
  $dlg.Filter = "All files (*.*)|*.*"
  if (-not [string]::IsNullOrWhiteSpace($InitialDirectory) -and (Test-Path -LiteralPath $InitialDirectory)) {
    $dlg.InitialDirectory = $InitialDirectory
  }
  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    return $dlg.FileName
  }
  return $null
}

function Select-FolderPath {
  param([string]$Description)

  $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
  $dlg.Description = $Description
  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    return $dlg.SelectedPath
  }
  return $null
}

function Invoke-ZTFSCommand {
  param(
    [string]$Action,
    [string]$TargetPath,
    [Nullable[Double]]$Minutes,
    [Nullable[Int]]$MaxReads,
    [string]$Deadline,
    [string]$Destination,
    [Nullable[Int]]$Recent,
    [switch]$Force
  )

  $invokeParams = @{
    Action = $Action
    ProjectRoot = $root
    SuppressResultDialog = $true
    WaitSeconds = 0
  }

  if (-not [string]::IsNullOrWhiteSpace($TargetPath)) {
    $invokeParams.TargetPath = $TargetPath
  }
  if ($PSBoundParameters.ContainsKey("Minutes") -and $null -ne $Minutes) {
    $invokeParams.Minutes = $Minutes
  }
  if ($PSBoundParameters.ContainsKey("MaxReads") -and $null -ne $MaxReads) {
    $invokeParams.MaxReads = $MaxReads
  }
  if (-not [string]::IsNullOrWhiteSpace($Deadline)) {
    $invokeParams.Deadline = $Deadline
  }
  if (-not [string]::IsNullOrWhiteSpace($Destination)) {
    $invokeParams.Destination = $Destination
  }
  if ($PSBoundParameters.ContainsKey("Recent") -and $null -ne $Recent) {
    $invokeParams.Recent = $Recent
  }
  if ($Force) {
    $invokeParams.Force = $true
  }

  try {
    $out = & $cmdScript @invokeParams 2>&1 | Out-String
    if ([string]::IsNullOrWhiteSpace($out)) {
      return "Command queued."
    }
    return $out.Trim()
  } catch {
    throw $_
  }
}

function Convert-StatusSummary {
  param([object]$StatusObj)

  if ($null -eq $StatusObj) {
    return "Status not available."
  }

  $lines = @()
  $lines += "Time: $($StatusObj.timestamp)"
  $lines += "Mode: $($StatusObj.control_mode)"
  $lines += "Files: $($StatusObj.files.count)"
  $lines += "Pending commands: $($StatusObj.external_commands.pending)"
  $lines += "Last action: $($StatusObj.external_commands.last_action)"
  $lines += "Last error: $($StatusObj.external_commands.last_error)"
  $lines += "Failed auth: $($StatusObj.auth.failed_attempts) / $($StatusObj.auth.max_attempts)"
  $lines += "Uptime (sec): $($StatusObj.system.uptime_seconds)"
  $lines += "Last sync: $($StatusObj.system.last_sync)"
  $lines += "Global TTL remaining (sec): $($StatusObj.triggers.global_ttl_remaining_seconds)"
  $lines += "Dead-man remaining (sec): $($StatusObj.triggers.dead_man_remaining_seconds)"
  return ($lines -join "`r`n")
}

$script:SeenProcessed = New-Object 'System.Collections.Generic.HashSet[string]'

$form = New-Object System.Windows.Forms.Form
$form.Text = "ZeroTraceFS Control Panel"
$form.Size = New-Object System.Drawing.Size(980, 760)
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)

$title = New-Object System.Windows.Forms.Label
$title.Text = "ZeroTraceFS - Click Control Panel"
$title.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(20, 15)
$form.Controls.Add($title)

$sub = New-Object System.Windows.Forms.Label
$sub.Text = "Keep main.R running in Explorer mode while using these buttons."
$sub.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$sub.AutoSize = $true
$sub.Location = New-Object System.Drawing.Point(20, 45)
$form.Controls.Add($sub)

$statusBox = New-Object System.Windows.Forms.TextBox
$statusBox.Multiline = $true
$statusBox.ReadOnly = $true
$statusBox.ScrollBars = "Vertical"
$statusBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$statusBox.Size = New-Object System.Drawing.Size(930, 120)
$statusBox.Location = New-Object System.Drawing.Point(20, 70)
$form.Controls.Add($statusBox)

$btnImport = New-Object System.Windows.Forms.Button
$btnImport.Text = "Import File"
$btnImport.Size = New-Object System.Drawing.Size(160, 40)
$btnImport.Location = New-Object System.Drawing.Point(20, 205)
$form.Controls.Add($btnImport)

$btnDestroy = New-Object System.Windows.Forms.Button
$btnDestroy.Text = "Destroy File"
$btnDestroy.Size = New-Object System.Drawing.Size(160, 40)
$btnDestroy.Location = New-Object System.Drawing.Point(200, 205)
$form.Controls.Add($btnDestroy)

$btnTTL = New-Object System.Windows.Forms.Button
$btnTTL.Text = "Set TTL"
$btnTTL.Size = New-Object System.Drawing.Size(160, 40)
$btnTTL.Location = New-Object System.Drawing.Point(380, 205)
$form.Controls.Add($btnTTL)

$btnReads = New-Object System.Windows.Forms.Button
$btnReads.Text = "Set Read Limit"
$btnReads.Size = New-Object System.Drawing.Size(160, 40)
$btnReads.Location = New-Object System.Drawing.Point(560, 205)
$form.Controls.Add($btnReads)

$btnDeadline = New-Object System.Windows.Forms.Button
$btnDeadline.Text = "Set Deadline"
$btnDeadline.Size = New-Object System.Drawing.Size(160, 40)
$btnDeadline.Location = New-Object System.Drawing.Point(740, 205)
$form.Controls.Add($btnDeadline)

$btnReadPreview = New-Object System.Windows.Forms.Button
$btnReadPreview.Text = "Read Preview"
$btnReadPreview.Size = New-Object System.Drawing.Size(160, 40)
$btnReadPreview.Location = New-Object System.Drawing.Point(20, 255)
$form.Controls.Add($btnReadPreview)

$btnOpenSecure = New-Object System.Windows.Forms.Button
$btnOpenSecure.Text = "Open Securely"
$btnOpenSecure.Size = New-Object System.Drawing.Size(160, 40)
$btnOpenSecure.Location = New-Object System.Drawing.Point(200, 255)
$form.Controls.Add($btnOpenSecure)

$btnExport = New-Object System.Windows.Forms.Button
$btnExport.Text = "Export File"
$btnExport.Size = New-Object System.Drawing.Size(160, 40)
$btnExport.Location = New-Object System.Drawing.Point(380, 255)
$form.Controls.Add($btnExport)

$btnList = New-Object System.Windows.Forms.Button
$btnList.Text = "List Vault Files"
$btnList.Size = New-Object System.Drawing.Size(160, 40)
$btnList.Location = New-Object System.Drawing.Point(560, 255)
$form.Controls.Add($btnList)

$btnAudit = New-Object System.Windows.Forms.Button
$btnAudit.Text = "Show Audit"
$btnAudit.Size = New-Object System.Drawing.Size(160, 40)
$btnAudit.Location = New-Object System.Drawing.Point(740, 255)
$form.Controls.Add($btnAudit)

$btnRefreshStatus = New-Object System.Windows.Forms.Button
$btnRefreshStatus.Text = "Refresh Status"
$btnRefreshStatus.Size = New-Object System.Drawing.Size(160, 40)
$btnRefreshStatus.Location = New-Object System.Drawing.Point(20, 305)
$form.Controls.Add($btnRefreshStatus)

$btnDestroyAll = New-Object System.Windows.Forms.Button
$btnDestroyAll.Text = "Destroy Entire Vault"
$btnDestroyAll.Size = New-Object System.Drawing.Size(160, 40)
$btnDestroyAll.Location = New-Object System.Drawing.Point(200, 305)
$btnDestroyAll.BackColor = [System.Drawing.Color]::FromArgb(255, 238, 238)
$form.Controls.Add($btnDestroyAll)

$btnLock = New-Object System.Windows.Forms.Button
$btnLock.Text = "Lock Vault"
$btnLock.Size = New-Object System.Drawing.Size(160, 40)
$btnLock.Location = New-Object System.Drawing.Point(380, 305)
$form.Controls.Add($btnLock)

$btnQuit = New-Object System.Windows.Forms.Button
$btnQuit.Text = "Quit Vault"
$btnQuit.Size = New-Object System.Drawing.Size(160, 40)
$btnQuit.Location = New-Object System.Drawing.Point(560, 305)
$form.Controls.Add($btnQuit)

$btnOpenCmd = New-Object System.Windows.Forms.Button
$btnOpenCmd.Text = "Open Commands Folder"
$btnOpenCmd.Size = New-Object System.Drawing.Size(180, 34)
$btnOpenCmd.Location = New-Object System.Drawing.Point(740, 305)
$form.Controls.Add($btnOpenCmd)

$btnOpenProcessed = New-Object System.Windows.Forms.Button
$btnOpenProcessed.Text = "Open Processed Results"
$btnOpenProcessed.Size = New-Object System.Drawing.Size(180, 34)
$btnOpenProcessed.Location = New-Object System.Drawing.Point(740, 345)
$form.Controls.Add($btnOpenProcessed)

$btnOpenMount = New-Object System.Windows.Forms.Button
$btnOpenMount.Text = "Open Mount Folder"
$btnOpenMount.Size = New-Object System.Drawing.Size(180, 34)
$btnOpenMount.Location = New-Object System.Drawing.Point(740, 385)
$form.Controls.Add($btnOpenMount)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ScrollBars = "Vertical"
$logBox.ReadOnly = $true
$logBox.Font = New-Object System.Drawing.Font("Consolas", 10)
$logBox.Size = New-Object System.Drawing.Size(930, 280)
$logBox.Location = New-Object System.Drawing.Point(20, 430)
$form.Controls.Add($logBox)

function Append-Log {
  param([string]$Message)
  $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $logBox.AppendText("[$stamp] $Message`r`n")
}

function Refresh-StatusView {
  if (-not (Test-Path -LiteralPath $statusFile)) {
    $statusBox.Text = "status.json not found yet. Start main.R first."
    return
  }

  try {
    $statusObj = Get-Content -LiteralPath $statusFile -Raw | ConvertFrom-Json
    $statusBox.Text = Convert-StatusSummary -StatusObj $statusObj
  } catch {
    $statusBox.Text = "Could not parse status.json: $($_.Exception.Message)"
  }
}

function Refresh-LatestProcessed {
  $files = Get-ChildItem -LiteralPath $processedDir -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime, Name

  foreach ($item in $files) {
    if ($script:SeenProcessed.Contains($item.FullName)) {
      continue
    }

    [void]$script:SeenProcessed.Add($item.FullName)

    try {
      $obj = Get-Content -LiteralPath $item.FullName -Raw | ConvertFrom-Json
      $action = "unknown"
      if ($null -ne $obj.payload -and $null -ne $obj.payload.action) {
        $action = [string]$obj.payload.action
      }

      Append-Log ("RESULT {0} [{1}]: {2}" -f $obj.status, $action, $obj.message)

      if ($action -eq "read" -and $null -ne $obj.data -and $null -ne $obj.data.preview) {
        $preview = [string]$obj.data.preview
        if ($preview.Length -gt 900) {
          $preview = $preview.Substring(0, 900) + "..."
        }
        Append-Log ("PREVIEW:`r`n{0}" -f $preview)
      }

      if ($action -eq "list" -and $null -ne $obj.data -and $null -ne $obj.data.count) {
        Append-Log ("LIST COUNT: {0}" -f [int]$obj.data.count)
      }

      if ($action -eq "audit" -and $null -ne $obj.data -and $null -ne $obj.data.count) {
        Append-Log ("AUDIT COUNT: {0}" -f [int]$obj.data.count)
      }

      if ($action -eq "open-secure" -and $null -ne $obj.data -and $null -ne $obj.data.temporary_path) {
        Append-Log ("OPENED TEMP FILE: {0}" -f [string]$obj.data.temporary_path)
      }
    } catch {
      Append-Log ("RESULT FILE: {0}" -f $item.Name)
    }
  }
}

$btnImport.Add_Click({
  $file = Select-AnyFile -InitialDirectory $root
  if ($null -eq $file) { return }
  try {
    $result = Invoke-ZTFSCommand -Action "import" -TargetPath $file
    Append-Log $result
  } catch {
    Append-Log "ERROR: $($_.Exception.Message)"
  }
})

$btnDestroy.Add_Click({
  $file = Select-AnyFile -InitialDirectory $mountDir
  if ($null -eq $file) { return }
  try {
    $result = Invoke-ZTFSCommand -Action "destroy" -TargetPath $file
    Append-Log $result
  } catch {
    Append-Log "ERROR: $($_.Exception.Message)"
  }
})

$btnTTL.Add_Click({
  $file = Select-AnyFile -InitialDirectory $mountDir
  if ($null -eq $file) { return }
  $input = [Microsoft.VisualBasic.Interaction]::InputBox("Enter TTL in minutes", "Set TTL", "10")
  if ([string]::IsNullOrWhiteSpace($input)) { return }
  $value = 0.0
  if (-not [double]::TryParse($input, [ref]$value) -or $value -le 0) {
    [System.Windows.Forms.MessageBox]::Show("TTL must be a positive number.", "Invalid input") | Out-Null
    return
  }
  try {
    $result = Invoke-ZTFSCommand -Action "set-ttl" -TargetPath $file -Minutes $value
    Append-Log $result
  } catch {
    Append-Log "ERROR: $($_.Exception.Message)"
  }
})

$btnReads.Add_Click({
  $file = Select-AnyFile -InitialDirectory $mountDir
  if ($null -eq $file) { return }
  $input = [Microsoft.VisualBasic.Interaction]::InputBox("Enter max reads", "Set Read Limit", "3")
  if ([string]::IsNullOrWhiteSpace($input)) { return }
  $value = 0
  if (-not [int]::TryParse($input, [ref]$value) -or $value -lt 1) {
    [System.Windows.Forms.MessageBox]::Show("Max reads must be an integer >= 1.", "Invalid input") | Out-Null
    return
  }
  try {
    $result = Invoke-ZTFSCommand -Action "set-reads" -TargetPath $file -MaxReads $value
    Append-Log $result
  } catch {
    Append-Log "ERROR: $($_.Exception.Message)"
  }
})

$btnDeadline.Add_Click({
  $file = Select-AnyFile -InitialDirectory $mountDir
  if ($null -eq $file) { return }
  $input = [Microsoft.VisualBasic.Interaction]::InputBox("Enter deadline (YYYY-MM-DD HH:MM:SS)", "Set Deadline", (Get-Date).AddMinutes(10).ToString("yyyy-MM-dd HH:mm:ss"))
  if ([string]::IsNullOrWhiteSpace($input)) { return }
  try {
    $result = Invoke-ZTFSCommand -Action "set-deadline" -TargetPath $file -Deadline $input
    Append-Log $result
  } catch {
    Append-Log "ERROR: $($_.Exception.Message)"
  }
})

$btnReadPreview.Add_Click({
  $file = Select-AnyFile -InitialDirectory $mountDir
  if ($null -eq $file) { return }
  try {
    $result = Invoke-ZTFSCommand -Action "read" -TargetPath $file
    Append-Log $result
  } catch {
    Append-Log "ERROR: $($_.Exception.Message)"
  }
})

$btnOpenSecure.Add_Click({
  $file = Select-AnyFile -InitialDirectory $mountDir
  if ($null -eq $file) { return }
  try {
    $result = Invoke-ZTFSCommand -Action "open-secure" -TargetPath $file
    Append-Log $result
  } catch {
    Append-Log "ERROR: $($_.Exception.Message)"
  }
})

$btnExport.Add_Click({
  $file = Select-AnyFile -InitialDirectory $mountDir
  if ($null -eq $file) { return }
  $dest = Select-FolderPath -Description "Select destination folder for export"
  if ([string]::IsNullOrWhiteSpace($dest)) { return }
  try {
    $result = Invoke-ZTFSCommand -Action "export" -TargetPath $file -Destination $dest
    Append-Log $result
  } catch {
    Append-Log "ERROR: $($_.Exception.Message)"
  }
})

$btnList.Add_Click({
  try {
    $result = Invoke-ZTFSCommand -Action "list"
    Append-Log $result
  } catch {
    Append-Log "ERROR: $($_.Exception.Message)"
  }
})

$btnAudit.Add_Click({
  $input = [Microsoft.VisualBasic.Interaction]::InputBox("How many recent audit entries?", "Audit", "20")
  if ([string]::IsNullOrWhiteSpace($input)) { return }
  $n = 0
  if (-not [int]::TryParse($input, [ref]$n) -or $n -lt 1) {
    [System.Windows.Forms.MessageBox]::Show("Recent count must be integer >= 1.", "Invalid input") | Out-Null
    return
  }
  try {
    $result = Invoke-ZTFSCommand -Action "audit" -Recent $n
    Append-Log $result
  } catch {
    Append-Log "ERROR: $($_.Exception.Message)"
  }
})

$btnRefreshStatus.Add_Click({
  try {
    Refresh-StatusView
    $result = Invoke-ZTFSCommand -Action "status"
    Append-Log $result
  } catch {
    Append-Log "ERROR: $($_.Exception.Message)"
  }
})

$btnDestroyAll.Add_Click({
  $confirm = [System.Windows.Forms.MessageBox]::Show("Destroy the entire vault?", "Confirm", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
  if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
  try {
    $result = Invoke-ZTFSCommand -Action "destroy-all" -Force
    Append-Log $result
  } catch {
    Append-Log "ERROR: $($_.Exception.Message)"
  }
})

$btnLock.Add_Click({
  try {
    $result = Invoke-ZTFSCommand -Action "lock"
    Append-Log $result
  } catch {
    Append-Log "ERROR: $($_.Exception.Message)"
  }
})

$btnQuit.Add_Click({
  try {
    $result = Invoke-ZTFSCommand -Action "quit"
    Append-Log $result
  } catch {
    Append-Log "ERROR: $($_.Exception.Message)"
  }
})

$btnOpenCmd.Add_Click({
  Start-Process explorer.exe $commandsDir
})

$btnOpenProcessed.Add_Click({
  Start-Process explorer.exe $processedDir
})

$btnOpenMount.Add_Click({
  Start-Process explorer.exe $mountDir
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({
  Refresh-StatusView
  Refresh-LatestProcessed
})
$timer.Start()

Append-Log "Control panel ready."
Append-Log "Project root: $root"
Append-Log "Run main.R and keep it in Explorer mode for command execution."
Append-Log "Use Open Securely to open files with password prompt from UI."
Append-Log "Tip: Click Refresh Status after launching main.R for latest runtime state."
Refresh-StatusView

[void]$form.ShowDialog()
