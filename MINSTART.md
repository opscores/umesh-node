# MINSTART — Production Deployment

Пошаговое руководство по развёртыванию топологии **Validator + Sentry + RPC** на трёх VPS.
Порядок изложения совпадает с порядком выполнения: подготовка → конфигурация → сеть → ноды → проверки.

---

## 0. Обзор

### 0.1 Топология

```
┌─────────────────────────┐         ┌─────────────────────────┐         ┌─────────────────────────┐
│      VPS-1: Validator   │◄──P2P──►│      VPS-2: Sentry      │◄──P2P──►│        VPS-3: RPC       │
│                         │  26656  │      (публичный)        │  26656  │      (публичный)        │
│                         │         │                         │         │                         │
│  data-validator/        │         │  data-sentry/           │         │  data-rpc/              │
│                         │         │                         │         │                         │
│  P2P: 0.0.0.0:26656     │         │  P2P: 0.0.0.0:26656     │         │  P2P: 0.0.0.0:26656     │
│  RPC: 0.0.0.0:26657     │         │  RPC: 0.0.0.0:26657     │         │  RPC: 0.0.0.0:26657     │
│  REST: ❌                │         │  REST: 0.0.0.0:1317     │         │  REST: 0.0.0.0:1317     │
│  gRPC: ❌                │         │  gRPC 9090 (+gRPC-Web)  │         │  gRPC 9090 (+gRPC-Web)  │
└─────────────────────────┘         └─────────────────────────┘         └─────────────────────────┘
```

### 0.2 Таблица ролей

| Роль | VPS | Data dir | Ключ валидатора | Публичные порты | Примечания |
|------|-----|----------|-----------------|-----------------|------------|
| **Validator** | VPS-1 | `data-validator/` | ✅ Да | 26656 (P2P), 26657 (RPC); REST/gRPC выключены | `p2p.pex=false`, `pruning custom 10000/1000`, `indexer null` |
| **Sentry** | VPS-2 | `data-sentry/` | ❌ Нет | 26656, 26657, 1317, 9090 (gRPC+Web) | `pex true 40/20`, `pruning custom 1000/100`, `snapshots 5000` |
| **RPC** | VPS-3 | `data-rpc/` | ❌ Нет | 26656, 26657, 1317, 9090 (gRPC+Web) | `node.pruning custom 1000/100` дефолт, `tx_index kv`, `9091` только с Envoy |

Плюс на всех ролях: 26660 (metrics) — только localhost, у Sentry дополнительно 26658 (DC) — только localhost.

> **Порты на хосте параметризованы** (`<ROLE>_<ENDPOINT>_PORT` в `.env.<role>`, секция
> `[compose]`): номера можно менять, чтобы поднять несколько контейнеров на одной
> машине (например, весь стек на одном VPS). Внутри контейнера порты всегда
> штатные (26656/26657/1317/9090/9091/26658/26660) — их слушает `umeshnode`.
> **Внимание:** при смене публичного порта RPC/P2P/REST вручную синхронизируйте
> ссылки в соседних YAML конфигах — `join.sentryRpc`/`join.validatorRpc`/`join.genesisUrl`
> (`http://<ip>:<порт>`) и `network.persistentPeers`/`network.seeds`
> (`<node-id>@<ip>:<порт>`); `--rpc-url` umeshctl задаётся флагом.

### 0.3 Порядок развёртывания

| Шаг | Действие | VPS |
|-----|----------|-----|
| 1 | Подготовка VPS: Docker, репозиторий, образ, CLI, firewall | все |
| 2 | Создание `.env` файлов | все |
| 3 | Конфигурация сети: Genesis Plan → `setup plan` (создаёт genesis) | 1 |
| 4 | Запуск **Validator** + сохранение ключей | 1 |
| 5 | Инициализация и запуск **Sentry**, подключение к валидатору | 2 |
| 6 | Инициализация и запуск **RPC**, подключение к Sentry | 3 |
| 7 | Верификация (синхронизация, P2P, блоки, подпись) | все |

### 0.4 Создаваемые артефакты

После выполнения `setup plan` на VPS-1 (папка `data-validator/config/`):

| Файл/директория | Назначение |
|-----------------|------------|
| `genesis.json` | Документ genesis сети (chain-id, tokenomics, module params) |
| `gentx/` | Genesis-транзакции валидаторов, собранные в genesis |
| `genesis-plan-report.txt` | Отчёт: распределение токенов, vesting, комиссии валидаторов |
| `.node-info` | Служебная метка инициализации (проверяется при повторных запусках) |

---

## 1. Подготовка VPS

Выполняется на **каждом** VPS.

### 1.1 Установка Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
```

### 1.2 Клонирование репозитория

```bash
git clone https://github.com/opscores/umesh-node.git
cd umesh-node
git checkout dev
```

### 1.3 Сборка Docker-образа

```bash
UMESHPREP_VERSION=$(cat .umeshprep-version) \
docker build \
  --build-arg VERSION="dev" \
  --build-arg COMMIT="$(git rev-parse --short HEAD)" \
  --build-arg BUILD_TYPE="umeshprep" \
  --build-arg UMESHPREP_VERSION="${UMESHPREP_VERSION}" \
  --build-arg TARGET_MODULE="github.com/opscores/umesh-node" \
  --build-arg BECH32_PREFIX="umesh" \
  --build-arg NODE_DIR=".umeshnode" \
  --build-arg BINARY_NAME="umeshnode" \
  --build-arg VERSION_NAME="umesh" \
  -t umesh-node:latest -f Dockerfile .
```

> `BUILD_TYPE=umeshprep` (значение по умолчанию) скачивает и запускает
> внешний инструмент **umesh-prep** (github.com/opscores/umesh-prep, версия из
> `.umeshprep-version`) для вывода исходников Umesh из wasmd внутри сборки.
> Альтернатива — `BUILD_TYPE=local` для сборки из локальной папки `src/umesh/`.

### 1.4 Сборка umeshctl

> `umeshctl` живёт в отдельном репозитории [umesh-cli](https://github.com/opscores/umesh-cli).
> `just build-cli` при необходимости клонирует исходники в `tools/umeshctl/` (папка
> в `.gitignore`, не коммитится) и собирает бинарник.

```bash
just build-cli
```

> `just build-cli` автоопределяет инструмент сборки: локальный Go 1.25+ или Docker.
> Бинарник появляется по пути `./tools/umeshctl/umeshctl`.

### 1.5 Firewall

**VPS-1 (Validator)** — P2P открыт для Sentry/пиров, RPC открыт для Sentry и RPC-ноды с других VPS:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow from <SENTRY_IP> to any port 26656 proto tcp
sudo ufw allow from <SENTRY_IP> to any port 26657 proto tcp
sudo ufw allow from <RPC_IP> to any port 26656 proto tcp
sudo ufw allow from <RPC_IP> to any port 26657 proto tcp
sudo ufw enable
```

**VPS-2 (Sentry)** — публичные порты (`9090` слушает и gRPC и gRPC-Web; `9091` только если ставите Envoy):

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow 26656/tcp  # P2P (обязательно)
sudo ufw allow 26657/tcp  # RPC (для RPC-ноды и umeshctl)
sudo ufw allow 1317/tcp   # REST (кошельки/эксплореры)
sudo ufw allow 9090/tcp   # gRPC + gRPC-Web (Keplr/Leap)
# sudo ufw allow 9091/tcp # только если Envoy на 9091
sudo ufw enable
```

**VPS-3 (RPC)** — аналогично Sentry (публичный API):

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow 26656/tcp  # P2P (опционально, если хотите inbound пиры)
sudo ufw allow 26657/tcp  # RPC
sudo ufw allow 1317/tcp   # REST
sudo ufw allow 9090/tcp   # gRPC + gRPC-Web
sudo ufw enable
```

---

## 2. Конфигурация (`.env` для compose + YAML для init)

Между хост-конфигурацией и docker-compose **две** зависимости:

| Источник | Файл | Потребитель | Когда применяется |
|----------|------|-------------|--------------------|
| **YAML конфиг ноды** | `config/node-<role>.yaml` | `umeshctl setup init --config` | **Одноразово** на хосте (init, gentx, otel.yaml) |
| **Compose-env** | `.env.<role>` | `docker compose --env-file` | **Каждый запуск/перезапуск** (порты, ресурсы, image) |

Создаются **до** запуска контейнеров. `docker compose` использует `--env-file` для интерполяции
`${...}` в `docker-compose.yml` (порты, ресурсы, image). `umeshctl setup init` использует
`--config` и параметры keyring-password для инициализации. **Env-файл в контейнер не попадает**:
переменные окружения процесса в контейнере не задаются.
Телеметрия конфигурируется файлом `otel.yaml` (пишет `umeshctl setup init` из `telemetry.*` в YAML конфиге),
а не переменными окружения.

### 2.1 Общие правила

1. **Keyring password** передаётся через флаги `--keyring-password-file`,
   `--keyring-password-stdin`, `--keyring-password-exec`, либо `--auto-password`
   (автоматическая генерация). Для интерактивного режима достаточно не указывать
   никаких флагов пароля — `umeshctl` запросит его в терминале.
2. Фактическая роль задаётся `umeshctl setup init --role <role>` и `--profile` при старте:
   `genesis` (создание сети) или `validator/sentry/rpc` (присоединение).
3. `CHAIN_ID`, `DENOM`, `MONIKER`, `MIN_GAS_PRICE`, `ENVIRONMENT` находятся в YAML конфиге
   (`chain.*` и `node.*`) и должны совпадать на всех трёх нодах.
4. Значения bind-IP в `VALIDATOR_RPC_BIND_IP` / `SENTRY_RPC_BIND_IP` / `RPC_RPC_BIND_IP`
   управляют доступностью портов наружу. Каждый тип ноды живёт в своём контейнере на
   своём VPS, поэтому по умолчанию все роли публикуют P2P (26656) и RPC (26657) наружу —
   Sentry и RPC-нода подключаются к валидатору по адресу `http://<validator-ip>:26657`.
     При желании сузить доступ задайте `VALIDATOR_RPC_BIND_IP=127.0.0.1` —
     но тогда Sentry/RPC на других VPS потеряют доступ к валидатору (безопасно
     только если вся инфраструктура на одном хосте).
4. После заполнения рекомендуется проверить `.env` через `docker compose config`
    (синтаксис) перед запуском.

### 2.2 `.env.validator` + YAML конфиг (VPS-1, создание сети)

**Compose-env** (`.env.genesis` или `.env.validator` — порты и ресурсы):

```bash
ENVIRONMENT=production
NODE_IMAGE=umesh-node:latest

# Порты на хосте
VALIDATOR_P2P_BIND_IP=0.0.0.0
VALIDATOR_P2P_PORT=26656
VALIDATOR_RPC_BIND_IP=0.0.0.0      # RPC наружу — Sentry/RPC с других VPS подключаются по http://<validator-ip>:26657
VALIDATOR_RPC_PORT=26657
VALIDATOR_METRICS_BIND_IP=127.0.0.1       # metrics: только localhost
VALIDATOR_METRICS_PORT=26660

# Ресурсы (container)
CPU_LIMIT=2.0
MEMORY_LIMIT=4g
MEMORY_RESERVATION=2g
```

**YAML конфиг** (`config/node-genesis.yaml` — параметры инициализации):

```yaml
apiVersion: umesh.network/v1
kind: Node
role: genesis
node:
  dataDir: ./data-validator
  moniker: my-validator
  environment: production
chain:
  chainId: umesh-testnet-1
  denom: uumesh
  minGasPrice: "0.0025"
validator:
  keyName: validator
  stakeAmount: "1000000000000uumesh"
  selfDelegation: "1000000000000uumesh"
  externalAddress: "<PUBLIC_IP_VPS1>"   # p2p.external_address + gentx --ip
  commission:
    rate: "0.05"
    maxRate: "0.20"
    maxChangeRate: "0.01"
  minSelfDelegation: "1000000"
telemetry:
  endpoint: "http://otel-collector.monitoring.svc:4317"
```

> **Модель ролей:** `genesis` создаёт новую сеть. Параметры подключения к
> существующей сети (`join.*`, `network.seeds`, `network.persistentPeers`)
> в этом конфиге **запрещены** — `umeshctl` отклоняет их для роли genesis.
> Для присоединения к существующей сети используйте `role: validator` и
> `config/node-validator.yaml` (см. ниже).

### 2.3 `.env.sentry` + YAML конфиг (VPS-2, join)

**Compose-env** (`.env.sentry` — порты и ресурсы):

```bash
ENVIRONMENT=production
NODE_IMAGE=umesh-node:latest

# Порты на хосте
SENTRY_P2P_BIND_IP=0.0.0.0
SENTRY_P2P_PORT=26656
SENTRY_RPC_BIND_IP=0.0.0.0
SENTRY_RPC_PORT=26657
SENTRY_REST_PORT=1317
SENTRY_GRPC_PORT=9090
SENTRY_GRPC_WEB_PORT=9091
SENTRY_METRICS_BIND_IP=127.0.0.1       # metrics: только localhost
SENTRY_METRICS_PORT=26660
SENTRY_DC_BIND_IP=127.0.0.1           # data companion: только localhost (debug endpoint)
SENTRY_DC_PORT=26658

# Ресурсы (container)
CPU_LIMIT_SENTRY=2.0
MEMORY_LIMIT_SENTRY=8g
MEMORY_RESERVATION_SENTRY=4g
```

**YAML конфиг** (`config/node-sentry.yaml` — параметры инициализации):

```yaml
apiVersion: umesh.network/v1
kind: Node
role: sentry
node:
  dataDir: ./data-sentry
  moniker: my-sentry
  environment: production
chain:
  # chainId/denom optional when join.* is set — auto-extracted from genesis
  chainId: umesh-testnet-1
  denom: uumesh
  minGasPrice: "0.0025"
join:
  # Priority: sentryRpc/genesis → validatorRpc/genesis → genesisUrl (raw)
  # validatorRpc is also used for usePrivate NodeID fetch (GET /status best-effort)
  genesisUrl: "https://raw.githubusercontent.com/umesh-network/mainnet/main/genesis.json"
  genesisSha256: ""
  sentryRpc: "http://<other-sentry-ip>:26657"  # optional, another sentry
  validatorRpc: "http://<validator-ip>:26657"  # for usePrivate
network:
  seeds: ""
  persistentPeers: "<VALIDATOR_NODE_ID>@<VALIDATOR_IP>:26656"  # must include validator; get offline: cat ./data-validator/config/node_key.json
  externalAddress: "<PUBLIC_IP_VPS2>:26656"   # TODO: your public IP:26656 — empty → 172.x warning
  usePrivate: true                   # add validator as private/unconditional peer (needs validatorRpc live, else manual persistentPeers)
telemetry:
  endpoint: "http://otel-collector.monitoring.svc:4317"
```

### 2.4 `.env.rpc` + YAML конфиг (VPS-3, join)

**Compose-env** (`.env.rpc` — порты и ресурсы):

```bash
ENVIRONMENT=production
NODE_IMAGE=umesh-node:latest

# Порты на хосте
RPC_P2P_BIND_IP=0.0.0.0
RPC_P2P_PORT=26656
RPC_RPC_BIND_IP=0.0.0.0
RPC_RPC_PORT=26657
RPC_REST_PORT=1317
RPC_GRPC_PORT=9090
RPC_GRPC_WEB_PORT=9091
RPC_METRICS_BIND_IP=127.0.0.1       # metrics: только localhost
RPC_METRICS_PORT=26660

# Ресурсы (container)
CPU_LIMIT_RPC=2.0
MEMORY_LIMIT_RPC=8g
MEMORY_RESERVATION_RPC=4g
```

**YAML конфиг** (`config/node-rpc.yaml` — параметры инициализации):

```yaml
apiVersion: umesh.network/v1
kind: Node
role: rpc
node:
  dataDir: ./data-rpc
  moniker: my-rpc
  environment: production
  pruning: custom   # local app.toml: custom 1000/100 (dApp window) | everything (broadcast) | nothing (archive)
chain:
  # chainId/denom optional when join.* is set — auto-extracted
  chainId: umesh-testnet-1
  denom: uumesh
  minGasPrice: "0.0025"
join:
  # Priority: sentryRpc → genesisUrl → validatorRpc (at least sentryRpc or genesisUrl required)
  # genesisUrl is fallback when Sentry is down (avoids Catch-22)
  genesisUrl: "https://raw.githubusercontent.com/umesh-network/mainnet/main/genesis.json"
  genesisSha256: ""
  sentryRpc: "http://<sentry-ip>:26657"   # primary genesis + upstream
  validatorRpc: "http://<validator-ip>:26657"  # optional fallback
network:
  seeds: ""
  persistentPeers: "<SENTRY_NODE_ID>@<SENTRY_IP>:26656"  # for instant broadcast_tx_sync, get Sentry NodeID via comet show-node-id
  externalAddress: "<PUBLIC_IP_VPS3>:26656"   # p2p.external_address — empty → 172.x warning if inbound P2P needed
telemetry:
  endpoint: "http://otel-collector.monitoring.svc:4317"
```

### 2.5 Справочник ключевых переменных

**`.env.<role>` (docker compose only — порты и ресурсы):**

| Переменная | Где | Назначение |
|------------|-----|------------|
| `NODE_IMAGE` | все | Docker-образ ноды |
| `ENVIRONMENT` | все | Метка окружения (production/testnet/devnet) |
| `VALIDATOR_RPC_BIND_IP` | validator | `0.0.0.0` — RPC публикуется наружу (нужен Sentry/RPC с других VPS) |
| `<ROLE>_<ENDPOINT>_PORT` | все | Номер порта **на хосте** для публикации (`P2P`/`RPC`/`REST`/`GRPC`/`GRPC_WEB`/`DC`/`METRICS`); по умолчанию — штатные значения |

**YAML config (umeshctl setup init — параметры инициализации):**

| Параметр | Где | Назначение |
|----------|-----|------------|
| `chain.chainId` | все | Идентификатор сети |
| `chain.denom` | все | Базовый деноминал |
| `chain.minGasPrice` | все | Минимальная цена газа |
| `node.moniker` | все | Имя ноды |
| `node.environment` | все | Окружение (попадает в otel.yaml) |
| `validator.*` | genesis | keyName, stakeAmount, selfDelegation, externalAddress, commission, minSelfDelegation |
| `join.genesisUrl` | validator/sentry/rpc | URL genesis для скачивания |
| `join.sentryRpc` | validator/sentry/rpc | RPC sentry (источник genesis) |
| `join.validatorRpc` | validator/sentry | RPC валидатора |
| `network.seeds` | validator/sentry/rpc | Seed-пиры |
| `network.persistentPeers` | validator/sentry/rpc | Постоянные пиры |
| `network.externalAddress` | validator/sentry/rpc | p2p.external_address (публичный IP) |
| `network.usePrivate` | sentry | true — добавить валидатора как private peer |
| `telemetry.endpoint` | все | OTLP gRPC endpoint (пусто = off) |
| `telemetry.serviceName` | все | service.name в otel.yaml (по умолчанию umesh-<role>) |

---

## 3. Genesis Plan — конфигурация сети (VPS-1)

Сеть создаётся декларативно из YAML-файла `tools/umeshctl/examples/genesis-plan.yaml`:
параметры chain, tokenomics, module params и soft launch записываются в `genesis.json` одним прогоном.
`setup plan` также создаёт Docker-сеть `umesh` и папку `data-validator/` автоматически.

### 3.1 Workflow

```bash
# 1. Валидация плана (обязательно перед выполнением)
./tools/umeshctl/umeshctl setup validate-plan --config tools/umeshctl/examples/genesis-plan.yaml

# 2. Просмотр отчёта о распределении (без выполнения)
./tools/umeshctl/umeshctl setup report --config tools/umeshctl/examples/genesis-plan.yaml

# 3. Выполнение плана (создание genesis)
#    При отсутствии флагов пароля umeshctl запросит пароль в терминале.
#    Для автоматизации используйте --auto-password (сгенерирует и сохранит пароль)
#    или --keyring-password-file / --keyring-password-stdin / --keyring-password-exec.
./tools/umeshctl/umeshctl setup plan \
  --config tools/umeshctl/examples/genesis-plan.yaml \
  --keyring-password-file ~/.umesh/keyring-pass
# или:
./tools/umeshctl/umeshctl setup plan \
  --config tools/umeshctl/examples/genesis-plan.yaml \
  --auto-password
```

Опции `setup plan`:

| Флаг | Назначение |
|------|------------|
| `--config <path>` | Путь к genesis-plan.yaml (обязательно) |
| `--keyring-password-file <path>` | Файл с паролем keyring (≥ 8 символов) |
| `--keyring-password-stdin` | Читать пароль из stdin |
| `--keyring-password-exec <cmd>` | Выполнить команду и прочитать пароль из stdout |
| `--auto-password` | Сгенерировать случайный пароль (32 символа) и сохранить в `<dataDir>/keyring.pass` |
| `--dry-run` | Только валидация и сводка, без выполнения |
| `--force` | Пересоздать genesis на существующем `data-validator/` |
| `--keep-keys` | Сохранить identity валидатора (consensus + P2P ключи), **только вместе с `--force`** |

> При повторном запуске на существующем `data-validator/` без `--force` команда завершится с ошибкой
> `node already initialized`.

### 3.2 Секция `chain`

| Поле | Назначение | Примечания |
|------|------------|------------|
| `chain_id` | Идентификатор сети | Должен совпадать во всех YAML конфигах (`chain.chainId`) | |
| `moniker` | Имя ноды | |
| `denom` | Базовый деном (например `uumesh`) | |
| `decimals` | Точность денома (0–18) | |
| `genesis_time` | Время запуска сети | `"now"`/пусто → старт сразу; RFC3339 → запланированный запуск |
| `denom_uri` | Документ о токене | → `bank.denom_metadata.uri` |
| `constitution` | Иммутабельный манифест сети | → `gov.constitution` |

**`genesis_time`:** значение `"now"` (или пустая строка) — блоки начинают идти сразу после запуска контейнера.
Любой RFC3339-момент (например `"2026-08-15T00:00:00Z"`) ставит запланированное время запуска —
до него нода будет спать (`Genesis time is in the future. Sleeping until then...`).

### 3.3 Секция `chain.consensus`

Параметры консенсуса CometBFT, записываемые в `genesis.json`. **Фиксируются навсегда при запуске сети.**
Любое поле без значения → production-дефолт (значения Cosmos Hub / cosmoshub-4).

```yaml
consensus:
  block_max_gas: 30000000        # газ-лимит блока (wasmd рекомендует ограничивать; -1 = без лимита, DoS-риск)
  # block_max_bytes: 22020096    # 21 MiB (дефолт)
  # time_iota_ms: 1000           # (дефолт)
  # evidence.max_age_num_blocks / max_age_duration / max_bytes
  # validator.pub_key_types: ["ed25519"]
  authority: "umesh10d07y265gmmuvt4z0w9aw880jnsr700jplz74g"
```

- `authority` — адрес, имеющий право менять consensus-параметры через `x/consensus MsgUpdateParams`;
  если пусто — используется gov-адрес модуля.

### 3.4 Секция `tokenomics`

```yaml
tokenomics:
  total_supply: "1000000000000000"   # в базовом деноме (1B UMESH при decimals=6)
  allocations: [...]
  validation:
    max_single_allocation_percent: 25.0
    max_insider_allocation_percent: 45.0
    min_validator_count: 1
    dust_destination: "community_pool"
```

**Типы allocation:**

| Тип | Описание | Обязательные поля |
|-----|----------|-------------------|
| `base_account` | Обычный аккаунт | `name`, `percentage`, `key_name` или `address` |
| `delayed_vesting` | Все токены залочены до `end_time` | `vesting.end_time` |
| `continuous_vesting` | Равномерная разблокировка с `start_time` по `end_time` | `vesting.start_time`, `vesting.end_time` |
| `clawback_vesting` | Vesting с отзывом (clawback) | `vesting` |
| `validator_set` | Сеть валидаторов с self-delegation | `validators[]` |

**Правила валидации** (ошибка, если нарушены):

- сумма `percentage` всех allocation = 100% (±0.01% допуск);
- ни одна allocation не превышает `max_single_allocation_percent` (дефолт 25%);
- сумма «инсайдерских» allocation (`team`, `investors`, `foundation`) не превышает `max_insider_allocation_percent` (дефолт 45%);
- количество валидаторов в `validator_set` ≥ `min_validator_count`;
- `vesting.start_time` не раньше `genesis_time`;
- у валидатора обязательны `name`, `self_delegation`, `commission_rate`.

`dust_destination` — куда отправляется остаток от округления процентов (по умолчанию `community_pool`).

### 3.5 Секция `modules`

| Модуль | Ключевые поля | Примечания |
|--------|---------------|------------|
| `staking` | `max_validators`, `unbonding_time`, `min_commission_rate` | `min_commission_rate` — защита от race-to-zero |
| `distribution` | `community_tax`, `base_proposer_reward`, `bonus_proposer_reward` | |
| `mint` | `inflation_rate_change/max/min`, `goal_bonded`, `blocks_per_year`, `max_supply` | `max_supply` = жёсткий кап; равен `total_supply` → фиксированная эмиссия |
| `gov` | `min_deposit`, `voting_period`, `quorum`, `threshold`, `veto_threshold`, `expedited_min_deposit`, `burn_vote_quorum`, `burn_proposal_deposit_prevote` | `expedited_min_deposit` обязан быть **строго больше** `min_deposit` (инвариант SDK) |
| `slashing` | `signed_blocks_window`, `min_signed_per_window`, `downtime_jail_duration`, `slash_fraction_*` | |
| `wasm` | `code_upload_access`, `instantiate_default_permission` | `nobody` — загрузка кода запрещена всем |

Пример (из `genesis-plan.yaml`):

```yaml
modules:
  staking:
    max_validators: 100
    unbonding_time: "1814400s"          # 21 дней
    min_commission_rate: "0.050000000000000000"   # 5% floor
  mint:
    max_supply: "1000000000000000"      # кап = total_supply (fixed supply)
  gov:
    min_deposit: "1000000000"           # 1000 uumesh
    expedited_min_deposit: "5000000000" # 5000 uumesh (обязан быть > min_deposit)
    voting_period: "1209600s"           # 14 дней
    quorum: "0.334000000000000000"
    threshold: "0.500000000000000000"
    veto_threshold: "0.334000000000000000"
    burn_vote_quorum: true              # сжигать депозит при недоборе кворума
    burn_proposal_deposit_prevote: true # сжигать депозит, если не дошло до голосования
  wasm:
    code_upload_access: "nobody"
    instantiate_default_permission: "everybody"
```

### 3.6 Секция `soft_launch`

Мягкий запуск сети: отключает часть функций на старте, включение позже — через governance.

```yaml
soft_launch:
  enabled: true
  disable_bank_send: true               # bank send_enabled = false для uumesh
  disable_ibc_transfer: true            # IBC transfers отключены
  allow_staking: true                   # стейкинг остаётся (нужен консенсусу)
  allow_gov: true                       # governance остаётся (механизм включения)
  allow_wasm_instantiate: false         # инстанциация wasm-контрактов запрещена
```

### 3.7 Ожидаемый результат

```
data-validator/config/genesis.json
data-validator/config/gentx/
data-validator/config/genesis-plan-report.txt
data-validator/config/.node-info
```

### 3.8 Пустые/deprecated поля в genesis.json

**Это норма, заполнять не нужно** — chain работает и без них (SDK v0.54):

- `gen_txs[*].body.messages[0].delegator_address` — поле deprecated; подписант msg = `validator_address`,
  SDK v0.54 намеренно не заполняет его (одна и та же учётка в acc/valoper нотации). Влияния на применение gentx нет.
- `app_state.gov.deposit_params` / `voting_params` / `tally_params` — deprecated; всё состояние хранится
  в `app_state.gov.params` (min_deposit, voting_period, quorum, threshold, veto_threshold...), его использует InitGenesis.
- `auth.accounts[*].pub_key` — заполняется при первой транзакции аккаунта.
- `app_hash`, `distribution.previous_proposer` — появляются после первого блока.

Настраиваемые (не-deprecated) поля задаются в `genesis-plan.yaml` (см. §3.2–3.6), плюс:
описание валидатора `website` / `security_contact` / `details` (и опционально `identity` — Keybase ID, 16 символов)
→ в gentx. `identity` можно добавить позже ончейн через `tx staking edit-validator`, без перезапуска сети.

---

## 4. Развёртывание Validator (VPS-1)

### 4.1 Выполнение Genesis Plan

См. §3.1 — команда `setup plan` создаёт genesis, ключи и gentx на хосте.

> Для кастомного пути используйте `--data-dir ./my-data` (опционально; по умолчанию `data-validator/`).

### 4.2 Сохранение ключей (критично)

> **Мнемоника показывается один раз** в логах `setup plan`. До потери доступа сохраните всё:

```bash
mkdir -p ~/secure-backup
cp data-validator/config/genesis-plan-report.txt ~/secure-backup/
cp -r data-validator/keyring ~/secure-backup/
cp data-validator/config/priv_validator_key.json ~/secure-backup/
```

### 4.3 Запуск

```bash
docker compose --env-file .env.genesis --profile validator up -d
docker logs -f umesh-validator
```

### 4.4 Проверка

```bash
./tools/umeshctl/umeshctl node status sync
```

Ожидаемый вывод:

```bash
Moniker:           umesh-genesis
Network:           umesh-testnet-1
Block Height:      <растёт>
Catching Up:       false
Voting Power:      100000000
```

---

## 5. Развёртывание Sentry (VPS-2 — щит, не подписывает)

### 5.1 Pre-check + NodeID валидатора (офлайн)

```bash
# На VPS-1 (валидатор) возьмите NodeID без запуска RPC:
cat ./data-validator/config/node_key.json
# или
docker run --rm -v ./data-validator:/home/umesh/.umeshnode umesh-node:latest umeshnode comet show-node-id --home /home/umesh/.umeshnode
# → a1b2c3... — вставьте в config/node-sentry.yaml: persistentPeers: "a1b2c3...@<VALIDATOR_IP>:26656"

# На VPS-2 проверьте источник генезиса до init (net/http, без curl|jq в коде):
./tools/umeshctl/umeshctl genesis fetch --url http://<validator-ip>:26657/genesis --dry-run  # или https://.../genesis.json --dry-run
```

### 5.2 Инициализация (офлайн, контейнер остановлен)

```bash
./tools/umeshctl/umeshctl setup init --role sentry --config config/node-sentry.yaml --auto-password
# offline docker run --rm: obtainGenesis (sentry→validator→genesisUrl, chainId/denom авто), umeshnode init, tune (pex true 40/20, snapshots 5000, grpc-web 9090), private_peer_ids best-effort
# Идемпотентно: повтор без --force → already initialized; --force --keep-keys сохраняет node_key.json (NodeID)
cp ./data-sentry/config/node_key.json ./backups-sentry/node_key.$(date +%s).json && chmod 600 ./backups-sentry/node_key.*
```

Сеть `umesh` и `data-sentry/` создаются автоматически. Для большой сети (>1M) — опционально `StateSync` (`node config set statesync.*`) или `snapshot restore --from` (нода остановлена).

### 5.3 Запуск + связка

```bash
docker compose --env-file .env.sentry --profile sentry up -d
curl -s http://localhost:26657/net_info | jq '.result.n_peers'  # >0
# На валидаторе (VPS-1) добавьте Sentry как shield:
./tools/umeshctl/umeshctl node peers add <SENTRY_NODE_ID>@<SENTRY_IP>:26656 --data-dir ./data-validator
# или legacy helper:
./tools/umeshctl/umeshctl node sentry connect --sentry-rpc <SENTRY_IP>:26657 --validator-rpc <VALIDATOR_IP>:26657
./tools/umeshctl/umeshctl ops doctor --check p2p --data-dir ./data-sentry  # ворнинг, не фатален (net/http)
```

---

## 6. Развёртывание RPC (VPS-3 — публичный API, node.pruning: custom 1000/100)

### 6.1 Инициализация (офлайн)

```bash
# join.sentryRpc или genesisUrl обязателен (приоритет sentryRpc → genesisUrl → validatorRpc); node.pruning: custom дефолт (окно для dApp), everything — light, nothing — archive
./tools/umeshctl/umeshctl genesis fetch --url http://<sentry-ip>:26657/genesis --dry-run  # или genesisUrl --dry-run
./tools/umeshctl/umeshctl setup init --role rpc --config config/node-rpc.yaml --auto-password
# offline: obtainGenesis (priority выше) → umeshnode init → enableRPC (0.0.0.0:26657 cors *) → tune (pex true 60/40, pruning custom 1000/100 из node.pruning, tx_index kv, grpc 9090 + grpc-web)
cp ./data-rpc/config/node_key.json ./backups-rpc/node_key.$(date +%s).json && chmod 600 ./backups-rpc/node_key.*
```

### 6.2 Запуск + проверка

```bash
docker compose --env-file .env.rpc --profile rpc up -d
./tools/umeshctl/umeshctl node health --wait-sync --timeout 15m  # catching_up=false
curl -s http://localhost:26657/status | jq .result.sync_info.catching_up  # false
curl -s http://localhost:1317/cosmos/base/tendermint/v1beta1/node_info | jq .default_node_info.moniker
curl -s http://localhost:26657/net_info | jq .result.n_peers
grep -E 'pruning|tx_index' ./data-rpc/config/app.toml ./data-rpc/config/config.toml  # pruning="custom" 1000/100, tx_index="kv"
```

---

## 7. Управление жизненным циклом

| Действие | Команда |
|----------|---------|
| Запуск | `docker compose --env-file .env.<role> --profile <role> up -d` |
| Остановка | `docker compose --profile <role> down` |
| Логи | `docker logs -f umesh-<validator\|sentry\|rpc>` |
| Перезапуск | `docker compose --env-file .env.<role> --profile <role> restart` |
| Состояние | `docker compose ps` |

Сервисы: `validator` (профиль `validator`, единый для создателя сети и пост-генезис валидатора), `sentry` (профиль `sentry`), `rpc` (профиль `rpc`).

---

## 8. Верификация

| Проверка | Команда | Где | Ожидание |
|----------|---------|-----|----------|
| Синхронизация | `./tools/umeshctl/umeshctl node status sync` / `node health --wait-sync` | все | `Catching Up: false`, высота растёт |
| P2P связи | `curl -s http://localhost:26657/net_info \| jq '.result.n_peers'` | validator, sentry, rpc | n_peers ≥ 1 (validator `pex false` → только sentry) |
| Рост блоков | `curl -s http://localhost:26657/status \| jq '.result.sync_info.latest_block_height'` | все | увеличивается |
| Подпись | `curl -s http://localhost:26657/status \| jq '.result.validator_info.voting_power'` | validator | >0 |
| REST/gRPC | `curl -s http://localhost:1317/cosmos/base/tendermint/v1beta1/node_info` / `curl -s http://localhost:9090` | sentry, rpc | `moniker`, `grpc-web true` на `9090` (9091 только с Envoy) |
| Pruning/tx_index | `grep -E 'pruning|tx_index' ./data-*/config/{app,config}.toml` | rpc/sentry `pruning custom 1000/100` `kv`, validator `custom 10000/1000` `null` | `node.pruning` дефолт, `tx_index kv` для RPC |
| P2P внешний | `./tools/umeshctl/umeshctl ops doctor --check p2p --data-dir ./data-<role>` | все | ворнинг если `172.x` (externalAddress пусто) |
| Кросс-роль | `./tools/umeshctl/umeshctl ops config verify --cross-role` | validator↔sentry | `persistentPeers`/`private_peer_ids` совпадают |

---

## 9. Полный перезапуск сети (reset / restart)

Применяется когда нужно начать новую цепочку с нуля (новый genesis, новые ключи).
Все шаги выполняются вручную на VPS-1.

> **ОСТОРОЖНО:** шаги 1–4 необратимо удаляют текущие ключи, genesis и данные.
> Перед выполнением обязательно сохраните мнемонику и ключи (см. §4.2).

### 9.1 Остановка и удаление контейнера

```bash
# Остановка (дождаться полной остановки)
docker compose --env-file .env.validator --profile validator down

# Если контейнер остался — удалить принудительно
docker rm -f umesh-validator 2>/dev/null || true
```

### 9.2 Очистка данных валидатора

```bash
rm -rf data-validator backups-validator
```

> Директория `src/umesh` и бинарник `tools/umeshctl/umeshctl` НЕ удаляются
> (в отличие от `just clean`), чтобы не пересобирать CLI.

### 9.3 Очистка docker-кэша (опционально)

```bash
docker builder prune -af
docker system prune -af
```

> Удаляет кэш сборки и неиспользуемые образы (golang, alpine, старые слои).
> При следующей сборке образ пересоберётся с нуля.

### 9.4 Пересборка образа и CLI

```bash
UMESHPREP_VERSION=$(cat .umeshprep-version) \
docker build \
  --build-arg VERSION="dev" \
  --build-arg COMMIT="$(git rev-parse --short HEAD)" \
  --build-arg BUILD_TYPE="umeshprep" \
  --build-arg UMESHPREP_VERSION="${UMESHPREP_VERSION}" \
  -t umesh-node:latest -f Dockerfile .

# Пересобрать umeshctl (локальный Go 1.25+)
cd tools/umeshctl && go build -o umeshctl . && cd ../..
```

### 9.5 Создание нового genesis

```bash
./tools/umeshctl/umeshctl setup plan \
  --config tools/umeshctl/examples/genesis-plan.yaml \
  --auto-password
```

Сохранить мнемонику и ключи (см. §4.2).

### 9.6 Запуск валидатора

```bash
# Сеть создаётся автоматически; при необходимости:
docker network inspect umesh >/dev/null 2>&1 || docker network create umesh

docker compose --env-file .env.validator --profile validator up -d
./tools/umeshctl/umeshctl node status sync
```

Ожидание: `Block Height` растёт, `Catching Up: false`.

### 9.7 Проверка параметров genesis (при необходимости)

```bash
python3 - <<'EOF'
import json
g = json.load(open('data-validator/config/genesis.json'))
print('genesis_time:', g['genesis_time'])
print('authority:', g['consensus']['params']['authority']['authority'])
print('max_gas:', g['consensus']['params']['block']['max_gas'])
print('min_commission_rate:', g['app_state']['staking']['params']['min_commission_rate'])
print('expedited_min_deposit:', g['app_state']['gov']['params']['expedited_min_deposit'])
print('bank send_enabled:', g['app_state']['bank']['send_enabled'])
print('wasm:', g['app_state']['wasm']['params'])
EOF
```

Значения соответствуют полям `genesis-plan.yaml`: `chain.consensus`, `modules.*` и `soft_launch` (§3.3–3.6).

---

## 10. Чеклист

- [ ] Docker установлен на всех VPS
- [ ] Репозиторий клонирован
- [ ] Docker-образ собран (`docker build ... -t umesh-node:latest`)
- [ ] `just build-cli` выполнен
- [ ] Firewall настроен (см. §1.5)
- [ ] `.env.<role>` файлы созданы (compose-env только: порты, ресурсы, image)
- [ ] YAML конфиги созданы (`config/node-*.yaml` из `config/node-config-*.yaml.example`): `chainId/denom` опциональны при `join`, `node.pruning` задан для RPC (`custom` дефолт)
- [ ] Keyring password: `--auto-password` (→ `<dataDir>/keyring.pass 600`) либо `--keyring-password-file`/`stdin`/`exec` (секреты не в YAML)
- [ ] `setup validate-plan` прошёл без ошибок
- [ ] `genesis_time` в плане задан (`"now"` или RFC3339)
- [ ] `umeshctl genesis fetch --dry-run` до `setup init` показывает `chain_id` (нет `curl|jq` зависимости в коде)
- [ ] Genesis Plan выполнен на VPS-1 (`setup plan`; `--force --keep-keys` сохраняет NodeID)
- [ ] Мнемоника и ключи сохранены (см. §4.2) + `node_key.json` бэкап для Sentry/RPC
- [ ] Validator запущен, догнал цепь (`health --wait-sync`), `check-balance` перед `create`, подписывает (Voting Power >0)
- [ ] Sentry инициализирован офлайн (`--keep-keys` для повторного), `externalAddress` = публичный IP, `persistentPeers` с `validator NodeID`, `usePrivate` fallback проверен, запущен, `ops doctor --check p2p` ok
- [ ] RPC инициализирован (`join.sentryRpc` или `genesisUrl` fallback, `node.pruning custom 1000/100`, `tx_index kv`, `grpc-web 9090`), запущен, `health` ok
- [ ] P2P связи установлены (`n_peers ≥1`, `private_peer_ids` содержит валидатора, `cross-role` verify)
- [ ] Блоки растут на всех нодах (`status sync`)
