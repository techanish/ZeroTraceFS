Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Remove-MenuVerb {
  param(
    [string]$BaseKey,
    [string]$VerbName
  )

  $path = "$BaseKey\$VerbName"
  & reg.exe delete $path /f | Out-Null
}

$fileBase = "HKCU\Software\Classes\*\shell"
$folderBase = "HKCU\Software\Classes\Directory\shell"
$dirBase = "HKCU\Software\Classes\Directory\Background\shell"

Remove-MenuVerb -BaseKey $fileBase -VerbName "ZeroTraceFSImport"
Remove-MenuVerb -BaseKey $fileBase -VerbName "ZeroTraceFSOpenSecure"
Remove-MenuVerb -BaseKey $fileBase -VerbName "ZeroTraceFSDestroy"
Remove-MenuVerb -BaseKey $fileBase -VerbName "ZeroTraceFSSetTTL"
Remove-MenuVerb -BaseKey $fileBase -VerbName "ZeroTraceFSSetReads"
Remove-MenuVerb -BaseKey $fileBase -VerbName "ZeroTraceFSSetDeadline"
Remove-MenuVerb -BaseKey $fileBase -VerbName "ZeroTraceFSRead"
Remove-MenuVerb -BaseKey $fileBase -VerbName "ZeroTraceFSExport"

Remove-MenuVerb -BaseKey $folderBase -VerbName "ZeroTraceFSDestroy"
Remove-MenuVerb -BaseKey $folderBase -VerbName "ZeroTraceFSSetTTL"
Remove-MenuVerb -BaseKey $folderBase -VerbName "ZeroTraceFSSetReads"
Remove-MenuVerb -BaseKey $folderBase -VerbName "ZeroTraceFSSetDeadline"
Remove-MenuVerb -BaseKey $folderBase -VerbName "ZeroTraceFSDestroyAll"
Remove-MenuVerb -BaseKey $folderBase -VerbName "ZeroTraceFSLock"
Remove-MenuVerb -BaseKey $folderBase -VerbName "ZeroTraceFSQuit"
Remove-MenuVerb -BaseKey $folderBase -VerbName "ZeroTraceFSControlPanel"
Remove-MenuVerb -BaseKey $folderBase -VerbName "ZeroTraceFSStatus"
Remove-MenuVerb -BaseKey $folderBase -VerbName "ZeroTraceFSList"
Remove-MenuVerb -BaseKey $folderBase -VerbName "ZeroTraceFSAudit"

Remove-MenuVerb -BaseKey $dirBase -VerbName "ZeroTraceFSDestroyAll"
Remove-MenuVerb -BaseKey $dirBase -VerbName "ZeroTraceFSLock"
Remove-MenuVerb -BaseKey $dirBase -VerbName "ZeroTraceFSQuit"
Remove-MenuVerb -BaseKey $dirBase -VerbName "ZeroTraceFSControlPanel"
Remove-MenuVerb -BaseKey $dirBase -VerbName "ZeroTraceFSStatus"
Remove-MenuVerb -BaseKey $dirBase -VerbName "ZeroTraceFSList"
Remove-MenuVerb -BaseKey $dirBase -VerbName "ZeroTraceFSAudit"

Write-Host "ZeroTraceFS Explorer menu removed for current user." -ForegroundColor Green
