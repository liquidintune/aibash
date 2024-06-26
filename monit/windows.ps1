# Установка необходимых модулей
if (-not (Get-Module -ListAvailable -Name BurntToast)) {
    Install-Module -Name BurntToast -Force
}

if (-not (Get-Module -ListAvailable -Name PSSendGrid)) {
    Install-Module -Name PSSendGrid -Force
}

$LogFile = "C:\MonitoringScript\monitoring_script.log"
$ConfigFile = "$env:USERPROFILE\.telegram_bot_config"
$SecretFile = "$env:USERPROFILE\.telegram_bot_secret"
$StatusFile = "C:\MonitoringScript\monitoring_status"
$DiskThreshold = 10
$CPUThreshold = 90
$MemThreshold = 92

function Write-Log {
    param (
        [string]$message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $message" | Out-File -Append -FilePath $LogFile
}

function Install-Packages {
    Write-Log "Checking if jq and curl are installed"
    if (-not (Get-Command jq -ErrorAction SilentlyContinue)) {
        Write-Log "Installing jq"
        Invoke-WebRequest -Uri "https://github.com/stedolan/jq/releases/download/jq-1.6/jq-win64.exe" -OutFile "C:\Windows\System32\jq.exe"
    }
    if (-not (Get-Command curl -ErrorAction SilentlyContinue)) {
        Write-Log "Installing curl"
        Invoke-WebRequest -Uri "https://curl.se/windows/dl-7.77.0_2/curl-7.77.0_2-win64-mingw.zip" -OutFile "$env:TEMP\curl.zip"
        Expand-Archive -Path "$env:TEMP\curl.zip" -DestinationPath "$env:TEMP\curl"
        Copy-Item -Path "$env:TEMP\curl\curl-7.77.0-win64-mingw\bin\curl.exe" -Destination "C:\Windows\System32\curl.exe"
    }
}

Install-Packages

$DefaultServicesToMonitor = "W3SVC,SQLSERVERAGENT,WinRM,sshd"

function Set-TelegramConfig {
    if (-not (Test-Path -Path $ConfigFile)) {
        $TelegramBotToken = Read-Host -Prompt "Enter Telegram bot token"
        $TelegramChatID = Read-Host -Prompt "Enter Telegram group chat ID"
        $ServerID = Read-Host -Prompt "Enter unique server ID"
        
        $SecretContent = "TELEGRAM_BOT_TOKEN=$TelegramBotToken"
        $SecretContent | Out-File -FilePath $SecretFile -Force
        $SecretFile | Set-ItemProperty -Name IsReadOnly -Value $true
        
        $ConfigContent = "TELEGRAM_CHAT_ID=$TelegramChatID`nSERVER_ID=$ServerID`nSERVICES_TO_MONITOR=$DefaultServicesToMonitor"
        $ConfigContent | Out-File -FilePath $ConfigFile -Force
        
        Write-Log "Configured Telegram bot and saved to $ConfigFile and $SecretFile"
    } else {
        . $ConfigFile
        . $SecretFile
    }
}

Set-TelegramConfig

function Send-TelegramMessage {
    param (
        [string]$message
    )
    $apiUrl = "https://api.telegram.org/bot$($env:TELEGRAM_BOT_TOKEN)/sendMessage"
    $postParams = @{
        chat_id = $env:TELEGRAM_CHAT_ID
        text    = $message
    }

    try {
        Invoke-RestMethod -Uri $apiUrl -Method Post -Body ($postParams | ConvertTo-Json) -ContentType "application/json" | Out-Null
        Write-Log "Sent message to Telegram: $message"
    } catch {
        Write-Log "Failed to send message to Telegram: $_"
    }
}

function Test-Services {
    $statusChanged = $false
    $currentStatus = ""

    foreach ($service in $env:SERVICES_TO_MONITOR.Split(',')) {
        $serviceStatus = Get-Service -Name $service
        if ($serviceStatus.Status -eq "Running") {
            $currentStatus += "$service:active;"
        } else {
            $currentStatus += "$service:inactive;"
        }
    }

    if (Test-Path -Path $StatusFile) {
        $previousStatus = Get-Content -Path $StatusFile
        if ($currentStatus -ne $previousStatus) {
            $statusChanged = $true
        }
    } else {
        $statusChanged = $true
    }

    if ($statusChanged) {
        $currentStatus | Out-File -FilePath $StatusFile -Force
        foreach ($service in $env:SERVICES_TO_MONITOR.Split(',')) {
            $serviceStatus = Get-Service -Name $service
            if ($serviceStatus.Status -eq "Running") {
                Send-TelegramMessage "🟢 [Server $($env:SERVER_ID)] Service $service is active."
            } else {
                Send-TelegramMessage "🔴 [Server $($env:SERVER_ID)] Service $service is inactive."
            }
        }
    }
}

function Test-Disk {
    $diskUsage = (Get-PSDrive -Name C).Used
    $totalSize = (Get-PSDrive -Name C).Used + (Get-PSDrive -Name C).Free
    $diskUsagePercent = [math]::round(($diskUsage / $totalSize) * 100, 2)

    if ($diskUsagePercent -ge (100 - $DiskThreshold)) {
        Send-TelegramMessage "🔴 [Server $($env:SERVER_ID)] Disk usage is above $((100 - $DiskThreshold))%: ${diskUsagePercent}% used."
    }
}

function Test-CPU {
    $cpuUsage = Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 3 | Measure-Object -Property CookedValue -Average | Select-Object -ExpandProperty Average
    $cpuUsage = [math]::round($cpuUsage, 2)

    if ($cpuUsage -gt $CPUThreshold) {
        Send-TelegramMessage "🔴 [Server $($env:SERVER_ID)] CPU load is above $CPUThreshold%: $cpuUsage%."
    }
}

function Test-Memory {
    $mem = Get-WmiObject Win32_OperatingSystem
    $memUsage = [math]::round((($mem.TotalVisibleMemorySize - $mem.FreePhysicalMemory) / $mem.TotalVisibleMemorySize) * 100, 2)
    if ($memUsage -gt $MemThreshold) {
        Send-TelegramMessage "🔴 [Server $($env:SERVER_ID)] Memory usage is above $($MemThreshold)%: $($memUsage)%."
    }
}

function Start-MonitoringLoop {
    while ($true) {
        Test-Services
        Test-Disk
        Test-CPU
        Test-Memory
        Start-Sleep -Seconds 60
    }
}

function Invoke-TelegramCommands {
    $lastUpdateID = 0

    while ($true) {
        $response = Invoke-RestMethod -Uri "https://api.telegram.org/bot$($env:TELEGRAM_BOT_TOKEN)/getUpdates?offset=$lastUpdateID"
        $updates = $response.result

        foreach ($update in $updates) {
            $updateID = $update.update_id
            $messageText = $update.message.text
            $chatID = $update.message.chat.id

            Write-Log "Processing update_id: $updateID, chat_id: $chatID, message_text: $messageText"

            if ($chatID -eq $env:TELEGRAM_CHAT_ID) {
                if ($messageText) {
                    $command = $messageText.Split()[0]
                    $arguments = $messageText.Substring($command.Length).Trim()

                    Write-Log "Received command: $command from chat_id: $chatID"

                    switch ($command) {
                        "/server_id" {
                            Write-Log "Sending server ID: $env:SERVER_ID"
                            Send-TelegramMessage "Server ID: $env:SERVER_ID"
                        }
                        "/help" {
                            $helpMessage = @"
Available commands:
/server_id - Show the server ID.
/list_enabled_services <server_id> - List all enabled services.
/status_service <server_id> <service> - Show the status of a service.
/start_service <server_id> <service> - Start a service.
/stop_service <server_id> <service> - Stop a service.
/restart_service <server_id> <service> - Restart a service.
/run <server_id> <command> - Execute a command without sudo privileges.
"@
                            Write-Log "Sending help message"
                            Send-TelegramMessage $helpMessage
                        }
                        "/list_enabled_services" {
                            $cmdServerID = $arguments.Split()[0]
                            if ($cmdServerID -eq $env:SERVER_ID) {
                                foreach ($service in $env:SERVICES_TO_MONITOR.Split(',')) {
                                    $serviceStatus = Get-Service -Name $service
                                    if ($serviceStatus.Status -eq "Running") {
                                        Send-TelegramMessage "🟢 [Server $($env:SERVER_ID)] $service is active."
                                    } else {
                                        Send-TelegramMessage "🔴 [Server $($env:SERVER_ID)] $service is inactive."
                                    }
                                }
                            }
                        }
                        "/status_service" {
                            $cmdServerID = $arguments.Split()[0]
                            $service = $arguments.Split()[1]
                            if ($cmdServerID -eq $env:SERVER_ID) {
                                if (-not $service) {
                                    Send-TelegramMessage "Error: service must be specified."
                                } else {
                                    $status = Get-Service -Name $service | Format-List -Property Name,Status,DisplayName,DependentServices,ServicesDependedOn
                                    Send-TelegramMessage "Status of service $service on server $env:SERVER_ID:`n$status"
                                }
                            }
                        }
                        "/start_service" {
                            $cmdServerID = $arguments.Split()[0]
                            $service = $arguments.Split()[1]
                            if ($cmdServerID -eq $env:SERVER_ID) {
                                if (-not $service) {
                                    Send-TelegramMessage "Error: service must be specified."
                                } else {
                                    $result = Start-Service -Name $service -PassThru
                                    Send-TelegramMessage "Service $service started on server $($env:SERVER_ID).`n$result"
                                }
                            }
                        }
                        "/stop_service" {
                            $cmdServerID = $arguments.Split()[0]
                            $service = $arguments.Split()[1]
                            if ($cmdServerID -eq $env:SERVER_ID) {
                                if (-not $service) {
                                    Send-TelegramMessage "Error: service must be specified."
                                } else {
                                    $result = Stop-Service -Name $service -PassThru
                                    Send-TelegramMessage "Service $service stopped on server $($env:SERVER_ID).`n$result"
                                }
                            }
                        }
                        "/restart_service" {
                            $cmdServerID = $arguments.Split()[0]
                            $service = $arguments.Split()[1]
                            if ($cmdServerID -eq $env:SERVER_ID) {
                                if (-not $service) {
                                    Send-TelegramMessage "Error: service must be specified."
                                } else {
                                    $resultStop = Stop-Service -Name $service -PassThru
                                    $resultStart = Start-Service -Name $service -PassThru
                                    Send-TelegramMessage "Service $service restarted on server $($env:SERVER_ID).`nStop result: $resultStop`nStart result: $resultStart"
                                }
                            }
                        }
                        "/run" {
                            $cmdServerID = $arguments.Split()[0]
                            $commandToRun = $arguments.Substring($cmdServerID.Length).Trim()
                            if ($cmdServerID -eq $env:SERVER_ID) {
                                if (-not $commandToRun) {
                                    Send-TelegramMessage "Error: command must be specified."
                                } else {
                                    $result = Invoke-Expression -Command $commandToRun
                                    Send-TelegramMessage $result
                                }
                            }
                        }
                        Default {
                            Send-TelegramMessage "Unknown command: $messageText"
                        }
                    }
                }
            }

            $lastUpdateID = $updateID + 1
        }

        Start-Sleep -Seconds 5
    }
}

Send-TelegramMessage "Monitoring script started on server $($env:SERVER_ID)."

Invoke-TelegramCommands
Start-MonitoringLoop
