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

  # Check if a file is selected in quick selector (if it exists)
  if ($null -ne $script:quickFileBox -and $script:quickFileBox.SelectedIndex -gt 0) {
    $selectedFile = Join-Path $mountDir $script:quickFileBox.SelectedItem
    if (Test-Path -LiteralPath $selectedFile) {
      return $selectedFile
    }
  }

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

  if ($null -ne $StatusObj.files -and $null -ne $StatusObj.files.details) {
    $lines += ""
    $lines += "File details:"
    foreach ($detail in $StatusObj.files.details) {
      $lines += ("- {0} | reads={1} | ttl_remaining={2}" -f $detail.filename, $detail.read_count, $detail.ttl_remaining_seconds)
    }
  }

  return ($lines -join "`r`n")
}

$script:SeenProcessed = New-Object 'System.Collections.Generic.HashSet[string]'

$form = New-Object System.Windows.Forms.Form
$form.Text = "ZeroTraceFS Control Panel"
$form.Size = New-Object System.Drawing.Size(1000, 800)
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.Color]::FromArgb(240, 244, 248)
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$title = New-Object System.Windows.Forms.Label
$title.Text = "ZeroTraceFS Control Panel"
$title.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = [System.Drawing.Color]::FromArgb(30, 58, 138)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(25, 20)
$form.Controls.Add($title)

$sub = New-Object System.Windows.Forms.Label
$sub.Text = "Keep main.R running in Explorer mode while using these controls"
$sub.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$sub.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
$sub.AutoSize = $true
$sub.Location = New-Object System.Drawing.Point(25, 52)
$form.Controls.Add($sub)

# Runtime health status indicator
$statusIndicator = New-Object System.Windows.Forms.Label
$statusIndicator.Size = New-Object System.Drawing.Size(940, 8)
$statusIndicator.Location = New-Object System.Drawing.Point(25, 75)
$statusIndicator.BackColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
$form.Controls.Add($statusIndicator)

$statusBox = New-Object System.Windows.Forms.TextBox
$statusBox.Multiline = $true
$statusBox.ReadOnly = $true
$statusBox.ScrollBars = "Vertical"
$statusBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$statusBox.BackColor = [System.Drawing.Color]::White
$statusBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$statusBox.Size = New-Object System.Drawing.Size(760, 130)
$statusBox.Location = New-Object System.Drawing.Point(25, 85)
$form.Controls.Add($statusBox)

# Quick file selector panel
$quickFileLabel = New-Object System.Windows.Forms.Label
$quickFileLabel.Text = "Quick Select:"
$quickFileLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
$quickFileLabel.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
$quickFileLabel.AutoSize = $true
$quickFileLabel.Location = New-Object System.Drawing.Point(795, 85)
$form.Controls.Add($quickFileLabel)

$script:quickFileBox = New-Object System.Windows.Forms.ComboBox
$script:quickFileBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$script:quickFileBox.Font = New-Object System.Drawing.Font("Consolas", 8)
$script:quickFileBox.Size = New-Object System.Drawing.Size(165, 25)
$script:quickFileBox.Location = New-Object System.Drawing.Point(795, 105)
$form.Controls.Add($script:quickFileBox)

function Update-QuickFileList {
  if ($null -eq $script:quickFileBox) { return }
  
  $script:quickFileBox.Items.Clear()
  [void]$script:quickFileBox.Items.Add("(Select a file...)")
  
  if (Test-Path -LiteralPath $mountDir) {
    $files = Get-ChildItem -LiteralPath $mountDir -File -ErrorAction SilentlyContinue | Select-Object -First 15
    foreach ($file in $files) {
      [void]$script:quickFileBox.Items.Add($file.Name)
    }
  }
  
  $script:quickFileBox.SelectedIndex = 0
}

# Helper function to create styled buttons
function New-StyledButton {
  param(
    [string]$Text,
    [System.Drawing.Point]$Location,
    [System.Drawing.Size]$Size,
    [System.Drawing.Color]$BackColor = [System.Drawing.Color]::FromArgb(59, 130, 246),
    [System.Drawing.Color]$ForeColor = [System.Drawing.Color]::White
  )
  
  $btn = New-Object System.Windows.Forms.Button
  $btn.Text = $Text
  $btn.Location = $Location
  $btn.Size = $Size
  $btn.BackColor = $BackColor
  $btn.ForeColor = $ForeColor
  $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $btn.FlatAppearance.BorderSize = 0
  $btn.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)
  $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
  return $btn
}

$btnImport = New-StyledButton -Text "&Import File" -Location (New-Object System.Drawing.Point(25, 230)) -Size (New-Object System.Drawing.Size(165, 42))
$form.Controls.Add($btnImport)

$btnDestroy = New-StyledButton -Text "&Destroy File" -Location (New-Object System.Drawing.Point(205, 230)) -Size (New-Object System.Drawing.Size(165, 42)) -BackColor ([System.Drawing.Color]::FromArgb(220, 38, 38))
$form.Controls.Add($btnDestroy)

$btnTTL = New-StyledButton -Text "Set &TTL" -Location (New-Object System.Drawing.Point(385, 230)) -Size (New-Object System.Drawing.Size(165, 42)) -BackColor ([System.Drawing.Color]::FromArgb(14, 165, 233))
$form.Controls.Add($btnTTL)

$btnReads = New-StyledButton -Text "Set Read &Limit" -Location (New-Object System.Drawing.Point(565, 230)) -Size (New-Object System.Drawing.Size(165, 42)) -BackColor ([System.Drawing.Color]::FromArgb(14, 165, 233))
$form.Controls.Add($btnReads)

$btnDeadline = New-StyledButton -Text "Set Dea&dline" -Location (New-Object System.Drawing.Point(745, 230)) -Size (New-Object System.Drawing.Size(165, 42)) -BackColor ([System.Drawing.Color]::FromArgb(14, 165, 233))
$form.Controls.Add($btnDeadline)

$btnReadPreview = New-StyledButton -Text "&Read Preview" -Location (New-Object System.Drawing.Point(25, 285)) -Size (New-Object System.Drawing.Size(165, 42)) -BackColor ([System.Drawing.Color]::FromArgb(16, 185, 129))
$form.Controls.Add($btnReadPreview)

$btnOpenSecure = New-StyledButton -Text "&Open Securely" -Location (New-Object System.Drawing.Point(205, 285)) -Size (New-Object System.Drawing.Size(165, 42)) -BackColor ([System.Drawing.Color]::FromArgb(139, 92, 246))
$form.Controls.Add($btnOpenSecure)

$btnExport = New-StyledButton -Text "&Export File" -Location (New-Object System.Drawing.Point(385, 285)) -Size (New-Object System.Drawing.Size(165, 42)) -BackColor ([System.Drawing.Color]::FromArgb(16, 185, 129))
$form.Controls.Add($btnExport)

$btnList = New-StyledButton -Text "&List Vault Files" -Location (New-Object System.Drawing.Point(565, 285)) -Size (New-Object System.Drawing.Size(165, 42)) -BackColor ([System.Drawing.Color]::FromArgb(100, 116, 139))
$form.Controls.Add($btnList)

$btnAudit = New-StyledButton -Text "Show &Audit" -Location (New-Object System.Drawing.Point(745, 285)) -Size (New-Object System.Drawing.Size(165, 42)) -BackColor ([System.Drawing.Color]::FromArgb(100, 116, 139))
$form.Controls.Add($btnAudit)

$btnRefreshStatus = New-StyledButton -Text "Refresh &Status" -Location (New-Object System.Drawing.Point(25, 340)) -Size (New-Object System.Drawing.Size(165, 42)) -BackColor ([System.Drawing.Color]::FromArgb(59, 130, 246))
$form.Controls.Add($btnRefreshStatus)

$btnDestroyAll = New-StyledButton -Text "Destroy Vault" -Location (New-Object System.Drawing.Point(205, 340)) -Size (New-Object System.Drawing.Size(165, 42)) -BackColor ([System.Drawing.Color]::FromArgb(185, 28, 28))
$form.Controls.Add($btnDestroyAll)

$btnLock = New-StyledButton -Text "Lock Vault" -Location (New-Object System.Drawing.Point(385, 340)) -Size (New-Object System.Drawing.Size(165, 42)) -BackColor ([System.Drawing.Color]::FromArgb(234, 88, 12))
$form.Controls.Add($btnLock)

$btnQuit = New-StyledButton -Text "Quit Vault" -Location (New-Object System.Drawing.Point(565, 340)) -Size (New-Object System.Drawing.Size(165, 42)) -BackColor ([System.Drawing.Color]::FromArgb(234, 88, 12))
$form.Controls.Add($btnQuit)

$btnOpenCmd = New-StyledButton -Text "Commands Folder" -Location (New-Object System.Drawing.Point(745, 340)) -Size (New-Object System.Drawing.Size(165, 36)) -BackColor ([System.Drawing.Color]::FromArgb(71, 85, 105)) -ForeColor ([System.Drawing.Color]::White)
$form.Controls.Add($btnOpenCmd)

$btnOpenProcessed = New-StyledButton -Text "Processed Results" -Location (New-Object System.Drawing.Point(745, 382)) -Size (New-Object System.Drawing.Size(165, 36)) -BackColor ([System.Drawing.Color]::FromArgb(71, 85, 105)) -ForeColor ([System.Drawing.Color]::White)
$form.Controls.Add($btnOpenProcessed)

$btnOpenMount = New-StyledButton -Text "Mount Folder" -Location (New-Object System.Drawing.Point(745, 424)) -Size (New-Object System.Drawing.Size(165, 36)) -BackColor ([System.Drawing.Color]::FromArgb(71, 85, 105)) -ForeColor ([System.Drawing.Color]::White)
$form.Controls.Add($btnOpenMount)

$commandLabel = New-Object System.Windows.Forms.Label
$commandLabel.Text = 'Quick Command (e.g., status, read "path/file.txt", set-ttl "path/file.txt" 5)'
$commandLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$commandLabel.ForeColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
$commandLabel.AutoSize = $true
$commandLabel.Location = New-Object System.Drawing.Point(25, 475)
$form.Controls.Add($commandLabel)

$commandBox = New-Object System.Windows.Forms.TextBox
$commandBox.Size = New-Object System.Drawing.Size(660, 28)
$commandBox.Location = New-Object System.Drawing.Point(25, 500)
$commandBox.Font = New-Object System.Drawing.Font("Consolas", 10)
$commandBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$form.Controls.Add($commandBox)

$btnRunCommand = New-StyledButton -Text "Run" -Location (New-Object System.Drawing.Point(695, 497)) -Size (New-Object System.Drawing.Size(95, 32)) -BackColor ([System.Drawing.Color]::FromArgb(34, 197, 94))
$form.Controls.Add($btnRunCommand)

$btnClearLog = New-StyledButton -Text "Clear Log" -Location (New-Object System.Drawing.Point(800, 497)) -Size (New-Object System.Drawing.Size(110, 32)) -BackColor ([System.Drawing.Color]::FromArgb(148, 163, 184))
$form.Controls.Add($btnClearLog)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ScrollBars = "Vertical"
$logBox.ReadOnly = $true
$logBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$logBox.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
$logBox.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
$logBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$logBox.Size = New-Object System.Drawing.Size(940, 220)
$logBox.Location = New-Object System.Drawing.Point(25, 545)
$form.Controls.Add($logBox)

function Write-LogMessage {
  param(
    [string]$Message,
    [string]$Type = "info"
  )
  $stamp = Get-Date -Format "HH:mm:ss"
  
  # Color coding prefix based on type
  $prefix = switch ($type) {
    "success" { "[OK]" }
    "error"   { "[ERR]" }
    "info"    { "[i]" }
    default   { "[i]" }
  }
  
  $logBox.AppendText("[$stamp] $prefix $Message`r`n")
  
  # Auto-scroll to bottom
  $logBox.SelectionStart = $logBox.Text.Length
  $logBox.ScrollToCaret()
}

function Update-StatusView {
  if (-not (Test-Path -LiteralPath $statusFile)) {
    $statusBox.Text = "status.json not found yet. Start main.R first."
    $statusIndicator.BackColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
    return
  }

  try {
    $statusObj = Get-Content -LiteralPath $statusFile -Raw | ConvertFrom-Json
    $statusBox.Text = Convert-StatusSummary -StatusObj $statusObj
    
    # Update health indicator based on timestamp age
    $timestampRaw = [string]$statusObj.timestamp
    if (-not [string]::IsNullOrWhiteSpace($timestampRaw)) {
      $statusUtc = (Get-Date -Date $timestampRaw).ToUniversalTime()
      $age = [Math]::Abs(((Get-Date).ToUniversalTime() - $statusUtc).TotalSeconds)
      
      if ($age -le 35) {
        $statusIndicator.BackColor = [System.Drawing.Color]::FromArgb(34, 197, 94)  # Green - healthy
      } elseif ($age -le 300) {
        $statusIndicator.BackColor = [System.Drawing.Color]::FromArgb(251, 191, 36)  # Yellow - warning
      } else {
        $statusIndicator.BackColor = [System.Drawing.Color]::FromArgb(239, 68, 68)   # Red - inactive
      }
    } else {
      $statusIndicator.BackColor = [System.Drawing.Color]::FromArgb(203, 213, 225)  # Gray - unknown
    }
  } catch {
    $statusBox.Text = "Could not parse status.json: $($_.Exception.Message)"
    $statusIndicator.BackColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
  }
}

function Update-LatestProcessed {
  $files = Get-ChildItem -LiteralPath $processedDir -File -Filter *.json -ErrorAction SilentlyContinue |
    Where-Object { -not $script:SeenProcessed.Contains($_.FullName) } |
    Sort-Object LastWriteTime, Name

  foreach ($item in $files) {
    [void]$script:SeenProcessed.Add($item.FullName)

    try {
      $obj = Get-Content -LiteralPath $item.FullName -Raw | ConvertFrom-Json
      $action = "unknown"
      if ($null -ne $obj.payload -and $null -ne $obj.payload.action) {
        $action = [string]$obj.payload.action
      }

      $logType = if ([string]$obj.status -eq "ok") { "success" } else { "error" }
      Write-LogMessage ("RESULT {0} [{1}]: {2}" -f $obj.status, $action, $obj.message) -Type $logType

      if ($action -eq "read" -and $null -ne $obj.data -and $null -ne $obj.data.preview) {
        $preview = [string]$obj.data.preview
        if ($preview.Length -gt 900) {
          $preview = $preview.Substring(0, 900) + "..."
        }
        Write-LogMessage ("PREVIEW:`r`n{0}" -f $preview) -Type "info"
      }

      if ($action -eq "list" -and $null -ne $obj.data -and $null -ne $obj.data.count) {
        Write-LogMessage ("LIST COUNT: {0}" -f [int]$obj.data.count) -Type "info"
      }

      if ($action -eq "audit" -and $null -ne $obj.data -and $null -ne $obj.data.count) {
        Write-LogMessage ("AUDIT COUNT: {0}" -f [int]$obj.data.count) -Type "info"
      }

      if ($action -eq "open-secure" -and $null -ne $obj.data -and $null -ne $obj.data.temporary_path) {
        Write-LogMessage ("OPENED TEMP FILE: {0}" -f [string]$obj.data.temporary_path) -Type "success"
      }
    } catch {
      Write-LogMessage ("RESULT FILE: {0}" -f $item.Name) -Type "info"
    }
  }
}

function Split-CommandParts {
  param([string]$CommandText)

  $parts = @()
  $regexMatches = [regex]::Matches($CommandText, '"([^"]*)"|\S+')
  foreach ($m in $regexMatches) {
    if ($m.Groups[1].Success) {
      $parts += $m.Groups[1].Value
    } else {
      $parts += $m.Value
    }
  }
  return $parts
}

function Invoke-FreeformCommand {
  param([string]$CommandText)

  $trimmed = [string]::Trim($CommandText)
  if ([string]::IsNullOrWhiteSpace($trimmed)) {
    return
  }

  $parts = Split-CommandParts -CommandText $trimmed
  if ($parts.Count -eq 0) {
    return
  }

  $verb = $parts[0].ToLowerInvariant()
  $result = $null

  Write-LogMessage ("Processing command: " + $verb + "...") -Type "info"
  
  switch ($verb) {
    "status" { $result = Invoke-ZTFSCommand -Action "status" }
    "list" { $result = Invoke-ZTFSCommand -Action "list" }
    "audit" {
      $recent = 20
      if ($parts.Count -ge 2) {
        [void][int]::TryParse($parts[1], [ref]$recent)
      }
      $result = Invoke-ZTFSCommand -Action "audit" -Recent $recent
    }
    "read" {
      if ($parts.Count -lt 2) { throw 'Usage: read [path]' }
      $result = Invoke-ZTFSCommand -Action "read" -TargetPath $parts[1]
    }
    "open-secure" {
      if ($parts.Count -lt 2) { throw 'Usage: open-secure [path]' }
      $result = Invoke-ZTFSCommand -Action "open-secure" -TargetPath $parts[1]
    }
    "import" {
      if ($parts.Count -lt 2) { throw 'Usage: import [path]' }
      $result = Invoke-ZTFSCommand -Action "import" -TargetPath $parts[1]
    }
    "destroy" {
      if ($parts.Count -lt 2) { throw 'Usage: destroy [path]' }
      $result = Invoke-ZTFSCommand -Action "destroy" -TargetPath $parts[1]
    }
    "set-ttl" {
      if ($parts.Count -lt 3) { throw 'Usage: set-ttl [path] [minutes]' }
      $minutes = 0.0
      if (-not [double]::TryParse($parts[2], [ref]$minutes)) {
        throw "set-ttl requires numeric minutes."
      }
      $result = Invoke-ZTFSCommand -Action "set-ttl" -TargetPath $parts[1] -Minutes $minutes
    }
    "set-reads" {
      if ($parts.Count -lt 3) { throw 'Usage: set-reads [path] [count]' }
      $count = 0
      if (-not [int]::TryParse($parts[2], [ref]$count)) {
        throw "set-reads requires integer max reads."
      }
      $result = Invoke-ZTFSCommand -Action "set-reads" -TargetPath $parts[1] -MaxReads $count
    }
    "set-deadline" {
      if ($parts.Count -lt 3) { throw 'Usage: set-deadline [path] [yyyy-mm-dd hh:mm:ss]' }
      $deadline = ($parts[2..($parts.Count - 1)] -join " ")
      $result = Invoke-ZTFSCommand -Action "set-deadline" -TargetPath $parts[1] -Deadline $deadline
    }
    "export" {
      if ($parts.Count -lt 2) { throw 'Usage: export [path] [destination]' }
      if ($parts.Count -ge 3) {
        $result = Invoke-ZTFSCommand -Action "export" -TargetPath $parts[1] -Destination $parts[2]
      } else {
        $result = Invoke-ZTFSCommand -Action "export" -TargetPath $parts[1]
      }
    }
    "lock" { $result = Invoke-ZTFSCommand -Action "lock" }
    "quit" { $result = Invoke-ZTFSCommand -Action "quit" }
    "destroy-all" { $result = Invoke-ZTFSCommand -Action "destroy-all" -Force }
    default { throw "Unsupported command. Use status/list/read/open-secure/import/destroy/set-ttl/set-reads/set-deadline/export/audit/lock/quit/destroy-all" }
  }

  if (-not [string]::IsNullOrWhiteSpace($result)) {
    Write-LogMessage $result -Type "success"
  }
}

$btnImport.Add_Click({
  $file = Select-AnyFile -InitialDirectory $root
  if ($null -eq $file) { return }
  try {
    $result = Invoke-ZTFSCommand -Action "import" -TargetPath $file
    Write-LogMessage $result -Type "success"
  } catch {
    Write-LogMessage "ERROR: $($_.Exception.Message)" -Type "error"
  }
})

$btnDestroy.Add_Click({
  $file = Select-AnyFile -InitialDirectory $mountDir
  if ($null -eq $file) { return }
  try {
    $result = Invoke-ZTFSCommand -Action "destroy" -TargetPath $file
    Write-LogMessage $result -Type "success"
  } catch {
    Write-LogMessage "ERROR: $($_.Exception.Message)" -Type "error"
  }
})

$btnTTL.Add_Click({
  $file = Select-AnyFile -InitialDirectory $mountDir
  if ($null -eq $file) { return }
  $userInput = [Microsoft.VisualBasic.Interaction]::InputBox("Enter TTL in minutes", "Set TTL", "10")
  if ([string]::IsNullOrWhiteSpace($userInput)) { return }
  $value = 0.0
  if (-not [double]::TryParse($userInput, [ref]$value) -or $value -le 0) {
    [System.Windows.Forms.MessageBox]::Show("TTL must be a positive number.", "Invalid input") | Out-Null
    return
  }
  try {
    $result = Invoke-ZTFSCommand -Action "set-ttl" -TargetPath $file -Minutes $value
    Write-LogMessage $result -Type "success"
  } catch {
    Write-LogMessage "ERROR: $($_.Exception.Message)" -Type "error"
  }
})

$btnReads.Add_Click({
  $file = Select-AnyFile -InitialDirectory $mountDir
  if ($null -eq $file) { return }
  $userInput = [Microsoft.VisualBasic.Interaction]::InputBox("Enter max reads", "Set Read Limit", "3")
  if ([string]::IsNullOrWhiteSpace($userInput)) { return }
  $value = 0
  if (-not [int]::TryParse($userInput, [ref]$value) -or $value -lt 1) {
    [System.Windows.Forms.MessageBox]::Show("Max reads must be an integer >= 1.", "Invalid input") | Out-Null
    return
  }
  try {
    $result = Invoke-ZTFSCommand -Action "set-reads" -TargetPath $file -MaxReads $value
    Write-LogMessage $result -Type "success"
  } catch {
    Write-LogMessage "ERROR: $($_.Exception.Message)" -Type "error"
  }
})

$btnDeadline.Add_Click({
  $file = Select-AnyFile -InitialDirectory $mountDir
  if ($null -eq $file) { return }
  $userInput = [Microsoft.VisualBasic.Interaction]::InputBox("Enter deadline (YYYY-MM-DD HH:MM:SS)", "Set Deadline", (Get-Date).AddMinutes(10).ToString("yyyy-MM-dd HH:mm:ss"))
  if ([string]::IsNullOrWhiteSpace($userInput)) { return }
  try {
    $result = Invoke-ZTFSCommand -Action "set-deadline" -TargetPath $file -Deadline $userInput
    Write-LogMessage $result -Type "success"
  } catch {
    Write-LogMessage "ERROR: $($_.Exception.Message)" -Type "error"
  }
})

$btnReadPreview.Add_Click({
  $file = Select-AnyFile -InitialDirectory $mountDir
  if ($null -eq $file) { return }
  try {
    $result = Invoke-ZTFSCommand -Action "read" -TargetPath $file
    Write-LogMessage $result -Type "info"
  } catch {
    Write-LogMessage "ERROR: $($_.Exception.Message)" -Type "error"
  }
})

$btnOpenSecure.Add_Click({
  $file = Select-AnyFile -InitialDirectory $mountDir
  if ($null -eq $file) { return }
  try {
    $result = Invoke-ZTFSCommand -Action "open-secure" -TargetPath $file
    Write-LogMessage $result -Type "success"
  } catch {
    Write-LogMessage "ERROR: $($_.Exception.Message)" -Type "error"
  }
})

$btnExport.Add_Click({
  $file = Select-AnyFile -InitialDirectory $mountDir
  if ($null -eq $file) { return }
  $dest = Select-FolderPath -Description "Select destination folder for export"
  if ([string]::IsNullOrWhiteSpace($dest)) { return }
  try {
    $result = Invoke-ZTFSCommand -Action "export" -TargetPath $file -Destination $dest
    Write-LogMessage $result -Type "success"
  } catch {
    Write-LogMessage "ERROR: $($_.Exception.Message)" -Type "error"
  }
})

$btnList.Add_Click({
  try {
    $result = Invoke-ZTFSCommand -Action "list"
    Write-LogMessage $result -Type "info"
  } catch {
    Write-LogMessage "ERROR: $($_.Exception.Message)" -Type "error"
  }
})

$btnAudit.Add_Click({
  $userInput = [Microsoft.VisualBasic.Interaction]::InputBox("How many recent audit entries?", "Audit", "20")
  if ([string]::IsNullOrWhiteSpace($userInput)) { return }
  $n = 0
  if (-not [int]::TryParse($userInput, [ref]$n) -or $n -lt 1) {
    [System.Windows.Forms.MessageBox]::Show("Recent count must be integer >= 1.", "Invalid input") | Out-Null
    return
  }
  try {
    $result = Invoke-ZTFSCommand -Action "audit" -Recent $n
    Write-LogMessage $result -Type "info"
  } catch {
    Write-LogMessage "ERROR: $($_.Exception.Message)" -Type "error"
  }
})

$btnRefreshStatus.Add_Click({
  try {
    Update-StatusView
    $result = Invoke-ZTFSCommand -Action "status"
    Write-LogMessage $result -Type "info"
  } catch {
    Write-LogMessage "ERROR: $($_.Exception.Message)" -Type "error"
  }
})

$btnDestroyAll.Add_Click({
  $confirm = [System.Windows.Forms.MessageBox]::Show("Destroy the entire vault?", "Confirm", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
  if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
  try {
    $result = Invoke-ZTFSCommand -Action "destroy-all" -Force
    Write-LogMessage $result -Type "success"
  } catch {
    Write-LogMessage "ERROR: $($_.Exception.Message)" -Type "error"
  }
})

$btnLock.Add_Click({
  try {
    $result = Invoke-ZTFSCommand -Action "lock"
    Write-LogMessage $result -Type "success"
  } catch {
    Write-LogMessage "ERROR: $($_.Exception.Message)" -Type "error"
  }
})

$btnQuit.Add_Click({
  try {
    $result = Invoke-ZTFSCommand -Action "quit"
    Write-LogMessage $result -Type "success"
  } catch {
    Write-LogMessage "ERROR: $($_.Exception.Message)" -Type "error"
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

$btnRunCommand.Add_Click({
  try {
    Invoke-FreeformCommand -CommandText $commandBox.Text
    $commandBox.Clear()
  } catch {
    Write-LogMessage "ERROR: $($_.Exception.Message)" -Type "error"
  }
})

$btnClearLog.Add_Click({
  $logBox.Clear()
  Write-LogMessage "Log cleared." -Type "info"
})

$commandBox.Add_KeyDown({
  param($s, $e)
  if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
    try {
      Invoke-FreeformCommand -CommandText $commandBox.Text
      $commandBox.Clear()
      $e.SuppressKeyPress = $true
    } catch {
      Write-LogMessage "ERROR: $($_.Exception.Message)" -Type "error"
    }
  }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({
  Update-StatusView
  Update-LatestProcessed
  Update-QuickFileList
})
$timer.Start()

Write-LogMessage "Control panel ready. ZeroTraceFS enhanced version." -Type "success"
Write-LogMessage "Project root: $root" -Type "info"
Write-LogMessage "Run main.R and keep it in Explorer mode for command execution." -Type "info"
Write-LogMessage "Tip: Status bar shows runtime health (Green=Active, Yellow=Warning, Red=Inactive)" -Type "info"
Update-StatusView
Update-QuickFileList

[void]$form.ShowDialog()
