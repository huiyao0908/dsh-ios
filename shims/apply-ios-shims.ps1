param([string]$Engine)
$ErrorActionPreference='Stop'
$PY = 'C:\Users\1\AppData\Local\Programs\Python\Python312\python.exe'
$NM = Join-Path $Engine 'dsh/node_modules'
if (-not (Test-Path $NM)) { Write-Host 'layout wrong'; exit 1 }
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Write-Host '[shim] S1 platform normalize'
& $PY (Join-Path $here '_shim1.py') (Join-Path $NM '@deepseek-ai/dsh-subprocess-local/lib')
Write-Host '[shim] S2 koffi guard'
& $PY (Join-Path $here '_shim2.py') $NM
Write-Host '[shim] done'