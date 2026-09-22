---
"title": "Mega Release pipeline review"
"chat_link": "https://chat.deepseek.com/a/chat/s/225a1f58-cd1b-4bc8-a982-26f8e4ba0272"
"create_time": "2026-09-22T15:35:28.465Z"
"update_time": "2026-09-22T15:42:40.629Z"
"model": "DeepSeek Chat"
"model_name": "default"
"date_export": "2026-09-22T15-43-50"
---

# Mega Release pipeline review

Рассмотрел все файлы. Это хорошо структурированный release-пайплайн с вариантом Mega Release, который подтягивает артефакты внешних модулей. Ниже - обзор и несколько замечаний, которые стоит учесть.

## Общая архитектура

Пайплайн чётко разделён:

1. **`create-release-tag.yml`** - создаёт аннотированный тег на merge-коммите PR, затем явно запускает либо `MegaRelease.yml` (приоритет), либо `release.yml` (fallback).
2. **`release.yml`** - классический пайплайн: checkout → restore → test → publish проектов + subProjects → staging → архивы (ZIP + защищённый 7z) → `update.json` → GitHub Release (локально + remotes).
3. **`MegaRelease.yml`** - переиспользует контракт staging основного продукта, затем добавляет immutable-артефакты внешних модулей, взятые из их опубликованных GitHub Releases.

**Контракт staging** согласован в обоих: `Stage-ReleaseFiles.ps1` пишет `staging_directory` в `GITHUB_OUTPUT`, а потребители (`New-ReleaseArchives.ps1`, `Mega-StageReleaseFiles.ps1`) читают его обратно.

## Что сделано хорошо

- **Всё через конфиг**: `release.config.json` управляет solution, projects, subProjects, publicHere, remote и modules. Никаких зашитых имён продуктов/зеркал в workflow.
- **Детерминированное версионирование**: `Major.Minor` берётся из MSBuild, затем `Build` = дни с 2000-01-01, `Revision` = floor(секунды/2). Вычисляется один раз и переиспользуется всеми путями публикации.
- **Дисциплина «manifest после архивов»**: `update.json` строится из уже посчитанных хешей, поэтому SHA-256 всегда совпадает с опубликованными ассетами.
- **Иммутабельность модулей в Mega**: latest release + ровно один ZIP-ассет + SHA-256 проверяется дважды (digest из API, затем вычисленный после скачивания). Lock-файл фиксирует выбор.
- **Безопасность ZIP**: `Copy-ZipEntry` отклоняет `..`-сегменты и абсолютные пути.
- **Разделение токенов**: `PRIVATE_SUBMODULE_TOKEN` (read, fallback) vs `DOC_PROPS_RELEASE_TOKEN` (write, remotes) vs `github.token` (локальная запись, тег, dispatch).

## Замечания, которые стоит рассмотреть

### 1. `release.config.json` - невалидный JSON (критично)

В файле есть висячая запятая после закрывающей `}` второй группы subProjects, перед `]`:

```json
  "subProjects": [
    {
      "projects": [ ... ]
    },
    {
      "projects": [
        "Archivist/Archivist/Archivist.csproj"
      ]
    },
   ],
```

`ConvertFrom-Json` (и в Windows PowerShell 5.1, и в PowerShell 6/7) **отклоняет висячие запятые**. Это упадёт в `Read-ReleaseConfig.ps1` ещё до всего остального.

Это, скорее всего, самое серьёзное: **конфиг в присланном виде невалиден и сломает любой workflow, который его читает.** Если в реальном репозитории он работает - значит, на диске лежит другая версия. Иначе - это реальный баг.

Та же висячая запятая продублирована в README в разделе «Полный пример текущей конфигурации».

### 2. `Mega-StageReleaseFiles.ps1` - чтение `GITHUB_OUTPUT` хрупкое


```powershell
$outputLines = @(Get-Content -LiteralPath $env:GITHUB_OUTPUT)
$stagingLine = $outputLines | Where-Object { $_ -like 'staging_directory=*' } | Select-Object -Last 1
```

Работает, но парсит весь файл output и берёт последнее совпадение. Если какой-то более ранний шаг в том же job напишет `staging_directory=` (например, будущий шаг или многострочное значение с таким префиксом), молча выберется не то. Внешний workflow уже передаёт `STAGING_DIRECTORY` через `${{ steps.stage.outputs.staging_directory }}` для шага архивации - чище было бы, чтобы `Mega-AddModules.ps1` принимал staging-каталог параметром или через env, заданный вызывающим, а не выводил его заново.

Плюс: `$stagingDirectory = $null` в строке 33 сразу же перезаписывается в строке 43 - мёртвый код.

### 3. `Mega-AddModules.ps1` - защита от перезаписи `.md` не различает случаи


```powershell
if (Test-Path -LiteralPath $megaMarkdownPath) { throw "Module Markdown '$moduleMarkdownName' would overwrite an existing Mega release file." }
```

Хорошо, что защищает `.md` основного продукта. Но если **два модуля** положат корневой `.md` с одинаковым именем, второй упадёт на этой проверке (первый уже скопировал). Сообщение говорит «would overwrite an existing Mega release file» - формально верно, но причина - коллизия модуль-с-модулем, а не модуль-с-основным. Стоит указать в сообщении конфликтующий модуль.

### 4. `Mega-AddModules.ps1` - определение корневого `.md` через regex


```powershell
($entryName -notmatch '/') -and ($entryName -match '\.md$')
```

`-notmatch '/'` корректно означает «верхний уровень». Замечание мелкое: `\.md$` не анкорит всё имя целиком за пределами расширения, но это не проблема. `-match` в PowerShell регистронезависим по умолчанию, так что `.MD` тоже поймается - вероятно, это и нужно.

### 5. `MegaRelease.yml` - область действия `GH_TOKEN`

Шаг `Stage primary release and immutable modules` использует `${{ github.token }}` с комментарием, что доступ к приватным кросс-репозиториям «будет реализован отдельно через GitHub App». Это задел на будущее, но прямо сейчас workflow упадёт для любого модуля в приватном репозитории. Стоит убедиться, что репозитории модулей публичные, либо подключить App-токен до включения приватных модулей.

### 6. `New-ReleaseArchives.ps1` - `Compress-Archive` и пустой staging

`Compress-Archive -Path $stagingContent`, где `$stagingContent = Join-Path $stagingDirectory '*'`. Если staging пуст, поведение `Compress-Archive` с wildcard-путём зависит от версии PowerShell: где-то создаст пустой (но валидный) архив, где-то упадёт. Сейчас безопасно, потому что в staging всегда есть хотя бы release notes `.md`, но инвариант не проверяется. Проверка количества через `Get-ChildItem` перед компрессией сделала бы режим отказа явным.

### 7. `New-UpdateManifest.ps1` - `protected.password`


```powershell
password = $product
```

Комментарий говорит, что это намеренно публично и часть контракта. Это осознанное решение, согласованное с `New-ReleaseArchives.ps1` (`$archiveKey = $product`). Просто отмечаю: это значит, что 7z не даёт конфиденциальности - только обфускацию транспорта. README/комментарии это признают, так что это дизайн-выбор, а не баг.

### 8. `Publish-Projects.ps1` - область `$script:projectTypes`


```powershell
$script:projectTypes += [pscustomobject]@{ ... }
```

Внутри `Publish-ReleaseProject` `$script:projectTypes` ссылается на script scope файла `.ps1`. Работает, потому что функция определена в том же скрипте. Паттерн валидный, но легко ломается, если функцию вынести в модуль. Параметр `[ref]` или возврат метаданных через pipeline были бы надёжнее.

### 9. `create-release-tag.yml` - сообщение тега через `jq`


```bash
jq -r '.pull_request.body // ""' "$GITHUB_EVENT_PATH" > tag-message.txt
```

Если тело PR пустое, `git tag -a ... -F tag-message.txt` с пустым файлом создаст тег с пустым сообщением. Это допустимо, но `New-ReleaseNotes.ps1` тогда добавит только `# $tag` и пропустит сообщение. Нормально, просто отмечаю путь с пустым телом.

### 10. `Mega-AddModules.ps1` - `releases/latest` и пререлизы

`gh api repos/$Repository/releases/latest` исключает пререлизы и черновики. Если модуль публикует пререлизы, которые вы хотите потреблять, этот вызов их не увидит. Вероятно, намеренно, но стоит задокументировать в README в разделе Mega.

## Что можно сделать дальше

Если хотите, могу:

- **Исправить висячую запятую** в `release.config.json` (и в примере README).
- **Отрефакторить `Mega-StageReleaseFiles.ps1`**, чтобы staging передавался через env/параметр, а не перепарсивался из `GITHUB_OUTPUT`.
- **Улучшить сообщение о коллизии** в `Mega-AddModules.ps1`, различая модуль-с-основным и модуль-с-модулем.
- **Добавить явную проверку пустого staging** в `New-ReleaseArchives.ps1`.

Скажите, за что взяться, и уточните: висячая запятая есть в реальном конфиге или это артефакт вставки?


#### You:
<time datetime="2026-09-22T15:39:57.475Z" title="22.09.2026, 18:39:57">18:39</time>

устраняй замечания по порядку

#### DeepSeek:
<time datetime="2026-09-22T15:39:57.470Z" title="22.09.2026, 18:39:57">18:39</time>

Начну устранять замечания по порядку. Но сначала важное уточнение по пункту 1: мне нужно проверить, действительно ли висячая запятая есть в реальном файле, потому что от этого зависит, править ли `release.config.json` или только README.

Проверю присланный `release.config.json` внимательно:

```json
  "subProjects": [
    {
      "projects": [
        "ChangedbMod/ChangeDBmod.NC/ChangeDBmod.NC.csproj",
        "ChangedbMod/ChangeDBmod.NC.21/ChangeDBmod.NC.21.0.csproj",
        "ChangedbMod/ChangeDBmod.NC.26/ChangeDBmod.NC.26.0.csproj"
      ]
    },
    {
      "projects": [
        "Archivist/Archivist/Archivist.csproj"
      ]
    },
   ],
```

Да, после `}` второй группы стоит `,` перед `]`. Это невалидный JSON.

Приступаю по порядку.

---

## Замечание 1. Висячая запятая в `release.config.json` и README

**`release.config.json`** - убираю запятую после закрывающей `}` второй группы subProjects:

```json
{
  "solution": "drzTools.sln",
  "projects": [
    "drzTools.NC/drzTools.NC.csproj"
  ],
   "subProjects": [
    {
      "projects": [
        "ChangedbMod/ChangeDBmod.NC/ChangeDBmod.NC.csproj",
        "ChangedbMod/ChangeDBmod.NC.21/ChangeDBmod.NC.21.0.csproj",
        "ChangedbMod/ChangeDBmod.NC.26/ChangeDBmod.NC.26.0.csproj"
      ]
    },
    {
      "projects": [
        "Archivist/Archivist/Archivist.csproj"
      ]
    }
   ],
  "publicHere": true,
  "remote": [
    "doctorRaz/Publish_Test"
  ],
  "modules": [
    {
      "repository": "doctorRaz/docProps",
      "projects": [
        "Archivist",
        "docProps.NC"
      ]
    },
    {
      "repository": "doctorRaz/ChangedbMod",
      "projects": [
        "ChangeDBmod.NC"
      ]
    }
  ]
}
```

Заодно уберу лишний пробел в отступе `"subProjects"` (там `   "subProjects"` вместо `  "subProjects"` - косметика, но раз уж правлю файл).

**README.md** - та же висячая запятая в примере:

```json
    },
   ],
```

Меняю на:

```json
    }
  ],
```

Но подожди - прежде чем править, мне нужно убедиться, что я вижу актуальную версию файла. Ты прислал содержимое в первом сообщении; я исхожу из того, что оно соответствует реальному файлу. Если в реальном репозитории файл уже валиден - скажи, и я не буду трогать `release.config.json`, только README.

---

## Замечание 2. `Mega-StageReleaseFiles.ps1` - чтение `GITHUB_OUTPUT`

Заменю перепарсивание `GITHUB_OUTPUT` на прямой приём staging-каталога через env-переменную, которую задаёт вызывающий workflow. Это устраняет хрупкость и мёртвый код (`$stagingDirectory = $null`).

Новый вариант `Mega-StageReleaseFiles.ps1`:

```powershell
<#
.SYNOPSIS
    Stages the existing primary Release output for Mega Release.

.DESCRIPTION
    This is a thin Mega-specific wrapper around the existing staging contract.
    It first runs the existing Stage-ReleaseFiles.ps1 and then adds immutable
    external module artifacts. The existing primary-module packaging logic is
    therefore reused without modification.

    The staging directory is obtained from STAGING_DIRECTORY, which the
    calling workflow sets from steps.stage.outputs.staging_directory. This
    avoids re-parsing GITHUB_OUTPUT and keeps the contract explicit.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$stageScript = Join-Path $env:GITHUB_WORKSPACE '.github/scripts/Stage-ReleaseFiles.ps1'
if (-not (Test-Path -LiteralPath $stageScript -PathType Leaf)) {
    throw "Existing release staging script was not found: $stageScript"
}

# These are PowerShell scripts, not native executables. A successful invocation
# does not set $LASTEXITCODE, so failures must propagate through PowerShell's
# terminating-error handling instead of checking that variable.
& $stageScript

# The workflow supplies the staging directory explicitly through the step
# output. Validate it here so Mega-AddModules.ps1 can rely on it.
$stagingDirectory = $env:STAGING_DIRECTORY
if ([string]::IsNullOrWhiteSpace($stagingDirectory)) {
    throw 'STAGING_DIRECTORY is not set. The calling workflow must pass steps.stage.outputs.staging_directory.'
}
if (-not (Test-Path -LiteralPath $stagingDirectory -PathType Container)) {
    throw "Staging directory was not found: $stagingDirectory"
}

& (Join-Path $env:GITHUB_WORKSPACE '.github/scripts/Mega-AddModules.ps1')

# Expose the same staging directory for the existing archive/manifest scripts.
"staging_directory=$stagingDirectory" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
```

**Соответствующее изменение в `MegaRelease.yml`** - шаг `Stage primary release and immutable modules` должен передать staging-каталог. Проблема: на этом шаге staging ещё не создан (его создаёт `Stage-ReleaseFiles.ps1` внутри). Значит, `${{ steps.stage.outputs.staging_directory }}` недоступен до выполнения шага.

Здесь есть архитектурная тонкость: `Stage-ReleaseFiles.ps1` сам вычисляет `staging_directory` и пишет его в `GITHUB_OUTPUT`. Обёртка `Mega-StageReleaseFiles.ps1` вызывает его и должна узнать результат. Варианты:

- **A.** Оставить чтение `GITHUB_OUTPUT`, но сделать его надёжным (парсить только строки, добавленные именно этим шагом). Сложно и хрупко.
- **B.** Изменить `Stage-ReleaseFiles.ps1`, чтобы он возвращал путь через выходной параметр скрипта (pipeline/return), а не только через `GITHUB_OUTPUT`. Тогда обёртка получает его напрямую.
- **C.** Вычислять staging-каталог в обёртке заранее и передавать его в `Stage-ReleaseFiles.ps1` через env.

Вариант **B** - минимально инвазивный и не ломает существующий контракт `release.yml` (там `staging_directory` всё так же попадает в `GITHUB_OUTPUT`). Добавлю в `Stage-ReleaseFiles.ps1` возврат пути в конце:

```powershell
# В конце Stage-ReleaseFiles.ps1, после записи в GITHUB_OUTPUT:
$stagingDirectory
```

Тогда обёртка сможет сделать:

```powershell
$stagingDirectory = & $stageScript
```

Но `& $stageScript` уже вызывается, и его вывод (Write-Host) идёт в консоль. Если добавить возврат значения, оно попадёт в pipeline. Нужно аккуратно: `Write-Host` пишет в information stream, не в success stream, поэтому `$stagingDirectory = & $stageScript` получит только возвращённое значение. Это безопасно.

Однако в `Stage-ReleaseFiles.ps1` уже есть несколько `Write-Host`, и последняя строка - запись в `GITHUB_OUTPUT`. Добавлю возврат **после** неё.

Тогда обёртка становится:

```powershell
$stagingDirectory = & $stageScript
if ([string]::IsNullOrWhiteSpace([string]$stagingDirectory)) {
    throw 'Stage-ReleaseFiles.ps1 did not return a staging directory.'
}
if (-not (Test-Path -LiteralPath $stagingDirectory -PathType Container)) {
    throw "Staging directory was not found: $stagingDirectory"
}
```

Это чище и не требует парсинга `GITHUB_OUTPUT`. Но это меняет `Stage-ReleaseFiles.ps1`, который используется и в `release.yml`. В `release.yml` он вызывается без присваивания:

```yaml
run: ./.github/scripts/Stage-ReleaseFiles.ps1
```

Возврат значения в pipeline без потребителя безвреден - PowerShell просто отбросит его. Существующий контракт `staging_directory` через `GITHUB_OUTPUT` сохраняется. Так что изменение безопасно.

Приму этот подход:

**Изменение в `Stage-ReleaseFiles.ps1`** - добавить возврат в самом конце:

```powershell
"staging_directory=$stagingDirectory" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8

# Возвращаем путь в success stream, чтобы обёртки (например,
# Mega-StageReleaseFiles.ps1) могли получить его без парсинга GITHUB_OUTPUT.
# В release.yml возврат игнорируется.
$stagingDirectory
```

**Новая версия `Mega-StageReleaseFiles.ps1`:**

```powershell
<#
.SYNOPSIS
    Stages the existing primary Release output for Mega Release.

.DESCRIPTION
    This is a thin Mega-specific wrapper around the existing staging contract.
    It first runs the existing Stage-ReleaseFiles.ps1 and then adds immutable
    external module artifacts. The existing primary-module packaging logic is
    therefore reused without modification.

    Stage-ReleaseFiles.ps1 returns the staging directory through the success
    stream. That value is captured here directly instead of re-parsing
    GITHUB_OUTPUT, which keeps the contract explicit and avoids picking up an
    unrelated line from the output file.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$stageScript = Join-Path $env:GITHUB_WORKSPACE '.github/scripts/Stage-ReleaseFiles.ps1'
if (-not (Test-Path -LiteralPath $stageScript -PathType Leaf)) {
    throw "Existing release staging script was not found: $stageScript"
}

# These are PowerShell scripts, not native executables. A successful invocation
# does not set $LASTEXITCODE, so failures must propagate through PowerShell's
# terminating-error handling instead of checking that variable.
#
# Stage-ReleaseFiles.ps1 writes its progress through Write-Host (information
# stream) and returns only the staging path through the success stream, so the
# captured value is exactly the directory we need.
$stagingDirectory = & $stageScript

if ([string]::IsNullOrWhiteSpace([string]$stagingDirectory)) {
    throw 'Stage-ReleaseFiles.ps1 did not return a staging directory.'
}
if (-not (Test-Path -LiteralPath $stagingDirectory -PathType Container)) {
    throw "Staging directory was not found: $stagingDirectory"
}

$env:STAGING_DIRECTORY = $stagingDirectory
& (Join-Path $env:GITHUB_WORKSPACE '.github/scripts/Mega-AddModules.ps1')

# Expose the same staging directory for the existing archive/manifest scripts.
"staging_directory=$stagingDirectory" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
```

Здесь `$stagingDirectory = & $stageScript` может получить массив, если `Stage-ReleaseFiles.ps1` случайно что-то ещё вернёт в success stream. Проверю его: все сообщения идут через `Write-Host`, ошибки - через `throw`, единственный `Out-File` пишет в файл. Значит, в success stream попадёт только добавленная мной строка `$stagingDirectory`. Это строка, не массив. `[string]::IsNullOrWhiteSpace([string]$stagingDirectory)` корректно обработает и случай массива (приведёт к строке), но лучше явно взять последний элемент, если вдруг что-то добавится. Оставлю как есть - контракт явный.

---

## Замечание 3. `Mega-AddModules.ps1` - сообщение о коллизии `.md`

Сейчас:

```powershell
$moduleMarkdownName = [System.IO.Path]::GetFileName($rootMarkdown[0].FullName)
$megaMarkdownPath = Join-Path $stagingDirectory $moduleMarkdownName
if (Test-Path -LiteralPath $megaMarkdownPath) { throw "Module Markdown '$moduleMarkdownName' would overwrite an existing Mega release file." }
Copy-ZipEntry -Entry $rootMarkdown[0] -DestinationRoot $stagingDirectory
```

Проблема: неясно, конфликт с основным продуктом или с ранее добавленным модулем. Улучшу сообщение, включив репозиторий модуля и различая случаи.

Чтобы различить, нужно знать, какие `.md` уже добавлены модулями в этом запуске. Веду учёт на уровне цикла. Добавлю хеш-таблицу `$moduleMarkdownOwners` перед циклом и проверку:

```powershell
$moduleMarkdownOwners = @{}
```

Внутри цикла, после определения `$moduleMarkdownName`:

```powershell
$moduleMarkdownName = [System.IO.Path]::GetFileName($rootMarkdown[0].FullName)
$megaMarkdownPath = Join-Path $stagingDirectory $moduleMarkdownName
if (Test-Path -LiteralPath $megaMarkdownPath) {
    if ($moduleMarkdownOwners.ContainsKey($moduleMarkdownName)) {
        throw "Module '$repository' release '$tag' would overwrite Markdown '$moduleMarkdownName' already provided by module '$($moduleMarkdownOwners[$moduleMarkdownName])'."
    }
    throw "Module '$repository' release '$tag' would overwrite an existing Mega release file '$moduleMarkdownName' produced by the primary product."
}
Copy-ZipEntry -Entry $rootMarkdown[0] -DestinationRoot $stagingDirectory
$moduleMarkdownOwners[$moduleMarkdownName] = $repository
```

Это различает оба случая и называет виновника.

---

## Замечание 4. `Mega-AddModules.ps1` - определение корневого `.md` через regex

Замечание было информационным: `-notmatch '/'` означает «верхний уровень», а `-match '\.md$'` не анкорит всё имя. Это работает корректно. Но для явности и чтобы избежать случайного совпадения с именем вроде `notes.md.backup` (которое не совпадёт из-за `$`, но всё же), можно ужесточить проверку - требовать, чтобы имя было именно `<something>.md` без лишних сегментов:

Текущее:

```powershell
$rootMarkdown = @($archive.Entries | Where-Object {
    $entryName = $_.FullName.Replace('\','/')
    ($entryName -notmatch '/') -and ($entryName -match '\.md$')
})
```

Ужесточу до явной проверки «нет `/` и имя заканчивается на `.md`, регистронезависимо»:

```powershell
$rootMarkdown = @($archive.Entries | Where-Object {
    $entryName = $_.FullName.Replace('\','/')
    # Корневой файл: ровно один сегмент и расширение .md.
    ($entryName.IndexOf('/') -lt 0) -and
    $entryName.EndsWith('.md', [System.StringComparison]::OrdinalIgnoreCase)
})
```

`IndexOf('/') -lt 0` - явная проверка отсутствия сегментов, `EndsWith(..., OrdinalIgnoreCase)` - явная регистронезависимая проверка расширения. Семантика та же, читаемость выше.

---

## Замечание 5. `MegaRelease.yml` - область действия `GH_TOKEN`

Замечание про приватные модули - это задел на будущее, не баг. Сейчас ничего не меняю в коде, но добавлю в README явное предупреждение в разделе Mega Release, что модули должны быть публичными до подключения GitHub App.

Изменение в `README.md`, раздел «Конфигурация Mega Release», после абзаца про `projects`:

Добавлю:

```
Текущий `GH_TOKEN` шага staging - это встроенный `${{ github.token }}`,
который видит только публичные репозитории. Модули в приватных репозиториях
требуют отдельного GitHub App-токена; до его подключения используйте только
публичные module repositories.
```

---

## Замечание 6. `New-ReleaseArchives.ps1` - проверка непустого staging

Добавлю явную проверку перед `Compress-Archive`:

```powershell
# Compress-Archive с wildcard-путём ведёт себя по-разному на пустом каталоге
# в разных версиях PowerShell. Проверяем инвариант явно: staging всегда
# содержит хотя бы release notes.
$stagingItems = @(Get-ChildItem -LiteralPath $stagingDirectory -Force)
if ($stagingItems.Count -eq 0) {
    throw "Staging directory is empty; nothing to archive: $stagingDirectory"
}

Write-Host "Staging contains $($stagingItems.Count) top-level item(s)."

# Упаковываем содержимое staging, а не сам каталог, чтобы сохранить текущую
# структуру ZIP и 7z без дополнительного уровня staging.
$stagingContent = Join-Path $stagingDirectory '*'
Compress-Archive -Path $stagingContent -DestinationPath $archivePath -Force
```

`-Force` в `Get-ChildItem` учитывает скрытые файлы - staging не должен содержать только скрытые, но проверка должна быть честной.

---

## Замечание 7. `New-UpdateManifest.ps1` - `protected.password`

Это дизайн-выбор, зафиксированный в комментариях. Менять поведение не буду. Но раз уж проходим по замечаниям, усилю комментарий, чтобы явно проговорить модель угроз:

Текущий комментарий:

```powershell
# Пароль не является секретом и входит в публичный контракт manifest.
# Способ его формирования можно изменить позже без изменения контракта.
password = $product
```

Заменю на:

```powershell
# Пароль не является секретом и входит в публичный контракт manifest.
# Защищённый 7z предназначен только для обхода инфраструктурной фильтрации
# ZIP, а не для конфиденциальности: значение публикуется здесь и совпадает
# с product. Не размещайте в protected-архиве данные, требующие сокрытия.
password = $product
```

Согласую с комментарием в `New-ReleaseArchives.ps1` (там уже есть похожая формулировка - оставлю как есть, она корректна).

---

## Замечание 8. `Publish-Projects.ps1` - область `$script:projectTypes`

Замечание о хрупкости. Не баг, но улучшу: заменю `$script:projectTypes` на переменную, явно объявленную в script scope, с комментарием, либо передам через `[ref]`. Минимально инвазивно - оставить `$script:`, но добавить явное объявление с комментарием, чтобы было видно намерение. Сейчас переменная объявлена как `$projectTypes = @()` в script scope, а функция использует `$script:projectTypes`. Это уже корректно. Улучшу комментарий:

Текущий:

```powershell
# Используем script scope: функция выполняется в дочерней области PowerShell,
# поэтому обычное += к переменной верхнего уровня не изменило бы исходный массив.
$script:projectTypes += [pscustomobject]@{
```

Оставлю код, но добавлю к объявлению перед функцией:

```powershell
# Метаданные проекта являются контрактом между publish и staging.
# Массив живёт в script scope и наполняется из Publish-ReleaseProject через
# $script:projectTypes, потому что функция выполняется в дочерней области.
$projectTypes = @()
```

Это уже есть - просто усилю комментарий. Функционально ничего не меняю.

---

## Замечание 9. `create-release-tag.yml` - пустое тело PR

Сейчас:

```bash
jq -r '.pull_request.body // ""' "$GITHUB_EVENT_PATH" > tag-message.txt
```

При пустом теле создаётся аннотированный тег с пустым сообщением. Это допустимо, `New-ReleaseNotes.ps1` корректно обработает пустое сообщение (проверка `[string]::IsNullOrEmpty`). Замечание информационное. Но можно подстраховаться: если тело пустое, использовать заголовок PR. Это улучшит `release-notes.md`.

Изменю bash-блок:

```bash
# Берём тело PR из исходного event payload. Если тело пустое, используем
# заголовок PR, чтобы аннотированный тег и release notes не остались без
# описания.
jq -r '
  (.pull_request.body // "")
  | if (. | gsub("\\s"; "")) == "" then (.pull_request.title // "") else . end
' "$GITHUB_EVENT_PATH" > tag-message.txt
```

Подожди - `jq` не имеет доступа к `.pull_request.title` внутри `if`, потому что мы уже прошли через `|`. Нужно иначе:

```bash
jq -r '
  if ((.pull_request.body // "") | gsub("\\s"; "")) == ""
  then (.pull_request.title // "")
  else (.pull_request.body // "")
  end
' "$GITHUB_EVENT_PATH" > tag-message.txt
```

Здесь на входе - весь event payload, `.pull_request.body` и `.pull_request.title` доступны. `gsub("\\s"; "")` убирает все пробельные символы, чтобы тело из одних пробелов считалось пустым.

Это безопасно: если и тело, и заголовок пусты, файл будет пустым - как и раньше.

---

## Замечание 10. README - `releases/latest` и пререлизы

Добавлю в README в раздел «Конфигурация Mega Release» абзац:

```
Mega Release использует GitHub API `releases/latest`, который исключает
черновики и пререлизы. Если модуль публикует пререлизы как источник
артефактов, это поведение нужно изменить в `Mega-AddModules.ps1`
(`Get-LatestRelease`).
```

---

## Итог: список изменяемых файлов

1. **`release.config.json`** - убрать висячую запятую, выровнять отступ.
2. **`README.md`** - убрать висячую запятую в примере; добавить предупреждение про `GH_TOKEN` и приватные модули; добавить заметку про `releases/latest` и пререлизы.
3. **`Stage-ReleaseFiles.ps1`** - вернуть `$stagingDirectory` в success stream в конце.
4. **`Mega-StageReleaseFiles.ps1`** - получать staging из возврата `Stage-ReleaseFiles.ps1` вместо парсинга `GITHUB_OUTPUT`.
5. **`Mega-AddModules.ps1`** - различать коллизии `.md` (модуль-с-модулем vs модуль-с-основным); ужесточить определение корневого `.md`.
6. **`New-ReleaseArchives.ps1`** - явная проверка непустого staging перед `Compress-Archive`.
7. **`New-UpdateManifest.ps1`** - уточнить комментарий про модель угроз `protected.password`.
8. **`Publish-Projects.ps1`** - уточнить комментарий про script scope (без смены поведения).
9. **`create-release-tag.yml`** - fallback на заголовок PR при пустом теле.

Прежде чем я выдам финальные версии всех файлов целиком, подтверди:

- **Править ли `release.config.json`** (замечание 1) - да/нет, если в реальном репозитории он уже валиден.
- **Согласен ли ты с подходом B** для замечания 2 (возврат staging из `Stage-ReleaseFiles.ps1` вместо парсинга `GITHUB_OUTPUT`)? Это меняет контракт скрипта, хоть и обратно совместимо.

После подтверждения выдам все изменённые файлы целиком, по порядку.


#### You:
<time datetime="2026-09-22T15:41:00.646Z" title="22.09.2026, 18:41:00">18:41</time>

выдавай

#### DeepSeek:
<time datetime="2026-09-22T15:41:00.641Z" title="22.09.2026, 18:41:00">18:41</time>

Выдаю все изменённые файлы целиком, по порядку замечаний. По пункту 1 принимаю, что `release.config.json` в присланном виде - это фактическое состояние, и правлю его.

---

## 1. `release.config.json`

Убрана висячая запятая после второй группы `subProjects`, выровнен отступ у `"subProjects"`.

```json
{
  "solution": "drzTools.sln",
  "projects": [
    "drzTools.NC/drzTools.NC.csproj"
  ],
  "subProjects": [
    {
      "projects": [
        "ChangedbMod/ChangeDBmod.NC/ChangeDBmod.NC.csproj",
        "ChangedbMod/ChangeDBmod.NC.21/ChangeDBmod.NC.21.0.csproj",
        "ChangedbMod/ChangeDBmod.NC.26/ChangeDBmod.NC.26.0.csproj"
      ]
    },
    {
      "projects": [
        "Archivist/Archivist/Archivist.csproj"
      ]
    }
  ],
  "publicHere": true,
  "remote": [
    "doctorRaz/Publish_Test"
  ],
  "modules": [
    {
      "repository": "doctorRaz/docProps",
      "projects": [
        "Archivist",
        "docProps.NC"
      ]
    },
    {
      "repository": "doctorRaz/ChangedbMod",
      "projects": [
        "ChangeDBmod.NC"
      ]
    }
  ]
}
```

---

## 2. `Stage-ReleaseFiles.ps1`

Изменение только в конце: возврат `$stagingDirectory` в success stream, чтобы обёртки могли получить его напрямую. Существующий контракт `staging_directory` через `GITHUB_OUTPUT` сохранён - `release.yml` продолжает работать без изменений.

```powershell
<#
.SYNOPSIS
    Формирует staging-каталог с предсказуемой структурой релизного архива.

.DESCRIPTION
    Итоговая структура staging:

        <SolutionName>/
            <MainFirstProjectName>/
                <файлы всех основных проектов>
            <SubProjectFirstProjectName>/
                <файлы всех проектов subProject>
            <содержимое assets с сохранением структуры>
        <Product>_<Version>.md

    PROJECT_TYPES_JSON содержит для каждого publish-проекта его тип и
    логическую группу. Все проекты одной группы объединяются непосредственно
    в каталог первого проекта этой группы. Это позволяет нескольким проектам
    одного subProject поставлять общий набор файлов без промежуточных
    каталогов отдельных проектов.

    Файлы publish с расширением .pdb исключаются из релиза.
    Для Library дополнительно исключаются .deps.json и .runtimeconfig.json.
    Для Exe эти файлы сохраняются, поскольку они необходимы для запуска.

    Main assets размещаются в каталоге solution с сохранением структуры.
    Assets из subProject в release не включаются.

    Скрипт пишет staging_directory в GITHUB_OUTPUT и дополнительно
    возвращает путь в success stream, чтобы обёртки (Mega-StageReleaseFiles.ps1)
    могли получить его без парсинга GITHUB_OUTPUT. В release.yml возврат
    игнорируется.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectPaths = @($env:PROJECTS_JSON | ConvertFrom-Json)
if ($projectPaths.Count -eq 0) {
    throw 'PROJECTS_JSON does not contain any projects.'
}

$projectTypes = @($env:PROJECT_TYPES_JSON | ConvertFrom-Json)
if ($projectTypes.Count -eq 0) {
    throw 'PROJECT_TYPES_JSON does not contain any projects.'
}

$publishRoot = Join-Path $env:GITHUB_WORKSPACE 'publish'
$assetsRoot = Join-Path $env:GITHUB_WORKSPACE 'assets'
$releaseNotesPath = Join-Path $env:GITHUB_WORKSPACE 'release-notes.md'

$solutionName = $env:PRODUCT
if ([string]::IsNullOrWhiteSpace($solutionName)) {
    throw 'PRODUCT is empty; cannot determine solution directory.'
}

# Первый основной проект определяет каталог основной группы.
$mainGroupName = [System.IO.Path]::GetFileNameWithoutExtension([string]$projectPaths[0])
if ([string]::IsNullOrWhiteSpace($mainGroupName)) {
    throw "Could not determine main project group name from: $($projectPaths[0])"
}

$stagingDirectory = Join-Path $env:RUNNER_TEMP "Stage_$($env:PRODUCT)_$($env:FULL_VERSION)"
$solutionDirectory = Join-Path $stagingDirectory $solutionName

Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $solutionDirectory -Force | Out-Null

$excludedExtensions = @('.pdb')

if (-not (Test-Path -LiteralPath $publishRoot -PathType Container)) {
    throw "Publish directory was not found: $publishRoot"
}

if (-not (Test-Path -LiteralPath $releaseNotesPath -PathType Leaf)) {
    throw "Release notes were not found: $releaseNotesPath"
}

# Каждый publish-проект получает собственную запись с абсолютным корнем.
# Path используется как ключ, чтобы одинаковые имена проектов в разных
# группах не смешивали результаты staging.
$projectRoots = @()
foreach ($projectPath in $projectPaths) {
    $projectPathText = [string]$projectPath
    $metadata = @($projectTypes | Where-Object { $_.Path -eq $projectPathText })
    if ($metadata.Count -ne 1) {
        throw "Project type metadata is missing or duplicated for project: $projectPathText"
    }

    $projectRoots += [pscustomobject]@{
        Path      = $projectPathText
        Name      = [string]$metadata[0].Name
        Type      = [string]$metadata[0].Type
        GroupName = [string]$metadata[0].GroupName
        GroupKind = [string]$metadata[0].GroupKind
        Root      = (Join-Path $publishRoot ([string]$metadata[0].Name))
    }
}

# Добавляем subProject roots из metadata. Их assets намеренно не сканируются:
# publish-каталог содержит только результаты dotnet publish.
foreach ($metadata in $projectTypes) {
    if ($metadata.GroupKind -ne 'SubProject') {
        continue
    }

    $existing = @($projectRoots | Where-Object { $_.Path -eq [string]$metadata.Path })
    if ($existing.Count -gt 0) {
        continue
    }

    $projectRoots += [pscustomobject]@{
        Path      = [string]$metadata.Path
        Name      = [string]$metadata.Name
        Type      = [string]$metadata.Type
        GroupName = [string]$metadata.GroupName
        GroupKind = [string]$metadata.GroupKind
        Root      = (Join-Path $publishRoot ([string]$metadata.Name))
    }
}

$files = Get-ChildItem -LiteralPath $publishRoot -File -Recurse |
    Where-Object { $excludedExtensions -notcontains $_.Extension.ToLowerInvariant() }

$stagedPublishFileCount = 0

foreach ($file in $files) {
    $matchedProject = $null
    foreach ($projectRoot in $projectRoots) {
        $prefix = $projectRoot.Root + [System.IO.Path]::DirectorySeparatorChar
        if ($file.FullName.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $matchedProject = $projectRoot
            break
        }
    }

    if ($null -eq $matchedProject) {
        throw "Could not determine publish project for file: $($file.FullName)"
    }

    $fileName = [System.IO.Path]::GetFileName($file.FullName)
    $isRuntimeMetadata =
        $fileName.EndsWith('.deps.json', [System.StringComparison]::OrdinalIgnoreCase) -or
        $fileName.EndsWith('.runtimeconfig.json', [System.StringComparison]::OrdinalIgnoreCase)

    if ($matchedProject.Type -eq 'Library' -and $isRuntimeMetadata) {
        Write-Host "Excluded for Library project: $($file.FullName)"
        continue
    }

    # Каталог назначения определяется группой, а не отдельным проектом.
    # Поэтому ProjectA1 и ProjectA2 из одной группы физически объединяются
    # в каталоге ProjectA1, сохраняя внутренние подпапки publish.
    $groupDirectory = Join-Path $solutionDirectory $matchedProject.GroupName
    $relativePath = $file.FullName.Substring($matchedProject.Root.Length).TrimStart([char]'\', [char]'/')
    $destinationPath = Join-Path $groupDirectory $relativePath
    $destinationDirectory = Split-Path -Parent $destinationPath

    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    Copy-Item -LiteralPath $file.FullName -Destination $destinationPath -Force
    $stagedPublishFileCount++
}

# Assets основного решения размещаются в каталоге solution, а не внутри
# project/subProject. Каталоги assets самих subProject сюда не попадают.
if (Test-Path -LiteralPath $assetsRoot -PathType Container) {
    $assetFiles = @(Get-ChildItem -LiteralPath $assetsRoot -File -Recurse)

    foreach ($assetFile in $assetFiles) {
        $relativeAssetPath = $assetFile.FullName.Substring($assetsRoot.Length).TrimStart([char]'\', [char]'/')
        $destinationPath = Join-Path $solutionDirectory $relativeAssetPath
        $destinationDirectory = Split-Path -Parent $destinationPath

        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        Copy-Item -LiteralPath $assetFile.FullName -Destination $destinationPath -Force
    }

    Write-Host "Staged $($assetFiles.Count) asset file(s) from: $assetsRoot"
}
else {
    Write-Host "Assets directory not found; no additional release files to stage."
}

$markdownName = "${env:PRODUCT}_${env:FULL_VERSION}.md"
$stagedMarkdownPath = Join-Path $stagingDirectory $markdownName
Copy-Item -LiteralPath $releaseNotesPath -Destination $stagedMarkdownPath -Force

$stagedFiles = @(Get-ChildItem -LiteralPath $stagingDirectory -File -Recurse |
    ForEach-Object {
        $_.FullName.Substring($stagingDirectory.Length).TrimStart([char]'\', [char]'/')
    } |
    Sort-Object)

Write-Host '--- Release staging tree ---'
if ($stagedFiles.Count -eq 0) {
    Write-Host '(empty)'
}
else {
    $stagedFiles | ForEach-Object { Write-Host $_ }
}
Write-Host "--- End release staging tree ($($stagedFiles.Count) file(s)) ---"
Write-Host "Staged $stagedPublishFileCount publish file(s), release notes and assets into: $stagingDirectory"

"staging_directory=$stagingDirectory" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8

# Возвращаем путь в success stream, чтобы обёртки (например,
# Mega-StageReleaseFiles.ps1) могли получить его без парсинга GITHUB_OUTPUT.
# В release.yml возврат игнорируется, существующий контракт через
# GITHUB_OUTPUT сохраняется.
$stagingDirectory
```

---

## 3. `Mega-StageReleaseFiles.ps1`

Получает staging из возврата `Stage-ReleaseFiles.ps1` вместо парсинга `GITHUB_OUTPUT`. Мёртвый код (`$stagingDirectory = $null`) убран.

```powershell
<#
.SYNOPSIS
    Stages the existing primary Release output for Mega Release.

.DESCRIPTION
    This is a thin Mega-specific wrapper around the existing staging contract.
    It first runs the existing Stage-ReleaseFiles.ps1 and then adds immutable
    external module artifacts. The existing primary-module packaging logic is
    therefore reused without modification.

    Stage-ReleaseFiles.ps1 returns the staging directory through the success
    stream. That value is captured here directly instead of re-parsing
    GITHUB_OUTPUT, which keeps the contract explicit and avoids picking up an
    unrelated line from the output file.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$stageScript = Join-Path $env:GITHUB_WORKSPACE '.github/scripts/Stage-ReleaseFiles.ps1'
if (-not (Test-Path -LiteralPath $stageScript -PathType Leaf)) {
    throw "Existing release staging script was not found: $stageScript"
}

# These are PowerShell scripts, not native executables. A successful invocation
# does not set $LASTEXITCODE, so failures must propagate through PowerShell's
# terminating-error handling instead of checking that variable.
#
# Stage-ReleaseFiles.ps1 writes progress through Write-Host (information
# stream) and returns only the staging path through the success stream, so the
# captured value is exactly the directory we need.
$stagingDirectory = & $stageScript

if ([string]::IsNullOrWhiteSpace([string]$stagingDirectory)) {
    throw 'Stage-ReleaseFiles.ps1 did not return a staging directory.'
}
if (-not (Test-Path -LiteralPath $stagingDirectory -PathType Container)) {
    throw "Staging directory was not found: $stagingDirectory"
}

$env:STAGING_DIRECTORY = $stagingDirectory
& (Join-Path $env:GITHUB_WORKSPACE '.github/scripts/Mega-AddModules.ps1')

# Expose the same staging directory for the existing archive/manifest scripts.
"staging_directory=$stagingDirectory" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
```

---

## 4. `Mega-AddModules.ps1`

Изменения:

- различение коллизий `.md` (модуль-с-модулем vs модуль-с-основным) через `$moduleMarkdownOwners`;
- ужесточённое определение корневого `.md` (явная проверка отсутствия сегментов и регистронезависимое расширение).
  
```powershell
<#
.SYNOPSIS
    Adds immutable external module release artifacts to Mega Release staging.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$configPath = Join-Path $env:GITHUB_WORKSPACE $env:RELEASE_CONFIG_FILE
$stagingDirectory = $env:STAGING_DIRECTORY

if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw "Release configuration was not found: $configPath" }
if (-not (Test-Path -LiteralPath $stagingDirectory -PathType Container)) { throw "Mega staging directory was not found: $stagingDirectory" }

$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
if ($null -eq $config.modules) { throw "Release configuration property 'modules' is required for Mega Release." }
$modules = @($config.modules)
if ($modules.Count -eq 0) { Write-Host 'No Mega Release modules are configured.'; exit 0 }

$destinationPaths = @{}
foreach ($module in $modules) {
    $repository = [string]$module.repository
    $projects = @($module.projects)
    if ($repository -notmatch '^[^/\s]+/[^/\s]+$') { throw "Invalid module repository '$repository'. Expected owner/repository." }
    if ($projects.Count -eq 0) { throw "Module '$repository' must define at least one project in 'projects'." }
    foreach ($projectValue in $projects) {
        $project = [string]$projectValue
        $normalizedProject = $project.Replace('\','/').Trim('/')
        if ([string]::IsNullOrWhiteSpace($normalizedProject)) { throw "Module '$repository' contains an empty project path." }
        if ($normalizedProject -match '(^|/)\.\.(/|$)') { throw "Invalid project path '$project' in module '$repository'. Parent directory traversal is not allowed." }
        if ([System.IO.Path]::IsPathRooted($normalizedProject)) { throw "Invalid project path '$project' in module '$repository'. Rooted paths are not allowed." }
        if ($destinationPaths.ContainsKey($normalizedProject)) { throw "Duplicate Mega Release project destination '$normalizedProject'." }
        $destinationPaths[$normalizedProject] = $repository
    }
}

$downloadRoot = Join-Path $env:RUNNER_TEMP ("MegaModules_" + $env:GITHUB_RUN_ID)
New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
$lock = @()

# Отслеживает, какой модуль уже добавил конкретный корневой .md, чтобы
# различать коллизию модуль-с-модулем и коллизию с файлом основного продукта.
$moduleMarkdownOwners = @{}

function Get-LatestRelease {
    param([Parameter(Mandatory)][string]$Repository)
    $json = gh api "repos/$Repository/releases/latest" --header "Accept: application/vnd.github+json"
    if ($LASTEXITCODE -ne 0) { throw "Could not get latest published release for '$Repository'." }
    return ($json | ConvertFrom-Json)
}

function Download-Asset {
    param([Parameter(Mandatory)][string]$Repository,[Parameter(Mandatory)][string]$Tag,[Parameter(Mandatory)][string]$AssetName,[Parameter(Mandatory)][string]$Directory)
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    gh release download $Tag --repo $Repository --pattern $AssetName --dir $Directory --clobber
    if ($LASTEXITCODE -ne 0) { throw "Could not download asset '$AssetName' from '$Repository' release '$Tag'." }
    $path = Join-Path $Directory $AssetName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Downloaded asset was not found: $path" }
    return $path
}

function Copy-ZipEntry {
    param([Parameter(Mandatory)]$Entry,[Parameter(Mandatory)][string]$DestinationRoot,[string]$StripPrefix = '')
    $entryName = $Entry.FullName.Replace('\','/')
    $segments = @($entryName -split '/')
    if ($segments | Where-Object { $_ -eq '..' }) { throw "Unsafe ZIP entry path: '$entryName'." }
    if ([System.IO.Path]::IsPathRooted($entryName)) { throw "Unsafe rooted ZIP entry path: '$entryName'." }
    $normalizedPrefix = $StripPrefix.Replace('\','/').TrimStart('/')
    if ($normalizedPrefix -and -not $normalizedPrefix.EndsWith('/')) { $normalizedPrefix += '/' }
    if ($normalizedPrefix) {
        if (-not $entryName.StartsWith($normalizedPrefix, [System.StringComparison]::Ordinal)) { throw "ZIP entry '$entryName' is outside expected root '$normalizedPrefix'." }
        $relativeName = $entryName.Substring($normalizedPrefix.Length)
    } else { $relativeName = $entryName }
    if ([string]::IsNullOrWhiteSpace($relativeName)) { return }
    $relativeName = $relativeName.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $destination = Join-Path $DestinationRoot $relativeName
    if ($Entry.FullName.EndsWith('/')) { New-Item -ItemType Directory -Path $destination -Force | Out-Null; return }
    $parent = Split-Path -Parent $destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $input = $Entry.Open()
    try {
        $output = [System.IO.File]::Create($destination)
        try { $input.CopyTo($output) } finally { $output.Dispose() }
    } finally { $input.Dispose() }
}

function Get-ArchiveRootDirectory {
    param([Parameter(Mandatory)]$Archive)
    $topLevelDirectories = @(
        $Archive.Entries | ForEach-Object {
            $name = $_.FullName.Replace('\','/')
            if ($name -match '^([^/]+)/') { $matches[1] }
        } | Sort-Object -Unique
    )
    if ($topLevelDirectories.Count -ne 1) { throw "Expected exactly one root directory in the selected artifact; found $($topLevelDirectories.Count)." }
    return [string]$topLevelDirectories[0]
}

function Copy-ProjectFromZip {
    param([Parameter(Mandatory)]$Archive,[Parameter(Mandatory)][string]$Project,[Parameter(Mandatory)][string]$ArchiveRoot,[Parameter(Mandatory)][string]$DestinationRoot)
    $normalizedProject = $Project.Replace('\','/').Trim('/')
    $projectPrefix = $ArchiveRoot.Trim('/') + '/' + $normalizedProject + '/'
    $projectEntries = @($Archive.Entries | Where-Object { $_.FullName.Replace('\','/').StartsWith($projectPrefix, [System.StringComparison]::Ordinal) })
    if ($projectEntries.Count -eq 0) { throw "Project directory '$ArchiveRoot/$Project' was not found in the selected artifact." }
    foreach ($entry in $projectEntries) { Copy-ZipEntry -Entry $entry -DestinationRoot $DestinationRoot -StripPrefix $ArchiveRoot }
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

for ($moduleIndex = 0; $moduleIndex -lt $modules.Count; $moduleIndex++) {
    $module = $modules[$moduleIndex]
    $repository = [string]$module.repository
    $projects = @($module.projects) | ForEach-Object { ([string]$_).Replace('\','/').Trim('/') }
    Write-Host ("=== Mega module repository: " + $repository + " ===")
    Write-Host ("Projects: " + ($projects -join ', '))

    $release = Get-LatestRelease -Repository $repository
    $tag = [string]$release.tag_name
    if ([string]::IsNullOrWhiteSpace($tag)) { throw "Latest release of '$repository' does not contain tag_name." }
    $zipAssets = @($release.assets | Where-Object { $_.state -eq 'uploaded' -and $_.name -match '\.zip$' })
    if ($zipAssets.Count -ne 1) { throw "Expected exactly one ZIP release asset in '$repository' release '$tag'; found $($zipAssets.Count)." }
    $asset = $zipAssets[0]
    $assetName = [string]$asset.name
    $digest = [string]$asset.digest
    if ($digest -notmatch '^sha256:[0-9a-fA-F]{64}$') { throw "Release asset '$assetName' in '$repository' has no valid SHA-256 digest." }
    $expectedHash = $digest.Substring(7).ToLowerInvariant()
    $moduleDownloadDirectory = Join-Path $downloadRoot ("module-" + $moduleIndex)
    $archivePath = Download-Asset -Repository $repository -Tag $tag -AssetName $assetName -Directory $moduleDownloadDirectory
    $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) { throw "SHA-256 mismatch for '$repository' release '$tag' asset '$assetName'. Expected '$expectedHash', actual '$actualHash'." }
    Write-Host ("Release fixed: " + $tag)
    Write-Host ("Artifact fixed: " + $assetName)
    Write-Host ("SHA-256 verified: " + $actualHash)

    $archive = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        $archiveRoot = Get-ArchiveRootDirectory -Archive $archive
        Write-Host ("Archive root: " + $archiveRoot)
        foreach ($project in $projects) {
            Write-Host ("Extracting project: " + $project)
            Copy-ProjectFromZip -Archive $archive -Project $project -ArchiveRoot $archiveRoot -DestinationRoot (Join-Path $stagingDirectory $env:PRODUCT)
        }

        # Корневой .md: ровно один сегмент в пути и расширение .md
        # (регистронезависимо). Явная проверка IndexOf вместо regex делает
        # намерение однозначным.
        $rootMarkdown = @($archive.Entries | Where-Object {
            $entryName = $_.FullName.Replace('\','/')
            ($entryName.IndexOf('/') -lt 0) -and
            $entryName.EndsWith('.md', [System.StringComparison]::OrdinalIgnoreCase)
        })
        if ($rootMarkdown.Count -ne 1) { throw "Expected exactly one MD file at the ZIP root in '$repository' release '$tag'; found $($rootMarkdown.Count)." }

        $moduleMarkdownName = [System.IO.Path]::GetFileName($rootMarkdown[0].FullName)
        $megaMarkdownPath = Join-Path $stagingDirectory $moduleMarkdownName
        if (Test-Path -LiteralPath $megaMarkdownPath) {
            if ($moduleMarkdownOwners.ContainsKey($moduleMarkdownName)) {
                throw "Module '$repository' release '$tag' would overwrite Markdown '$moduleMarkdownName' already provided by module '$($moduleMarkdownOwners[$moduleMarkdownName])'."
            }
            throw "Module '$repository' release '$tag' would overwrite an existing Mega release file '$moduleMarkdownName' produced by the primary product."
        }
        Copy-ZipEntry -Entry $rootMarkdown[0] -DestinationRoot $stagingDirectory
        $moduleMarkdownOwners[$moduleMarkdownName] = $repository
    }
    finally { $archive.Dispose() }

    $lock += [pscustomobject]@{ repository=$repository; projects=@($projects); release=$tag; artifact=$assetName; sha256=$actualHash }
}

$lockPath = Join-Path $env:RUNNER_TEMP ("mega-modules-" + $env:GITHUB_RUN_ID + ".lock.json")
$lock | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $lockPath -Encoding utf8NoBOM
Write-Host '=== Mega module selection ==='
$lock | Format-Table -AutoSize | Out-String | Write-Host
Write-Host ("Module lock: " + $lockPath)
```

---

## 5. `New-ReleaseArchives.ps1`

Добавлена явная проверка непустого staging перед `Compress-Archive`.

```powershell
<#
.SYNOPSIS
    Создаёт финальные release-архивы: обычный ZIP и защищённый 7z.

.DESCRIPTION
    Скрипт отвечает только за формирование физических архивов и их метаданных.
    Оба архива создаются из одного и того же подготовленного staging-каталога.

    Защищённый архив предназначен не для контроля доступа, а для повышения
    надёжности распространения через инфраструктуру, которая может фильтровать
    обычные ZIP-файлы. Значение для открытия архива является частью публичного
    контракта update.json и на текущем этапе совпадает с именем продукта.

    Outputs через GITHUB_OUTPUT:
      archive_name, archive_sha256, archive_size,
      protected_archive_name, protected_sha256, protected_size.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$product = $env:PRODUCT
$fullVersion = $env:FULL_VERSION
$stagingDirectory = $env:STAGING_DIRECTORY

if ([string]::IsNullOrWhiteSpace($product)) { throw 'PRODUCT is not set.' }
if ([string]::IsNullOrWhiteSpace($fullVersion)) { throw 'FULL_VERSION is not set.' }
if (-not (Test-Path -LiteralPath $stagingDirectory -PathType Container)) {
    throw "Staging directory was not found: $stagingDirectory"
}

$archiveName = "${product}_${fullVersion}.zip"
# Имя защищённого архива использует тот же префикс product_version,
# что и обычный ZIP, а суффикс -protected однозначно указывает его назначение.
$protectedArchiveName = "${product}_${fullVersion}-protected.7z"
$archivePath = Join-Path $env:GITHUB_WORKSPACE $archiveName
$protectedArchivePath = Join-Path $env:GITHUB_WORKSPACE $protectedArchiveName

# Значение не является секретом: оно публикуется в update.json как часть
# контракта и может быть заменено другой схемой без изменения формата 7z.
$archiveKey = $product

# Явно разрешаем путь к 7-Zip, чтобы workflow не зависел от PATH runner.
$sevenZipCandidates = @(
    (Get-Command 7z.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
    (Get-Command 7zz.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
    (Join-Path ${env:ProgramFiles} '7-Zip\7z.exe'),
    (Join-Path ${env:ProgramFiles} '7-Zip\7zz.exe')
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

$sevenZipPath = $sevenZipCandidates |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1

if ([string]::IsNullOrWhiteSpace($sevenZipPath)) {
    throw '7-Zip executable was not found on the runner.'
}

Write-Host "Using 7-Zip: $sevenZipPath"

# Compress-Archive с wildcard-путём ведёт себя по-разному на пустом каталоге
# в разных версиях PowerShell: где-то создаёт пустой (но валидный) архив,
# где-то завершается ошибкой. Проверяем инвариант явно: staging всегда
# содержит хотя бы release notes.
$stagingItems = @(Get-ChildItem -LiteralPath $stagingDirectory -Force)
if ($stagingItems.Count -eq 0) {
    throw "Staging directory is empty; nothing to archive: $stagingDirectory"
}
Write-Host "Staging contains $($stagingItems.Count) top-level item(s)."

# 7-Zip в режиме создания архива может обновить существующий файл, поэтому
# старый защищённый архив удаляем явно. Для ZIP это не требуется: -Force уже
# определяет поведение Compress-Archive при существующем файле.
Remove-Item -LiteralPath $protectedArchivePath -Force -ErrorAction SilentlyContinue

# Упаковываем содержимое staging, а не сам каталог, чтобы сохранить текущую
# структуру ZIP и 7z без дополнительного уровня staging.
$stagingContent = Join-Path $stagingDirectory '*'
Compress-Archive -Path $stagingContent -DestinationPath $archivePath -Force

if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
    throw "Release archive was not created: $archivePath"
}

# Оба архива получают одинаковое содержимое. -mhe=on дополнительно шифрует
# заголовки 7z, включая имена файлов внутри архива. Формат 7z использует
# AES-256 для password-based encryption.
$sevenZipArguments = @(
    'a',
    '-t7z',
    '-mhe=on',
    "-p$archiveKey",
    $protectedArchivePath,
    $stagingContent
)

& $sevenZipPath @sevenZipArguments
if ($LASTEXITCODE -ne 0) {
    throw "7-Zip failed with exit code $LASTEXITCODE."
}

if (-not (Test-Path -LiteralPath $protectedArchivePath -PathType Leaf)) {
    throw "Protected release archive was not created: $protectedArchivePath"
}

$archiveFile = Get-Item -LiteralPath $archivePath
$protectedFile = Get-Item -LiteralPath $protectedArchivePath
$archiveSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
$protectedSha256 = (Get-FileHash -LiteralPath $protectedArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()

Write-Host "Created archive: $archiveName"
Write-Host "Archive size: $($archiveFile.Length) bytes"
Write-Host "Archive SHA256: $archiveSha256"
Write-Host "Created protected archive: $protectedArchiveName"
Write-Host "Protected archive size: $($protectedFile.Length) bytes"
Write-Host "Protected archive SHA256: $protectedSha256"

"archive_name=$archiveName" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
"archive_sha256=$archiveSha256" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
"archive_size=$($archiveFile.Length)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
"protected_archive_name=$protectedArchiveName" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
"protected_sha256=$protectedSha256" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
"protected_size=$($protectedFile.Length)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
```

---

## 6. `New-UpdateManifest.ps1`

Уточнён комментарий про модель угроз `protected.password`. Поведение не меняется.

```powershell
<#
.SYNOPSIS
    Формирует update.json из метаданных уже созданных release-архивов.

.DESCRIPTION
    Скрипт НЕ создаёт архивы. Архивы должны быть полностью сформированы до его
    запуска, а их имена, SHA-256 и размеры передаются через environment.

    Это разделяет упаковку и описание релиза: update.json содержит метаданные
    именно тех файлов, которые будут опубликованы, поэтому повторная упаковка
    после расчёта SHA-256 невозможна.

    Release notes добавляются в staging до упаковки и потому уже входят в оба
    финальных архива. Проверка их наличия здесь не дублируется: за staging
    отвечает Stage-ReleaseFiles.ps1, а за успешное создание обоих архивов -
    New-ReleaseArchives.ps1.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$product = $env:PRODUCT
$fullVersion = $env:FULL_VERSION
$mandatory = [System.Convert]::ToBoolean($env:MANDATORY)
$minimumVersionJson = $env:MINIMUM_VERSION_JSON
$commit = $env:COMMIT
$archiveName = $env:ARCHIVE_NAME
$archiveSha256 = $env:ARCHIVE_SHA256
$archiveSize = [long]$env:ARCHIVE_SIZE
$protectedArchiveName = $env:PROTECTED_ARCHIVE_NAME
$protectedSha256 = $env:PROTECTED_SHA256
$protectedSize = [long]$env:PROTECTED_SIZE

# Hashtable enumeration returns keys when iterated directly in PowerShell.
# GetEnumerator() is required here so that both the variable name (Key) and
# its value (Value) are available for validation under StrictMode.
foreach ($entry in @{
    PRODUCT = $product
    FULL_VERSION = $fullVersion
    COMMIT = $commit
    ARCHIVE_NAME = $archiveName
    ARCHIVE_SHA256 = $archiveSha256
    PROTECTED_ARCHIVE_NAME = $protectedArchiveName
    PROTECTED_SHA256 = $protectedSha256
}.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace([string]$entry.Value)) {
        throw "$($entry.Key) is empty."
    }
}

$version = [System.Version]::Parse($fullVersion)
if ($version.Revision -lt 0) {
    throw "Revision is not available in version: $fullVersion"
}

$minimumVersion = if ($minimumVersionJson -eq 'null' -or [string]::IsNullOrWhiteSpace($minimumVersionJson)) {
    $null
}
else {
    $minimumVersionJson | ConvertFrom-Json
}

# Сохраняем существующий update.json contract и только добавляем новый
# protected-блок. Клиенты, использующие обычный ZIP, продолжают получать
# прежние поля без изменения их смысла.
$manifest = [ordered]@{
    product = $product
    version = [ordered]@{
        major = $version.Major
        minor = $version.Minor
        build = $version.Build
        revision = $version.Revision
    }
    tag = $env:GITHUB_REF_NAME
    asset = $archiveName
    sha256 = $archiveSha256
    size = $archiveSize
    commit = $commit
    mandatory = $mandatory
    minimumVersion = $minimumVersion
    publishedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    protected = [ordered]@{
        asset = $protectedArchiveName
        sha256 = $protectedSha256
        size = $protectedSize
        format = '7z'
        encryption = 'AES-256'
        encryptedHeaders = $true
        # Пароль не является секретом и входит в публичный контракт manifest.
        # Защищённый 7z предназначен только для обхода инфраструктурной
        # фильтрации ZIP, а не для конфиденциальности: значение публикуется
        # здесь и совпадает с product. Не размещайте в protected-архиве
        # данные, требующие сокрытия.
        password = $product
    }
}

$manifestPath = Join-Path $env:GITHUB_WORKSPACE 'update.json'
$manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM
```

---

## 7. `Publish-Projects.ps1`

Уточнён комментарий про script scope. Поведение не меняется.

```powershell
<#
.SYNOPSIS
    Публикует основные проекты и группы subProjects для release.

.DESCRIPTION
    Основные проекты передаются через PROJECTS_JSON, дополнительные группы -
    через SUBPROJECTS_JSON. Каждый проект публикуется в отдельный каталог,
    после чего Stage-ReleaseFiles.ps1 объединяет результаты внутри своей
    логической группы.

    Первый проект группы определяет имя каталога группы. Для каждого проекта
    сохраняется Path, Name, Type, GroupName и GroupKind, чтобы staging не
    терял принадлежность проекта к subProject даже при совпадении имён.

    Build и Revision общие для всех публикаций. Restore выполняется отдельно
    для subProject-проектов, потому что они могут находиться в подключённом
    Git submodule и не входить в основной solution.

    Для legacy MSBuild-проектов dotnet publish может успешно завершиться, но
    не заполнить указанный --output каталог. В этом случае результат берётся
    из TargetDir, чтобы такие проекты также попадали в единый publish tree.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$mainProjects = @($env:PROJECTS_JSON | ConvertFrom-Json)
$subProjects = if ([string]::IsNullOrWhiteSpace($env:SUBPROJECTS_JSON)) {
    @()
} else {
    @($env:SUBPROJECTS_JSON | ConvertFrom-Json)
}

if ($mainProjects.Count -eq 0) {
    throw 'PROJECTS_JSON does not contain any projects.'
}

$publishRoot = Join-Path $env:GITHUB_WORKSPACE 'publish'
Remove-Item -LiteralPath $publishRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $publishRoot -Force | Out-Null

# Метаданные проекта являются контрактом между publish и staging.
# Массив живёт в script scope и наполняется из Publish-ReleaseProject через
# $script:projectTypes, потому что функция выполняется в дочерней области
# PowerShell и обычное += к переменной верхнего уровня не изменило бы
# исходный массив. При выносе функции в отдельный модуль это место нужно
# будет заменить на явный [ref]-параметр или pipeline-возврат.
$projectTypes = @()

function Publish-ReleaseProject {
    param(
        [Parameter(Mandatory)] [string]$ProjectPath,
        [Parameter(Mandatory)] [string]$GroupName,
        [Parameter(Mandatory)] [string]$GroupKind
    )

    if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
        throw 'Release configuration contains an empty project path.'
    }

    $projectName = [System.IO.Path]::GetFileNameWithoutExtension($ProjectPath)
    if ([string]::IsNullOrWhiteSpace($projectName)) {
        throw "Could not determine project name from: $ProjectPath"
    }

    $projectDirectory = Join-Path $publishRoot $projectName

    # OutputType вычисляется MSBuild с учётом SDK defaults и импортов.
    $outputType = (dotnet msbuild "$ProjectPath" -getProperty:OutputType).Trim()
    if ([string]::IsNullOrWhiteSpace($outputType)) {
        throw "OutputType is empty for project: $ProjectPath"
    }

    switch ($outputType.ToLowerInvariant()) {
        'library' { $projectType = 'Library' }
        'exe'     { $projectType = 'Exe' }
        'winexe'  { $projectType = 'Exe' }
        default   { throw "Unsupported OutputType '$outputType' for project: $ProjectPath" }
    }

    # Используем script scope: функция выполняется в дочерней области PowerShell,
    # поэтому обычное += к переменной верхнего уровня не изменило бы исходный массив.
    $script:projectTypes += [pscustomobject]@{
        Path      = $ProjectPath
        Name      = $projectName
        Type      = $projectType
        GroupName = $GroupName
        GroupKind = $GroupKind
    }

    Write-Host "Publishing: $ProjectPath"
    Write-Host "Output: $projectDirectory"
    Write-Host "Project type: $projectType (OutputType=$outputType)"
    Write-Host "Release group: $GroupName ($GroupKind)"

    # Основной solution уже восстановлен workflow. Для subProject выполняем
    # restore здесь, так как его проекты могут не входить в solution.
    if ($GroupKind -eq 'SubProject') {
        dotnet restore "$ProjectPath"
        if ($LASTEXITCODE -ne 0) {
            throw "dotnet restore failed for $ProjectPath with exit code $LASTEXITCODE"
        }
    }

    dotnet publish "$ProjectPath" `
        --configuration Release `
        --no-restore `
        --output "$projectDirectory" `
        --self-contained false `
        -p:Build=$env:BUILD `
        -p:Revision=$env:REVISION

    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed for $ProjectPath with exit code $LASTEXITCODE"
    }

    # SDK-style projects normally populate --output directly. Legacy MSBuild
    # projects can report success without doing so, поэтому проверяем результат
    # явно и переносим стандартный TargetDir только для такого случая.
    $publishedFiles = @(Get-ChildItem -LiteralPath $projectDirectory -File -Recurse -ErrorAction SilentlyContinue)
    if ($publishedFiles.Count -eq 0) {
        $targetDirectory = (dotnet msbuild "$ProjectPath" -getProperty:TargetDir).Trim()
        if ([string]::IsNullOrWhiteSpace($targetDirectory)) {
            throw "Project publish produced no files and TargetDir is empty: $ProjectPath"
        }

        if (-not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
            throw "Project publish produced no files and TargetDir was not found: $targetDirectory"
        }

        $targetFiles = @(Get-ChildItem -LiteralPath $targetDirectory -File -Recurse)
        if ($targetFiles.Count -eq 0) {
            throw "Project publish produced no files and TargetDir is empty: $targetDirectory"
        }

        Write-Host "dotnet publish did not populate output for legacy project; copying $($targetFiles.Count) file(s) from TargetDir: $targetDirectory"
        New-Item -ItemType Directory -Path $projectDirectory -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $targetDirectory '*') -Destination $projectDirectory -Recurse -Force

        $publishedFiles = @(Get-ChildItem -LiteralPath $projectDirectory -File -Recurse)
    }

    if ($publishedFiles.Count -eq 0) {
        throw "Project publish produced no files: $ProjectPath"
    }

    Write-Host "Published $($publishedFiles.Count) file(s) for: $ProjectPath"
}

# Основная группа сохраняет прежнюю семантику: её каталог определяется
# первым проектом списка projects.
$mainGroupName = [System.IO.Path]::GetFileNameWithoutExtension([string]$mainProjects[0])
foreach ($projectPath in $mainProjects) {
    Publish-ReleaseProject -ProjectPath ([string]$projectPath) -GroupName $mainGroupName -GroupKind 'Main'
}

# Каждая subProjects запись является отдельной логической группой. Первый
# проект записи определяет имя каталога группы в итоговом архиве.
foreach ($subProject in $subProjects) {
    $groupProjects = @($subProject.projects)
    if ($groupProjects.Count -eq 0) {
        throw 'Each subProjects entry must contain at least one project.'
    }

    $groupName = [System.IO.Path]::GetFileNameWithoutExtension([string]$groupProjects[0])
    if ([string]::IsNullOrWhiteSpace($groupName)) {
        throw "Could not determine subproject group name from: $($groupProjects[0])"
    }

    foreach ($projectPath in $groupProjects) {
        Publish-ReleaseProject -ProjectPath ([string]$projectPath) -GroupName $groupName -GroupKind 'SubProject'
    }
}

$projectTypesJson = $projectTypes | ConvertTo-Json -Compress -Depth 5
"project_types_json=$projectTypesJson" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
```

---

## 8. `create-release-tag.yml`

Fallback на заголовок PR при пустом теле. Меняется только bash-блок `Create tag on merged commit`.

```yaml
name: Create release tag

# Автоматически создаёт release/mandatory tag после merge PR в master.
# Публикацию GitHub Release выполняет отдельный release.yml, который
# запускается уже по push созданного тега.
on:
  pull_request:
    types: [closed]
    branches:
      - master

permissions:
  contents: write
  # Нужно для явного запуска другого workflow через workflow_dispatch.
  actions: write

jobs:
  create-tag:
    name: Create release tag
    # closed означает только закрытие PR; реальный merge проверяется отдельно.
    if: >
      github.event.pull_request.merged == true &&
      contains(github.event.pull_request.labels.*.name, 'publish')
    runs-on: ubuntu-latest

    env:
      RELEASE_CONFIG_FILE: '.github/release-settings/release.config.json'

    steps:
      # Проверяем именно merge commit этого PR, чтобы конфигурация и версия
      # соответствовали тому же состоянию исходного кода, на которое будет
      # установлен release/mandatory tag.
      - name: Checkout
        uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.merge_commit_sha }}
          fetch-depth: 0

      # Версия берётся из первого проекта release.config.json.
      - name: Read version configuration
        id: version
        shell: pwsh
        run: |
          $configPath = Join-Path $env:GITHUB_WORKSPACE $env:RELEASE_CONFIG_FILE
          if (-not (Test-Path -LiteralPath $configPath)) { throw "Release configuration was not found: $configPath" }
          $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
          if ($null -eq $config.projects -or @($config.projects).Count -eq 0) { throw "Release configuration property 'projects' must contain at least one project." }
          $projectPath = [string]@($config.projects)[0]
          $projectFile = Join-Path $env:GITHUB_WORKSPACE $projectPath
          if (-not (Test-Path -LiteralPath $projectFile)) { throw "First configured project was not found: $projectPath" }
          $product = [System.IO.Path]::GetFileNameWithoutExtension([string]$config.solution)
          if ([string]::IsNullOrWhiteSpace($product)) { throw "Could not determine product name from solution: $($config.solution)" }

          # Используем MSBuild, а не разбор XML .csproj напрямую.
          # Так учитываются Directory.Build.props, свойства проекта и их
          # переопределения в реальной вычисленной конфигурации проекта.
          $baseVersion = (dotnet msbuild "$projectFile" -getProperty:Version).Trim()
          if ([string]::IsNullOrWhiteSpace($baseVersion)) { throw "Effective Version was not found for first project: $projectPath" }
          if ($baseVersion -notmatch '^([0-9]+)\.([0-9]+)$') { throw "Effective project Version must contain only Major.Minor: '$baseVersion'" }
          $major = [int]$Matches[1]
          $minor = [int]$Matches[2]
          "project=$projectPath" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
          "product=$product" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
          "base_version=$baseVersion" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
          "major=$major" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
          "minor=$minor" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
          Write-Host "Product: $product"
          Write-Host "First project: $projectPath"
          Write-Host "Effective Version: $baseVersion"

      # Сравниваем Major текущей версии с предыдущей версией из tags.
      - name: Determine release type
        id: release-type
        shell: pwsh
        env:
          PRODUCT: ${{ steps.version.outputs.product }}
          CURRENT_MAJOR: ${{ steps.version.outputs.major }}
        run: |
          $tags = @(git tag --list "$($env:PRODUCT)_*" --sort=-version:refname)
          $previousMajor = $null
          foreach ($tag in $tags) {
              if ($tag -match "^$([regex]::Escape($env:PRODUCT))_([0-9]+)\.([0-9]+)-(release|mandatory)([0-9]+)$") {
                  $previousMajor = [int]$Matches[1]
                  Write-Host "Previous release tag: $tag"
                  break
              }
          }
          if ($null -eq $previousMajor) { $type = 'release' }
          elseif ([int]$env:CURRENT_MAJOR -ne $previousMajor) { $type = 'mandatory' }
          else { $type = 'release' }
          "type=$type" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
          Write-Host "Release type: $type"

      # release и mandatory имеют независимые счётчики внутри своей серии.
      - name: Calculate next tag number
        id: next-tag
        shell: pwsh
        env:
          PRODUCT: ${{ steps.version.outputs.product }}
          BASE_VERSION: ${{ steps.version.outputs.base_version }}
          RELEASE_TYPE: ${{ steps.release-type.outputs.type }}
        run: |
          $prefix = "$($env:PRODUCT)_$($env:BASE_VERSION)-$($env:RELEASE_TYPE)"
          $existing = @(git tag --list "$prefix[0-9]*")
          $maxNumber = 0
          foreach ($tag in $existing) {
              if ($tag -match "^$([regex]::Escape($prefix))([0-9]+)$") {
                  $number = [int]$Matches[1]
                  if ($number -gt $maxNumber) { $maxNumber = $number }
              }
          }
          $nextNumber = $maxNumber + 1
          $tag = "$prefix$nextNumber"
          if (git tag --list $tag) { throw "Tag '$tag' already exists. Refusing to overwrite an existing tag." }
          "tag=$tag" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
          Write-Host "Next tag: $tag"

      # Тег ставится на commit результата merge PR.
      - name: Create tag on merged commit
        env:
          TAG: ${{ steps.next-tag.outputs.tag }}
          MERGE_SHA: ${{ github.event.pull_request.merge_commit_sha }}
          TAG_TOKEN: ${{ github.token }}
        shell: bash
        run: |
          if [ -z "$MERGE_SHA" ] || [ "$MERGE_SHA" = "null" ]; then
            echo "Merged commit SHA is unavailable."
            exit 1
          fi
          # Используем GITHUB_TOKEN для создания тега.
          # Следующий шаг явно запускает Release, поэтому зависимость от
          # автоматического push-события здесь не требуется.
          git fetch origin "$MERGE_SHA" --no-tags

          # Берём тело PR из исходного event payload. Если тело пустое или
          # состоит только из пробельных символов, используем заголовок PR,
          # чтобы аннотированный тег и release notes не остались без описания.
          # gsub("\\s"; "") убирает все пробелы, табы и переводы строк.
          jq -r '
            if ((.pull_request.body // "") | gsub("\\s"; "")) == ""
            then (.pull_request.title // "")
            else (.pull_request.body // "")
            end
          ' "$GITHUB_EVENT_PATH" > tag-message.txt

          # Annotated tag требует Git identity; без неё git tag -a завершается
          # ошибкой "Committer identity unknown".
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

          # Annotated tag сохраняет полное описание PR, включая Markdown '#'.
          git tag -a "$TAG" "$MERGE_SHA" --cleanup=verbatim -F tag-message.txt
          git push "https://x-access-token:$TAG_TOKEN@github.com/$GITHUB_REPOSITORY.git" "refs/tags/$TAG"
          echo "Created annotated tag '$TAG' on commit '$MERGE_SHA'."

      # Выбираем активный release mode после создания тега.
      # MegaRelease имеет приоритет над обычным Release. Если MegaRelease
      # отключён, проверяется обычный Release. Если оба отключены, workflow
      # останавливается после создания тега.
      - name: Start active release workflow
        env:
          GH_TOKEN: ${{ github.token }}
          TAG: ${{ steps.next-tag.outputs.tag }}
        shell: bash
        run: |
          set -euo pipefail

          workflows="$(gh workflow list --repo "$GITHUB_REPOSITORY" --all --json path,state)"

          mega_state="$(echo "$workflows" | jq -r '.[] | select(.path == ".github/workflows/MegaRelease.yml") | .state' | head -n 1)"
          release_state="$(echo "$workflows" | jq -r '.[] | select(.path == ".github/workflows/release.yml") | .state' | head -n 1)"

          if [ "$mega_state" = "active" ]; then
            gh workflow run MegaRelease.yml --repo "$GITHUB_REPOSITORY" --ref "$TAG"
            echo "Started MegaRelease workflow for tag '$TAG'."
          elif [ "$release_state" = "active" ]; then
            gh workflow run release.yml --repo "$GITHUB_REPOSITORY" --ref "$TAG"
            echo "Started Release workflow for tag '$TAG'."
          else
            echo "Neither MegaRelease.yml nor release.yml is active. Tag creation completed without starting a release workflow."
          fi
```

---

## 9. `README.md`

Изменения: убрана висячая запятая в примере `release.config.json`, добавлено предупреждение про `GH_TOKEN` и приватные модули, добавлена заметка про `releases/latest` и пререлизы.

```markdown
# Release settings

Этот каталог содержит настройки и служебные значения, используемые CI и release workflows.

## Release pipeline

Публикация разделена на два независимых этапа:

```
merge PR в master
↓
create-release-tag.yml
↓
release/mandatory tag
↓
active production release workflow
↓
MegaRelease.yml (если активен)
или release.yml (fallback)
↓
build → package → GitHub Release
```

### 1. Create release tag

`.github/workflows/create-release-tag.yml` запускается только после закрытия PR в `master`, если PR действительно был merged.

Workflow:

1. checkout-ит именно `merge_commit_sha`;
2. читает первый проект из `release.config.json`;
3. получает эффективную версию проекта через MSBuild;
4. определяет `Major.Minor`;
5. сравнивает Major с предыдущим release tag;
6. выбирает `release` или `mandatory`;
7. вычисляет следующий номер серии;
8. создаёт tag на commit merged PR;
9. определяет активный production release workflow;
10. запускает `MegaRelease.yml`, если он активен, иначе `release.yml`.

Формат:

``` <solution>*<major>.<minor>-releaseN <solution>*<major>.<minor>-mandatoryN
```

Изменение Major является границей `mandatory`. Для `release` и `mandatory` используются независимые счётчики.

Создание tag не выполняет сборку или публикацию Release. После создания tag запускается активный production release workflow.

Если тело PR пустое или состоит только из пробельных символов, в качестве сообщения аннотированного тега используется заголовок PR.

### 2. Mega Release

При активном `.github/workflows/MegaRelease.yml` tag запускает Mega Release. Workflow сохраняет существующий release-контракт основного проекта и дополняет его опубликованными immutable artifacts внешних модулей.

Порядок работы:

1. checkout основного репозитория выполняется без submodules;
2. читается и валидируется `release.config.json`;
3. вычисляется версия основного проекта;
4. выполняются restore и test;
5. основные проекты публикуются существующим механизмом `Publish-Projects.ps1`;
6. существующий `Stage-ReleaseFiles.ps1` формирует staging основного продукта;
7. для каждого элемента `modules` получается последний опубликованный GitHub Release;
8. из выбранного Release выбирается ровно один опубликованный ZIP artifact;
9. конкретные Release tag, artifact и SHA-256 фиксируются для текущего запуска;
10. artifact скачивается и его SHA-256 проверяется повторно;
11. из ZIP извлекаются только настроенные каталоги модулей;
12. MD-файл каждого подключённого модуля добавляется в корень Mega Release рядом с MD основного продукта;
13. общий staging архивируется и публикуется как Mega Release.

Mega Release не выполняет checkout, build или packaging исходного кода внешних модулей. Источником модуля является опубликованный Release artifact.

Если ожидаемый каталог модуля отсутствует в artifact, структура ZIP некорректна, найдено не ровно одно ZIP либо SHA-256 не совпадает, workflow завершается ошибкой и неполный Mega Release не публикуется.

Полученные при запуске Release/tag и artifact используются до конца этого запуска. Появление нового Release модуля во время выполнения не изменяет уже выбранный artifact.

#### Конфигурация Mega Release

Для Mega Release используется свойство `modules` в `release.config.json`. Список модулей задаётся конфигурацией и не зашивается в workflow или PowerShell-код.

Элемент конфигурации содержит `repository` и список `projects`. `repository` задаёт GitHub repository модуля, а `projects` - каталоги, которые должны существовать внутри корня опубликованного ZIP и которые добавляются в Mega staging.

Пример:

```json
{
  "modules": [
    {
      "repository": "owner/ModuleRepository",
      "projects": ["ModuleDirectory"]
    }
  ]
}
```

Mega Release не валидирует `projects` против исходного дерева репозитория: исходный код модуля не используется при сборке Mega.

Mega Release использует GitHub API `releases/latest`, который исключает черновики и пререлизы. Если модуль публикует пререлизы как источник артефактов, это поведение нужно изменить в `Mega-AddModules.ps1` (`Get-LatestRelease`).

##### Доступ к module repositories

Текущий `GH_TOKEN` шага staging - это встроенный `${{ github.token }}`, который видит только публичные репозитории. Модули в приватных репозиториях требуют отдельного GitHub App-токена; до его подключения используйте только публичные module repositories.

### 3. Release

`.github/workflows/release.yml` отвечает за полный production release pipeline.

Он:

1. checkout-ит исходный репозиторий;
2. при наличии `.gitmodules` отдельно получает submodules;
3. читает и валидирует `release.config.json`;
4. проверяет соответствие tag продукту;
5. вычисляет полную версию;
6. выполняет restore и test;
7. публикует основные проекты и `subProjects`;
8. формирует единый staging;
9. создаёт ZIP и защищённый 7z;
10. формирует `update.json` на основе уже созданных архивов;
11. публикует один и тот же набор файлов в текущий репозиторий и настроенные `remote`.

Повторной сборки архивов для разных репозиториев нет: один и тот же результат публикуется во все targets.

### 4. CI

`.github/workflows/ci.yml` используется для обычной проверки изменений.

Он берёт solution из `release.config.json` и выполняет:

```
restore → build → test
```

CI не создаёт tag и не публикует Release.

## Файлы

### `release.config.json`

Основная конфигурация публикации:

- `solution` - solution, из которого определяется продукт и выполняется сборка;
- `projects` - основные проекты, публикуемые в release package;
- `subProjects` - дополнительные группы проектов, в том числе проекты из git submodules;
- `publicHere` - создавать ли GitHub Release в текущем репозитории;
- `remote` - список репозиториев, в которые публикуется тот же набор release-файлов;
- `modules` - список внешних модулей, используемых Mega Release.

Конфигурация читается и валидируется скриптом `.github/scripts/Read-ReleaseConfig.ps1` до restore, test и publish.

### `release-version.txt`

Минимальная версия для обычного release-канала.

Пустой файл означает, что минимальная версия для обычного релиза не задаётся.

### `mandatory-version.txt`

Минимальная версия для mandatory release.

Пустой файл означает, что минимальная версия для mandatory-релиза не задаётся.

## Полный пример текущей конфигурации

Ниже приведён **фактически используемый сейчас** `.github/release-settings/release.config.json`. Этот пример предназначен для документации текущей конфигурации проекта, а не как универсальный шаблон.

```json
{
  "solution": "drzTools.sln",
  "projects": [
    "drzTools.NC/drzTools.NC.csproj"
  ],
  "subProjects": [
    {
      "projects": [
        "ChangedbMod/ChangeDBmod.NC/ChangeDBmod.NC.csproj",
        "ChangedbMod/ChangeDBmod.NC.21/ChangeDBmod.NC.21.0.csproj",
        "ChangedbMod/ChangeDBmod.NC.26/ChangeDBmod.NC.26.0.csproj"
      ]
    },
    {
      "projects": [
        "Archivist/Archivist/Archivist.csproj"
      ]
    }
  ],
  "publicHere": true,
  "remote": [
    "doctorRaz/Publish_Test"
  ],
  "modules": [
    {
      "repository": "doctorRaz/docProps",
      "projects": [
        "Archivist",
        "docProps.NC"
      ]
    },
    {
      "repository": "doctorRaz/ChangedbMod",
      "projects": [
        "ChangeDBmod.NC"
      ]
    }
  ]
}
```

Значение `remote` в текущей конфигурации является тестовым и может быть заменено перед финальной публикацией.

### `subProjects`

`subProjects` - необязательный массив групп дополнительных проектов. Каждая группа публикуется отдельно, а затем попадает в общий release staging в каталоге группы.

Проекты могут находиться непосредственно в основном репозитории или в git submodule. Checkout submodules выполняется отдельным скриптом `.github/scripts/Checkout-Submodules.ps1`: сначала используется обычный Git-доступ, а при ошибке доступа повторно используется `PRIVATE_SUBMODULE_TOKEN`. Вложенные submodules обрабатываются рекурсивно.

Простейший вариант без дополнительных проектов:

```json
{
  "solution": "MyProduct.sln",
  "projects": [
    "MyProduct/MyProduct.csproj"
  ],
  "subProjects": []
}
```

Вариант с одним дополнительным проектом:

```json
{
  "solution": "MyProduct.sln",
  "projects": [
    "MyProduct/MyProduct.csproj"
  ],
  "subProjects": [
    {
      "projects": [
        "Tools/ToolA/ToolA.csproj"
      ]
    }
  ]
}
```

`subProjects` не заменяет `projects`: основные проекты остаются в `projects`, а дополнительные - в `subProjects`.

## Ключи и токены GitHub Actions

Workflow использует разные ключи для чтения приватных зависимостей и записи релизов. Их назначение не следует смешивать.

### Чтение приватных submodules - `PRIVATE_SUBMODULE_TOKEN`

Используется скриптом `.github/scripts/Checkout-Submodules.ps1` **только как fallback**, если обычный checkout конкретного submodule завершился ошибкой доступа.

Назначение ключа - **read**: получить код приватных git submodules во время checkout.

Этот ключ не используется для основного checkout репозитория и не используется для публикации release в удалённые репозитории.

### Публикация release - `DOC_PROPS_RELEASE_TOKEN`

Используется на шаге `Publish release to configured repositories`:

```yaml
env:
  GH_TOKEN: ${{ secrets.DOC_PROPS_RELEASE_TOKEN }}
```

Назначение ключа - **write**: создавать или обновлять GitHub Release и загружать release assets в настроенные remote repositories.

### Локальный release в текущем репозитории

Для `Create release in current repository` используется встроенный `${{ github.token }}`:

```yaml
env:
  GH_TOKEN: ${{ github.token }}
```

Его назначение - **write** в текущем репозитории, необходимый для создания GitHub Release и загрузки assets.

### Создание tag и запуск production release workflow

`create-release-tag.yml` использует встроенный `${{ github.token }}`:

- `contents: write` - создание и push tag;
- `actions: write` - явный запуск активного production release workflow через `workflow_dispatch`.

После создания tag workflow определяет активный production workflow. Если `MegaRelease.yml` активен, запускается:

```
gh workflow run MegaRelease.yml --ref <created-tag>
```

Если Mega Release не активен, используется `release.yml` как fallback. Это позволяет не зависеть от повторного запуска workflow по push, выполненного другим workflow.

### Принцип разделения

| Операция                          | Secret / token            | Доступ             |
| --------------------------------- | ------------------------- | ------------------ |
| Checkout приватных submodules     | `PRIVATE_SUBMODULE_TOKEN` | **read, fallback** |
| Создание release tag              | `${{ github.token }}`     | **write**          |
| Запуск активного release workflow | `${{ github.token }}`     | **actions: write** |
| Release в текущем репозитории     | `${{ github.token }}`     | **write**          |
| Release в configured remotes      | `DOC_PROPS_RELEASE_TOKEN` | **write**          |

Не следует использовать один универсальный ключ для всех операций: чтение приватного кода, управление workflow и публикация релизов имеют разные назначения и права доступа.

## Тестовые workflows

Файлы `test-*.yml` предназначены для технических проверок GitHub Actions:

- `test-called.yml` - reusable workflow и передача inputs/outputs;
- `test-orchestrator.yml` - цепочка reusable workflow → job outputs → PowerShell → итоговая проверка;
- `test-json.yml` - чтение JSON и передача отдельных значений между steps;
- `test-outputs.yml` - варианты передачи значений через `GITHUB_OUTPUT`.

Эти workflows запускаются вручную или используются как технические тесты и не входят в production release pipeline.

## Как изменять настройки

Изменения в `.github/release-settings` влияют непосредственно на последующие публикации.

При изменении структуры или контракта `release.config.json` необходимо одновременно проверить:

- `.github/scripts/Read-ReleaseConfig.ps1`;
- `.github/scripts/Publish-Projects.ps1`;
- `.github/scripts/Stage-ReleaseFiles.ps1`;
- `.github/scripts/New-ReleaseArchives.ps1`;
- `.github/scripts/New-UpdateManifest.ps1`;
- `.github/scripts/Publish-PublicRelease.ps1`;
- `.github/scripts/Mega-StageReleaseFiles.ps1`;
- `.github/scripts/Mega-AddModules.ps1`;
- `.github/workflows/MegaRelease.yml`;
- `.github/workflows/create-release-tag.yml`;
- `.github/workflows/release.yml`;
- `.github/workflows/ci.yml`.

Документация должна отражать фактическое поведение workflows. При изменении порядка шагов, токенов, триггеров или контрактов конфигурации этот README следует обновлять вместе с workflow.

```

---

## Сводка изменений

| № | Файл | Что изменено |
|---|---|---|
| 1 | `release.config.json` | Убрана висячая запятая в `subProjects`, выровнен отступ |
| 2 | `Stage-ReleaseFiles.ps1` | Добавлен возврат `$stagingDirectory` в success stream |
| 3 | `Mega-StageReleaseFiles.ps1` | Staging берётся из возврата `Stage-ReleaseFiles.ps1` вместо парсинга `GITHUB_OUTPUT`; убран мёртвый код |
| 4 | `Mega-AddModules.ps1` | Различение коллизий `.md`; ужесточено определение корневого `.md` |
| 5 | `New-ReleaseArchives.ps1` | Явная проверка непустого staging перед `Compress-Archive` |
| 6 | `New-UpdateManifest.ps1` | Уточнён комментарий про модель угроз `protected.password` |
| 7 | `Publish-Projects.ps1` | Уточнён комментарий про script scope |
| 8 | `create-release-tag.yml` | Fallback на заголовок PR при пустом теле |
| 9 | `README.md` | Убрана висячая запятая в примере; заметки про `GH_TOKEN`/приватные модули и про `releases/latest`/пререлизы |

Файлы `release.yml`, `MegaRelease.yml`, `New-Release.ps1`, `Publish-PublicRelease.ps1`, `Read-ReleaseConfig.ps1`, `New-ReleaseNotes.ps1`, `Checkout-Submodules.ps1`, `release-version.txt`, `mandatory-version.txt` не менялись - замечаний по ним не было либо они информационные.

Отдельно отмечу: изменение №2 (`Stage-ReleaseFiles.ps1` возвращает путь) обратно совместимо с `release.yml` - там возврат просто игнорируется, а `staging_directory` по-прежнему попадает в `GITHUB_OUTPUT`. Если предпочитаешь вообще не трогать `Stage-ReleaseFiles.ps1`, скажи - тогда для замечания 2 оставлю только чтение `GITHUB_OUTPUT`, но сделаю его более строгим (парсинг только строк, добавленных за текущий шаг).
```
