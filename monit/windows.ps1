# Установить необходимые модули
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

function Log {
    param (
        [string]$message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $message" | Out-File -Append -FilePath $LogFile
}

function Install-Packages {
    Log "Checking if jq and curl are installed"
    if (-not (Get-Command jq -ErrorAction SilentlyContinue)) {
        Log "Installing jq"
        Invoke-WebRequest -Uri "https://github.com/stedolan/jq/releases/download/jq-1.6/jq-win64.exe" -OutFile "C:\Windows\System32\jq.exe"
    }
    if (-not (Get-Command curl -ErrorAction SilentlyContinue)) {
        Log "Installing curl"
        Invoke-WebRequest -Uri "https://curl.se/windows/dl-7.77.0_2/curl-7.77.0_2-win64-mingw.zip" -OutFile "$env:TEMP\curl.zip"
        Expand-Archive -Path "$env:TEMP\curl.zip" -DestinationPath "$env:TEMP\curl"
        Copy-Item -Path "$env:TEMP\curl\curl-7.77.0-win64-mingw\bin\curl.exe" -Destination "C:\Windows\System32\curl.exe"
    }
}

Install-Packages

$DefaultServicesToMonitor = "W3SVC,SQLSERVERAGENT,WinRM"

function Configure-Telegram {
    if (-not (Test-Path -Path $ConfigFile)) {
        $TelegramBotToken = Read-Host "Enter Telegram bot token"
        $TelegramChatID = Read-Host "Enter Telegram group chat ID"
        $ServerID = Read-Host "Enter unique server ID"

        $TelegramBotToken | Out-File -FilePath $SecretFile
        Set-ItemProperty -Path $SecretFile -Name IsReadOnly -Value $true

        $Config = @"
TELEGRAM_CHAT_ID=$TelegramChatID
SERVER_ID=$ServerID
SERVICES_TO_MONITOR=$DefaultServicesToMonitor
"@
        $Config | Out-File -FilePath $ConfigFile

        Log "Configured Telegram bot and saved to $ConfigFile and $SecretFile"
    } else {
        $Config = Get-Content -Path $ConfigFile
        $Secret = Get-Content -Path $SecretFile
        foreach ($line in $Config) {
            if ($line -match "TELEGRAM_CHAT_ID=(.+)") {
                $Global:TelegramChatID = $matches[1]
            } elseif ($line -match "SERVER_ID=(.+)") {
                $Global:ServerID = $matches[1]
            } elseif ($line -match "SERVICES_TO_MONITOR=(.+)") {
                $Global:ServicesToMonitor = $matches[1].Split(",")
            }
        }
        $Global:TelegramBotToken = $Secret
    }
}

Configure-Telegram

function Send-TelegramMessage {
    param (
        [string]$message
    )
    $apiUrl = "https://api.telegram.org/bot$TelegramBotToken/sendMessage"
    $data = @{
        chat_id = $TelegramChatID
        text    = $message
    }
    $json = $data | ConvertTo-Json
    Invoke-RestMethod -Uri $apiUrl -Method Post -ContentType "application/json" -Body $json
    Log "Sent message to Telegram: $message"
}

function Monitor-Services {
    $currentStatus = @()
    $statusChanged = $false

    foreach ($service in $ServicesToMonitor) {
        $serviceStatus = Get-Service -Name $service
        if ($serviceStatus.Status -eq "Running") {
            $currentStatus += "$service:active"
        } else {
            $currentStatus += "$service:inactive"
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
        $currentStatus | Out-File -FilePath $StatusFile
        foreach ($service in $ServicesToMonitor) {
            $serviceStatus = Get-Service -Name $service
            if ($serviceStatus.Status -eq "Running") {
                Send-TelegramMessage "🟢 [Server $ServerID] Service $service is active."
            } else {
                Send-TelegramMessage "🔴 [Server $ServerID] Service $service is inactive."
            }
        }
    }
}

function Monitor-Disk {
    $diskUsage = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -gt 0 } | Select-Object -Property Used,UsedPercentage
    foreach ($disk in $diskUsage) {
        if ($disk.UsedPercentage -gt $DiskThreshold) {
            Send-TelegramMessage "🔴 [Server $ServerID] Disk usage is above $($DiskThreshold)%: $($disk.UsedPercentage)% used."
        }
    }
}

function Monitor-CPU {
    $cpuLoad = Get-WmiObject win32_processor | Measure-Object -Property LoadPercentage -Average | Select-Object -ExpandProperty Average
    if ($cpuLoad -gt $CPUThreshold) {
        Send-TelegramMessage "🔴 [Server $ServerID] CPU load is above $($CPUThreshold)%: $($cpuLoad)%."
    }
}

function Monitor-Memory {
    $mem = Get-WmiObject Win32_OperatingSystem
    $memUsage = [math]::round((($mem.TotalVisibleMemorySize - $mem.FreePhysicalMemory) / $mem.TotalVisibleMemorySize) * 100, 2)
    if ($memUsage -gt $MemThreshold) {
        Send-TelegramMessage "🔴 [Server $ServerID] Memory usage is above $($MemThreshold)%: $($memUsage)%."
    }
}

function Monitoring-Loop {
    while ($true) {
        Monitor-Services
        Monitor-Disk
        Monitor-CPU
        Monitor-Memory
        Start-Sleep -Seconds 60
    }
}

function Handle-TelegramCommands {
    $lastUpdateID = 0

    while ($true) {
        $response = Invoke-RestMethod -Uri "https://api.telegram.org/bot$TelegramBotToken/getUpdates?offset=$lastUpdateID"
        $updates = $response.result

        foreach ($update in $updates) {
            $updateID = $update.update_id
            $messageText = $update.message.text
            $chatID = $update.message.chat.id

            Log "Processing update_id: $updateID, chat_id: $chatID, message_text: $messageText"

            if ($chatID -eq $TelegramChatID) {
                if ($messageText) {
                    $command = $messageText.Split()[0]
                    $args = $messageText.Substring($command.Length).Trim()

                    Log "Received command: $command from chat_id: $chatID"

                    switch ($command) {
                        "/server_id" {
                            Log "Sending server ID: $ServerID"
                            Send-TelegramMessage "Server ID: $ServerID"
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
                            Log "Sending help message"
                            Send-TelegramMessage $helpMessage
                        }
                        "/list_enabled_services" {
                            $cmdServerID = $args.Split()[0]
                            if ($cmdServerID -eq $ServerID) {
                                foreach ($service in $ServicesToMonitor) {
                                    $serviceStatus = Get-Service -Name $service
                                    if ($serviceStatus.Status -eq "Running") {
                                        Send-TelegramMessage "🟢 [Server $ServerID] $service is active."
                                    } else {
                                        Send-TelegramMessage "🔴 [Server $ServerID] $service is inactive."
                                    }
                                }
                            }
                        }
                        "/status_service" {
                            $cmdServerID = $args.Split()[0]
                            $service = $args.Split()[1]
                            if ($cmdServerID -eq $ServerID) {
                                if (-not $service) {
                                    Send-TelegramMessage "Error: service must be specified."
                                } else {
                                    $status = Get-Service -Name $service | Format-List -Property Name,Status,DisplayName,DependentServices,ServicesDependedOn
                                    Send-TelegramMessage "Status of service $service on server $ServerID:`n$status"
                                }
                            }
                        }
                        "/start_service" {
                            $cmdServerID = $args.Split()[0]
                            $service = $args.Split()[1]
                            if ($cmdServerID -eq $ServerID) {
                                if (-not $service) {
                                    Send-TelegramMessage "Error: service must be specified."
                                } else {
                                    $result = Start-Service -Name $service -PassThru
                                    Send-TelegramMessage "Service $service started on server $ServerID.`n$result"
                                }
                            }
                        }
                        "/stop_service" {
                            $cmdServerID = $args.Split()[0]
                            $service = $args.Split()[1]
                            if ($cmdServerID -eq $ServerID) {
                                if (-not $service) {
                                    Send-TelegramMessage "Error: service must be specified."
                                } else {
                                    $result = Stop-Service -Name $service -PassThru
                                    Send-TelegramMessage "Service $service stopped on server $ServerID.`n$result"
                                }
                            }
                        }
                        "/restart_service" {
                            $cmdServerID = $args.Split()[0]
                            $service = $args.Split()[1]
                            if ($cmdServerID -eq $ServerID) {
                                if (-not $service) {
                                    Send-TelegramMessage "Error: service must be specified."
                                } else {
                                    $resultStop = Stop-Service -Name $service -PassThru
                                    $resultStart = Start-Service -Name $service -PassThru
                                    Send-TelegramMessage "Service $service restarted on server $ServerID.`nStop result: $resultStop`nStart result: $resultStart"
                                }
                            }
                        }
                        "/run" {
                            $cmdServerID = $args.Split()[0]
                            $commandToRun = $args.Substring($cmdServerID.Length).Trim()
                            if ($cmdServerID -eq $ServerID) {
                                if (-not $commandToRun) {
                                    Send-TelegramMessage "Error: command must be specified."
                                } else {
                                    $result = Invoke-Expression $commandToRun
                                    Send-TelegramMessage $result
                                }
                            }
                        }
                        default {
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

Send-TelegramMessage "Monitoring script started on server $ServerID."

Start-Job -ScriptBlock { Handle-TelegramCommands }
Monitoring-Loop
