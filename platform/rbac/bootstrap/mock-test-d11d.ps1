# README D-11d PowerShell example test (offline, fake oc). Exit 1 if any case FAILs.
# PR#43 review 5566384887 B1: the prior KUBECONFIG state (set/unset) and the prior file are preserved,
# and only this run's temp kubeconfig/folder are removed.
# Runs the exact code between <!-- d11d-ps:start/end --> in README.md (no separate copy).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File mock-test-d11d.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$readme = Get-Content -LiteralPath (Join-Path $here 'README.md') -Encoding UTF8
$on = $false; $lines = @()
foreach ($l in $readme) {
  if ($l -match '<!-- d11d-ps:start -->') { $on = $true; continue }
  if ($l -match '<!-- d11d-ps:end -->') { $on = $false; continue }
  if ($on -and $l -notmatch '^   ```') { $lines += ($l -replace '^   ', '') }
}
$code = ($lines -join "`n") -replace '<[^>]*API_URL>', 'https://api.mock:443'
if ($code -notmatch 'd11PreviousConfig') { Write-Output 'FAIL: D-11d block not found in README'; exit 1 }
$blocks = @{}
foreach ($u in @('gwonuk', 'jaehwan')) { $blocks[$u] = [scriptblock]::Create(($code -replace '<[^>]* id>', $u)) }

$script:mode = 'ok'; $script:user = 'gwonuk'
function oc {
  $a = $args -join ' '
  $m = $script:mode
  switch -Regex ($a) {
    '^login '                 { if ($m -eq 'loginfail') { $global:LASTEXITCODE = 1; return }
                                Set-Content -LiteralPath $env:KUBECONFIG -Value 'mock'; $global:LASTEXITCODE = 0; return }
    '^whoami --show-server$'  { $global:LASTEXITCODE = 0; if ($m -eq 'wrongserver') { return 'https://api.other:443' }; return 'https://api.mock:443' }
    '^whoami$'                { $global:LASTEXITCODE = 0; if ($m -eq 'wronguser') { return 'other' }; return $script:user }
    '^auth can-i get pods -n fds-app$' { $global:LASTEXITCODE = 0; return 'yes' }
    '^auth can-i list nodes$' { if ($m -eq 'canibad') { $global:LASTEXITCODE = 0; return 'yes' }; $global:LASTEXITCODE = 1; return 'no' }
    # monitoring-edit: jaehwan only. monmissing = jaehwan without it, monleak = gwonuk with it
    '^auth can-i create (servicemonitors|prometheusrules).monitoring.coreos.com -n fds-app$' {
      if (($script:user -eq 'jaehwan' -and $m -ne 'monmissing') -or $m -eq 'monleak') { $global:LASTEXITCODE = 0; return 'yes' }
      $global:LASTEXITCODE = 1; return 'no' }
    '^auth can-i '            { $global:LASTEXITCODE = 1; return 'no' }
    'logout'                  { $global:LASTEXITCODE = 0; return }
    default                   { $global:LASTEXITCODE = 0; return }
  }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('d11d-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$savedTmp = $env:TMP; $savedTemp = $env:TEMP
$savedHad = Test-Path Env:KUBECONFIG; $savedKc = $env:KUBECONFIG
$fail = 0
function Run-Case($name, $user, $mode, $wantPass, $prior) {
  $tmpd = Join-Path $root "tmp-$name"; New-Item -ItemType Directory -Path $tmpd | Out-Null
  $p1 = Join-Path $root "p1-$name.kubeconfig"; Set-Content -LiteralPath $p1 -Value 'phase1-context'
  $before = (Get-FileHash -LiteralPath $p1).Hash
  $env:TMP = $tmpd; $env:TEMP = $tmpd
  if ($prior -eq 'set') { $env:KUBECONFIG = $p1 } else { Remove-Item Env:KUBECONFIG -ErrorAction SilentlyContinue }
  $script:mode = $mode; $script:user = $user
  $out = @()
  try { $out = & $blocks[$user] 2>&1 } catch { $out += "THROWN: $($_.Exception.Message)" }
  $passed = [bool]($out | Where-Object { "$_" -eq 'D-11d RESULT: PASS' })
  $afterHad = Test-Path Env:KUBECONFIG; $afterKc = $env:KUBECONFIG
  $keptOk = if ($prior -eq 'set') { $afterHad -and $afterKc -eq $p1 } else { -not $afterHad }
  $left = @(Get-ChildItem -LiteralPath $tmpd -Force -Recurse).Count
  $p1ok = (Get-FileHash -LiteralPath $p1).Hash -eq $before
  $ok = ($passed -eq $wantPass) -and $keptOk -and ($left -eq 0) -and $p1ok
  if (-not $ok) { $script:fail = 1 }
  $env:TMP = $savedTmp; $env:TEMP = $savedTemp
  '{0,-36} result={1,-4} expect={2,-4} KUBECONFIG_restored={3,-5} tmp_left={4} phase1_file_unchanged={5} => {6}' -f `
    $name, $(if ($passed) { 'PASS' } else { 'FAIL' }), $(if ($wantPass) { 'PASS' } else { 'FAIL' }), $keptOk, $left, $p1ok, $(if ($ok) { 'PASS' } else { 'FAIL' })
}

"PowerShell $($PSVersionTable.PSVersion) / $([Environment]::OSVersion.VersionString)"
foreach ($prior in @('set', 'unset')) {
  Run-Case "P1_${prior}_normal"              'gwonuk'  'ok'          $true  $prior
  Run-Case "P2_${prior}_login_fail"          'gwonuk'  'loginfail'   $false $prior
  Run-Case "P3_${prior}_wrong_user"          'gwonuk'  'wronguser'   $false $prior
  Run-Case "P4_${prior}_wrong_server"        'gwonuk'  'wrongserver' $false $prior
  Run-Case "P5_${prior}_cani_mismatch"       'gwonuk'  'canibad'     $false $prior
  Run-Case "P6_${prior}_jaehwan_normal"      'jaehwan' 'ok'          $true  $prior
  Run-Case "P7_${prior}_jaehwan_mon_missing" 'jaehwan' 'monmissing'  $false $prior
  Run-Case "P8_${prior}_gwonuk_mon_leak"     'gwonuk'  'monleak'     $false $prior
}
if ($savedHad) { $env:KUBECONFIG = $savedKc } else { Remove-Item Env:KUBECONFIG -ErrorAction SilentlyContinue }
Remove-Item -LiteralPath $root -Recurse -Force
exit $fail
