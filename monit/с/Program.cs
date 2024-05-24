using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

class Program
{
    private static string LogFile = @"C:\MonitoringScript\monitoring_script.log";
    private static string ConfigFile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".telegram_bot_config");
    private static string SecretFile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".telegram_bot_secret");
    private static string StatusFile = @"C:\MonitoringScript\monitoring_status";
    private static int DiskThreshold = 10;
    private static int CPUThreshold = 90;
    private static int MemThreshold = 92;
    private static string DefaultServicesToMonitor = "W3SVC,SQLSERVERAGENT,WinRM,sshd";
    private static string TelegramBotToken;
    private static string TelegramChatID;
    private static string ServerID;

    static async Task Main(string[] args)
    {
        InstallPackages();
        ConfigureTelegram();
        await SendTelegramMessage($"Monitoring script started on server {ServerID}.");

        var monitoringTask = Task.Run(() => MonitoringLoop());
        var commandHandlingTask = Task.Run(() => HandleTelegramCommands());

        await Task.WhenAll(monitoringTask, commandHandlingTask);
    }

    static void Log(string message)
    {
        var timestamp = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
        File.AppendAllText(LogFile, $"{timestamp} - {message}\n");
    }

    static void InstallPackages()
    {
        Log("Checking if jq and curl are installed");
        if (!File.Exists(@"C:\Windows\System32\jq.exe"))
        {
            Log("Installing jq");
            using (var client = new HttpClient())
            {
                var response = client.GetAsync("https://github.com/stedolan/jq/releases/download/jq-1.6/jq-win64.exe").Result;
                File.WriteAllBytes(@"C:\Windows\System32\jq.exe", response.Content.ReadAsByteArrayAsync().Result);
            }
        }

        if (!File.Exists(@"C:\Windows\System32\curl.exe"))
        {
            Log("Installing curl");
            using (var client = new HttpClient())
            {
                var response = client.GetAsync("https://curl.se/windows/dl-7.77.0_2/curl-7.77.0_2-win64-mingw.zip").Result;
                var zipPath = Path.GetTempFileName();
                File.WriteAllBytes(zipPath, response.Content.ReadAsByteArrayAsync().Result);
                System.IO.Compression.ZipFile.ExtractToDirectory(zipPath, Path.GetTempPath());
                File.Copy(Path.Combine(Path.GetTempPath(), "curl-7.77.0-win64-mingw", "bin", "curl.exe"), @"C:\Windows\System32\curl.exe", true);
            }
        }
    }

    static void ConfigureTelegram()
    {
        if (!File.Exists(ConfigFile))
        {
            Console.Write("Enter Telegram bot token: ");
            TelegramBotToken = Console.ReadLine();
            Console.Write("Enter Telegram group chat ID: ");
            TelegramChatID = Console.ReadLine();
            Console.Write("Enter unique server ID: ");
            ServerID = Console.ReadLine();

            File.WriteAllText(SecretFile, $"TELEGRAM_BOT_TOKEN={TelegramBotToken}");
            File.SetAttributes(SecretFile, FileAttributes.ReadOnly);
            File.WriteAllText(ConfigFile, $"TELEGRAM_CHAT_ID={TelegramChatID}\nSERVER_ID={ServerID}\nSERVICES_TO_MONITOR={DefaultServicesToMonitor}");

            Log($"Configured Telegram bot and saved to {ConfigFile} and {SecretFile}");
        }
        else
        {
            var configLines = File.ReadAllLines(ConfigFile);
            TelegramChatID = configLines[0].Split('=')[1];
            ServerID = configLines[1].Split('=')[1];
            DefaultServicesToMonitor = configLines[2].Split('=')[1];

            var secretLines = File.ReadAllLines(SecretFile);
            TelegramBotToken = secretLines[0].Split('=')[1];
        }
    }

    static async Task SendTelegramMessage(string message)
    {
        var apiUrl = $"https://api.telegram.org/bot{TelegramBotToken}/sendMessage";
        var postParams = new { chat_id = TelegramChatID, text = message };

        try
        {
            using (var client = new HttpClient())
            {
                var response = await client.PostAsJsonAsync(apiUrl, postParams);
                response.EnsureSuccessStatusCode();
                Log($"Sent message to Telegram: {message}");
            }
        }
        catch (Exception ex)
        {
            Log($"Failed to send message to Telegram: {ex.Message}");
        }
    }

    static void MonitoringLoop()
    {
        while (true)
        {
            TestServices();
            TestDisk();
            TestCPU();
            TestMemory();
            Thread.Sleep(60000);
        }
    }

    static void HandleTelegramCommands()
    {
        long lastUpdateID = 0;

        while (true)
        {
            using (var client = new HttpClient())
            {
                var response = client.GetAsync($"https://api.telegram.org/bot{TelegramBotToken}/getUpdates?offset={lastUpdateID}").Result;
                var updates = response.Content.ReadAsAsync<dynamic>().Result.result;

                foreach (var update in updates)
                {
                    lastUpdateID = update.update_id + 1;
                    string messageText = update.message.text;
                    long chatID = update.message.chat.id;

                    Log($"Processing update_id: {update.update_id}, chat_id: {chatID}, message_text: {messageText}");

                    if (chatID == long.Parse(TelegramChatID))
                    {
                        if (!string.IsNullOrEmpty(messageText))
                        {
                            string[] splitMessage = messageText.Split(' ', 3);
                            string command = splitMessage[0];
                            string[] args = splitMessage.Length > 1 ? splitMessage[1].Split(' ') : new string[0];

                            Log($"Received command: {command} from chat_id: {chatID}");

                            switch (command)
                            {
                                case "/server_id":
                                    Log("Sending server ID");
                                    SendTelegramMessage($"Server ID: {ServerID}").Wait();
                                    break;
                                case "/help":
                                    var helpMessage = @"
Available commands:
/server_id - Show the server ID.
/list_enabled_services <server_id> - List all enabled services.
/status_service <server_id> <service> - Show the status of a service.
/start_service <server_id> <service> - Start a service.
/stop_service <server_id> <service> - Stop a service.
/restart_service <server_id> <service> - Restart a service.
/run <server_id> <command> - Execute a command without sudo privileges.
";
                                    Log("Sending help message");
                                    SendTelegramMessage(helpMessage).Wait();
                                    break;
                                case "/list_enabled_services":
                                    if (args.Length > 0 && args[0] == ServerID)
                                    {
                                        foreach (var service in DefaultServicesToMonitor.Split(','))
                                        {
                                            var serviceStatus = GetServiceStatus(service);
                                            SendTelegramMessage($"🟢 [Server {ServerID}] {service} is {serviceStatus}.").Wait();
                                        }
                                    }
                                    break;
                                case "/status_service":
                                    if (args.Length > 1 && args[0] == ServerID)
                                    {
                                        var service = args[1];
                                        var status = GetServiceStatus(service);
                                        SendTelegramMessage($"Status of service {service} on server {ServerID}: {status}").Wait();
                                    }
                                    break;
                                case "/start_service":
                                    if (args.Length > 1 && args[0] == ServerID)
                                    {
                                        var service = args[1];
                                        var result = StartService(service);
                                        SendTelegramMessage($"Service {service} started on server {ServerID}.\n{result}").Wait();
                                    }
                                    break;
                                case "/stop_service":
                                    if (args.Length > 1 && args[0] == ServerID)
                                    {
                                        var service = args[1];
                                        var result = StopService(service);
                                        SendTelegramMessage($"Service {service} stopped on server {ServerID}.\n{result}").Wait();
                                    }
                                    break;
                                case "/restart_service":
                                    if (args.Length > 1 && args[0] == ServerID)
                                    {
                                        var service = args[1];
                                        var resultStop = StopService(service);
                                        var resultStart = StartService(service);
                                        SendTelegramMessage($"Service {service} restarted on server {ServerID}.\nStop result: {resultStop}\nStart result: {resultStart}").Wait();
                                    }
                                    break;
                                case "/run":
                                    if (args.Length > 1 && args[0] == ServerID)
                                    {
                                        var commandToRun = string.Join(" ", args, 1, args.Length - 1);
                                        var result = RunCommand(commandToRun);
                                        SendTelegramMessage(result).Wait();
                                    }
                                    break;
                                default:
                                    SendTelegramMessage($"Unknown command: {messageText}").Wait();
                                    break;
                            }
                        }
                    }
                }
            }
            Thread.Sleep(5000);
        }
    }

    static string GetServiceStatus(string serviceName)
    {
        try
        {
            var service = new ServiceController(serviceName);
            return service.Status.ToString();
        }
        catch (Exception ex)
        {
            return $"Error: {ex.Message}";
        }
    }

    static string StartService(string serviceName)
    {
        try
        {
            var service = new ServiceController(serviceName);
            service.Start();
            service.WaitForStatus(ServiceControllerStatus.Running);
            return $"Service {serviceName} started successfully.";
        }
        catch (Exception ex)
        {
            return $"Error: {ex.Message}";
        }
    }

    static string StopService(string serviceName)
    {
        try
        {
            var service = new ServiceController(serviceName);
            service.Stop();
            service.WaitForStatus(ServiceControllerStatus.Stopped);
            return $"Service {serviceName} stopped successfully.";
        }
        catch (Exception ex)
        {
            return $"Error: {ex.Message}";
        }
    }

    static string RunCommand(string command)
    {
        try
        {
            var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = "cmd.exe",
                    Arguments = $"/C {command}",
                    RedirectStandardOutput = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                }
            };
            process.Start();
            string result = process.StandardOutput.ReadToEnd();
            process.WaitForExit();
            return result;
        }
        catch (Exception ex)
        {
            return $"Error: {ex.Message}";
        }
    }

    static void TestServices()
    {
        bool statusChanged = false;
        string currentStatus = "";

        foreach (var service in DefaultServicesToMonitor.Split(','))
        {
            var serviceStatus = GetServiceStatus(service);
            currentStatus += $"{service}:{serviceStatus};";
        }

        if (File.Exists(StatusFile))
        {
            var previousStatus = File.ReadAllText(StatusFile);
            if (currentStatus != previousStatus)
            {
                statusChanged = true;
            }
        }
        else
        {
            statusChanged = true;
        }

        if (statusChanged)
        {
            File.WriteAllText(StatusFile, currentStatus);
            foreach (var service in DefaultServicesToMonitor.Split(','))
            {
                var serviceStatus = GetServiceStatus(service);
                SendTelegramMessage(serviceStatus == "Running" ?
                    $"🟢 [Server {ServerID}] Service {service} is active." :
                    $"🔴 [Server {ServerID}] Service {service} is inactive.").Wait();
            }
        }
    }

    static void TestDisk()
    {
        var drive = new DriveInfo("C");
        var diskUsagePercent = (double)drive.TotalSize / (drive.TotalSize + drive.AvailableFreeSpace) * 100;

        if (diskUsagePercent >= 100 - DiskThreshold)
        {
            SendTelegramMessage($"🔴 [Server {ServerID}] Disk usage is above {100 - DiskThreshold}%: {diskUsagePercent:F2}% used.").Wait();
        }
    }

    static void TestCPU()
    {
        var cpuCounter = new PerformanceCounter("Processor", "% Processor Time", "_Total");
        cpuCounter.NextValue();
        Thread.Sleep(1000);
        var cpuUsage = cpuCounter.NextValue();

        if (cpuUsage > CPUThreshold)
        {
            SendTelegramMessage($"🔴 [Server {ServerID}] CPU load is above {CPUThreshold}%: {cpuUsage:F2}%.").Wait();
        }
    }

    static void TestMemory()
    {
        var memCounter = new PerformanceCounter("Memory", "% Committed Bytes In Use");
        var memUsage = memCounter.NextValue();

        if (memUsage > MemThreshold)
        {
            SendTelegramMessage($"🔴 [Server {ServerID}] Memory usage is above {MemThreshold}%: {memUsage:F2}%.").Wait();
        }
    }
}
