. "$PSScriptRoot\RT_settings.ps1"

if ($client_url -eq '' -or $nul -eq $client_url ) {
    Write-Output 'Проверьте наличие и заполненность файла настроек в каталоге скрипта'
    Pause
    exit
}

If ($args.Count -eq 0 ) {

    $choice = ( Read-Host -Prompt 'Выберите раздел' ).ToString()
    $min_id = ( Read-Host -Prompt 'Минимальный ID ( 0 если не нужно проверять ID)' )
    if ( $min_id -ne '0' ) {
        $min_id = $min_id.ToInt32($null)
        $max_id = ( Read-Host -Prompt 'Максимальный ID' )
        $max_id = $max_id.ToInt32($null)
    }
    $min_sid = ( Read-Host -Prompt 'Минимальное количество сидов ( 0 если не нужно проверять сидов)' )
}
elseif ($args.count -eq 1) {
    $choice = $args[0].ToString()
    $min_id = 0
}
elseif ($args.count -eq 3) {
    $choice = $args[0].ToString()
    $min_id = $args[1].ToInt32($nul)
    $max_id = $args[2].ToInt32($nul)
}
else { Write-Output 'Параметров должно быть не столько. Либо 0, либо 1, либо 3'; pause ; Exit }

if ( $PSVersionTable.OS.ToLower().contains('windows')) {
    $separator = '\'
    $drive_separator = ':\'
}
else {
    $separator = '/'
    $drive_separator = '/'
}

$secure_pass = ConvertTo-SecureString -String $proxy_password -AsPlainText -Force
$proxyCreds = New-Object System.Management.Automation.PSCredential -ArgumentList $proxy_login, $secure_pass

Write-Output 'Авторизуемся в клиенте'
$logindata = "username=$webui_login&password=$webui_password"
$loginheader = @{Referer = $client_url }
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -Headers $loginheader -Body $logindata ( $client_url + '/api/v2/auth/login' ) -Method POST -SessionVariable sid > $nul
Write-Output 'Получаем список раздач из клиента'
$client_torrents_list = (( Invoke-WebRequest -uri ( $client_url + '/api/v2/torrents/info' )-WebSession $sid ).Content | ConvertFrom-Json | Select-Object hash ).hash

Write-Output 'Запрашиваем список раздач в разделе'
$tracker_torrents_list = ( ( Invoke-WebRequest -Uri ( 'http://api.rutracker.org/v1/static/pvc/f/' + $choice ) ).content | ConvertFrom-Json -AsHashtable ).result
if ($min_id -ne '0') {
    $tracker_torrents_list_required = @{}
    foreach ( $key in $tracker_torrents_list.keys ) {
        if ( $key.ToInt32($null) -ge $min_id -and $key.ToInt32($null) -le $max_id ) {
            $tracker_torrents_list_required[$key] = $tracker_torrents_list[$key]
        }
    }
    $tracker_torrents_list = $tracker_torrents_list_required
}

if ($min_sid -ne '0' -and $nul -ne $min_sid ) {
    $tracker_torrents_list_required = @{}
    foreach ( $key in $tracker_torrents_list.keys ) {
        if ( $tracker_torrents_list[$key][1] -ge $min_sid ) {
            $tracker_torrents_list_required[$key] = $tracker_torrents_list[$key]
        }
    }
    $tracker_torrents_list = $tracker_torrents_list_required
}


$category = $default_category
if ( $default_category -eq '' ) {
    $category = ( ( Invoke-WebRequest -Uri ( 'http://api.rutracker.org/v1/get_forum_name?by=forum_id&val=' + $choice ) ).content | ConvertFrom-Json -AsHashtable ).result[$choice]
}

if ( $tracker_torrents_list.count -eq 0) {
    Write-Output 'Не получено ни одной раздачи'
    Pause
    Exit
}

Write-Output 'Авторизуемся на форуме'
$headers = @{'User-Agent' = 'Mozilla/5.0' }
$payload = @{'login_username' = $rutracker_login; 'login_password' = $rutracker_password; 'login' = '%E2%F5%EE%E4' }
Invoke-WebRequest -uri 'https://rutracker.org/forum/login.php' -SessionVariable forum_login -Method Post -body $payload -Headers $headers -Proxy $proxy_address -ProxyCredential $proxyCreds | Out-Null
Write-Output 'Проверяем есть ли что добавить'
$current = 1

$sorted = @{}
if ( $min_sid -gt 0 -and $nul -ne $min_sid ) {
    $tracker_torrents_list.keys | ForEach-Object { try { $sorted[$_] = $tracker_torrents_list[$_][1] } catch {} }
    $sorted = ( $sorted.GetEnumerator() | Sort-Object { $_.Value } -Descending ) | Where-Object { $_.Value -ne '' -and $nul -ne $_.Value }
}
else { 
    $tracker_torrents_list.keys | ForEach-Object { try { $sorted[$_] = $tracker_torrents_list[$_][3] } catch {} }
    $sorted = ( $sorted.GetEnumerator() | Sort-Object { $_.Value } ) | Where-Object { $_.Value -ne '' -and $nul -ne $_.Value }
}

ForEach ( $id in $sorted ) {
    $ProgressPreference = 'Continue'
    Write-Progress -Activity 'Обрабатываем раздачи' -Status ( "$current штук, " + ( [math]::Round( $current * 100 / $tracker_torrents_list.Keys.Count ) ) + '%' ) -PercentComplete ( $current * 100 / $tracker_torrents_list.Keys.Count )
    $ProgressPreference = 'SilentlyContinue'
    $current++
    $reqdata = @{'by' = 'topic_id'; 'val' = $id.Name.ToString() }
    # по каждой раздаче с трекера ищем её hash
    try {
        $hash = (( Invoke-WebRequest -Uri ( 'http://api.rutracker.org/v1/get_tor_hash?by=topic_id&val=' + $id.Name ) ).content | ConvertFrom-Json -AsHashtable ).result[$id.Name].ToLower()
    }
    catch {
        Write-Output ( "Не получилось найти хэш раздачи " + $id.name + ". Вероятно, это и не раздача вовсе." )
        Continue
    }
    if ( $client_torrents_list -notcontains $hash ) {
        # если такого hash ещё нет в клиенте, то:
        # проверяем, что такая ещё не заархивирована
        $folder_name = '\ArchRuT_' + ( 300000 * [math]::Truncate(( $id.Name - 1 ) / 300000) + 1 ) + '-' + 300000 * ( [math]::Truncate(( $id.Name - 1 ) / 300000) + 1 ) + '\'
        $zip_name = $google_folders[0] + $folder_name + $id.Name + '_' + $hash.ToLower() + '.7z'
        if ( -not ( test-path -Path $zip_name ) ) {
            # поглощённые раздачи пропускаем
            $info = (( Invoke-WebRequest -uri 'http://api.rutracker.org/v1/get_tor_topic_data' -body $reqdata).content | ConvertFrom-Json -AsHashtable ).result[$id.Name]
            if ( -not ( $info.tor_status -eq 7 ) ) {
                # Скачиваем торрент с форума
                Write-Output ( "Скачиваем " + $id.Name + ' ' + $info.topic_title )
                $forum_torrent_path = 'https://rutracker.org/forum/dl.php?t=' + $id.Name
                Invoke-WebRequest -uri $forum_torrent_path -WebSession $forum_login -OutFile ( $tmp_drive + $drive_separator + $id.Name + '.torrent') | Out-Null

                # и добавляем торрент в клиент
                if ( $torrent_folders -eq 1 ) { $extract_path = $store_path + $separator + $id.Name }
                else { $extract_path = $store_path }
                $dl_url = @{
                    name        = 'torrents'
                    torrents    = get-item ( $tmp_drive + $drive_separator + $id.Name + '.torrent' )
                    savepath    = $extract_path
                    category    = $category
                    root_folder = 'false'
                }
                Invoke-WebRequest -uri ( $client_url + '/api/v2/torrents/add' ) -form $dl_url -WebSession $sid -Method POST -ContentType 'application/x-bittorrent' | Out-Null
                Remove-Item -Path ( $tmp_drive + $drive_separator + $id.Name + '.torrent' ) 
            }
        }
    }
}
