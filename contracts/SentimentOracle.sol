// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SentimentOracle
 * @notice On-chain sentiment analysis via Ritual's LLM Precompile (0x0802).
 *         No external APIs. No off-chain oracles. The model runs inside a TEE,
 *         result is attested and written directly to contract state.
 *
 * Architecture:
 *   [Python Agent] ──► analyzeSentiment()
 *                          │
 *                          ▼
 *                   LLM Precompile (0x0802)
 *                   GLM-4.7 inside TEE
 *                          │
 *                          ▼
 *                   onSentimentResult() callback
 *                          │
 *                          ▼
 *                   sentiment + signal stored on-chain
 */

interface ILLMPrecompile {
    struct LLMRequest {
        string model;       // model identifier (empty = default TEE model)
        string prompt;      // user prompt
        uint256 maxTokens;  // max completion tokens
        bool streaming;     // enable SSE streaming (EIP-712 signed tokens)
    }

    function requestCompletion(
        LLMRequest calldata req,
        address callbackContract,
        bytes4 callbackSelector
    ) external returns (bytes32 requestId);
}

contract SentimentOracle {
    // ─── Ritual precompile address ───────────────────────────────────────────
    address public constant LLM_PRECOMPILE = address(0x0802);
    address public constant ASYNC_DELIVERY  = 0x5A16214fF555848411544b005f7Ac063742f39F6;

    // ─── State ───────────────────────────────────────────────────────────────
    address public owner;

    struct SentimentResult {
        string  asset;          // e.g. "ETH", "BTC"
        int8    score;          // -1 = bearish, 0 = neutral, 1 = bullish
        string  signal;         // "BUY" | "SELL" | "HOLD"
        string  reasoning;      // LLM's one-line rationale
        uint256 timestamp;
        bool    fulfilled;
    }

    mapping(bytes32 => SentimentResult) public results;   // requestId → result
    bytes32[] public requestHistory;

    // latest per asset
    mapping(string => bytes32) public latestRequestId;

    // ─── Events ──────────────────────────────────────────────────────────────
    event SentimentRequested(bytes32 indexed requestId, string asset, uint256 timestamp);
    event SentimentFulfilled(bytes32 indexed requestId, string asset, int8 score, string signal);

    // ─── Errors ──────────────────────────────────────────────────────────────
    error NotOwner();
    error NotAsyncDelivery();
    error AlreadyFulfilled();

    // ─── Constructor ─────────────────────────────────────────────────────────
    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyAsyncDelivery() {
        if (msg.sender != ASYNC_DELIVERY) revert NotAsyncDelivery();
        _;
    }

    // ─── Core: Request ───────────────────────────────────────────────────────

    /**
     * @notice Submits a sentiment analysis request for a given asset + context.
     * @param asset     Token symbol, e.g. "ETH"
     * @param context   Recent headlines or on-chain data summary (injected by agent)
     */
    function analyzeSentiment(
        string calldata asset,
        string calldata context
    ) external onlyOwner returns (bytes32 requestId) {

        string memory prompt = _buildPrompt(asset, context);

        ILLMPrecompile.LLMRequest memory req = ILLMPrecompile.LLMRequest({
            model:     "",       // use default TEE-hosted GLM-4.7-FP8
            prompt:    prompt,
            maxTokens: 120,
            streaming: false
        });

        requestId = ILLMPrecompile(LLM_PRECOMPILE).requestCompletion(
            req,
            address(this),
            this.onSentimentResult.selector
        );

        results[requestId] = SentimentResult({
            asset:     asset,
            score:     0,
            signal:    "PENDING",
            reasoning: "",
            timestamp: block.timestamp,
            fulfilled: false
        });

        requestHistory.push(requestId);
        latestRequestId[asset] = requestId;

        emit SentimentRequested(requestId, asset, block.timestamp);
    }

    // ─── Core: Callback ──────────────────────────────────────────────────────

    /**
     * @notice Called by AsyncDelivery router once the TEE completes inference.
     *         Parses the LLM output and writes final state.
     * @dev Expected LLM output format (strict):
     *      SCORE:<-1|0|1> SIGNAL:<BUY|SELL|HOLD> REASON:<one sentence>
     */
    function onSentimentResult(
        bytes32 requestId,
        bytes calldata result
    ) external onlyAsyncDelivery {
        SentimentResult storage r = results[requestId];
        if (r.fulfilled) revert AlreadyFulfilled();

        string memory raw = string(result);
        (int8 score, string memory signal, string memory reason) = _parse(raw);

        r.score     = score;
        r.signal    = signal;
        r.reasoning = reason;
        r.fulfilled = true;

        emit SentimentFulfilled(requestId, r.asset, score, signal);
    }

    // ─── View Helpers ────────────────────────────────────────────────────────

    function getLatest(string calldata asset)
        external view
        returns (SentimentResult memory)
    {
        return results[latestRequestId[asset]];
    }

    function totalRequests() external view returns (uint256) {
        return requestHistory.length;
    }

    // ─── Internal: Prompt Builder ────────────────────────────────────────────

    function _buildPrompt(
        string memory asset,
        string memory context
    ) internal pure returns (string memory) {
        return string(abi.encodePacked(
            "You are a crypto market analyst. Analyze the following context for ",
            asset,
            " and respond ONLY in this exact format:\n",
            "SCORE:<-1 for bearish, 0 for neutral, 1 for bullish> ",
            "SIGNAL:<BUY|SELL|HOLD> ",
            "REASON:<one sentence max 20 words>\n\n",
            "Context:\n",
            context
        ));
    }

    // ─── Internal: Parser ────────────────────────────────────────────────────

    /**
     * @dev Minimal on-chain parser for structured LLM output.
     *      Production version should use a stricter byte-level parser.
     */
    function _parse(string memory raw)
        internal pure
        returns (int8 score, string memory signal, string memory reason)
    {
        bytes memory b = bytes(raw);

        // Default fallback
        score  = 0;
        signal = "HOLD";
        reason = raw;

        // Detect SCORE token
        for (uint i = 0; i + 7 < b.length; i++) {
            if (b[i]=='S' && b[i+1]=='C' && b[i+2]=='O' && b[i+3]=='R' && b[i+4]=='E' && b[i+5]==':') {
                if (b[i+6] == '-') {
                    score = -1;
                } else if (b[i+6] == '1') {
                    score = 1;
                } else {
                    score = 0;
                }
                break;
            }
        }

        // Detect SIGNAL token
        for (uint i = 0; i + 10 < b.length; i++) {
            if (b[i]=='S' && b[i+1]=='I' && b[i+2]=='G' && b[i+3]=='N' && b[i+4]=='A' && b[i+5]=='L' && b[i+6]==':') {
                if (b[i+7]=='B' && b[i+8]=='U' && b[i+9]=='Y') {
                    signal = "BUY";
                } else if (b[i+7]=='S' && b[i+8]=='E' && b[i+9]=='L' && b[i+10]=='L') {
                    signal = "SELL";
                } else {
                    signal = "HOLD";
                }
                break;
            }
        }
    }

    // ─── Admin ───────────────────────────────────────────────────────────────
    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }
}
