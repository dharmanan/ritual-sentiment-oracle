"""Ritual market watcher helper CLI.

This script is intentionally a deploy/debug helper, not part of the core market
watcher logic. It discovers executors, checks RitualWallet balances, configures
tracked assets, schedules recurring watcher jobs, and inspects on-chain state.
"""

import argparse
import json
import os
import time

from dotenv import load_dotenv
from web3 import Web3

load_dotenv()

RPC_URL = os.getenv("RITUAL_RPC_URL", "https://rpc.ritualfoundation.org")
PRIVATE_KEY = os.getenv("PRIVATE_KEY", "").strip()
CONTRACT_ADDRESS = os.getenv("CONTRACT_ADDRESS", "").strip()

DEFAULT_SYMBOL = os.getenv("ASSET_SYMBOL", "ETH").strip().upper()
DEFAULT_COIN_ID = os.getenv("COIN_ID", "ethereum").strip()
DEFAULT_CADENCE = int(os.getenv("SCHEDULE_CADENCE", "360"))
DEFAULT_ANALYSIS_DELAY = int(os.getenv("ANALYSIS_DELAY", "120"))
DEFAULT_NUM_CALLS = int(os.getenv("NUM_CALLS", "24"))
DEFAULT_GAS_LIMIT = int(os.getenv("SCHEDULE_GAS_LIMIT", "2200000"))
DEFAULT_SCHEDULER_TTL = int(os.getenv("SCHEDULER_TTL", "240"))

HTTP_EXECUTOR = os.getenv("HTTP_EXECUTOR", "").strip()
LLM_EXECUTOR = os.getenv("LLM_EXECUTOR", "").strip()

CHAIN_ID = 1979
HTTP_CALL_CAPABILITY = 0
LLM_CAPABILITY = 1

TEESERVICE_REGISTRY = Web3.to_checksum_address("0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F")
RITUAL_WALLET = Web3.to_checksum_address("0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948")
ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"

CONTRACT_ABI = json.loads(
    """
[
  {
    "inputs": [
      {"name": "symbol", "type": "string"},
      {"name": "coinId", "type": "string"},
      {"name": "httpExecutor", "type": "address"},
      {"name": "llmExecutor", "type": "address"}
    ],
    "name": "configureAsset",
    "outputs": [{"name": "assetId", "type": "bytes32"}],
    "stateMutability": "nonpayable",
    "type": "function"
  },
  {
    "inputs": [
      {"name": "assetId", "type": "bytes32"},
      {"name": "cadence", "type": "uint32"},
      {"name": "analysisDelay", "type": "uint32"},
      {"name": "numCalls", "type": "uint32"},
      {"name": "gasLimit", "type": "uint32"},
      {"name": "schedulerTtl", "type": "uint32"},
      {"name": "maxFeePerGas", "type": "uint256"},
      {"name": "maxPriorityFeePerGas", "type": "uint256"}
    ],
    "name": "scheduleAssetWatcher",
    "outputs": [],
    "stateMutability": "nonpayable",
    "type": "function"
  },
  {
    "inputs": [{"name": "assetId", "type": "bytes32"}],
    "name": "cancelAssetWatcher",
    "outputs": [],
    "stateMutability": "nonpayable",
    "type": "function"
  },
  {
    "inputs": [{"name": "lockBlocks", "type": "uint256"}],
    "name": "depositScheduleFees",
    "outputs": [],
    "stateMutability": "payable",
    "type": "function"
  },
  {
    "inputs": [{"name": "assetId", "type": "bytes32"}],
    "name": "fetchNow",
    "outputs": [],
    "stateMutability": "nonpayable",
    "type": "function"
  },
  {
    "inputs": [{"name": "assetId", "type": "bytes32"}],
    "name": "analyzeNow",
    "outputs": [],
    "stateMutability": "nonpayable",
    "type": "function"
  },
  {
    "inputs": [{"name": "assetId", "type": "bytes32"}],
    "name": "getAssetConfig",
    "outputs": [
      {
        "components": [
          {"name": "symbol", "type": "string"},
          {"name": "coinId", "type": "string"},
          {"name": "httpExecutor", "type": "address"},
          {"name": "llmExecutor", "type": "address"},
          {"name": "fetchScheduleId", "type": "uint256"},
          {"name": "analysisScheduleId", "type": "uint256"},
          {"name": "configured", "type": "bool"}
        ],
        "name": "",
        "type": "tuple"
      }
    ],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "inputs": [{"name": "assetId", "type": "bytes32"}],
    "name": "getMarketSnapshot",
    "outputs": [
      {
        "components": [
          {"name": "symbol", "type": "string"},
          {"name": "summary", "type": "string"},
          {"name": "bodyHash", "type": "bytes32"},
          {"name": "statusCode", "type": "uint16"},
          {"name": "bodySize", "type": "uint256"},
          {"name": "errorMessage", "type": "string"},
          {"name": "fetchedAt", "type": "uint256"},
          {"name": "fetchExecutionIndex", "type": "uint256"},
          {"name": "available", "type": "bool"}
        ],
        "name": "",
        "type": "tuple"
      }
    ],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "inputs": [{"name": "assetId", "type": "bytes32"}],
    "name": "getSentimentResult",
    "outputs": [
      {
        "components": [
          {"name": "symbol", "type": "string"},
          {"name": "score", "type": "int8"},
          {"name": "signal", "type": "string"},
          {"name": "reasoning", "type": "string"},
          {"name": "rawResponse", "type": "string"},
          {"name": "errorMessage", "type": "string"},
          {"name": "model", "type": "string"},
          {"name": "executor", "type": "address"},
          {"name": "analyzedAt", "type": "uint256"},
          {"name": "analysisExecutionIndex", "type": "uint256"},
          {"name": "snapshotTimestamp", "type": "uint256"},
          {"name": "fulfilled", "type": "bool"},
          {"name": "hasError", "type": "bool"}
        ],
        "name": "",
        "type": "tuple"
      }
    ],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "inputs": [{"name": "symbol", "type": "string"}],
    "name": "assetIdFor",
    "outputs": [{"name": "", "type": "bytes32"}],
    "stateMutability": "pure",
    "type": "function"
  },
  {
    "inputs": [],
    "name": "owner",
    "outputs": [{"name": "", "type": "address"}],
    "stateMutability": "view",
    "type": "function"
  }
]
"""
)

REGISTRY_ABI = json.loads(
    """
[
  {
    "inputs": [],
    "name": "getCapabilityIndexStatus",
    "outputs": [
      {"name": "cursor", "type": "uint256"},
      {"name": "total", "type": "uint256"},
      {"name": "initialized", "type": "bool"},
      {"name": "finalized", "type": "bool"}
    ],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "inputs": [
      {"name": "capability", "type": "uint8"},
      {"name": "checkValidity", "type": "bool"},
      {"name": "seed", "type": "uint256"},
      {"name": "maxProbes", "type": "uint256"}
    ],
    "name": "pickServiceByCapability",
    "outputs": [
      {"name": "teeAddress", "type": "address"},
      {"name": "found", "type": "bool"}
    ],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "inputs": [
      {"name": "capability", "type": "uint8"},
      {"name": "checkValidity", "type": "bool"}
    ],
    "name": "getServicesByCapability",
    "outputs": [
      {
        "components": [
          {
            "components": [
              {"name": "paymentAddress", "type": "address"},
              {"name": "teeAddress", "type": "address"},
              {"name": "teeType", "type": "uint8"},
              {"name": "publicKey", "type": "bytes"},
              {"name": "endpoint", "type": "string"},
              {"name": "certPubKeyHash", "type": "bytes32"},
              {"name": "capability", "type": "uint8"}
            ],
            "name": "node",
            "type": "tuple"
          },
          {"name": "isValid", "type": "bool"},
          {"name": "workloadId", "type": "bytes32"}
        ],
        "name": "",
        "type": "tuple[]"
      }
    ],
    "stateMutability": "view",
    "type": "function"
  }
]
"""
)

WALLET_ABI = json.loads(
    """
[
  {
    "inputs": [{"name": "user", "type": "address"}],
    "name": "balanceOf",
    "outputs": [{"name": "", "type": "uint256"}],
    "stateMutability": "view",
    "type": "function"
  },
  {
    "inputs": [{"name": "user", "type": "address"}],
    "name": "lockUntil",
    "outputs": [{"name": "", "type": "uint256"}],
    "stateMutability": "view",
    "type": "function"
  }
]
"""
)


def require_private_key() -> None:
    if not PRIVATE_KEY or PRIVATE_KEY == "your_wallet_private_key_here":
        raise RuntimeError("Set PRIVATE_KEY in .env before using the helper.")
    normalized = PRIVATE_KEY[2:] if PRIVATE_KEY.startswith("0x") else PRIVATE_KEY
    if len(normalized) != 64:
        raise RuntimeError("PRIVATE_KEY must be 32 bytes / 64 hex chars.")


def require_contract_address() -> None:
    if not CONTRACT_ADDRESS or CONTRACT_ADDRESS == "deployed_contract_address_here":
        raise RuntimeError("Set CONTRACT_ADDRESS in .env after deploying the watcher contract.")


w3 = Web3(Web3.HTTPProvider(RPC_URL))
require_private_key()
account = w3.eth.account.from_key(PRIVATE_KEY)
registry = w3.eth.contract(address=TEESERVICE_REGISTRY, abi=REGISTRY_ABI)
ritual_wallet = w3.eth.contract(address=RITUAL_WALLET, abi=WALLET_ABI)

contract = None
if CONTRACT_ADDRESS and CONTRACT_ADDRESS != "deployed_contract_address_here":
    contract = w3.eth.contract(address=Web3.to_checksum_address(CONTRACT_ADDRESS), abi=CONTRACT_ABI)


def wallet_status(target_address: str) -> dict:
    balance = ritual_wallet.functions.balanceOf(target_address).call()
    lock_until = ritual_wallet.functions.lockUntil(target_address).call()
    current_block = w3.eth.block_number
    return {
        "balance_wei": balance,
        "lock_until": lock_until,
        "current_block": current_block,
        "locked": current_block < lock_until,
    }


def select_executor(capability: int, provided: str = "") -> str:
    if provided:
        return Web3.to_checksum_address(provided)

    _, _, _, finalized = registry.functions.getCapabilityIndexStatus().call()
    if finalized:
        seed = int(time.time())
        executor, found = registry.functions.pickServiceByCapability(capability, True, seed, 5).call()
        if found and executor != ZERO_ADDRESS:
            return Web3.to_checksum_address(executor)

    services = registry.functions.getServicesByCapability(capability, True).call()
    for service in services:
        executor = service[0][1]
        if executor != ZERO_ADDRESS:
            return Web3.to_checksum_address(executor)

    raise RuntimeError(f"No valid executor found for capability {capability}.")


def fee_params() -> dict:
    latest_block = w3.eth.get_block("latest")
    base_fee = int(latest_block.get("baseFeePerGas", w3.eth.gas_price))
    try:
        priority_fee = int(w3.eth.max_priority_fee)
    except Exception:
        priority_fee = Web3.to_wei(1, "gwei")

    return {
        "chainId": CHAIN_ID,
        "type": 2,
        "maxFeePerGas": base_fee * 2 + priority_fee,
        "maxPriorityFeePerGas": priority_fee,
    }


def asset_id(symbol: str) -> str:
    return Web3.keccak(text=symbol.upper()).hex()


def normalized_symbol(symbol: str) -> str:
    return symbol.strip().upper()


def contract_ref():
    require_contract_address()
    if contract is None:
        raise RuntimeError("Contract not initialized.")
    return contract


def send_transaction(function_call, value: int = 0, gas: int = 1_500_000):
    tx = function_call.build_transaction(
        {
            "from": account.address,
            "nonce": w3.eth.get_transaction_count(account.address),
            "gas": gas,
            "value": value,
            **fee_params(),
        }
    )
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=180)
    return tx_hash.hex(), receipt


def print_wallet(label: str, status: dict) -> None:
    print(f"{label} balance : {Web3.from_wei(status['balance_wei'], 'ether')} RITUAL")
    print(f"{label} lock    : block {status['lock_until']} (current {status['current_block']})")


def inspect_command() -> None:
    print("=" * 72)
    print("Ritual Scheduled Market Watcher Helper")
    print(f"Owner wallet     : {account.address}")
    print(f"RPC              : {RPC_URL}")
    print_wallet("Owner wallet", wallet_status(account.address))

    http_executor = select_executor(HTTP_CALL_CAPABILITY, HTTP_EXECUTOR)
    llm_executor = select_executor(LLM_CAPABILITY, LLM_EXECUTOR)
    print(f"HTTP executor    : {http_executor}")
    print(f"LLM executor     : {llm_executor}")

    if contract is not None:
        print(f"Contract         : {contract.address}")
        owner = contract.functions.owner().call()
        print(f"Contract owner   : {owner}")
        print_wallet("Contract", wallet_status(contract.address))

    print("=" * 72)


def configure_command(args) -> None:
    watcher = contract_ref()
    symbol = normalized_symbol(args.symbol)
    http_executor = select_executor(HTTP_CALL_CAPABILITY, args.http_executor or HTTP_EXECUTOR)
    llm_executor = select_executor(LLM_CAPABILITY, args.llm_executor or LLM_EXECUTOR)

    tx_hash, _ = send_transaction(
        watcher.functions.configureAsset(symbol, args.coin_id, http_executor, llm_executor),
        gas=900_000,
    )

    print(f"Configured asset  : {symbol}")
    print(f"CoinGecko id      : {args.coin_id}")
    print(f"Asset id          : {asset_id(symbol)}")
    print(f"HTTP executor     : {http_executor}")
    print(f"LLM executor      : {llm_executor}")
    print(f"Transaction hash  : {tx_hash}")


def fund_command(args) -> None:
    watcher = contract_ref()
    value = Web3.to_wei(args.amount, "ether")
    tx_hash, _ = send_transaction(
        watcher.functions.depositScheduleFees(args.lock_blocks),
        value=value,
        gas=250_000,
    )
    print(f"Funded contract RitualWallet with {args.amount} RITUAL-equivalent native tokens")
    print(f"Transaction hash  : {tx_hash}")


def schedule_command(args) -> None:
    watcher = contract_ref()
    symbol = normalized_symbol(args.symbol)
    current_fees = fee_params()
    schedule_max_fee = args.schedule_max_fee_wei or current_fees["maxFeePerGas"]
    schedule_priority_fee = args.schedule_priority_fee_wei or current_fees["maxPriorityFeePerGas"]

    if args.analysis_delay >= args.cadence:
        raise RuntimeError("analysis-delay must be lower than cadence.")
    if args.analysis_delay < 100:
        print("Warning: analysis-delay below 100 blocks can race HTTP settlement on Ritual testnet.")
    if args.scheduler_ttl < 180:
        print("Warning: scheduler-ttl below 180 blocks can be too low for async settlement, especially for LLM analysis.")

    tx_hash, _ = send_transaction(
        watcher.functions.scheduleAssetWatcher(
            Web3.to_bytes(hexstr=asset_id(symbol)),
            args.cadence,
            args.analysis_delay,
            args.num_calls,
            args.gas_limit,
            args.scheduler_ttl,
            schedule_max_fee,
            schedule_priority_fee,
        ),
        gas=1_200_000,
    )

    print(f"Scheduled watcher : {symbol}")
    print(f"Asset id          : {asset_id(symbol)}")
    print(f"Cadence           : {args.cadence} blocks")
    print(f"Analysis delay    : {args.analysis_delay} blocks")
    print(f"Num calls         : {args.num_calls}")
    print(f"Transaction hash  : {tx_hash}")


def cancel_command(args) -> None:
    watcher = contract_ref()
    symbol = normalized_symbol(args.symbol)
    tx_hash, _ = send_transaction(
        watcher.functions.cancelAssetWatcher(Web3.to_bytes(hexstr=asset_id(symbol))),
        gas=500_000,
    )
    print(f"Cancelled watcher for {symbol}")
    print(f"Transaction hash  : {tx_hash}")


def fetch_now_command(args) -> None:
    watcher = contract_ref()
    symbol = normalized_symbol(args.symbol)
    tx_hash, _ = send_transaction(
        watcher.functions.fetchNow(Web3.to_bytes(hexstr=asset_id(symbol))),
        gas=1_500_000,
    )
    print(f"Triggered fetchNow for {symbol}")
    print(f"Transaction hash  : {tx_hash}")


def analyze_now_command(args) -> None:
    watcher = contract_ref()
    symbol = normalized_symbol(args.symbol)
    tx_hash, _ = send_transaction(
        watcher.functions.analyzeNow(Web3.to_bytes(hexstr=asset_id(symbol))),
        gas=1_800_000,
    )
    print(f"Triggered analyzeNow for {symbol}")
    print(f"Transaction hash  : {tx_hash}")


def show_command(args) -> None:
    watcher = contract_ref()
    symbol = normalized_symbol(args.symbol)
    asset_key = Web3.to_bytes(hexstr=asset_id(symbol))
    config = watcher.functions.getAssetConfig(asset_key).call()
    snapshot = watcher.functions.getMarketSnapshot(asset_key).call()
    sentiment = watcher.functions.getSentimentResult(asset_key).call()

    print("Asset config")
    print(f"  symbol            : {config[0]}")
    print(f"  coin id           : {config[1]}")
    print(f"  http executor     : {config[2]}")
    print(f"  llm executor      : {config[3]}")
    print(f"  fetch schedule id : {config[4]}")
    print(f"  analysis schedule : {config[5]}")
    print(f"  configured        : {config[6]}")
    print("")
    print("Latest snapshot")
    print(f"  summary           : {snapshot[1]}")
    print(f"  body hash         : {snapshot[2].hex()}")
    print(f"  status code       : {snapshot[3]}")
    print(f"  body size         : {snapshot[4]}")
    print(f"  error             : {snapshot[5]}")
    print(f"  fetched at        : {snapshot[6]}")
    print(f"  execution index   : {snapshot[7]}")
    print(f"  available         : {snapshot[8]}")
    print("")
    print("Latest sentiment")
    print(f"  score             : {sentiment[1]}")
    print(f"  signal            : {sentiment[2]}")
    print(f"  reasoning         : {sentiment[3]}")
    print(f"  raw response      : {sentiment[4]}")
    print(f"  error             : {sentiment[5]}")
    print(f"  model             : {sentiment[6]}")
    print(f"  executor          : {sentiment[7]}")
    print(f"  analyzed at       : {sentiment[8]}")
    print(f"  execution index   : {sentiment[9]}")
    print(f"  snapshot ts       : {sentiment[10]}")
    print(f"  fulfilled         : {sentiment[11]}")
    print(f"  has error         : {sentiment[12]}")


def parse_args():
    parser = argparse.ArgumentParser(description="Ritual market watcher deploy/debug helper")
    subparsers = parser.add_subparsers(dest="command")

    subparsers.add_parser("inspect", help="Inspect executors, balances, and current contract owner")

    configure = subparsers.add_parser("configure", help="Configure one tracked asset")
    configure.add_argument("--symbol", default=DEFAULT_SYMBOL)
    configure.add_argument("--coin-id", default=DEFAULT_COIN_ID)
    configure.add_argument("--http-executor", default="")
    configure.add_argument("--llm-executor", default="")

    fund = subparsers.add_parser("fund", help="Deposit native tokens into the contract's RitualWallet")
    fund.add_argument("--amount", type=float, required=True)
    fund.add_argument("--lock-blocks", type=int, default=50000)

    schedule = subparsers.add_parser("schedule", help="Schedule recurring fetch and analysis")
    schedule.add_argument("--symbol", default=DEFAULT_SYMBOL)
    schedule.add_argument("--cadence", type=int, default=DEFAULT_CADENCE)
    schedule.add_argument("--analysis-delay", type=int, default=DEFAULT_ANALYSIS_DELAY)
    schedule.add_argument("--num-calls", type=int, default=DEFAULT_NUM_CALLS)
    schedule.add_argument("--gas-limit", type=int, default=DEFAULT_GAS_LIMIT)
    schedule.add_argument("--scheduler-ttl", type=int, default=DEFAULT_SCHEDULER_TTL)
    schedule.add_argument("--schedule-max-fee-wei", type=int, default=0)
    schedule.add_argument("--schedule-priority-fee-wei", type=int, default=0)

    cancel = subparsers.add_parser("cancel", help="Cancel both schedules for an asset")
    cancel.add_argument("--symbol", default=DEFAULT_SYMBOL)

    fetch_now = subparsers.add_parser("fetch-now", help="Manually trigger the HTTP fetch phase")
    fetch_now.add_argument("--symbol", default=DEFAULT_SYMBOL)

    analyze_now = subparsers.add_parser("analyze-now", help="Manually trigger the LLM analysis phase")
    analyze_now.add_argument("--symbol", default=DEFAULT_SYMBOL)

    show = subparsers.add_parser("show", help="Show config, snapshot, and sentiment for an asset")
    show.add_argument("--symbol", default=DEFAULT_SYMBOL)

    return parser.parse_args()


def main() -> None:
    args = parse_args()
    command = args.command or "inspect"

    if command == "inspect":
        inspect_command()
    elif command == "configure":
        configure_command(args)
    elif command == "fund":
        fund_command(args)
    elif command == "schedule":
        schedule_command(args)
    elif command == "cancel":
        cancel_command(args)
    elif command == "fetch-now":
        fetch_now_command(args)
    elif command == "analyze-now":
        analyze_now_command(args)
    elif command == "show":
        show_command(args)
    else:
        raise RuntimeError(f"Unsupported command: {command}")


if __name__ == "__main__":
    main()
