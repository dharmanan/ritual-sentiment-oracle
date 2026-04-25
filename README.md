# ritual-onchain-oracle

> **On-chain sentiment analysis powered entirely by Ritual's LLM Precompile (0x0802).**  
> No external APIs. No Chainlink. No off-chain relayers. The model runs inside a TEE — attested, verified, written to chain.

---

## What This Is

`ritual-onchain-oracle` is an autonomous agent + smart contract pair that demonstrates Ritual Chain's core value proposition: **AI inference as a native EVM operation**.

A Python agent collects market context (price data + headlines), then calls `analyzeSentiment()` on-chain. The contract forwards the prompt to the **LLM Precompile at `0x0802`** — which runs `GLM-4.7-FP8` inside a Trusted Execution Environment. The result is attested, delivered via async callback, and written directly to contract state. No middleware. No trust assumptions.

```
Python Agent
    │
    ▼  analyzeSentiment(asset, context)
SentimentOracle.sol
    │
    ▼  ILLMPrecompile(0x0802).requestCompletion(prompt)
GLM-4.7-FP8 (TEE)
    │
    ▼  onSentimentResult(requestId, result)  ← async callback
SentimentOracle.sol  →  score + signal stored on-chain
```

---

## Architecture

| Component | Description |
|---|---|
| `contracts/SentimentOracle.sol` | EVM++ contract. Sends prompts to 0x0802, parses structured LLM output, emits `SentimentFulfilled` events |
| `agent/oracle_agent.py` | Python agent. Fetches context, submits tx, polls result |
| `scripts/deploy.js` | Hardhat deploy script for Ritual testnet |

### Why Ritual's LLM Precompile?

Traditional oracle setups require: off-chain computation → signature verification → on-chain settlement. This involves trust in the off-chain operator, latency from multiple hops, and extra infrastructure.

With Ritual's 0x0802 precompile, the LLM is a **first-class EVM citizen**:
- Inference runs inside a TEE with hardware attestation
- Result delivered to the contract in the same async flow as any other precompile
- Zero external API keys, zero off-chain trust surface

---

## Quickstart

### 1. Clone & Install

```bash
git clone https://github.com/YOUR_USERNAME/ritual-onchain-oracle
cd ritual-onchain-oracle
npm install
pip install web3 requests python-dotenv
```

### 2. Configure

```bash
cp .env.example .env
# Fill in PRIVATE_KEY and RITUAL_RPC_URL
```

### 3. Deploy Contract

```bash
npm run deploy
# Copy the deployed address into .env as CONTRACT_ADDRESS
```

### 4. Run Agent

```bash
python agent/oracle_agent.py
```

---

## On-Chain Output Format

The contract enforces a structured output from the LLM:

```
SCORE:<-1|0|1> SIGNAL:<BUY|SELL|HOLD> REASON:<max 20 words>
```

This is parsed on-chain by `_parse()` — no off-chain post-processing.

---

## Roadmap

- [x] LLM Precompile integration (0x0802)
- [x] Structured on-chain output parsing
- [x] Python agent with real market context
- [ ] Deploy on Ritual Testnet (pending testnet RITUAL for gas)
- [ ] HTTP Precompile (0x0801) for fully on-chain data fetch
- [ ] Scheduler precompile for autonomous periodic execution
- [ ] Multi-asset aggregation + on-chain signal history

---

## Stack

- **Ritual Chain** — AI-native L1 (EVM++), Chain ID `1979`
- **LLM Precompile 0x0802** — TEE-hosted GLM-4.7-FP8, 64K context
- **AsyncDelivery** — `0x5A16214fF555848411544b005f7Ac063742f39F6`
- **Solidity 0.8.20** — EVM++ compatible contract
- **Python + Web3.py** — off-chain agent
- **Hardhat** — compile & deploy tooling

### Chain Reference

| Property | Value |
|---|---|
| Chain ID | `1979` |
| RPC | `https://rpc.ritualfoundation.org` |
| Explorer | `https://explorer.ritualfoundation.org` |
| Currency | RITUAL (18 decimals) |

---

## Status

**Testnet-ready.** Contract compiles and is staged for deployment.  
Pending testnet RITUAL tokens for gas to complete on-chain testing.

---

## License

MIT
