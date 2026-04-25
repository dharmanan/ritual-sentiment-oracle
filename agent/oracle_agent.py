"""
ritual-onchain-oracle · Python Agent
=====================================
Collects market context from public sources and submits it
to SentimentOracle.sol via Ritual Chain RPC.

Flow:
  1. Fetch price + volume data  (CoinGecko public API)
  2. Fetch recent headlines     (CryptoPanic public API)
  3. Summarise into a context string
  4. Call analyzeSentiment() on the deployed contract
  5. Poll for the callback result and log it

Dependencies:
  pip install web3 requests python-dotenv
"""

import os
import time
import json
import requests
from datetime import datetime, timezone
from web3 import Web3
from dotenv import load_dotenv

load_dotenv()

# ── Config ────────────────────────────────────────────────────────────────────

RPC_URL          = os.getenv("RITUAL_RPC_URL", "https://rpc.ritualfoundation.org")
PRIVATE_KEY      = os.getenv("PRIVATE_KEY")           # deployer / owner wallet
CONTRACT_ADDRESS = os.getenv("CONTRACT_ADDRESS")       # deployed SentimentOracle

ASSETS = ["ETH", "BTC"]       # assets to analyse each cycle
POLL_INTERVAL  = 60            # seconds between agent cycles
CALLBACK_WAIT  = 30            # seconds to wait for LLM callback

# ── ABI (minimal — only functions the agent calls) ────────────────────────────

ABI = json.loads("""
[
  {
    "inputs": [
      {"name": "asset",   "type": "string"},
      {"name": "context", "type": "string"}
    ],
    "name": "analyzeSentiment",
    "outputs": [{"name": "requestId", "type": "bytes32"}],
    "stateMutability": "nonpayable",
    "type": "function"
  },
  {
    "inputs": [{"name": "asset", "type": "string"}],
    "name": "getLatest",
    "outputs": [
      {
        "components": [
          {"name": "asset",     "type": "string"},
          {"name": "score",     "type": "int8"},
          {"name": "signal",    "type": "string"},
          {"name": "reasoning", "type": "string"},
          {"name": "timestamp", "type": "uint256"},
          {"name": "fulfilled", "type": "bool"}
        ],
        "name": "",
        "type": "tuple"
      }
    ],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "anonymous": false,
    "inputs": [
      {"indexed": true,  "name": "requestId", "type": "bytes32"},
      {"indexed": false, "name": "asset",     "type": "string"},
      {"indexed": false, "name": "score",     "type": "int8"},
      {"indexed": false, "name": "signal",    "type": "string"}
    ],
    "name": "SentimentFulfilled",
    "type": "event"
  }
]
""")

# ── Web3 setup ────────────────────────────────────────────────────────────────

w3       = Web3(Web3.HTTPProvider(RPC_URL))
account  = w3.eth.account.from_key(PRIVATE_KEY)
contract = w3.eth.contract(
    address=Web3.to_checksum_address(CONTRACT_ADDRESS),
    abi=ABI
)

# ── Data fetchers ─────────────────────────────────────────────────────────────

COINGECKO_IDS = {"ETH": "ethereum", "BTC": "bitcoin"}

def fetch_price_context(asset: str) -> str:
    """Returns a one-line price/volume summary from CoinGecko."""
    coin_id = COINGECKO_IDS.get(asset, asset.lower())
    try:
        url = (
            f"https://api.coingecko.com/api/v3/coins/{coin_id}"
            "?localization=false&tickers=false&community_data=false&developer_data=false"
        )
        r = requests.get(url, timeout=10)
        r.raise_for_status()
        data = r.json()["market_data"]

        price        = data["current_price"]["usd"]
        change_24h   = data["price_change_percentage_24h"]
        volume       = data["total_volume"]["usd"] / 1_000_000  # in millions
        market_cap   = data["market_cap"]["usd"] / 1_000_000_000

        direction = "up" if change_24h > 0 else "down"
        return (
            f"{asset} is trading at ${price:,.2f}, "
            f"{direction} {abs(change_24h):.2f}% in the last 24h. "
            f"24h volume: ${volume:.0f}M. Market cap: ${market_cap:.1f}B."
        )
    except Exception as e:
        return f"{asset} price data unavailable ({e})."


def fetch_headline_context(asset: str) -> str:
    """Returns the top 3 recent headlines from CryptoPanic (public feed)."""
    try:
        url = f"https://cryptopanic.com/api/v1/posts/?auth_token=public&currencies={asset}&kind=news"
        r = requests.get(url, timeout=10)
        r.raise_for_status()
        posts = r.json().get("results", [])[:3]
        headlines = [p["title"] for p in posts]
        if not headlines:
            return "No recent headlines found."
        return "Recent headlines: " + " | ".join(headlines)
    except Exception as e:
        return f"Headlines unavailable ({e})."


def build_context(asset: str) -> str:
    price_ctx    = fetch_price_context(asset)
    headline_ctx = fetch_headline_context(asset)
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    return f"[{ts}] {price_ctx} {headline_ctx}"

# ── Contract interaction ───────────────────────────────────────────────────────

def submit_analysis(asset: str, context: str) -> str:
    """Calls analyzeSentiment() and returns the requestId hex."""
    nonce = w3.eth.get_transaction_count(account.address)
    tx = contract.functions.analyzeSentiment(asset, context).build_transaction({
        "from":     account.address,
        "nonce":    nonce,
        "gas":      500_000,
        "gasPrice": w3.eth.gas_price,
    })
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)

    # Extract requestId from logs
    logs = contract.events.SentimentRequested().process_receipt(receipt)
    if logs:
        request_id = logs[0]["args"]["requestId"].hex()
    else:
        request_id = tx_hash.hex()   # fallback

    print(f"  ↳ tx: {tx_hash.hex()}")
    print(f"  ↳ requestId: {request_id}")
    return request_id


def poll_result(asset: str, wait: int = CALLBACK_WAIT) -> dict | None:
    """Waits for the TEE callback and reads the on-chain result."""
    print(f"  ⏳ Waiting {wait}s for LLM callback...")
    time.sleep(wait)

    try:
        r = contract.functions.getLatest(asset).call()
        # r is a tuple: (asset, score, signal, reasoning, timestamp, fulfilled)
        return {
            "asset":     r[0],
            "score":     r[1],
            "signal":    r[2],
            "reasoning": r[3],
            "timestamp": r[4],
            "fulfilled": r[5],
        }
    except Exception as e:
        print(f"  ✗ Could not read result: {e}")
        return None

# ── Main loop ─────────────────────────────────────────────────────────────────

def run():
    print("=" * 60)
    print("  Ritual On-Chain Sentiment Oracle — Agent Started")
    print(f"  Wallet : {account.address}")
    print(f"  Chain  : {RPC_URL}")
    print(f"  Contract: {CONTRACT_ADDRESS}")
    print("=" * 60)

    while True:
        for asset in ASSETS:
            print(f"\n[{asset}] Building context...")
            context = build_context(asset)
            print(f"  Context: {context[:120]}...")

            print(f"[{asset}] Submitting to SentimentOracle...")
            try:
                submit_analysis(asset, context)
            except Exception as e:
                print(f"  ✗ Submission failed: {e}")
                continue

            result = poll_result(asset)
            if result and result["fulfilled"]:
                score_label = {1: "🟢 BULLISH", 0: "⚪ NEUTRAL", -1: "🔴 BEARISH"}.get(result["score"], "?")
                print(f"\n  ✅ Result for {asset}:")
                print(f"     Sentiment : {score_label}")
                print(f"     Signal    : {result['signal']}")
                print(f"     Reasoning : {result['reasoning']}")
            else:
                print(f"  ⚠ Result not yet fulfilled (callback pending)")

        print(f"\n⏸  Sleeping {POLL_INTERVAL}s before next cycle...\n")
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    run()
