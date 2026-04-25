# ritual-sentiment-oracle

Autonomous on-chain market watcher for Ritual.

This repository demonstrates a Ritual-native market intelligence workflow built around the chain's core execution primitives. It fetches market data through Ritual HTTP, normalizes the payload through Ritual JQ, runs sentiment analysis through Ritual LLM, and stores structured outputs on-chain on a recurring schedule.

## What This Repository Demonstrates

- A two-phase Ritual workflow split across scheduled fetch and scheduled analysis
- On-chain market snapshots generated from HTTP + JQ precompiles
- Structured `SCORE / SIGNAL / REASON` outputs generated through the LLM precompile
- A clean operator surface for funding, configuration, scheduling, and inspection
- Local mocked validation that proves the core contract flow before faucet-funded live execution

## Review Snapshot

- Contract surface: scheduled HTTP fetch, deterministic JQ extraction, scheduled LLM analysis
- Local proof: compile passes, mocked unit tests pass, helper syntax check passes, CI is configured
- Live proof pending: Ritual testnet deployment and recurring execution require faucet-funded RITUAL

## Core Workflow

- HTTP precompile `0x0801` fetches external market data
- JQ precompile `0x0803` extracts deterministic summary fields on-chain
- LLM precompile `0x0802` produces structured sentiment output
- Scheduler automates recurring fetch and analysis jobs
- Python is used as an operator helper CLI for funding, configuration, scheduling, and inspection

## Architecture

Ritual does not allow two short-running async precompile calls in the same transaction, so the watcher is split into two scheduled phases.

```text
Phase 1: Scheduled fetch
    Scheduler -> executeFetch(assetId)
                        -> HTTP precompile 0x0801
                        -> JQ precompile 0x0803
                        -> store normalized market snapshot on-chain

Phase 2: Scheduled analysis
    Scheduler -> executeAnalysis(assetId)
                        -> LLM precompile 0x0802
                        -> store SCORE / SIGNAL / REASON on-chain
```

This follows Ritual's documented model:

- one short-running async precompile per transaction
- EIP-1559 transactions only
- executor selection through `TEEServiceRegistry`
- recurring automation through the Scheduler contract
- fee escrow through `RitualWallet`

## Project Layout

| Path | Purpose |
|---|---|
| `contracts/ScheduledMarketWatcher.sol` | `ScheduledMarketWatcher` contract with scheduled HTTP/JQ and LLM phases |
| `agent/oracle_agent.py` | Helper CLI for funding, configuration, scheduling, and inspection |
| `scripts/deploy.js` | Deployment script for Ritual testnet |

## Validation

```bash
npm run validate
```

Current validation scope:

- `hardhat compile`
- `hardhat test test/ScheduledMarketWatcher.test.js`
- Python helper syntax check

These tests run locally with mocked Ritual system contracts at the fixed precompile and scheduler addresses, so the core watcher logic can be validated without faucet-funded tokens.

GitHub Actions can run the same validation command on every push and pull request.

## Live Ritual Testnet Status

This repository does not currently have faucet-funded testnet RITUAL, so it does not claim a live end-to-end Ritual testnet proof yet.

That limitation is explicit by design: the repo is meant to be technically reviewable now, while staying honest about what still requires live network funding.

Once faucet access is available, this repository will add:

- live deploy verification on Ritual testnet
- funded `RitualWallet` execution checks
- recurring scheduler smoke tests with captured on-chain results

## Quickstart

### 1. Install

```bash
npm install
pip install web3 python-dotenv
```

### 2. Configure

```bash
cp .env.example .env
```

Fill in:

- `PRIVATE_KEY`
- `RITUAL_RPC_URL`

After deploy, also fill in:

- `CONTRACT_ADDRESS`

### 3. Deploy

```bash
npm run deploy
```

Before asking for faucet access or sharing the repo, run the local validation suite:

```bash
npm run validate
```

### 4. Inspect available executors and balances

```bash
npm run helper:inspect
```

### 5. Configure a tracked asset

```bash
npm run helper:configure -- --symbol ETH --coin-id ethereum
```

### 6. Fund the contract's RitualWallet

```bash
python agent/oracle_agent.py fund --amount 0.05 --lock-blocks 50000
```

### 7. Schedule recurring jobs

```bash
npm run helper:schedule -- --symbol ETH
```

Safe starter values in this repo are intentionally conservative:

- `SCHEDULE_CADENCE=360`
- `ANALYSIS_DELAY=120`
- `SCHEDULER_TTL=240`

These defaults are chosen to leave room for short-running async settlement on Ritual rather than optimize for speed.

### 8. Inspect stored snapshot and analysis

```bash
python agent/oracle_agent.py show --symbol ETH
```

## Ritual-Native Design

- Market data fetches are executed through Ritual's HTTP precompile.
- Deterministic normalization is handled on-chain through the JQ precompile.
- Recurring execution cadence is owned by the Scheduler contract.
- Structured sentiment output is stored on-chain after LLM analysis.
- Python remains outside the core business logic and serves only as operator tooling.

## Current Limits

- Runtime behavior is validated with local mocked precompile and scheduler tests, not with live funded testnet execution yet.
- A live deploy is still required to prove the schedule timing on real Ritual testnet conditions.
- The current market snapshot is sourced from CoinGecko only; multi-source context would be stronger.

## Current Status

- [x] Scheduled HTTP + JQ phase added
- [x] Scheduled LLM phase added
- [x] Python reduced to helper CLI
- [x] Local mocked unit tests cover scheduler, fetch, and analysis flows
- [x] Compile, local unit tests, and helper syntax validation pass
- [ ] Live deploy and recurring execution proof need testnet RITUAL from the faucet

## License

MIT
