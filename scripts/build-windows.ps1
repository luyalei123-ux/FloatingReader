param([ValidateSet('win-x64')][string]$Runtime = 'win-x64')
$ErrorActionPreference = 'Stop'
$Repo = Split-Path $PSScriptRoot -Parent
$Version = (Get-Content (Join-Path $Repo 'windows/VERSION') -Raw).Trim()
$Out = Join-Path $Repo "dist/windows-$Runtime-$Version"
dotnet publish (Join-Path $Repo 'windows/FloatingReader.Windows.csproj') -c Release -r $Runtime --self-contained true -p:Version=$Version -p:PublishSingleFile=false -p:PublishReadyToRun=false -o $Out
if ($LASTEXITCODE -ne 0) { throw 'Windows build failed.' }
if (-not (Test-Path (Join-Path $Out 'FloatingReader.exe'))) { throw 'Missing Windows executable.' }
Copy-Item (Join-Path $Repo 'docs/WINDOWS.md') (Join-Path $Out 'WINDOWS-README.md')
Copy-Item (Join-Path $Repo 'docs/WINDOWS.md') (Join-Path $Out '使用说明.txt')
Copy-Item (Join-Path $Repo 'windows/VERSION') (Join-Path $Out 'VERSION.txt')
$Zip = Join-Path $Repo "dist/FloatingReader-Windows-x64-$Version-preview.zip"
Compress-Archive -Path "$Out/*" -DestinationPath $Zip -Force
Write-Host "Built: $Zip"
