# Test syntax of control panel
$ErrorActionPreference = "Stop"

try {
    $scriptPath = "d:\ZeroTraceFS\tools\ztfs_control_panel.ps1"
    
    # Try to parse the script
    $errors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
    
    if ($errors.Count -gt 0) {
        Write-Host "SYNTAX ERRORS FOUND:" -ForegroundColor Red
        foreach ($err in $errors) {
            Write-Host "  Line $($err.Extent.StartLineNumber): $($err.Message)" -ForegroundColor Yellow
        }
        exit 1
    } else {
        Write-Host "✓ No syntax errors found!" -ForegroundColor Green
        Write-Host "Script is valid PowerShell." -ForegroundColor Cyan
        exit 0
    }
} catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
    exit 1
}
