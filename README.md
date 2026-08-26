# umesh-node

**`umesh-node`** — это инфраструктурный проект для развёртывания и эксплуатации нод блокчейна **Umesh** в Docker-контейнерах. Umesh — это блокчейн на базе **Cosmos SDK** с поддержкой **CosmWasm** (WebAssembly смарт-контрактов).

Проект представляет собой **полноценный DevOps-инструментарий** с автоматизацией сборки, настройки, запуска и мониторинга нод. Он ориентирован на production-использование и поддерживает четыре роли ноды.

---

## Оглавление
- [Главные особенности](#главные-особенности)
- [Технический стек](#технический-стек)
- [Быстрый старт](#быстрый-старт)
- [Архитектура: 4 роли ноды](#архитектура-4-роли-ноды)
- [Сценарии работы (Scenarios)](#сценарии-работы-scenarios)
- [Genesis Plan (Production)](#genesis-plan-production)
- [Структура проекта](#структура-проекта)
- [Как работает система](#как-работает-система)
- [Как работает сборка](#как-работает-сборка)
- [Безопасность](#безопасность)
- [Производственная настройка (`umeshctl tune`)](#производственная-настройка-umeshctl-tune)
- [Мониторинг: OpenTelemetry](#мониторинг-opentelemetry)
- [Переменные окружения](#переменные-окружения)
- [Команды umeshctl](#команды-umeshctl)
- [Docker Image Versioning](#docker-image-versioning)
- [Документация](#документация)

---

## Главные особенности

1. **Полная автоматизация** — от клонирования `wasmd` до production-запуска.
2. **Декларативный Genesis Plan** — создание genesis из YAML-конфигурации с tokenomics, vesting, module params.
3. **Многоуровневая безопасность** — Sentry-Validator архитектура, read-only контейнеры, приватные пиры.
4. **Четыре роли ноды** — покрывают все сценарии: от devnet до mainnet.
5. **Строгие проверки** — 8 проверок при сборке, compliance-верификация роли.
6. **Cosmos SDK v0.54** — использует последнюю версию с BlockSTM и новыми модулями.
7. **OpenTelemetry** — нативная интеграция мониторинга.
8. **State-Sync** — быстрая синхронизация для новых нод.
9. **Mainnet Ritual** — поддержка координированного запуска с внешними валидаторами.
10. **Soft Launch** — отключение transfers/IBC на старте сети с включением через governance.

---

## Технический стек

| Компонент | Версия | Назначение |
|-----------|--------|------------|
| **Cosmos SDK** | v0.54.3 | Базовый фреймворк блокчейна |
| **CosmWasm / wasmd** | v0.70.3 (WasmVM v3.0.7) | WebAssembly смарт-контракты |
| **CometBFT** | v0.39.3 | Консенсус и сетевой уровень |
| **Go** | 1.25.12 | Язык сборки бинарника |
| **Ubuntu** | 26.04 LTS | Базовый образ контейнера |
| **Docker** | — | Контейнеризация |
| **Docker Compose** | v2.0+ | Оркестрация (с профилями) |
| **dasel** | v3.11.2 | Редактирование TOML-конфигов (debug) |
| **jq** | 1.8.2 | Passthrough в entrypoint.sh (debug). umeshctl использует нативный Go JSON |
| **umeshctl** | — | Go-CLI для init (genesis/validator/sentry/rpc), genesis plan/validate/report/add-account/add-validator, keys, tune, verify, backup. Выполняет инициализацию и патчинг genesis на хосте через `docker run`. Развивается в отдельном репозитории [umesh-cli](https://github.com/opscores/umesh-cli) |
| **OpenTelemetry** | SDK v0.54+ | Мониторинг и телеметрия |

---

## Быстрый старт

Пошаговое руководство для production-топологии **Validator + Sentry + RPC** на трёх VPS —
см. [MINSTART.md](MINSTART.md). Ниже — минимальная последовательность для одной ноды.

> **`umeshctl` — отдельный репозиторий.** CLI развивается независимо в
> [github.com/opscores/umesh-cli](https://github.com/opscores/umesh-cli). Для
> разработки исходники клонируются в `tools/umeshctl/` (папка в `.gitignore`, не
> коммитится):
>
> ```bash
> git clone --depth 1 --branch dev git@github.com:opscores/umesh-cli.git tools/umeshctl
> cd tools/umeshctl && go build -o umeshctl . && cd ../..
> ```
>
> После сборки бинарник доступен по пути `./tools/umeshctl/umeshctl`.

### 1. Создайте конфигурацию ноды и файл с паролем keyring

Создайте YAML конфиг для вашей роли из шаблона, и файл с паролем:

```bash
# Node config (init parameters: chain, validator, join sources, telemetry)
cp config/node-config-validator.yaml.example config/node-validator.yaml
nano config/node-validator.yaml

# Keyring password (secret — never committed to git)
mkdir -p ~/.umesh
echo "your-secure-password" > ~/.umesh/keyring-pass
chmod 600 ~/.umush/keyring-pass
```

> **Роли и join-параметры:** конфиг настраивается под конкретную роль (`role:` в YAML).
> Для создания новой сети используйте `role: genesis`, для присоединения — `role: validator`.
> Конфиги находятся в `config/node-config-*.yaml.example`; каждая роль имеет свой шаблон.

> **Секреты:** пароль keyring передаётся через `--keyring-password-file`, `--keyring-password-stdin`, `--keyring-password-exec`, `--auto-password` или вводится интерактивно. Он никогда не хранится в YAML конфиге или `.env` файле.

### 2. Получите образ

```bash
# Вариант A: из GHCR (production)
docker pull ghcr.io/opscores/umesh-node:latest

# Вариант B: локальная сборка (development)
docker build \
  --build-arg VERSION="dev" \
  --build-arg COMMIT="$(git rev-parse --short HEAD)" \
  --build-arg BUILD_TYPE="umeshprep" \
  --build-arg UMESHPREP_VERSION="$(cat .umeshprep-version)" \
  --build-arg TARGET_MODULE="github.com/opscores/umesh-node" \
  --build-arg BECH32_PREFIX="umesh" \
  --build-arg BINARY_NAME="umeshnode" \
  -t umesh-node:latest -f Dockerfile .
```

### 3. Инициализируйте ноду (на хосте, до запуска контейнера)

```bash
# === Production Genesis через Plan (рекомендуется) ===
cp tools/umeshctl/examples/genesis-plan.yaml genesis-plan.yaml
nano genesis-plan.yaml  # отредактируйте под свои параметры
umeshctl setup validate-plan --config genesis-plan.yaml
umeshctl setup plan --config genesis-plan.yaml --auto-password

# === Legacy Genesis (devnet, быстрый старт) ===
umeshctl setup init --role genesis --config config/node-genesis.yaml --auto-password

# === Присоединение к существующей сети (validator/join) ===
umeshctl setup init --role validator --config config/node-validator.yaml --auto-password

# === С переопределением флагов ===
umeshctl setup init --role validator --config config/node-validator.yaml \
  --auto-password \
  --chain-id umesh-1 --moniker val-1 --genesis-url https://example.com/genesis.json

# === Sentry / RPC ===
umeshctl setup init --role sentry --config config/node-sentry.yaml --auto-password
umeshctl setup init --role rpc --config config/node-rpc.yaml --auto-password
```

> **Для CI/Ansible:** вместо `--auto-password` используйте `--keyring-password-file`,
> `--keyring-password-stdin` или `--keyring-password-exec`.

### 4. Запустите контейнер

```bash
# Validator (профиль единый для genesis/validator):
docker compose --env-file .env.validator --profile validator up -d

# Sentry:
docker compose --env-file .env.sentry --profile sentry up -d

# RPC:
docker compose --env-file .env.rpc --profile rpc up -d
```

Entrypoint только запускает `umeshnode` (PID 1). Инициализация выполняется отдельно через `umeshctl setup init` / `umeshctl setup plan`.

### 5. Проверьте синхронизацию

```bash
./tools/umeshctl/umeshctl node status sync
```

---

## Архитектура: 4 роли ноды

Проект поддерживает четыре роли: **один создатель сети** (`genesis`) и **три
присоединяемых типа** (`validator`, `sentry`, `rpc`). Роль выбирается при
инициализации (`umeshctl setup init --role <role> --config config/node-<role>.yaml`);
каждый сервис (validator, sentry, rpc) использует свой `.env.<role>` для
интерполяции портов/ресурсов в `docker-compose.yml` и свой YAML конфиг для init.

### 1. `genesis` — Создание новой сети (создатель)
- Инициализирует блокчейн с нуля (Block 0) — **не присоединяется** ни к какой сети.
- Создаёт genesis-аккаунт и генерирует `gentx` (genesis transaction).
- Помечает ноду готовой (`"VALIDATOR_READY": 1` в `config/.node-info`).
- Параметры подключения к существующей сети (`join.*` и `network.*` в YAML конфиге:
  `genesisUrl`, `sentryRpc`, `validatorRpc`, `seeds`, `persistentPeers`)
  **запрещены** и отклоняются командой для роли genesis.

### 2. `validator` — Присоединение к существующей сети (джойнер)
- Пост-генезис валидатор, **обязан join-иться** в существующую сеть: минимум
  один источник genesis (в YAML: `join.genesisUrl`, `join.sentryRpc` или `join.validatorRpc`; `chain.chainId` и `chain.denom` опциональны при `join` — авто-извлекаются из `genesis.json` как `chain_id`/`bond_denom`).
- Скачивает `genesis.json` по приоритету `sentryRpc/genesis → validatorRpc/genesis → genesisUrl` (`net/http`, без `curl|jq` на хосте; `--dry-run` в `genesis fetch` покажет без записи; ошибка показывает все попытки `tried [url: err]`).
- Валидирует SHA256 и chain-id, скачивает `addrbook.json`, генерирует consensus-ключи (`priv_validator_key.json`, `node_key.json`), создаёт кошелёк в `keyring/` и делает автобэкап `./backups-validator/validator-consensus-<ts>/`. Инициализация **офлайн** (`docker run --rm -u 1000:1000` с bind-mount), идемпотентна: повтор без `--force` → `already initialized`; `--force` при живом контейнере → `refusing --force while container is running` (сначала `docker compose down`); `--keep-keys` сохраняет `node_key.json`/`priv_validator_key.json`.
- Синхронизируется с сетью с нуля (full sync) или через StateSync/Snapshot (опционально, см. `node snapshot restore`).
- Конфигурация runtime: API выключен, State-Sync выключен, PEX выключен; хранит `priv_validator_key.json` (подписывает блоки); `p2p.external_address` из `network.externalAddress` (YAML) — без него анонсируется bridge `172.x` и `ops doctor --check p2p` предупредит.
- Внутри контейнера RPC слушает `0.0.0.0:26657` и публикуется наружу
  (`VALIDATOR_RPC_BIND_IP`, по умолчанию `0.0.0.0`) — Sentry/RPC с других VPS подключаются
  по `http://<validator-ip>:26657`. При желании сузить доступ задайте `VALIDATOR_RPC_BIND_IP=127.0.0.1` (но тогда Sentry/RPC на других VPS потеряют доступ — безопасно только если вся инфраструктура на одном хосте).
- P2P публикуется на `0.0.0.0:26656` (`VALIDATOR_P2P_BIND_IP`/`VALIDATOR_P2P_PORT`) для связи с Sentry/пирами (`p2p.laddr 0.0.0.0:26656` уже в тюнинге, дополнительно править не нужно).

### 3. `sentry` — Публичный шлюз (джойнер)
- Публичная нода с открытым API, gRPC, gRPC-Web на `9090` (`grpc-web.enable true` на том же порту, `9091` только через Envoy).
- Поддерживает **State-Sync** (`statesync.enable true`) и создаёт снапшоты каждые 5000 блоков (`state-sync.snapshot-interval 5000`).
- Скачивает genesis по тому же приоритету, **удаляет** `priv_validator_key.json` при `umeshnodeInit(..., pruneState=true)` — **не содержит приватных ключей валидатора** (безопасность), `node.pruning` не требуется (дефолт `custom 1000/100` через тюнинг).
- При `network.usePrivate=true` пробует `GET <validatorRpc>/status` для `private_peer_ids`/`unconditional_peer_ids` (best-effort, при недоступности — ворнинг и fallback на ручной `persistentPeers: "<validatorNodeID>@<ip>:26656"`; NodeID берите офлайн `cat ./data-validator/config/node_key.json` или `comet show-node-id`).
- Защищает валидатор от DDoS/eclipse, `p2p.pex=true`, лимиты `40/20` уже в тюнинге; `--force --keep-keys` сохраняет `node_key.json` чтобы не менять NodeID.
- `p2p.addr_book_strict=true`, `data_companion 0.0.0.0:26658`.

### 4. `rpc` — Публичная RPC-нода (джойнер)
- Публичная нода для клиентов: **JSON-RPC 26657** (`rpc.laddr 0.0.0.0:26657` `cors *`), **REST 1317**, **gRPC 9090** + **gRPC-Web** на том же `9090` (отдельный `9091` только с Envoy), `tx_index.indexer="kv"` (у валидатора `null`).
- Включён **PEX** (`pex = true`, `max 60/40`) и **State-Sync** (`true`) для быстрого старта; `pruning` — **`node.pruning` в YAML** (`custom` дефолт `1000/100` окно ~1.5ч, `everything` — light `broadcast` без истории, `nothing` — archive), `chain.pruning` не существует (локально vs цепь, см. `umesh-cli`).
- Скачивает genesis по приоритету `sentryRpc/genesis → genesisUrl (S3/CDN) → validatorRpc/genesis` (для RPC `genesisUrl` — фоллбек когда Sentry на обслуживании); `chainId/denom` авто-извлекаются; минимум один из `join.sentryRpc`/`join.genesisUrl` обязателен (для RPC).
- Хранит только `node_key.json`; **priv_validator_key.json отсутствует** (не подписывает); `pruning` настраивается через `node.pruning`, а не `environment==production → everything` (скрытый баг удалён — теперь явно).

---

## Сценарии работы (Scenarios)

### Сценарий 1: Запуск новой сети (Genesis Network)

#### Вариант A: Production Genesis через Plan (рекомендуемый)
```bash
1. Создайте genesis-plan.yaml (см. tools/umeshctl/examples/genesis-plan.yaml)
2. Валидируйте план:
   umeshctl setup validate-plan --config genesis-plan.yaml
3. Просмотрите отчёт о распределении:
   umeshctl setup report --config genesis-plan.yaml
4. Выполните план:
   umeshctl setup plan --config genesis-plan.yaml --auto-password
5. Запустите контейнер:
   docker compose --env-file .env.validator --profile validator up -d
```

#### Вариант B: Быстрый Genesis (legacy, devnet)
```bash
1. Координатор: umeshctl setup init --role genesis --config config/node-genesis.yaml --auto-password
    ↓ создаёт genesis.json, патчит denom (Go code), генерирует gentx
2. Координатор: docker compose --env-file .env.genesis --profile validator up -d
    ↓ запускает контейнер с genesis-нодой
3. Sentry: umeshctl setup init --role sentry --config config/node-sentry.yaml --auto-password
4. Sentry: docker compose --env-file .env.sentry --profile sentry up -d
5. Координатор: umeshctl node sentry connect --sentry-rpc <sentry> --validator-rpc <validator>
6. Валидатор: docker compose --env-file .env.genesis --profile validator restart
```

### Сценарий 2: Присоединение к сети (Join Existing Network — офлайн `setup init`)
```bash
# 0) Pre-check генезиса (до init, net/http без curl|jq на хосте в коде, для оператора curl — проверка):
1. umeshctl genesis fetch --url http://<sentryRpc>/genesis --dry-run  # или https://.../genesis.json --dry-run
   ↓ показывает chain_id/bond_denom, все попытки tried [url: err]

# 1) Валидатор (VPS-1, контейнер остановлен):
2. umeshctl setup init --role validator --config config/node-validator.yaml --auto-password
    ↓ offline docker run --rm: obtainGenesis (sentry→validator→genesisUrl, chainId/denom авто), umeshnode init, tune (pex false), keyring + автобэкап ./backups-validator/
3. cp data-validator/config/priv_validator_key.json ~/secure-backup/ && umeshctl node keys show validator  # umesh1...
4. docker compose --env-file .env.validator --profile validator up -d && umeshctl node health --wait-sync --timeout 15m
5. umeshctl node validator check-balance --from <umesh1> --amount 5000000uumesh  # до синка, экономит часы
6. umeshctl node validator create --key-name validator --from <umesh1> --moniker "My Node" --amount 5000000uumesh --chain-id <id> --keyring-pass <pass> # gas auto/1.5/0.0025

# 2) Sentry (VPS-2, нужен NodeID валидатора заранее — offline):
7. VAL_ID=$(docker run --rm -v ./data-validator:/home/umesh/.umeshnode umesh-node:latest umeshnode comet show-node-id --home /home/umesh/.umeshnode)
8. umeshctl setup init --role sentry --config config/node-sentry.yaml --auto-password  # persistentPeers: "<VAL_ID>@<validatorIP>:26656", usePrivate best-effort
9. cp data-sentry/config/node_key.json ./backups-sentry/  # --force --keep-keys сохраняет NodeID
10. docker compose --env-file .env.sentry --profile sentry up -d && curl -s http://localhost:26657/net_info | jq .result.n_peers

# 3) RPC (VPS-3, node.pruning: custom 1000/100 дефолт):
11. umeshctl setup init --role rpc --config config/node-rpc.yaml --auto-password  # join.sentryRpc или genesisUrl (fallback), node.pruning explicit
12. docker compose --env-file .env.rpc --profile rpc up -d && umeshctl node health --wait-sync --timeout 15m

# 4) Связка validator→sentry (shield):
13. umeshctl node peers add <sentryNodeID>@<sentryIP>:26656 --data-dir ./data-validator
```

### Сценарий 3: Координированный запуск (Mainnet Ritual)
```bash
1. Координатор: umeshctl setup init --role genesis --config config/node-genesis.yaml --auto-password
2. Валидаторы: umeshctl node validator generate-gentx --key-name <name> --keyring-pass <pass> --moniker <moniker> --chain-id <chain-id> → Pull Request в GitHub
3. Координатор: собирает принятые gentx и добавляет их в config/gentx, затем пересобирает genesis
4. Все: скачивают финальный genesis (umeshctl genesis fetch --url <url>) и запускают ноды через docker compose
```

---

## Genesis Plan (Production)

`umeshctl setup plan` — рекомендуемый способ создания genesis для testnet/mainnet. Читает декларативный YAML-конфиг и полностью автоматизирует создание genesis.

Полный актуальный пример: **`tools/umeshctl/examples/genesis-plan.yaml`** (источник истины).

### Структура genesis-plan.yaml

```yaml
# Umesh Genesis Plan — declarative config for production genesis
chain:
  chain_id: "umesh-testnet-1"
  moniker: "umesh-genesis"
  denom: "uumesh"
  decimals: 6
  genesis_time: "now"                  # "now" / "" = start immediately; or RFC3339 e.g. "2026-08-15T00:00:00Z"
   denom_uri: "https://github.com/opscores/umesh-node"   # optional: docs URL for the token (bank denom_metadata.uri)
  # Immutable on-chain constitution (gov.constitution). Shown in governance UI.
  constitution: |
    Umesh is a sovereign interchain platform built on the Cosmos SDK, designed
    to enable secure, transparent and self-sovereign collaboration. The network
    upholds neutrality, open participation and long-term sustainability, and is
    governed on-chain by its stakers through transparent, verifiable governance.

  # Consensus parameters written into genesis.json. Fixed forever at launch.
  # Any field omitted here falls back to production defaults matching Cosmos
  # Hub (cosmoshub-4). Only override deliberately.
  consensus:
    block_max_gas: 30000000        # 30M gas cap per block (wasmd recommends limiting; -1 = unlimited/DoS risk)
    # block_max_bytes: 22020096   # 21 MiB max block size
    # time_iota_ms: 1000          # 1s granularity for block time
    # evidence.max_age_num_blocks: 100000
    # evidence.max_age_duration: "48h"   # evidence retention window
    # evidence.max_bytes: 1048576         # 1 MiB max evidence per block
    # validator.pub_key_types: ["ed25519"]
    # Authority allowed to update consensus params via x/consensus
    # MsgUpdateParams. When empty, the gov module address is used by default.
    authority: "umesh10d07y265gmmuvt4z0w9aw880jnsr700jplz74g"

tokenomics:
  # Total supply in base denom (uumesh)
  # 1_000_000_000 UMESH = 1_000_000_000_000_000 uumesh
  total_supply: "1000000000000000"

  allocations:
    - name: "foundation"                # --- Foundation / Treasury ---
      type: "base_account"
      percentage: 20.0
      key_name: "foundation"

    - name: "team"                      # --- Core Team (continuous vesting) ---
      type: "continuous_vesting"
      percentage: 15.0
      key_name: "team"
      vesting:
        start_time: "2026-08-15T00:00:00Z"
        end_time: "2029-08-15T00:00:00Z"

    - name: "investors"                 # --- Seed/Private Investors (delayed vesting) ---
      type: "delayed_vesting"
      percentage: 10.0
      key_name: "investors"
      vesting:
        end_time: "2028-08-15T00:00:00Z"

    - name: "ecosystem"                 # --- Ecosystem Grants ---
      type: "base_account"
      percentage: 15.0
      key_name: "ecosystem"

    - name: "airdrop"                   # --- Airdrop / Community ---
      type: "base_account"
      percentage: 25.0
      key_name: "airdrop"

    - name: "validators"                # --- Genesis Validators ---
      type: "validator_set"
      percentage: 15.0
      validators:
        - name: "validator"
          self_delegation: "100000000000000"   # 100M UMESH (в базовом деномине uumesh)
          commission_rate: "0.05"
          commission_max: "0.20"
          commission_max_change: "0.01"
          min_self_delegation: "1000000000000"   # 1M UMESH, prevents dust validators
          operational_funds: "50000000000000"   # 50M UMESH for operations
          website: "https://github.com/opscores/umesh-node"
          security_contact: "security@umesh.network"
          details: "Umesh Network genesis validator"

  # Validation rules for decentralization
  validation:
    max_single_allocation_percent: 25.0   # No single account > 25%
    max_insider_allocation_percent: 45.0  # Foundation + Team + Investors < 45%
    min_validator_count: 1                # Minimum validators in genesis
    dust_destination: "community_pool"    # Where to send rounding remainder

# Module parameters
modules:
  staking:
    max_validators: 100
    max_entries: 7
    historical_entries: 10000
    unbonding_time: "1814400s"          # 21 days
    min_commission_rate: "0.050000000000000000"   # 5% floor, prevents race-to-zero

  distribution:
    community_tax: "0.020000000000000000"
    base_proposer_reward: "0.010000000000000000"
    bonus_proposer_reward: "0.040000000000000000"
    withdraw_addr_enabled: true

  mint:
    inflation_rate_change: "0.13"
    inflation_max: "0.20"
    inflation_min: "0.07"
    goal_bonded: "0.67"
    blocks_per_year: "6311520"
    max_supply: "1000000000000000"     # hard cap = total supply (fixed supply, no infinite mint)

  gov:
    min_deposit: "1000000000"            # 1000 UMESH
    expedited_min_deposit: "5000000000"  # 5000 UMESH (must be > min_deposit)
    max_deposit_period: "1209600s"       # 14 days
    voting_period: "1209600s"            # 14 days
    quorum: "0.334000000000000000"       # 33.4%
    threshold: "0.500000000000000000"    # 50%
    veto_threshold: "0.334000000000000000"
    min_initial_deposit_ratio: "0.100000000000000000"   # 10% of min_deposit, anti-spam
    burn_vote_quorum: true               # burn deposit if proposal misses quorum (anti-spam)
    burn_proposal_deposit_prevote: true  # burn deposit if proposal never reaches voting (anti-spam)

  slashing:
    signed_blocks_window: "10000"
    min_signed_per_window: "0.050000000000000000"
    downtime_jail_duration: "600s"
    slash_fraction_double_sign: "0.050000000000000000"
    slash_fraction_downtime: "0.000100000000000000"

  wasm:
    code_upload_access: "nobody"
    instantiate_default_permission: "everybody"

# Soft launch configuration
soft_launch:
  enabled: true
  disable_bank_send: true               # bank send_enabled = false for uumesh
  disable_ibc_transfer: true            # IBC transfers disabled
  allow_staking: true                   # Keep staking enabled (needed for consensus)
  allow_gov: true                       # Keep governance enabled
  allow_wasm_instantiate: false         # Optional: disable wasm instantiation
```

### Типы аккаунтов (allocation types)

| Тип | Описание | Ключевые поля |
|-----|----------|---------------|
| `base_account` | Обычный аккаунт с немедленным доступом к токенам | `key_name` или `address` |
| `delayed_vesting` | Токены разблокируются в указанное время (`end_time`) | `vesting.end_time` |
| `continuous_vesting` | Токены разблокируются линейно от `start_time` до `end_time` | `vesting.start_time`, `vesting.end_time` |
| `clawback_vesting` | Vesting с возможностью отзыва фондом (foundation) | `vesting` |
| `validator_set` | Набор валидаторов с self-delegation и операционными фондами | `validators[]` |

### Параметры модулей

| Модуль | Параметры |
|--------|-----------|
| `staking` | `max_validators`, `max_entries`, `historical_entries`, `unbonding_time`, `bond_denom` (дефолт — `chain.denom`), `min_commission_rate` |
| `distribution` | `community_tax`, `base_proposer_reward`, `bonus_proposer_reward`, `withdraw_addr_enabled` |
| `mint` | `inflation_rate_change`, `inflation_max`, `inflation_min`, `goal_bonded`, `blocks_per_year`, `max_supply` |
| `gov` | `min_deposit`, `expedited_min_deposit`, `max_deposit_period`, `voting_period`, `quorum`, `threshold`, `veto_threshold`, `min_initial_deposit_ratio`, `burn_vote_quorum`, `burn_proposal_deposit_prevote` |
| `slashing` | `signed_blocks_window`, `min_signed_per_window`, `downtime_jail_duration`, `slash_fraction_double_sign`, `slash_fraction_downtime` |
| `wasm` | `code_upload_access`, `instantiate_default_permission` |

### Валидация децентрализации

| Правило | Описание |
|---------|----------|
| `max_single_allocation_percent` | Ни один аккаунт не получит больше указанного % (дефолт 25%) |
| `max_insider_allocation_percent` | Foundation + Team + Investors не получат больше указанного % (дефолт 45%) |
| `min_validator_count` | Минимальное количество валидаторов в genesis |
| `dust_destination` | Куда отправлять остаток от округления (`community_pool`) |

Ошибка валидации, если: сумма `percentage` ≠ 100% (±0.01), `vesting.start_time` раньше `genesis_time`,
у валидатора нет `self_delegation`/`commission_rate`.

### Soft Launch

При включённом soft launch на старте сети:
- **Отключено**: bank send для нативного denom, IBC transfers, инстанциация wasm (опционально).
- **Включено**: staking, governance.

Включение transfers происходит через governance proposal после достижения децентрализации.

### Пример workflow

```bash
# 1. Валидация плана
umeshctl setup validate-plan --config genesis-plan.yaml

# 2. Просмотр отчёта
umeshctl setup report --config genesis-plan.yaml

# 3. Выполнение плана
umeshctl setup plan --config genesis-plan.yaml --auto-password

# 4. Запуск сети
docker compose --env-file .env.validator --profile validator up -d
```

---

## Структура проекта

 ```text
 umesh-node/
 ├── .env.genesis.example        # Шаблон compose-env для Validator (genesis)
 ├── .env.validator.example      # Шаблон compose-env для Validator (join)
 ├── .env.sentry.example         # Шаблон compose-env для Sentry
 ├── .env.rpc.example            # Шаблон compose-env для RPC
 ├── .umeshprep-version          # Закреплённая версия внешнего инструмента umesh-prep
 ├── config/
 │   ├── node-config-genesis.yaml.example  # YAML-конфиг инициализации (genesis)
 │   ├── node-config-validator.yaml.example # YAML-конфиг инициализации (join)
 │   ├── node-config-sentry.yaml.example   # YAML-конфиг инициализации (sentry)
 │   └── node-config-rpc.yaml.example      # YAML-конфиг инициализации (rpc)
 ├── Dockerfile                  # Multi-stage сборка (go-toolchain → src-provider → builder → runtime)
 ├── docker-compose.yml          # 3 сервиса: validator + sentry + rpc (профили)
 ├── entrypoint.sh               # Точка входа контейнера
 ├── justfile                    # Быстрый запуск: just run-validator-genesis / run-validator / run-sentry / run-rpc
 ├── tools/
 │   └── umeshctl/               # Go-CLI для управления нодами — клон отдельного репозитория umesh-cli (см. .gitignore, не коммитится)
 └── src/umesh/                  # Исходный код блокчейна (генерируется external umesh-prep)
 ```

---

## Как работает система

### Разделение ответственности

| Где | Что | Зачем |
|-----|-----|-------|
| **В контейнере** | `umeshnode` + `entrypoint.sh` (bash) | Запуск ноды, privilege drop. **Не выполняет инициализацию** |
| **На хосте** | `umeshctl` (Go CLI) | Инициализация: setup init/plan, патчинг denom (Go code), bank metadata (Go code), gentx |
| **На хосте** | `umeshctl` (Go CLI) | Администрирование: backup, doctor, verify, connect-sentry, keys, genesis fetch |
| **На хосте** | `docker compose` + `.env` | Управление контейнерами (после инициализации) |

### Разделение init и start

Инициализация и запуск разделены:

```
# === ХОСТ (umeshctl setup init) ===
umeshctl setup init --role genesis --config config/node-genesis.yaml --auto-password
  ├─ docker run ... umeshnode init genesis-account
  ├─ Go code patch: bond_denom, mint_denom, gov min_deposit → $DENOM
  ├─ Go code add: bank denom_metadata
  ├─ docker run ... keys add + genesis add-genesis-account + gentx + collect-gentxs
  └─ docker run ... genesis validate-genesis

# === КОНТЕЙНЕР (entrypoint.sh + docker compose) ===
docker compose --env-file .env.genesis --profile validator up -d
  ├─ entrypoint.sh: ensure dirs, chown, privilege drop
  └─ exec umeshnode start (PID 1)

Инициализация выполняется **на хосте** через `umeshctl setup init` / `umeshctl setup plan` **до запуска контейнера**. `umeshctl` запускает `umeshnode` в одноразовых `docker run --rm` контейнерах с монтированием `./data-validator`/`./data-sentry`/`./data-rpc` и сетью `umesh`. После инициализации контейнер только запускает `umeshnode` через `entrypoint.sh` (без патчинга).

#### Полный flow `umeshctl setup init --role genesis`

```
RunGenesis(p)
  ├─ AbortIfInitialized()          — идемпотентность: если genesis.json существует → ErrAlreadyInitialized
  ├─ ValidateConfig()               — валидация YAML конфига: chainId, moniker, denom, minGasPrice, environment
  ├─ ValidatePrivateIP()           — опционально: проверка внешнего IP (если задан)
  │
  ├─ [1/8] umeshnodeInit()            — docker run ... umeshnode init <moniker> --chain-id <id>
  │     └─ создаёт: genesis.json (stake denom), config.toml, app.toml, keyring
  │
  ├─ [2/8] tune.Apply()            — host-side Go code: production tuning (consensus, p2p, mempool, API)
  │
  ├─ [3/8] patchDenom()            — host-side Go code: патчит genesis.json
  │     ├─ staking.params.bond_denom → $DENOM
  │     ├─ mint.params.mint_denom → $DENOM
  │     ├─ gov.params.min_deposit[*].denom → $DENOM
  │     └─ gov.params.expedited_min_deposit[*].denom → $DENOM
  │
  ├─ [4/8] addBankMetadata()       — host-side Go code: добавляет bank.denom_metadata
  │     └─ denom_units: uumesh (0), mumesh (3), UMESH (6); display = UMESH
  │
  ├─ [5/8] createValidatorAccount()— docker run ... keys show || keys add
  │     └─ создаёт/проверяет ключ валидатора в keyring (физически: `keyring/keyring-file/`)
  │
  ├─ [6/8] addGenesisValidatorAccount() — docker run ... genesis add-genesis-account
  │     └─ добавляет баланс валидатора: $SELF_DELEGATION$DENOM
  │
  ├─ [7/8] generateGentx()         — docker run ... genesis gentx
  │     └─ создаёт gentx: $STAKE_AMOUNT$DENOM, validator key, moniker
  │
  ├─ [8/8] collectGentxs()         — docker run ... genesis collect-gentxs
  │     └─ собирает все gentx в genesis.json
  │
  └─ validateGenesis()             — docker run ... genesis validate-genesis
       └─ валидация genesis → writeNodeInfo: `"VALIDATOR_READY": 1`
```

#### Режимы инициализации

| Режим | Описание | Уникальные шаги (все — `docker run --rm` офлайн, идемпотентно, `--force` требует остановленного контейнера) |
|-------|----------|-----------------|
| `genesis` | Создание новой сети (Block 0) | `umeshnode init → tune → patch denom/metadata → keys add → add-genesis-account → gentx → collect-gentxs → validate` |
| `validator` | Присоединение как валидатор (post-genesis) | `obtainGenesis` (приоритет `sentryRpc/genesis → validatorRpc/genesis → genesisUrl`, `chainId/denom` авто) → `umeshnodeInit` (offline, `--keep-keys` сохраняет NodeID) → `tune` (`pex false`) → `p2p`/`externalAddress` → `keyring` + автобэкап |
| `sentry` | Публичный шлюз (щит, не подписывает) | `obtainGenesis` → `umeshnodeInit(..., pruneState=true, удаляет priv_validator_key)` → `tune` (`pex true 40/20`, `snapshots 5000`, `grpc-web 9090`) → `addPrivatePeer` (best-effort `validatorRpc/status`, иначе ручной `persistentPeers`) |
| `rpc` | Публичная RPC-нода (не подписывает) | `obtainGenesis` (приоритет `sentryRpc → genesisUrl → validatorRpc` для RPC, `genesisUrl` фоллбек) → `umeshnodeInit` → `enableRPC` (`rpc.laddr 0.0.0.0:26657` `cors *`) → `tune` (`node.pruning` `custom 1000/100` дефолт, `pex true 60/40`, `kv indexer`, `grpc-web 9090`) |

#### Параметры инициализации (YAML config `umeshctl setup init --config`)

Параметры инициализации теперь находятся в типизированном YAML-конфиге, а не в `.env` файлах.
Секрет (ключевой пароль) передаётся через `--keyring-password-file` / `--keyring-password-stdin` / `--keyring-password-exec`,
флаг `--auto-password` (автоматически генерирует и сохраняет пароль) или вводится интерактивно.

| Параметр YAML | Секция | Используется в | Назначение |
|--------------|--------|---------------|------------|
| `chain.chainId` / `chain.denom` | `chain` | obtainGenesis + ValidateCommon (auto-extract) | Опциональны при `join` — берутся из `genesis.json` (`chain_id`/`bond_denom`), иначе обязательны; `chain.minGasPrice` обязателен |
| `node.moniker` / `node.environment` | `node` | umeshnode init + tune | Имя и окружение ноды |
| `node.pruning` | `node` | tune.Apply (RoleRPC/Sentry/Validator) | **Локальная** стратегия `app.toml` (не `chain`): `custom` (дефолт RPC `1000/100`, validator `10000/1000`), `everything` (light), `nothing` (archive), `default` |
| `validator.keyName` | `validator` | createValidatorAccount | Имя ключа в keyring |
| `validator.stakeAmount` | `validator` | generateGentx | Сумма self-delegation для gentx (напр. `1000000000uumesh`) |
| `validator.selfDelegation` | `validator` | addGenesisValidatorAccount | Начальный баланс валидатора в genesis |
| `validator.*` (commission, minSelfDelegation) | `validator` | generateGentx (опционально) | Комиссия и минимальная self-delegation |
| `validator.externalAddress` | `validator` | generateGentx + tune (опционально) | Публичный IP: уходит в gentx `--ip` и `p2p.external_address` |
| `join.genesisUrl` | `join` | obtainGenesis (validator/sentry/rpc) | URL `genesis.json` для скачивания (raw). Для RPC — фоллбек когда `sentryRpc` на обслуживании (приоритет `sentryRpc/genesis → genesisUrl → validatorRpc/genesis`) |
| `join.genesisSha256` | `join` | FetchGenesis | SHA-256 для верификации genesis |
| `join.sentryRpc` | `join` | obtainGenesis (validator/sentry/rpc) | RPC sentry (`http://ip:26657`) — `+ /genesis` внутри; для RPC обязателен `sentryRpc` **или** `genesisUrl` |
| `join.validatorRpc` | `join` | obtainGenesis (validator/sentry/rpc) | RPC валидатора (`http://ip:26657`) — fallback, для `usePrivate` также источник NodeID |
| `network.seeds` | `network` | applyP2P | Seed-пиры в config.toml |
| `network.persistentPeers` | `network` | applyP2P | Постоянные пиры (`NodeID@IP:26656`) — для RPC добавьте Sentry `persistentPeers` чтобы `broadcast_tx_sync` летел мгновенно |
| `network.externalAddress` | `network` | tune.Apply + setExternalAddress | `p2p.external_address` (`IP:26656`); пусто → `172.x` bridge и `doctor --check p2p` ворнинг |
| `network.usePrivate` | `network` | sentry addPrivatePeer | `true` — добавить валидатора в `private_peer_ids`/`unconditional_peer_ids` (требует живой `validatorRpc`, иначе ручной `persistentPeers`) |
| `telemetry.endpoint` | `telemetry` | WriteOtelConfig | OTLP gRPC endpoint для otel.yaml |
| `telemetry.serviceName` | `telemetry` | WriteOtelConfig | service.name в otel.yaml |

*Если значения комиссии/`minSelfDelegation` не заданы в YAML, `generateGentx` использует дефолты `umeshnode` (`rate=0.10`, `max_rate=0.20`, `max_change_rate=0.01`, `min_self_delegation=1`).*

> Для production-развёртывания предпочтителен **Genesis Plan** (`setup plan`) — он задаёт те же параметры декларативно в YAML (см. [Genesis Plan](#genesis-plan-production)).

---

## Как работает сборка

Сборка полностью самодостаточна (`self-contained Dockerfile`). При выполнении `docker build` Dockerfile автоматически выполняет подготовку исходного кода из `wasmd` внутри контейнера-билдера.

### Этап 1: Подготовка исходного кода (внутри Dockerfile)

Внешний инструмент `umesh-prep` (github.com/opscores/umesh-prep, версия из `.umeshprep-version`) скачивается и запускается на стадии `src-provider-umeshprep` внутри Dockerfile:
1. Клонирует `wasmd` v0.70.3 из официального репозитория CosmWasm.
2. Переименовывает:
   - `cmd/wasmd` → `cmd/umeshnode`
   - `AppName = "wasmd"` → `"umeshnode"`
   - `DefaultNodeHome = ".wasmd"` → `".umeshnode"`
   - `Bech32Prefix = "wasm"` → `"umesh"`
3. Меняет путь модуля: `github.com/CosmWasm/wasmd` → `github.com/opscores/umesh-node`.
4. **Критические патчи для Cosmos SDK v0.54** (через AST, `go/parser` + `go/format`):
   - `banktypes.ModuleName` ставит **первым** в `SetOrderEndBlockers` (требование BlockSTM).
   - Хардкодит Wasm capabilities (вместо `BuiltInCapabilities()`): `iterator`, `staking`, `stargate`, `ibc2`, `cosmwasm_1_1`–`cosmwasm_3_0`.
   - Удаляет `x/protocolpool` (не совместим с SDK v0.54.3).
5. Добавляет `replace` директивы в `go.mod`:
   - `cometbft => v0.39.3`
   - `cosmos-sdk => v0.54.3`
6. Выполняет `go mod tidy` (сеть доступна на этапе сборки) и инициализирует git-коммит в `src/umesh`.
7. Компиляция бинарника с `CGO_ENABLED=1` выполняется в стадии `builder`.

Источник исходников выбирается build-arg `BUILD_TYPE`:

| Значение | Источник | Когда использовать |
|----------|----------|--------------------|
| `umeshprep` (по умолчанию) | Внешний `umesh-prep` (github.com/opscores/umesh-prep) выводит исходники из wasmd внутри контейнера | Стандартная сборка |
| `local` | Локальная папка `src/umesh/` | Разработка с локально изменёнными исходниками (`--build-arg BUILD_TYPE=local`) |

#### Конфигурация `umesh-prep` (внешний инструмент)

Инструмент `umesh-prep` (github.com/opscores/umesh-prep) — это внешний Go-инструмент, который клонирует `wasmd`, переименовывает модуль и применяет патчи. Версия закрепляется в файле `.umeshprep-version` (single source of truth).

Все опции задаются флагом, переменной окружения или значением по умолчанию (приоритет: **flag > env > default**).

| Флаг | Env | Default | Назначение |
|---|---|---|---|
| `-wasmd-version` | `WASMD_VERSION` | `v0.70.3` | Версия wasmd для клонирования |
| `-wasmd-repo` | `WASMD_REPO` | `https://github.com/CosmWasm/wasmd.git` | URL репозитория wasmd |
| `-output-dir` | `OUTPUT_DIR` | `./src` | Выходной каталог форка |
| `-target-module` | `TARGET_MODULE` | `github.com/opscores/umesh-node` | Go module path форка |
| `-bech32-prefix` | `BECH32_PREFIX` | `umesh` | Bech32-префикс аккаунтов |
| `-node-dir` | `NODE_DIR` | `.umeshnode` | Имя каталога ноды |
| `-binary-name` | `BINARY_NAME` | `umeshnode` | Имя бинарника |
| `-version-name` | `VERSION_NAME` | `umesh` | `version.Name` приложения |
| `-sdk-version` | `SDK_VERSION` | `v0.54.3` | cosmos-sdk в replace (только v0.54.x) |
| `-cometbft-version` | `COMETBFT_VERSION` | `v0.39.3` | cometbft в replace |
| `-capabilities` | `CAPABILITIES` | `iterator,staking,...,cosmwasm_3_0` | Wasm capabilities (через запятую) |
| `-goproxy` | `GOPROXY` | `https://proxy.golang.org,direct` | Прокси для Go-команд |
| `-keep-tests` | `KEEP_TESTS=true` | `false` | Не удалять `*_test.go` |
| `-skip-tidy` | `SKIP_TIDY=1` | `false` | Пропустить `go mod tidy` |
| `-skip-build` | `SKIP_BUILD=1` | `false` | Пропустить build-gate `CGO_ENABLED=1 go build ./...` |
| `-in-container` | `UMESHPREP_IN_CONTAINER=1` | `false` | Go toolchain доступна локально (в контейнере) |
| `-enable-ibc` | `ENABLE_IBC` | `true` | Включить IBC стек (ibc, transfer, ica, ibctm, ibccallbacks) |
| `-enable-evidence` | `ENABLE_EVIDENCE` | `true` | Включить evidence модуль (core) |
| `-enable-upgrade` | `ENABLE_UPGRADE` | `true` | Включить upgrade модуль |
| `-enable-feegrant` | `ENABLE_FEAGRANT` | `true` | Включить feegrant модуль (делегирование комиссий) |
| `-enable-authz` | `ENABLE_AUTHZ` | `true` | Включить authz модуль (авторизация сообщений) |
| `-enable-vesting` | `ENABLE_VESTING` | `true` | Включить vesting модуль |
| `-enable-deprecated` | `ENABLE_DEPRECATED` | `false` | Включить deprecated модули (protocolpool, group, nft, crisis) |

### Этап 2: Сборка и верификация образов

- **Multi-stage Dockerfile**:
  - **go-toolchain**: Ubuntu 26.04 + Go 1.25.12 (amd64, multi-mirror загрузка).
  - **src-provider**: источник исходников — `src-provider-umeshprep` (по умолчанию: внешний `umesh-prep` в контейнере) или `src-provider-local`.
  - **builder**: Ubuntu 26.04 + clang/llvm — компиляция `umeshnode` из `src-provider` с `CGO_ENABLED=1`.
  - **runtime**: Ubuntu 26.04 + `umeshnode` + `libwasmvm.x86_64.so` + `dasel` + `jq` (debug/passthrough) + `gosu`.
- Сборка выполняется через `docker build` с необходимыми build-args.
  - Архитектура образа: `amd64`.
  - Multi-stage: go-toolchain → src-provider → builder → runtime.

### Как получить образ: GHCR или локальная сборка

Образ можно получить двумя способами — выбор задаётся через `NODE_IMAGE` в `.env`:

| Вариант | `NODE_IMAGE` | Команда | Рекомендуется для |
|---|---|---|---|
| **A. Взять из GHCR** | `ghcr.io/opscores/umesh-node:latest` | `docker pull ghcr.io/opscores/umesh-node:latest` | **Production Deployment** |
| **B. Собрать локально** | `umesh-node:latest` (по умолчанию) | `docker build -t umesh-node:latest -f Dockerfile .` | **Development / Testing** |

*   **Production Deployment**: используйте `docker pull`, чтобы скачать готовый образ из GHCR.
*   **Development**: используйте `docker build`, если вы изменили исходный код или скрипты внутри репозитория и хотите проверить их локально.

`docker compose up -d` использует `NODE_IMAGE` из `.env` при старте контейнера.

---

## Безопасность

| Мера | Реализация |
|------|-----------|
| **Sentry-Validator архитектура** | Валидатор скрыт за Sentry, не имеет публичного IP |
| **Read-only контейнеры** | `read_only: true` в docker-compose |
| **No new privileges** | `security_opt: no-new-privileges:true` |
| **Tmpfs для чувствительных данных** | `/tmp`, `/var/tmp`, `.cache`; `wasm` в tmpfs (validator) / persistent volume (sentry, rpc) |
| **Привилегированный пользователь** | `umesh` (UID 1000), не root |
| **Приватные пиры** | `private_peer_ids` + `unconditional_peer_ids` для Sentry |
| **PEX отключён на валидаторе** | Валидатор не ищет пиров самостоятельно |
| **API отключён на валидаторе** | Только localhost, Sentry/RPC открыты публично |
| **State-Sync отключён на валидаторе** | Только на Sentry/RPC |
| **RPC-нода без ключа валидатора** | `priv_validator_key.json` отсутствует |
| **Проверка NTP** | Синхронизация времени обязательна |
| **SHA256 валидация genesis** | Защита от MITM |
| **Keyring с паролем** | `--auto-password` (автогенерация) или `--keyring-password-file` (chmod 600) |
| **Автоматические бэкапы** | `priv_validator_key.json`, `node_key.json`, keyring |

---

## Производственная настройка (`umeshctl tune`)

Команда `umeshctl setup tune --role <validator|sentry|rpc>` применяет настройки для каждой роли:

| Параметр | Validator (Bunker) | Sentry (Public Gateway) | RPC (Public API) |
|----------|------------------|----------------------|------------------|
| **API** | `false` | `true` | `true` |
| **gRPC** | `false` | `true` | `true` |
| **gRPC-Web** | `false` | `true`² | `true`² |
| **State-Sync** | `false` | `true` | `true` |
| **Snapshots** | `0` (выключены) | `5000` | `0` |
| **Pruning** | `custom` (10000/1000) | `custom` (1000/100) | `custom` (1000/100)³ |
| **IAVL Cache** | 781250 | 1562500 | 1562500 |
| **Inbound Peers** | 5 | 40 | 60 |
| **Outbound Peers** | 4 | 20 | 40 |
| **Mempool (P2P)** | 5000 | 10000 | 5000 |
| **PEX** | `false` | `true` | `true` |
| **Indexer** | `null` | `kv` | `kv` |
| **Data Companion** | `false` | `true` (порт 26658) | `false` |
| **RPC** | `0.0.0.0` | `0.0.0.0` | `0.0.0.0` |
| **Consensus timeouts** | 3s commit, 1s prevote | 3s commit, 1s prevote | 3s commit, 1s prevote |
| **Log format** | json | json | json |
| **Telemetry** | enabled¹ | enabled¹ | enabled¹ |

¹ `[telemetry]` в `app.toml` (legacy go-metrics, in-memory) включается `tune` для всех ролей. **OTLP-экспорт — opt-in**: включается только через `otel.yaml` (пишет `umeshctl setup init` при заданном `telemetry.endpoint` в YAML конфиге), см. [Мониторинг](#мониторинг-opentelemetry).

² `gRPC-Web` — `grpc-web.enable true` на том же `0.0.0.0:9090` что и `grpc` (`tune: grpc 9090 + grpc-web`); отдельный `9091` только с внешним Envoy-прокси.

³ `Pruning` дефолт `custom` (`keep-recent 1000/100` для RPC/Sentry ~1.5ч при 5s блоке, `10000/1000` для validator). Переопределяется **явно** через `node.pruning` в YAML (`custom`|`everything`|`nothing`|`default`); `chain.pruning` не существует — pruning это свойство инстанса, не сети. Скрытая логика `environment==production → everything` удалена.

---

## Мониторинг: OpenTelemetry

Umesh использует нативный OTLP Exporter из Cosmos SDK v0.54+ — метрики, трейсы и логи экспортируются на OTEL Collector без сторонних зависимостей.

### Как работает

```
umeshnode → config/otel.yaml → OTLP Exporter (gRPC) → OTEL Collector → Jaeger / Prometheus → Grafana
```

- Cosmos SDK читает конфигурацию OpenTelemetry из файла `otel.yaml` в конфиг-дир ноды (`~/.umeshnode/config/otel.yaml`), а **не** из `OTEL_EXPORTER_*` переменных окружения — SDK их игнорирует (см. спецификацию opentelemetry-configuration).
- `otel.yaml` пишет `umeshctl setup init` на хосте из секции `telemetry.*` в YAML конфиге (`node-config.yaml`). Пустой файл (создаётся `umeshnode init` по умолчанию) = телеметрия выключена (noop-провайдер).
- `[telemetry]` секция в `app.toml` включается автоматически `umeshctl tune`.

### Настройка

В YAML конфиге (`telemetry.*` секция, читается `umeshctl setup init`):

```yaml
telemetry:
  endpoint: "http://otel-collector.monitoring.svc:4317"  # OTLP gRPC; пусто = off
  serviceName: "umesh-validator"                          # service.name (по умолчанию umesh-<role>)
```

После `umeshctl setup init` в `data-<role>/config/otel.yaml` появится заполненный конфиг (resource-атрибуты `service.name`/`deployment.environment`, batch-экспортёры OTLP gRPC для трейсов/метрик/логов, host/runtime/diskio-инструментация). Применится при следующем старте контейнера.

> Если `telemetry.endpoint` недоступен — телеметрия работает, но данные никуда не уходят.
> Для devnet можно не настраивать (оставить `endpoint` пустым).

---

## Переменные окружения

В проекте есть **две конфигурации**:

1. **YAML конфиг ноды** (`config/node-<role>.yaml`) — параметры инициализации
   (chain ID, moniker, denom, keystore password, genesis sources, peers, telemetry).
   Используется `umeshctl setup init --config <file>` **только одноразово** на хосте.

2. **`.env.<role>` файл** — параметры **только для docker-compose** (порты, ресурсы, image, метки).
   Используется `docker compose --env-file .env.<role>` **на каждый запуск/перезапуск**.

### `.env.<role>` — переменные для docker-compose

Каждая роль имеет свой `.env.<role>` файл (создайте из `.env.<role>.example`).
Эти переменные **только для `docker compose`** — `umeshctl` их не читает.

| Группа | Переменные | Назначение |
|--------|-----------|------------|
| **Общие** | `NODE_IMAGE`, `ENVIRONMENT` | Docker образ, метка окружения |
| **Порты (validator)** | `VALIDATOR_P2P_BIND_IP`, `VALIDATOR_P2P_PORT`, `VALIDATOR_RPC_BIND_IP`, `VALIDATOR_RPC_PORT`, `VALIDATOR_METRICS_BIND_IP`, `VALIDATOR_METRICS_PORT` | Публикация портов на хост |
| **Порты (sentry)** | `SENTRY_P2P_BIND_IP`, `SENTRY_P2P_PORT`, `SENTRY_RPC_BIND_IP`, `SENTRY_RPC_PORT`, `SENTRY_REST_PORT`, `SENTRY_GRPC_PORT`, `SENTRY_GRPC_WEB_PORT`, `SENTRY_METRICS_BIND_IP`, `SENTRY_METRICS_PORT`, `SENTRY_DC_BIND_IP`, `SENTRY_DC_PORT` | Публикация портов на хост |
| **Порты (rpc)** | `RPC_P2P_BIND_IP`, `RPC_P2P_PORT`, `RPC_RPC_BIND_IP`, `RPC_RPC_PORT`, `RPC_REST_PORT`, `RPC_GRPC_PORT`, `RPC_GRPC_WEB_PORT`, `RPC_METRICS_BIND_IP`, `RPC_METRICS_PORT` | Публикация портов на хост |
| **Ресурсы** | `CPU_LIMIT`/[`CPU_LIMIT_<ROLE>`], `MEMORY_LIMIT`/[`MEMORY_LIMIT_<ROLE>`], `MEMORY_RESERVATION`/[`MEMORY_RESERVATION_<ROLE>`] | Лимиты и резервы контейнера |

**Важно:** `*_BIND_IP` и `*_PORT` управляют **только публикацией** порта на хосте.
Внутри контейнера `laddr` всегда `0.0.0.0` (жёстко в `docker-compose.yml`).
Все `.env` переменные используются **только для интерполяции** `${...}`
в `docker-compose.yml` и **не попадают в контейнер**.

### YAML конфиг ноды (`config/node-<role>.yaml`)

Параметры инициализации находятся в типизированном YAML-конфиге.
Шаблоны находятся в `config/node-config-<role>.yaml.example`; создайте свои копии:

```bash
cp config/node-config-genesis.yaml.example config/node-genesis.yaml
cp config/node-config-validator.yaml.example config/node-validator.yaml
cp config/node-config-sentry.yaml.example config/node-sentry.yaml
cp config/node-config-rpc.yaml.example config/node-rpc.yaml
```

Секрет (keyring password) передаётся через флаги, а не в YAML:

- `--auto-password` — автоматически генерирует надёжный пароль (32 символа) и сохраняет
  его в `<dataDir>/keyring.pass` с правами `chmod 600` (рекомендуется для интерактивного
  использования и Ansible).
- `--keyring-password-file <path>` — читает пароль из файла (для CI/Ansible).
- `--keyring-password-stdin` — читает пароль из stdin.
- `--keyring-password-exec <cmd>` — выполняет команду и читает пароль из stdout (например, из Vault/1Password).

```bash
# Самый простой способ — автогенерация:
umeshctl setup init --role genesis --config config/node-genesis.yaml --auto-password

# или интерактивный ввод:
umeshctl setup init --role validator --config config/node-validator.yaml
```

---

## Команды umeshctl

`umeshctl` работает **на хосте** и выполняет инициализацию через `docker run --rm`. Команды сгруппированы по фазам жизненного цикла:

### setup — ДО запуска

| Команда | Назначение |
|---------|-----------|
| `umeshctl setup init --role <role>` | Инициализация ноды (genesis/validator/sentry/rpc). См. флаги ниже |
| `umeshctl setup plan --config <yaml>` | Production genesis из YAML-плана (`--dry-run`, `--force`, `--keep-keys`) |
| `umeshctl setup validate-plan --config <yaml>` | Валидация YAML-плана без выполнения |
| `umeshctl setup report --config <yaml>` | Отчёт о распределении (table/json) |
| `umeshctl setup add-account` | Инкрементальное добавление аккаунта в genesis |
| `umeshctl setup add-validator` | Инкрементальное добавление валидатора в genesis |
| `umeshctl setup tune --role <role>` | Применить tuning profile |
| `umeshctl setup keys add <name>` | Создать ключ |

#### Флаги `umeshctl setup init`

Приоритет: **флаг > `--config` (YAML) > окружение**. Модель ролей:
- `genesis` — **создаёт** новую сеть; join-параметры (`--genesis-url`,
  `--sentry-rpc`, `--validator-rpc`, `--seeds`, `--persistent-peers`,
  `--rpc-upstream`, `--addrbook-url`, `--use-private` и др.) для него
  **отклоняются**.
- `validator`/`sentry`/`rpc` — **присоединяются** к существующей сети;
  обязателен минимум один источник genesis (`--genesis-url` / `--sentry-rpc` /
  `--validator-rpc`; для `rpc` достаточно `join.sentryRpc` **или** `join.genesisUrl` — `genesisUrl` фоллбек когда Sentry на обслуживании, `validatorRpc` — третий fallback). При наличии `join` поле `chain.chainId` опционально (авто-извлекается из `genesis.json` `chain_id`/`bond_denom`); `chain.denom` также опционален.
- Секреты **никогда** не в YAML — только через `--keyring-password-*` / `--auto-password` (иначе `Validate` отклонит файл с `keyringPassword`).
- `--plan-file` в `setup init` **удалён** — используйте `setup plan --config` для генезиса.

| Флаг | YAML config | Роли |
|------|------------|------|
| `--config <file>` | *(весь файл YAML)* | все (**обязательно**, `setup init` без него падает) |
| `--chain-id`, `--moniker`, `--denom`, `--min-gas-price`, `--environment` | `chain.*`, `node.*` | все (`chainId`/`denom` опциональны при `join`) |
| `--pruning` | `node.pruning` | rpc/sentry/validator (`custom`/`everything`/`default`/`nothing`; для RPC дефолт `custom 1000/100`) |
| `--force` | *(пересоздание)* | все (требует `--config`, контейнер должен быть остановлен, иначе `refusing --force while container is running`) |
| `--keep-keys` | *(сохранение идентичности)* | validator/sentry/rpc (работает только с `--force`, сохраняет `node_key.json`/`priv_validator_key.json`) |
| `--keyring-password-file <f>` | *(секрет)* | genesis/validator |
| `--keyring-password-stdin` | *(секрет)* | genesis/validator |
| `--keyring-password-exec <cmd>` | *(секрет)* | genesis/validator |
| `--auto-password` | *(автогенерация пароля 32 символа → `<dataDir>/keyring.pass` `600`)* | genesis/validator |
| `--genesis-url` | `join.genesisUrl` | validator/sentry/rpc (для `rpc` — фоллбек) |
| `--sentry-rpc` | `join.sentryRpc` | validator/sentry/rpc (для `rpc` — приоритет №1) |
| `--validator-rpc` | `join.validatorRpc` | validator/sentry/rpc (для `rpc` — fallback №3, для `sentry` источник NodeID при `usePrivate`) |
| `--rpc-upstream` | `join.sentryRpc` (legacy alias) | rpc |
| `--genesis-sha256` | `join.genesisSha256` | validator/sentry/rpc |
| `--addrbook-url`, `--addrbook-sha256` | `join.*` | validator/sentry |
| `--seeds`, `--persistent-peers` | `network.*` | validator/sentry/rpc |
| `--external-address` | `network.externalAddress` | validator/sentry/rpc (пусто → `172.x` ворнинг `doctor --check p2p`) |
| `--public-ip`, `--external-port` | `network.*` | sentry |
| `--use-private` | `network.usePrivate` | sentry (best-effort `GET /status`, иначе ручной `persistentPeers`) |

> **`genesis` — не профиль compose.** «genesis» — это фаза инициализации
> валидатора (создание новой сети через `setup init --role genesis`),
> а не сервис/профиль. Создатель сети и пост-генезис
> валидатор запускаются одним и тем же сервисом `validator`
> (`--profile validator`).

### node — ПОСЛЕ запуска (контейнер запущен `docker exec`, кроме помеченных офлайн)

| Команда | Назначение |
|---------|-----------|
| `umeshctl node status sync/node/peers/validator/docker` | Статус: sync (height/catching_up), нода, пиры, валидатор, docker health |
| `umeshctl node health [--wait-sync]` | Быстрая проверка + ожидание синка для CI |
| `umeshctl node config get/set/diff` | Чтение/запись `config.toml`/`app.toml`/`client.toml`, `diff --role` vs тюнинг |
| `umeshctl node peers list/add/remove/clear` | Управление `persistent_peers`, `unconditional_peer_ids`, `private_peer_ids` |
| `umeshctl node logs [--level --module --since -f]` | Логи с фильтрацией |
| `umeshctl node prune [--keep-recent N]` | Ручной pruning (требует остановленного контейнера) |
| `umeshctl node snapshot create/list/restore --from` | Снапшоты State-Sync (офлайн, `docker run --rm`) |
| `umeshctl node statesync enable/disable` | Вкл/выкл StateSync (`trust-height/hash`, `rpc_servers`) |
| `umeshctl node upgrade info` | Версия бинарника |
| `umeshctl node validator create` | Создать валидатора в **живой** сети (онлайн, `docker exec -i`, JSON `validator.json` из `comet show-validator`, `gas auto/1.5/0.0025`, 3 pre-flight: running/catching_up/balance) |
| `umeshctl node validator check-balance` | Проверить баланс без ожидания синка (`balance >= amount+fee`) |
| `umeshctl node validator generate-gentx` | Gentx для Mainnet Ritual (pre-genesis) |
| `umeshctl node validator signing-info/unjail/operator-address/backup-consensus` | `missed_blocks/tombstoned`, разжалование, `valoper`, бэкап `priv_validator_key.json` |
| `umeshctl node sentry connect/update` | Связка sentry↔validator (legacy helper, сейчас через `persistentPeers` + `usePrivate`) |
| `umeshctl node keys list/show/export/import/delete` | Ключи (`show` — `umesh1...` офлайн, `operator-address` — `valoper` онлайн) |

### ops — ОБСЛУЖИВАНИЕ (хост)

| Команда | Назначение |
|---------|-----------|
| `umeshctl ops backup --output ./backups` | Бэкап `priv_validator_key.json`, `node_key.json`, `keyring` (сразу после `setup init`) |
| `umeshctl ops restore --from ./backups/... [--role <role>]` | Восстановление (контейнер остановлен, иначе ворнинг) |
| `umeshctl ops doctor [--check arch/ntp/gitignore/readiness/wasmvm/container-health/peers/p2p/join]` | Диагностика; `p2p`/`join` — warning-only (`net/http`, без `curl|jq/ufw`) |
| `umeshctl ops config verify [--role <role>] [--cross-role]` | Верификация роли, `config.toml` и связности по RPC |

### genesis — УТИЛИТЫ КООРДИНАТОРА

| Команда | Назначение |
|---------|-----------|
| `umeshctl genesis fetch --url <url> [--sha256 <hash>] [--dry-run]` | Скачать `genesis.json` (`--dry-run` — проверить без записи, `net/http` без `curl|jq`), показывает все попытки `tried [url: err]` |
| `umeshctl genesis inspect --file <path>` | Показать `chain_id`, `denom` (`bond_denom`), `genesis_time` |
| `umeshctl genesis validate` | `validate-genesis` через `docker run` |
| `umeshctl genesis set-param --path <dot> --value <json>` | Патч параметра в `genesis.json` |
| `umeshctl genesis set-time --time <RFC3339>` | Установить `genesis_time` |
| `umeshctl genesis collect-gentx --repo <url>` | Сбор gentx из GitHub-репозитория |

---

## Docker Image Versioning

Образы публикуются с несколькими тегами для трассируемости:

| Тег | Назначение | Пример |
|-----|------------|--------|
| `v*` | Семантическая версия (релиз) | `v0.1.0` |
| `v*-sha` | Версия + git SHA (трассируемость) | `v0.1.0-abc1234` |
| `latest` | Текущая development-версия | `latest` |

### Публикация нового релиза

```bash
# Создать и запушить version-тег
git tag v0.1.0
git push origin v0.1.0

# GitHub Actions автоматически соберёт и запушит:
# - ghcr.io/opscores/umesh-node:v0.1.0
# - ghcr.io/opscores/umesh-node:v0.1.0-<sha>
# - ghcr.io/opscores/umesh-node:latest
```

### Использование конкретной версии

```bash
# Скачать конкретную версию
docker pull ghcr.io/opscores/umesh-node:v0.1.0

# Запустить с конкретной версией
NODE_IMAGE=ghcr.io/opscores/umesh-node:v0.1.0 docker compose --profile validator up -d
```

---

## Документация

| Документ | Назначение |
|----------|------------|
| [MINSTART.md](MINSTART.md) | Пошаговое руководство по production-развёртыванию Validator + Sentry + RPC на трёх VPS |
| [umeshctl](https://github.com/opscores/umesh-cli) | Отдельный репозиторий CLI; пример genesis-плана — `tools/umeshctl/examples/genesis-plan.yaml` (источник истины) |
| [justfile](justfile) | Автоматизация сборки и запуска (`just build`, `just run-validator`, `just clean`) |
