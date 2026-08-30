# Provider_Qwen.ps1
# Адаптер для работы с Qwen (chat.qwen.ai)
# Зависит от: CDP_Core.ps1 (должен лежать в той же папке)

param(
    [string]$Action = "Test", # Действие: Send, Delete, Test
    [string]$MessageText = "", # Текст сообщения
    [string]$OutputFolder = "." # Папка для сохранения ответа
)

# 1. Подключаем ядро
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$corePath = Join-Path $scriptPath "CDP_Core.ps1"

if (-not (Test-Path $corePath)) {
    Write-Host "ОШИБКА: Не найден файл CDP_Core.ps1 в папке $scriptPath" -ForegroundColor Red
    exit 1
}

# Загружаем код ядра (так как это не модуль .psm1, а скрипт с классом, используем Add-Type напрямую или dot-source)
# В нашем случае CDP_Core.ps1 содержит определение класса. 
# Чтобы избежать дублирования при частых вызовах, проверим, загружен ли тип.
if (-not ([System.Management.Automation.PSTypeName]'CDPSession').Type) {
    try {
        . $corePath
    } catch {
        Write-Host "Ошибка загрузки ядра: $_" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "Ядро CDP уже загружено." -ForegroundColor Gray
}

# --- КОНСТАНТЫ И НАСТРОЙКИ ---
$TargetUrl = "chat.qwen.ai"
$DebugPort = 9222
$MaxWaitSeconds = 300 # 5 минут на ответ

# --- ФУНКЦИИ ---

function Get-QwenSession {
    # Находит вкладку и возвращает объект сессии
    try {
        $response = Invoke-RestMethod -Uri "http://127.0.0.1:$DebugPort/json" -TimeoutSec 5 -ErrorAction Stop
        $tab = $response | Where-Object { $_.url -like "*$TargetUrl*" } | Select-Object -First 1
        
        if ($null -eq $tab) {
            Write-Host "ОШИБКА: Вкладка $TargetUrl не найдена. Проверьте браузер." -ForegroundColor Red
            return $null
        }
        
        $session = New-Object CDPSession
        if ($session.Connect($tab.webSocketDebuggerUrl)) {
            return $session
        } else {
            return $null
        }
    } catch {
        Write-Host "Ошибка подключения: $_" -ForegroundColor Red
        return $null
    }
}

function Send-QwenMessage {
    param([string]$Text, [CDPSession]$Session)
    
    Write-Host "[Qwen] Ввод текста..." -ForegroundColor Cyan
    
    # Экранирование для JS
    $safeText = $Text.Replace("\", "\\").Replace("'", "\'").Replace("`n", "\n").Replace("`r", "")
    
    $jsInject = @"
    (function() {
        var ta = document.querySelector('textarea.message-input-textarea');
        if (!ta) return 'ERR_NO_INPUT';
        ta.focus();
        var setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set;
        setter.call(ta, '$safeText');
        ta.dispatchEvent(new Event('input', {bubbles: true}));
        return 'OK';
    })()
"@
    
    $res = $Session.EvaluateJS($jsInject)
    if ($res -ne "OK") {
        Write-Host "[Qwen] Ошибка ввода: $res" -ForegroundColor Red
        return $null
    }
    
    Start-Sleep -Milliseconds 500
    
    # Отправка через Enter
    Write-Host "[Qwen] Отправка (Enter)..." -ForegroundColor Cyan
    $Session.SendKey("Enter")
    
    # Ожидание ответа
    Write-Host "[Qwen] Ожидание ответа (макс. $MaxWaitSeconds сек)..." -ForegroundColor Yellow
    
    $answer = $Session.WaitForStableText(
        ".response-message-content", # Селектор контейнера ответа
        $MaxWaitSeconds,
        3 # Количество проверок стабильности
    )
    
    if ([string]::IsNullOrEmpty($answer)) {
        Write-Host "[Qwen] Таймаут или ошибка получения ответа." -ForegroundColor Red
        return ""
    }
    
    # Декодирование Unicode (\u041d -> Н)
    # В PowerShell есть встроенный метод для этого через JSON или Regex
    # Простой способ: использовать [System.Web.Script.Serialization.JavaScriptSerializer]
    try {
        $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        # Оборачиваем в кавычки, чтобы десериализовать как строку
        $decoded = $js.DeserializeObject("`"$answer`"")
        # Если результат строка - отлично, если нет - берем как есть
        if ($decoded -is [string]) {
            return $decoded
        } else {
             # Если вдруг вернулся объект, сериализуем обратно в строку без экранирования (редкий случай)
             return $answer 
        }
    } catch {
        Write-Host "[Qwen] Предупреждение: не удалось декодировать Unicode полностью. Возвращаю как есть."
        return $answer
    }
}

function Remove-QwenChat {
    param([CDPSession]$Session)
    
    Write-Host "[Qwen] Удаление текущего чата..." -ForegroundColor Magenta
    
    # Логика из Python-скрипта:
    # 1. Найти активную строку в сайдбаре (.chat-item-drag-link.active)
    # 2. Навести на неё мышь (чтобы появилось меню)
    # 3. Найти кнопку "Chat Menu" рядом с этой строкой
    # 4. Кликнуть, выбрать "Удалить", подтвердить
    
    # Шаг 1: Координаты активной строки
    $rowCoordsJson = $Session.EvaluateJS(@"
    (function() {
        var rows = document.querySelectorAll('.chat-item-drag-link-content');
        for(var i=0; i<rows.length; i++) {
            var link = rows[i].closest('.chat-item-drag-link');
            if (link && link.className.includes('active')) {
                var r = rows[i].getBoundingClientRect();
                // Возвращаем X (чуть слева) и Y (центр)
                return JSON.stringify({x: Math.round(r.x + 20), y: Math.round(r.y + r.height/2)});
            }
        }
        return null;
    })()
"@)
    
    if ($rowCoordsJson -eq "null" -or [string]::IsNullOrEmpty($rowCoordsJson)) {
        Write-Host "[Qwen] Не найдена активная строка чата." -ForegroundColor Red
        return $false
    }
    
    # Парсим координаты (простой парсинг JSON строки вручную или через serializer)
    $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $coords = $js.DeserializeObject($rowCoordsJson)
    $x = $coords["x"]
    $y = $coords["y"]
    
    Write-Host "[Qwen] Навожу мышь на чат (X:$x, Y:$y)..." -ForegroundColor Gray
    $Session.RealMouseMove($x, $y)
    Start-Sleep -Milliseconds 800 # Ждем появления кнопки меню
    
    # Шаг 2: Клик по кнопке "Chat Menu" (три точки)
    # Ищем кнопку с aria-label="Chat Menu", которая видима и ближе всего к координатам строки
    $menuBtnCoordsJson = $Session.EvaluateJS(@"
    (function() {
        var rows = document.querySelectorAll('.chat-item-drag-link-content');
        var targetRow = null;
        // Находим снова активную строку для сравнения расстояний
        for(var i=0; i<rows.length; i++) {
             var link = rows[i].closest('.chat-item-drag-link');
             if (link && link.className.includes('active')) {
                 targetRow = rows[i]; break;
             }
        }
        if (!targetRow) return null;
        
        var tr = targetRow.getBoundingClientRect();
        var acx = tr.x + tr.width/2;
        var acy = tr.y + tr.height/2;
        
        var bestBtn = null;
        var minDist = 10000;
        
        var btns = document.querySelectorAll('button[aria-label="Chat Menu"]');
        for(var i=0; i<btns.length; i++) {
            if (btns[i].offsetParent === null) continue; // Скрытые
            var br = btns[i].getBoundingClientRect();
            var bcx = br.x + br.width/2;
            var bcy = br.y + br.height/2;
            var dist = Math.abs(bcx - acx) + Math.abs(bcy - acy);
            if (dist < minDist) {
                minDist = dist;
                bestBtn = br;
            }
        }
        if (bestBtn) {
            return JSON.stringify({x: Math.round(bestBtn.x + bestBtn.width/2), y: Math.round(bestBtn.y + bestBtn.height/2)});
        }
        return null;
    })()
"@)
    
    if ($menuBtnCoordsJson -eq "null" -or [string]::IsNullOrEmpty($menuBtnCoordsJson)) {
        Write-Host "[Qwen] Не найдена кнопка меню чата." -ForegroundColor Red
        return $false
    }
    
    $menuCoords = $js.DeserializeObject($menuBtnCoordsJson)
    $mx = $menuCoords["x"]
    $my = $menuCoords["y"]
    
    Write-Host "[Qwen] Клик по меню (X:$mx, Y:$my)..." -ForegroundColor Gray
    $Session.RealClick($mx, $my)
    Start-Sleep -Milliseconds 500
    
    # Шаг 3: Выбор пункта "Удалить"
    # Ищем элемент с role="menuitem" и текстом "Удалить"
    $delItemCoordsJson = $Session.EvaluateJS(@"
    (function() {
        var items = document.querySelectorAll('[role="menuitem"]');
        for(var i=0; i<items.length; i++) {
            if (items[i].innerText.trim() === "Удалить" && items[i].offsetParent !== null) {
                var r = items[i].getBoundingClientRect();
                return JSON.stringify({x: Math.round(r.x + r.width/2), y: Math.round(r.y + r.height/2)});
            }
        }
        return null;
    })()
"@)
    
    if ($delItemCoordsJson -eq "null" -or [string]::IsNullOrEmpty($delItemCoordsJson)) {
        Write-Host "[Qwen] Пункт 'Удалить' не найден в меню." -ForegroundColor Red
        return $false
    }
    
    $delCoords = $js.DeserializeObject($delItemCoordsJson)
    $dx = $delCoords["x"]
    $dy = $delCoords["y"]
    
    Write-Host "[Qwen] Клик по 'Удалить' (X:$dx, Y:$dy)..." -ForegroundColor Gray
    $Session.RealClick($dx, $dy)
    Start-Sleep -Milliseconds 500
    
    # Шаг 4: Подтверждение в модальном окне
    # Ищем кнопку с текстом "Удалить" (обычно красная) в диалоге подтверждения
    $confirmBtnCoordsJson = $Session.EvaluateJS(@"
    (function() {
        // Ищем кнопки, внутри которых есть текст "Удалить"
        var btns = document.querySelectorAll('button');
        for(var i=0; i<btns.length; i++) {
            if (btns[i].innerText.trim() === "Удалить" && btns[i].offsetParent !== null) {
                // Проверяем, видима ли она (диалог открыт)
                var r = btns[i].getBoundingClientRect();
                if (r.width > 0 && r.height > 0) {
                     return JSON.stringify({x: Math.round(r.x + r.width/2), y: Math.round(r.y + r.height/2)});
                }
            }
        }
        return null;
    })()
"@)
    
    if ($confirmBtnCoordsJson -ne "null" -and -not [string]::IsNullOrEmpty($confirmBtnCoordsJson)) {
        $confCoords = $js.DeserializeObject($confirmBtnCoordsJson)
        $cx = $confCoords["x"]
        $cy = $confCoords["y"]
        
        Write-Host "[Qwen] Подтверждение удаления (X:$cx, Y:$cy)..." -ForegroundColor Gray
        $Session.RealClick($cx, $cy)
        Start-Sleep -Milliseconds 1000
        
        # Проверка: ушли ли со страницы чата (URL изменился)
        $isHome = $Session.EvaluateJS("location.href.indexOf('/c/') < 0 ? 'YES' : 'NO'")
        if ($isHome -eq "YES") {
            Write-Host "[Qwen] Чат успешно удален." -ForegroundColor Green
            return $true
        } else {
            Write-Host "[Qwen] Страница не вернулась на главную. Возможно, удаление не прошло." -ForegroundColor Yellow
            return $false
        }
    } else {
        Write-Host "[Qwen] Кнопка подтверждения не найдена." -ForegroundColor Red
        return $false
    }
}

# --- ОСНОВНАЯ ЛОГИКА (ЕСЛИ ЗАПУЩЕН КАК СКРИПТ) ---

if ($Action -eq "Test") {
    Write-Host "=== Тест провайдера Qwen ===" -ForegroundColor Cyan
    
    $session = Get-QwenSession
    if ($session) {
        # Тест отправки
        $testMsg = "Напиши одно слово: ТЕСТ."
        $answer = Send-QwenMessage -Text $testMsg -Session $session
        
        if ($answer) {
            Write-Host "Ответ получен: $answer" -ForegroundColor Green
            # Сохраняем в файл
            $outFile = Join-Path $OutputFolder "qwen_test_result.txt"
            $answer | Out-File -FilePath $outFile -Encoding UTF8
            Write-Host "Сохранено в: $outFile"
            
            # Тест удаления (раскомментируйте, если хотите проверить удаление после теста)
            # Remove-QwenChat -Session $session
        }
        
        $session.Dispose()
    }
} elseif ($Action -eq "SendOnly") {
     # Режим для вызова из Оркестратора
     $session = Get-QwenSession
     if ($session) {
         $answer = Send-QwenMessage -Text $MessageText -Session $session
         $session.Dispose()
         # Выводим ответ в stdout, чтобы оркестратор мог его перехватить
         if ($answer) {
             Write-Output $answer
         }
     }
} elseif ($Action -eq "DeleteOnly") {
     $session = Get-QwenSession
     if ($session) {
         $result = Remove-QwenChat -Session $session
         $session.Dispose()
         if ($result) { Write-Output "SUCCESS" } else { Write-Output "FAIL" }
     }
}
