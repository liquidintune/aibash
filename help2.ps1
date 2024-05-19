# Функция для создания GUI
function Show-TicketForm {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object Windows.Forms.Form
    $form.Text = "Создать обращение"
    $form.Size = New-Object Drawing.Size(400,300)
    $form.StartPosition = "CenterScreen"

    $labelSubject = New-Object Windows.Forms.Label
    $labelSubject.Text = "Тема:"
    $labelSubject.AutoSize = $true
    $labelSubject.Location = New-Object Drawing.Point(10,20)
    $form.Controls.Add($labelSubject)

    $textBoxSubject = New-Object Windows.Forms.TextBox
    $textBoxSubject.Size = New-Object Drawing.Size(360,20)
    $textBoxSubject.Location = New-Object Drawing.Point(10,40)
    $form.Controls.Add($textBoxSubject)

    $labelMessage = New-Object Windows.Forms.Label
    $labelMessage.Text = "Сообщение:"
    $labelMessage.AutoSize = $true
    $labelMessage.Location = New-Object Drawing.Point(10,70)
    $form.Controls.Add($labelMessage)

    $textBoxMessage = New-Object Windows.Forms.TextBox
    $textBoxMessage.Multiline = $true
    $textBoxMessage.Size = New-Object Drawing.Size(360,120)
    $textBoxMessage.Location = New-Object Drawing.Point(10,90)
    $form.Controls.Add($textBoxMessage)

    $buttonSubmit = New-Object Windows.Forms.Button
    $buttonSubmit.Text = "Отправить"
    $buttonSubmit.Location = New-Object Drawing.Point(300,220)
    $form.Controls.Add($buttonSubmit)

    $buttonSubmit.Add_Click({
        $global:subject = $textBoxSubject.Text
        $global:message = $textBoxMessage.Text
        $form.Close()
    })

    $form.ShowDialog()
}

Show-TicketForm

# Сбор информации о сети и компьютере
$networkInfo = ipconfig /all
$computerInfo = Get-WmiObject -Class Win32_ComputerSystem
$ipAddress = (Test-Connection -ComputerName (hostname) -Count 1).IPV4Address.IPAddressToString
$userName = $computerInfo.UserName

# Установка клиента RustDesk, если не установлен
$rustDeskPath = "C:\Program Files\RustDesk\rustdesk.exe"
if (-Not (Test-Path $rustDeskPath)) {
    $rustDeskUrl = "https://github.com/rustdesk/rustdesk/releases/download/nightly/rustdesk-1.1.9.exe"
    $rustDeskInstaller = "C:\rustdesk-1.1.9.exe"
    Invoke-WebRequest -Uri $rustDeskUrl -OutFile $rustDeskInstaller
    Start-Process -FilePath $rustDeskInstaller -ArgumentList "/S" -Wait

    # Настройка RustDesk клиента
    $rustDeskConfig = @"
{
  "server": "78.108.193.14",
  "id": "Udjjewieufnkudnwikmk9e8uilekuskjef"
}
"@
    $rustDeskConfigPath = "C:\Program Files\RustDesk\config\config.json"
    New-Item -ItemType Directory -Force -Path (Split-Path $rustDeskConfigPath)
    $rustDeskConfig | Out-File -FilePath $rustDeskConfigPath -Force
}

# Формирование и отправка обращения через OTRS API
$otrsUrl = "http://your-otrs-domain/otrs/nph-genericinterface.pl/Webservice/GenericTicketConnectorREST/Ticket"
$otrsUser = "your-username"
$otrsPassword = "your-password"

$ticketData = @{
    Ticket = @{
        Title = $subject
        Queue = "Raw"
        State = "new"
        Priority = "3 normal"
        CustomerUser = $userName
    }
    Article = @{
        Subject = $subject
        Body = "$message`n`nNetwork Info:`n$networkInfo`n`nComputer Info:`n$computerInfo`n`nIP Address: $ipAddress"
        ContentType = "text/plain; charset=utf8"
    }
}

$jsonData = $ticketData | ConvertTo-Json -Compress

Invoke-RestMethod -Uri $otrsUrl -Method Post -Credential (New-Object System.Management.Automation.PSCredential ($otrsUser, (ConvertTo-SecureString $otrsPassword -AsPlainText -Force))) -Body $jsonData -ContentType "application/json"

# Отображение окна с номером телефона техподдержки
[System.Windows.Forms.MessageBox]::Show("Обращение отправлено. Для получения поддержки позвоните по телефону: +1234567890", "Поддержка")
