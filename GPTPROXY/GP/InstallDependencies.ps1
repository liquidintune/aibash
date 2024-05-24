# Определение путей
$dotnetInstallerUrl = "https://download.visualstudio.microsoft.com/download/pr/abc123xyz/dotnet-sdk-5.0.100-win-x64.exe"
$dotnetInstallerPath = "$env:TEMP\dotnet-sdk-5.0.100-win-x64.exe"
$projectDirectory = "C:\Path\To\Your\Project"

# Функция для скачивания файла
function Download-File {
    param (
        [string]$url,
        [string]$outputPath
    )
    Write-Host "Скачивание $url в $outputPath..."
    Invoke-WebRequest -Uri $url -OutFile $outputPath
    Write-Host "Завершено скачивание $url."
}

# Установка .NET SDK
if (-Not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Host "Установка .NET SDK..."
    Download-File -url $dotnetInstallerUrl -outputPath $dotnetInstallerPath
    Start-Process -FilePath $dotnetInstallerPath -ArgumentList "/quiet" -Wait
    Write-Host ".NET SDK установлен."
} else {
    Write-Host ".NET SDK уже установлен."
}

# Переход в каталог проекта
Write-Host "Переход в каталог проекта $projectDirectory"
Set-Location -Path $projectDirectory

# Установка NuGet пакетов
Write-Host "Установка NuGet пакетов..."
dotnet add package Newtonsoft.Json
dotnet add package System.Net.Http

Write-Host "Все зависимости установлены."

# Создание и компиляция проекта WPF
Write-Host "Создание проекта WPF..."
dotnet new wpf -n ChatGPTClient -o $projectDirectory\ChatGPTClient
Set-Location -Path "$projectDirectory\ChatGPTClient"

Write-Host "Компиляция проекта WPF..."
dotnet build

Write-Host "Проект WPF создан и скомпилирован."

# Установка WiX Toolset
Write-Host "Установка WiX Toolset..."
$wixInstallerUrl = "https://github.com/wixtoolset/wix3/releases/download/wix3111rtm/wix311.exe"
$wixInstallerPath = "$env:TEMP\wix311.exe"
Download-File -url $wixInstallerUrl -outputPath $wixInstallerPath
Start-Process -FilePath $wixInstallerPath -ArgumentList "/quiet" -Wait
Write-Host "WiX Toolset установлен."

Write-Host "Все необходимые компоненты установлены."
