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
release.yml
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
9. явно запускает `release.yml` на созданном tag.

Формат:

```
<solution>_<major>.<minor>-releaseN
<solution>_<major>.<minor>-mandatoryN
```

Изменение Major является границей `mandatory`. Для `release` и `mandatory` используются независимые счётчики.

Создание tag не выполняет сборку или публикацию Release. Публикация выполняется только `release.yml`.

### 2. Release

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

### 3. CI

`.github/workflows/ci.yml` используется для обычной проверки изменений.

Он берёт solution из `release.config.json` и выполняет:

```
restore → build → test
```

CI не создаёт tag и не публикует Release.

## Файлы

### `release.config.json`

Основная конфигурация публикации:

- `solution` — solution, из которого определяется продукт и выполняется сборка;
- `projects` — основные проекты, публикуемые в release package;
- `subProjects` — дополнительные группы проектов, в том числе проекты из git submodules;
- `publicHere` — создавать ли GitHub Release в текущем репозитории;
- `remote` — список репозиториев, в которые публикуется тот же набор release-файлов.

Конфигурация читается и валидируется скриптом `.github/scripts/Read-ReleaseConfig.ps1` до restore, test и publish.

### `release-version.txt`

Минимальная версия для обычного release-канала.

Пустой файл означает, что минимальная версия для обычного релиза не задаётся.

### `mandatory-version.txt`

Минимальная версия для mandatory release.

Пустой файл означает, что минимальная версия для mandatory-релиза не задаётся.

## Пример конфигурации

```json
{
  "solution": "docProps.sln",
  "projects": [
    "docProps.NC/docProps.NC.csproj"
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
    "doctorRaz/docProps",
    "doctorRaz/docProps_TEST"
  ]
}
```

### `subProjects`

`subProjects` — необязательный массив групп дополнительных проектов. Каждая группа публикуется отдельно, а затем попадает в общий release staging в каталоге группы.

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

`subProjects` не заменяет `projects`: основные проекты остаются в `projects`, а дополнительные — в `subProjects`.

## Ключи и токены GitHub Actions

Workflow использует разные ключи для чтения приватных зависимостей и записи релизов. Их назначение не следует смешивать.

### Чтение приватных submodules — `PRIVATE_SUBMODULE_TOKEN`

Используется скриптом `.github/scripts/Checkout-Submodules.ps1` **только как fallback**, если обычный checkout конкретного submodule завершился ошибкой доступа.

Назначение ключа — **read**: получить код приватных git submodules во время checkout.

Этот ключ не используется для основного checkout репозитория и не используется для публикации release в удалённые репозитории.

### Публикация release — `DOC_PROPS_RELEASE_TOKEN`

Используется на шаге `Publish release to configured repositories`:

```yaml
env:
  GH_TOKEN: ${{ secrets.DOC_PROPS_RELEASE_TOKEN }}
```

Назначение ключа — **write**: создавать или обновлять GitHub Release и загружать release assets в настроенные remote repositories.

### Локальный release в текущем репозитории

Для `Create release in current repository` используется встроенный `${{ github.token }}`:

```yaml
env:
  GH_TOKEN: ${{ github.token }}
```

Его назначение — **write** в текущем репозитории, необходимый для создания GitHub Release и загрузки assets.

### Создание tag и запуск Release

`create-release-tag.yml` использует встроенный `${{ github.token }}`:

- `contents: write` — создание и push tag;
- `actions: write` — явный запуск `release.yml` через `workflow_dispatch`.

После создания tag workflow вызывает:

```text
gh workflow run release.yml --ref <created-tag>
```

Это позволяет не зависеть от повторного запуска workflow по push, выполненного другим workflow.

### Принцип разделения

| Операция | Secret / token | Доступ |
|---|---|---|
| Checkout приватных submodules | `PRIVATE_SUBMODULE_TOKEN` | **read, fallback** |
| Создание release tag | `${{ github.token }}` | **write** |
| Запуск `release.yml` | `${{ github.token }}` | **actions: write** |
| Release в текущем репозитории | `${{ github.token }}` | **write** |
| Release в configured remotes | `DOC_PROPS_RELEASE_TOKEN` | **write** |

Не следует использовать один универсальный ключ для всех операций: чтение приватного кода, управление workflow и публикация релизов имеют разные назначения и права доступа.

## Тестовые workflows

Файлы `test-*.yml` предназначены для технических проверок GitHub Actions:

- `test-called.yml` — reusable workflow и передача inputs/outputs;
- `test-orchestrator.yml` — цепочка reusable workflow → job outputs → PowerShell → итоговая проверка;
- `test-json.yml` — чтение JSON и передача отдельных значений между steps;
- `test-outputs.yml` — варианты передачи значений через `GITHUB_OUTPUT`.

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
- `.github/workflows/create-release-tag.yml`;
- `.github/workflows/release.yml`;
- `.github/workflows/ci.yml`.

Документация должна отражать фактическое поведение workflows. При изменении порядка шагов, токенов, триггеров или контрактов конфигурации этот README следует обновлять вместе с workflow.
