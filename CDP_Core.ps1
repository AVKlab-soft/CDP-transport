# CDP_Core.ps1
# Ядро взаимодействия с браузером через Chrome DevTools Protocol (CDP)
# Работает на чистом .NET (System.Net.WebSockets) без сторонних библиотек.
# Реализует логику "реального клика" и ожидания стабильности контента.

class CDPSession {
    [System.Net.WebSockets.ClientWebSocket] $Socket
    [string] $WsUrl
    [int] $MessageId = 0
    [hashtable] $PendingRequests = @{}

    # Конструктор: подключение по WebSocket URL
    CDPSession([string] $wsUrl) {
        $this.WsUrl = $wsUrl
        $this.Socket = New-Object System.Net.WebSockets.ClientWebSocket
        
        # Настройка SSL (если нужно, хотя локально http/ws обычно не шифруется)
        $this.Socket.Options.SslProtocols = [System.Security.Authentication.SslProtocols]::Tls12
        
        $uri = New-Object System.Uri $wsUrl
        $task = $this.Socket.ConnectAsync($uri, [System.Threading.CancellationToken]::None)
        $task.Wait()
        
        if ($this.Socket.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
            throw "Не удалось подключиться к CDP: $wsUrl"
        }
        
        # Запускаем фоновый прием сообщений
        $this.StartReceiver()
    }

    # Отправка команды и ожидание ответа
    [pscustomobject] Send([string] $method, [hashtable] $params) {
        $this.MessageId++
        $id = $this.MessageId
        
        $payload = @{
            id = $id
            method = $method
            params = $params
        } | ConvertTo-Json -Depth 10 -Compress
        
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
        $buffer = [System.ArraySegment[byte]]::new($bytes)
        
        $task = $this.Socket.SendAsync($buffer, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None)
        $task.Wait()
        
        # Создаем задачу ожидания ответа
        $tcs = New-Object System.Threading.Tasks.TaskCompletionObject[pscustomobject]
        $this.PendingRequests[$id] = $tcs
        
        # Ждем ответ (таймаут 30 сек)
        $timeoutTask = [System.Threading.Tasks.Task]::Delay(30000)
        $completedTask = [System.Threading.Tasks.Task]::WhenAny($tcs.Task, $timeoutTask)
        $completedTask.Wait()
        
        if ($completedTask.Result -eq $timeoutTask) {
            throw "Таймаут ожидания ответа от CDP для метода: $method"
        }
        
        return $tcs.Task.Result
    }

    # Фоновый прием сообщений
    [void] StartReceiver() {
        $buffer = New-Object byte[] 8192
        $segment = [System.ArraySegment[byte]]::new($buffer)
        
        Start-Job -ScriptBlock {
            param($socket, $pendingRequests)
            
            while ($socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                try {
                    $receiveTask = $socket.ReceiveAsync($segment, [System.Threading.CancellationToken]::None)
                    # В рамках Job это сложно синхронизировать напрямую с объектами родителя, 
                    # поэтому упростим: будем читать синхронно в цикле внутри метода Send или отдельным потоком.
                    # Для MVP сделаем чтение прямо в потоке вызова, если Send блокирует, 
                    # но для асинхронности событий (Runtime.consoleAPICalled) нужен отдельный поток.
                } catch { break }
            }
        } -ArgumentList $this.Socket, $this.PendingRequests | Out-Null
        
        # УПРОЩЕННАЯ РЕАЛИЗАЦИЯ ДЛЯ MVP:
        # Читаем сообщения в отдельном потоке внутри этого же процесса
        $receiverScript = {
            param($socket, $pendingRequests, $buffer)
            $segment = [System.ArraySegment[byte]]::new($buffer)
            
            while ($socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                try {
                    $result = $socket.ReceiveAsync($segment, [System.Threading.CancellationToken]::None).Result
                    $jsonStr = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count)
                    $msg = $jsonStr | ConvertFrom-Json
                    
                    if ($msg.id -and $pendingRequests.ContainsKey($msg.id)) {
                        $tcs = $pendingRequests[$msg.id]
                        if ($msg.error) {
                            $tcs.SetException((New-Object Exception "CDP Error: $($msg.error.message)"))
                        } else {
                            $tcs.SetResult($msg.result)
                        }
                        $pendingRequests.Remove($msg.id)
                    }
                    # События (без id) пока игнорируем для простоты, можно добавить обработку позже
                } catch {
                    break
                }
            }
        }
        
        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $runspace.Open()
        $pipeline = $runspace.CreatePipeline()
        $pipeline.Commands.AddScript($receiverScript)
        $pipeline.Commands.Add("Out-String")
        $pipeline.InvokeAsync($receiverScript, $this.PendingRequests, $buffer) | Out-Null
    }

    # Выполнение JS на странице
    [object] Evaluate([string] $expression) {
        $params = @{
            expression = $expression
            returnByValue = $true
            awaitPromise = $true
        }
        $result = $this.Send("Runtime.evaluate", $params)
        
        if ($result.result.exceptionDetails) {
            Write-Warning "JS Exception: $($result.result.exceptionDetails.text)"
            return $null
        }
        
        return $result.result.value
    }

    # Получение координат центра элемента для клика
    [nullable[object]] GetCenterCoords([string] $selector) {
        $script = @"
(function() {
    const el = document.querySelector('$selector');
    if (!el || el.getClientRects().length === 0) return null;
    const r = el.getBoundingClientRect();
    return [Math.round(r.x + r.width / 2), Math.round(r.y + r.height / 2)];
})()
"@
        return $this.Evaluate($script)
    }

    # Реальный клик мышью (эмуляция событий мыши)
    # Критично для Ant Design и сложных UI, где .click() не работает
    [void] RealClick([int] $x, [int] $y) {
        # Двигаем курсор
        $this.Send("Input.dispatchMouseEvent", @{
            type = "mouseMoved"
            x = $x
            y = $y
            button = "none"
            pointerType = "mouse"
        }) | Out-Null
        
        Start-Sleep -Milliseconds 200
        
        # Нажимаем
        $this.Send("Input.dispatchMouseEvent", @{
            type = "mousePressed"
            x = $x
            y = $y
            button = "left"
            clickCount = 1
            pointerType = "mouse"
        }) | Out-Null
        
        Start-Sleep -Milliseconds 150
        
        # Отпускаем
        $this.Send("Input.dispatchMouseEvent", @{
            type = "mouseReleased"
            x = $x
            y = $y
            button = "left"
            clickCount = 1
            pointerType = "mouse"
        }) | Out-Null
    }

    # Ввод текста в поле (через событие input)
    [void] TypeText([string] $selector, [string] $text) {
        $script = @"
(function() {
    const el = document.querySelector('$selector');
    if (!el) return false;
    el.focus();
    // Эмуляция ввода значения с триггером событий
    const nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set;
    if (nativeSetter) {
        nativeSetter.call(el, `$text`);
    } else {
        el.value = `$text`;
    }
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    return true;
})()
"@
        # Экранирование обратных кавычек и кавычек в тексте для JS
        $safeText = $text -replace "'", "\'" -replace "`"", '\"'
        $script = $script -replace '`$text', "'$safeText'"
        
        $success = $this.Evaluate($script)
        if (-not $success) {
            throw "Не удалось ввести текст в селектор: $selector"
        }
    }

    # Ожидание появления текста и его стабилизации
    [string] WaitStableText([string] $containerSelector, [int] $timeoutSec = 60, [int] $stableChecks = 3) {
        $deadline = (Get-Date).AddSeconds($timeoutSec)
        $prevText = ""
        $stableCount = 0
        
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            
            $script = @"
(function() {
    const container = document.querySelector('$containerSelector');
    if (!container) return '';
    return (container.innerText || '').trim();
})()
"@
            $currentText = $this.Evaluate($script)
            
            if ($currentText -ne $prevText) {
                $prevText = $currentText
                $stableCount = 0
            } else {
                $stableCount++
            }
            
            if ($currentText -and $stableCount -ge $stableChecks) {
                return $currentText
            }
        }
        
        if ($prevText) { return $prevText }
        throw "Таймаут ожидания стабильного текста в $containerSelector"
    }
    
    # Закрытие соединения
    [void] Close() {
        if ($this.Socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $this.Socket.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "Closing", [System.Threading.CancellationToken]::None) | Out-Null
        }
        $this.Socket.Dispose()
    }
}

# Вспомогательная функция для получения списка вкладок и поиска нужной
function Get-CDPTab {
    param([string] $FilterUrl)
    
    $response = Invoke-RestMethod -Uri "http://127.0.0.1:9222/json" -TimeoutSec 5
    foreach ($tab in $response) {
        if ($tab.url -like "*$FilterUrl*") {
            return $tab
        }
    }
    return $null
}

# Пример использования (закомментирован):
# $tab = Get-CDPTab -FilterUrl "chat.qwen.ai"
# if ($tab) {
#     $session = [CDPSession]::new($tab.webSocketDebuggerUrl)
#     $session.RealClick(100, 100)
#     $session.Close()
# }
