// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRitualWallet {
    function deposit(uint256 lockDuration) external payable;
}

interface IScheduler {
    function schedule(
        bytes calldata data,
        uint32 gas,
        uint32 startBlock,
        uint32 numCalls,
        uint32 frequency,
        uint32 ttl,
        uint256 maxFeePerGas,
        uint256 maxPriorityFeePerGas,
        uint256 value,
        address payer
    ) external returns (uint256 callId);

    function cancel(uint256 callId) external;

    function getCallState(uint256 callId) external view returns (uint8 state);
}

contract ScheduledMarketWatcher {
    address public constant HTTP_PRECOMPILE = 0x0000000000000000000000000000000000000801;
    address public constant LLM_PRECOMPILE = 0x0000000000000000000000000000000000000802;
    address public constant JQ_PRECOMPILE = 0x0000000000000000000000000000000000000803;
    address public constant RITUAL_WALLET = 0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948;
    address public constant SCHEDULER_ADDRESS = 0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B;

    string public constant DEFAULT_MODEL = "zai-org/GLM-4.7-FP8";
    uint256 public constant HTTP_TTL = 50;
    uint256 public constant LLM_TTL = 300;
    int256 public constant DEFAULT_MAX_COMPLETION_TOKENS = 4096;
    int256 public constant DEFAULT_TEMPERATURE = 200;

    string private constant COINGECKO_URL_PREFIX = "https://api.coingecko.com/api/v3/coins/";
    string private constant COINGECKO_URL_SUFFIX = "?localization=false&tickers=false&community_data=false&developer_data=false&sparkline=false";
    string private constant MARKET_JQ_FILTER = ".market_data | \"price_usd=\\(.current_price.usd) price_change_24h=\\(.price_change_percentage_24h) volume_usd=\\(.total_volume.usd) market_cap_usd=\\(.market_cap.usd)\"";

    address public owner;
    IScheduler public immutable scheduler;

    struct StorageRef {
        string platform;
        string path;
        string keyRef;
    }

    struct AssetConfig {
        string symbol;
        string coinId;
        address httpExecutor;
        address llmExecutor;
        uint256 fetchScheduleId;
        uint256 analysisScheduleId;
        bool configured;
    }

    struct MarketSnapshot {
        string symbol;
        string summary;
        bytes32 bodyHash;
        uint16 statusCode;
        uint256 bodySize;
        string errorMessage;
        uint256 fetchedAt;
        uint256 fetchExecutionIndex;
        bool available;
    }

    struct SentimentResult {
        string symbol;
        int8 score;
        string signal;
        string reasoning;
        string rawResponse;
        string errorMessage;
        string model;
        address executor;
        uint256 analyzedAt;
        uint256 analysisExecutionIndex;
        uint256 snapshotTimestamp;
        bool fulfilled;
        bool hasError;
    }

    mapping(bytes32 => AssetConfig) private assetConfigs;
    mapping(bytes32 => MarketSnapshot) private marketSnapshots;
    mapping(bytes32 => SentimentResult) private sentimentResults;
    bytes32[] public trackedAssets;

    event ScheduleFeesDeposited(uint256 amount, uint256 lockBlocks);
    event AssetConfigured(bytes32 indexed assetId, string symbol, string coinId, address httpExecutor, address llmExecutor);
    event WatcherScheduled(bytes32 indexed assetId, uint256 fetchScheduleId, uint256 analysisScheduleId, uint32 cadence, uint32 analysisDelay);
    event WatcherCancelled(bytes32 indexed assetId, uint256 fetchScheduleId, uint256 analysisScheduleId);
    event MarketSnapshotUpdated(bytes32 indexed assetId, string symbol, uint256 executionIndex, uint16 statusCode, bool available);
    event SentimentAnalyzed(bytes32 indexed assetId, string symbol, uint256 executionIndex, bool hasError, int8 score, string signal, string model);

    error NotOwner();
    error NotScheduler();
    error InvalidExecutor();
    error InvalidOwner();
    error AssetNotConfigured();
    error InvalidScheduleConfig();
    error PrecompileCallFailed();
    error SnapshotUnavailable();
    error EmptyCompletion();

    constructor() {
        owner = msg.sender;
        scheduler = IScheduler(SCHEDULER_ADDRESS);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyScheduler() {
        if (msg.sender != address(scheduler)) revert NotScheduler();
        _;
    }

    function depositScheduleFees(uint256 lockBlocks) external payable onlyOwner {
        IRitualWallet(RITUAL_WALLET).deposit{value: msg.value}(lockBlocks);
        emit ScheduleFeesDeposited(msg.value, lockBlocks);
    }

    function configureAsset(
        string calldata symbol,
        string calldata coinId,
        address httpExecutor,
        address llmExecutor
    ) external onlyOwner returns (bytes32 assetId) {
        if (httpExecutor == address(0) || llmExecutor == address(0)) revert InvalidExecutor();

        assetId = _assetId(symbol);
        AssetConfig storage config = assetConfigs[assetId];

        if (!config.configured) {
            trackedAssets.push(assetId);
        }

        config.symbol = symbol;
        config.coinId = coinId;
        config.httpExecutor = httpExecutor;
        config.llmExecutor = llmExecutor;
        config.configured = true;

        emit AssetConfigured(assetId, symbol, coinId, httpExecutor, llmExecutor);
    }

    function scheduleAssetWatcher(
        bytes32 assetId,
        uint32 cadence,
        uint32 analysisDelay,
        uint32 numCalls,
        uint32 gasLimit,
        uint32 schedulerTtl,
        uint256 maxFeePerGas,
        uint256 maxPriorityFeePerGas
    ) external onlyOwner {
        AssetConfig storage config = _requireAssetConfig(assetId);
        if (cadence == 0 || analysisDelay == 0 || analysisDelay >= cadence || numCalls == 0) {
            revert InvalidScheduleConfig();
        }

        _cancelSchedules(config);

        uint32 startBlock = uint32(block.number) + cadence;
        bytes memory fetchData = abi.encodeWithSelector(this.executeFetch.selector, uint256(0), assetId);
        bytes memory analysisData = abi.encodeWithSelector(this.executeAnalysis.selector, uint256(0), assetId);

        config.fetchScheduleId = scheduler.schedule(
            fetchData,
            gasLimit,
            startBlock,
            numCalls,
            cadence,
            schedulerTtl,
            maxFeePerGas,
            maxPriorityFeePerGas,
            0,
            address(this)
        );

        config.analysisScheduleId = scheduler.schedule(
            analysisData,
            gasLimit,
            startBlock + analysisDelay,
            numCalls,
            cadence,
            schedulerTtl,
            maxFeePerGas,
            maxPriorityFeePerGas,
            0,
            address(this)
        );

        emit WatcherScheduled(assetId, config.fetchScheduleId, config.analysisScheduleId, cadence, analysisDelay);
    }

    function cancelAssetWatcher(bytes32 assetId) external onlyOwner {
        AssetConfig storage config = _requireAssetConfig(assetId);
        uint256 fetchScheduleId = config.fetchScheduleId;
        uint256 analysisScheduleId = config.analysisScheduleId;

        _cancelSchedules(config);
        emit WatcherCancelled(assetId, fetchScheduleId, analysisScheduleId);
    }

    function executeFetch(uint256 executionIndex, bytes32 assetId) external onlyScheduler {
        _fetchMarketData(assetId, executionIndex);
    }

    function executeAnalysis(uint256 executionIndex, bytes32 assetId) external onlyScheduler {
        _analyzeMarketData(assetId, executionIndex);
    }

    function fetchNow(bytes32 assetId) external onlyOwner {
        _fetchMarketData(assetId, 0);
    }

    function analyzeNow(bytes32 assetId) external onlyOwner {
        _analyzeMarketData(assetId, 0);
    }

    function getAssetConfig(bytes32 assetId) external view returns (AssetConfig memory) {
        return assetConfigs[assetId];
    }

    function getMarketSnapshot(bytes32 assetId) external view returns (MarketSnapshot memory) {
        return marketSnapshots[assetId];
    }

    function getSentimentResult(bytes32 assetId) external view returns (SentimentResult memory) {
        return sentimentResults[assetId];
    }

    function assetIdFor(string calldata symbol) external pure returns (bytes32) {
        return _assetId(symbol);
    }

    function totalTrackedAssets() external view returns (uint256) {
        return trackedAssets.length;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidOwner();
        owner = newOwner;
    }

    function _fetchMarketData(bytes32 assetId, uint256 executionIndex) internal {
        AssetConfig storage config = _requireAssetConfig(assetId);
        bytes memory actualOutput = _executeHTTP(config.httpExecutor, _buildCoinGeckoUrl(config.coinId));
        (uint16 statusCode, , , bytes memory body, string memory errorMessage) = abi.decode(
            actualOutput,
            (uint16, string[], string[], bytes, string)
        );

        string memory summary = "";
        bool available = false;

        if (statusCode >= 200 && statusCode < 300 && bytes(errorMessage).length == 0 && body.length > 0) {
            summary = _extractMarketSummary(string(body));
            available = bytes(summary).length > 0;
            if (!available) {
                errorMessage = "JQ extraction returned empty summary";
            }
        }

        MarketSnapshot storage snapshot = marketSnapshots[assetId];
        snapshot.symbol = config.symbol;
        snapshot.summary = summary;
        snapshot.bodyHash = keccak256(body);
        snapshot.bodySize = body.length;
        snapshot.statusCode = statusCode;
        snapshot.errorMessage = errorMessage;
        snapshot.fetchedAt = block.timestamp;
        snapshot.fetchExecutionIndex = executionIndex;
        snapshot.available = available;

        emit MarketSnapshotUpdated(assetId, config.symbol, executionIndex, statusCode, available);
    }

    function _analyzeMarketData(bytes32 assetId, uint256 executionIndex) internal {
        AssetConfig storage config = _requireAssetConfig(assetId);
        MarketSnapshot storage snapshot = marketSnapshots[assetId];
        if (!snapshot.available || bytes(snapshot.summary).length == 0) revert SnapshotUnavailable();

        bytes memory actualOutput = _executeLLM(config.llmExecutor, config.symbol, snapshot.summary);
        (bool hasError, bytes memory completionData, , string memory errorMessage, ) = abi.decode(
            actualOutput,
            (bool, bytes, bytes, string, StorageRef)
        );

        SentimentResult storage stored = sentimentResults[assetId];
        stored.symbol = config.symbol;
        stored.model = DEFAULT_MODEL;
        stored.executor = config.llmExecutor;
        stored.analyzedAt = block.timestamp;
        stored.analysisExecutionIndex = executionIndex;
        stored.snapshotTimestamp = snapshot.fetchedAt;
        stored.fulfilled = true;
        stored.hasError = hasError;

        if (hasError) {
            stored.signal = "ERROR";
            stored.errorMessage = errorMessage;
            stored.rawResponse = "";
            stored.reasoning = "";
            stored.score = 0;
        } else {
            _recordSuccessfulAnalysis(stored, completionData);
        }

        emit SentimentAnalyzed(
            assetId,
            config.symbol,
            executionIndex,
            stored.hasError,
            stored.score,
            stored.signal,
            stored.model
        );
    }

    function _executeHTTP(address executor, string memory url) internal returns (bytes memory actualOutput) {
        string[] memory headerKeys = new string[](1);
        string[] memory headerValues = new string[](1);
        headerKeys[0] = "Accept";
        headerValues[0] = "application/json";

        bytes memory encoded = abi.encode(
            executor,
            new bytes[](0),
            HTTP_TTL,
            new bytes[](0),
            bytes(""),
            url,
            uint8(1),
            headerKeys,
            headerValues,
            bytes(""),
            uint256(0),
            uint8(0),
            false
        );

        (bool success, bytes memory rawOutput) = HTTP_PRECOMPILE.call(encoded);
        if (!success) revert PrecompileCallFailed();
        (, actualOutput) = abi.decode(rawOutput, (bytes, bytes));
    }

    function _executeLLM(
        address executor,
        string memory asset,
        string memory context
    ) internal returns (bytes memory actualOutput) {
        bytes memory input = abi.encode(
            executor,
            new bytes[](0),
            LLM_TTL,
            new bytes[](0),
            bytes(""),
            _buildMessagesJson(_buildPrompt(asset, context)),
            DEFAULT_MODEL,
            int256(0),
            "",
            false,
            DEFAULT_MAX_COMPLETION_TOKENS,
            "",
            "",
            uint256(1),
            true,
            int256(0),
            "medium",
            bytes(""),
            int256(-1),
            "auto",
            "",
            false,
            DEFAULT_TEMPERATURE,
            bytes(""),
            bytes(""),
            int256(-1),
            int256(1000),
            "",
            false,
            StorageRef({platform: "", path: "", keyRef: ""})
        );

        (bool success, bytes memory rawResult) = LLM_PRECOMPILE.call(input);
        if (!success) revert PrecompileCallFailed();
        (, actualOutput) = abi.decode(rawResult, (bytes, bytes));
    }

    function _recordSuccessfulAnalysis(
        SentimentResult storage stored,
        bytes memory completionData
    ) internal {
        string memory content = _extractContent(completionData);
        if (bytes(content).length == 0) revert EmptyCompletion();

        (int8 score, string memory signal, string memory reason) = _parse(content);
        stored.score = score;
        stored.signal = signal;
        stored.reasoning = reason;
        stored.rawResponse = content;
        stored.errorMessage = "";
    }

    function _extractMarketSummary(string memory rawJson) internal view returns (string memory) {
        bytes memory input = abi.encode(MARKET_JQ_FILTER, rawJson, uint8(2));
        (bool ok, bytes memory result) = JQ_PRECOMPILE.staticcall(input);
        if (!ok || result.length < 96) {
            return "";
        }

        return _decodeJQString(result);
    }

    function _cancelSchedules(AssetConfig storage config) internal {
        if (config.fetchScheduleId != 0) {
            _cancelIfActive(config.fetchScheduleId);
            config.fetchScheduleId = 0;
        }

        if (config.analysisScheduleId != 0) {
            _cancelIfActive(config.analysisScheduleId);
            config.analysisScheduleId = 0;
        }
    }

    function _cancelIfActive(uint256 scheduleId) internal {
        try scheduler.getCallState(scheduleId) returns (uint8 state) {
            if (state < 2) {
                scheduler.cancel(scheduleId);
            }
        } catch {
            // Ignore already-pruned or inaccessible schedules during rescheduling cleanup.
        }
    }

    function _requireAssetConfig(bytes32 assetId) internal view returns (AssetConfig storage config) {
        config = assetConfigs[assetId];
        if (!config.configured) revert AssetNotConfigured();
    }

    function _buildCoinGeckoUrl(string memory coinId) internal pure returns (string memory) {
        return string(abi.encodePacked(COINGECKO_URL_PREFIX, coinId, COINGECKO_URL_SUFFIX));
    }

    function _buildPrompt(string memory asset, string memory context) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                "You are a crypto market analyst. Analyze the following normalized market context for ",
                asset,
                " and respond ONLY in this exact format:\n",
                "SCORE:<-1|0|1> SIGNAL:<BUY|SELL|HOLD> REASON:<one sentence max 20 words>\n\n",
                "Context:\n",
                context
            )
        );
    }

    function _buildMessagesJson(string memory prompt) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '[{"role":"system","content":"You are a concise crypto market analyst."},',
                '{"role":"user","content":"',
                _escapeJsonString(prompt),
                '"}]'
            )
        );
    }

    function _extractContent(bytes memory completionData) internal pure returns (string memory) {
        (, , , , , , uint256 choicesCount, bytes[] memory choicesData, ) = abi.decode(
            completionData,
            (string, string, uint256, string, string, string, uint256, bytes[], bytes)
        );

        if (choicesCount == 0 || choicesData.length == 0) {
            return "";
        }

        (, , bytes memory messageData) = abi.decode(choicesData[0], (uint256, string, bytes));
        (, string memory content, , , ) = abi.decode(messageData, (string, string, string, uint256, bytes[]));
        return content;
    }

    function _decodeJQString(bytes memory raw) internal pure returns (string memory) {
        if (raw.length < 96) {
            return "";
        }

        uint256 strLen;
        assembly {
            strLen := mload(add(raw, 96))
        }

        bytes memory result = new bytes(strLen);
        for (uint256 i = 0; i < strLen; i++) {
            result[i] = raw[96 + i];
        }

        return string(result);
    }

    function _parse(string memory raw) internal pure returns (int8 score, string memory signal, string memory reason) {
        bytes memory data = bytes(raw);
        uint256 reasonStart = type(uint256).max;

        score = 0;
        signal = "HOLD";
        reason = raw;

        for (uint256 i = 0; i + 5 < data.length; i++) {
            if (
                data[i] == "S" &&
                data[i + 1] == "C" &&
                data[i + 2] == "O" &&
                data[i + 3] == "R" &&
                data[i + 4] == "E" &&
                data[i + 5] == ":"
            ) {
                uint256 cursor = _skipWhitespace(data, i + 6);
                if (cursor + 1 < data.length && data[cursor] == "-" && data[cursor + 1] == "1") {
                    score = -1;
                } else if (cursor < data.length && data[cursor] == "1") {
                    score = 1;
                }
                break;
            }
        }

        for (uint256 i = 0; i + 6 < data.length; i++) {
            if (
                data[i] == "S" &&
                data[i + 1] == "I" &&
                data[i + 2] == "G" &&
                data[i + 3] == "N" &&
                data[i + 4] == "A" &&
                data[i + 5] == "L" &&
                data[i + 6] == ":"
            ) {
                uint256 cursor = _skipWhitespace(data, i + 7);
                if (_matchesAt(data, cursor, "BUY")) {
                    signal = "BUY";
                } else if (_matchesAt(data, cursor, "SELL")) {
                    signal = "SELL";
                }
                break;
            }
        }

        for (uint256 i = 0; i + 6 < data.length; i++) {
            if (
                data[i] == "R" &&
                data[i + 1] == "E" &&
                data[i + 2] == "A" &&
                data[i + 3] == "S" &&
                data[i + 4] == "O" &&
                data[i + 5] == "N" &&
                data[i + 6] == ":"
            ) {
                reasonStart = i + 7;
                break;
            }
        }

        if (reasonStart != type(uint256).max) {
            reason = _trim(data, reasonStart, data.length);
        }
    }

    function _assetId(string memory symbol) internal pure returns (bytes32) {
        return keccak256(bytes(symbol));
    }

    function _escapeJsonString(string memory value) internal pure returns (string memory) {
        bytes memory input = bytes(value);
        bytes memory buffer = new bytes(input.length * 2 + 8);
        uint256 length;

        for (uint256 i = 0; i < input.length; i++) {
            bytes1 char = input[i];
            if (char == "\\") {
                buffer[length++] = "\\";
                buffer[length++] = "\\";
            } else if (char == '"') {
                buffer[length++] = "\\";
                buffer[length++] = '"';
            } else if (char == "\n") {
                buffer[length++] = "\\";
                buffer[length++] = "n";
            } else if (char == "\r") {
                buffer[length++] = "\\";
                buffer[length++] = "r";
            } else if (char == "\t") {
                buffer[length++] = "\\";
                buffer[length++] = "t";
            } else {
                buffer[length++] = char;
            }
        }

        bytes memory output = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            output[i] = buffer[i];
        }

        return string(output);
    }

    function _matchesAt(bytes memory data, uint256 start, string memory needle) internal pure returns (bool) {
        bytes memory target = bytes(needle);
        if (start + target.length > data.length) {
            return false;
        }

        for (uint256 i = 0; i < target.length; i++) {
            if (data[start + i] != target[i]) {
                return false;
            }
        }

        return true;
    }

    function _skipWhitespace(bytes memory data, uint256 start) internal pure returns (uint256 cursor) {
        cursor = start;
        while (cursor < data.length && _isWhitespace(data[cursor])) {
            cursor++;
        }
    }

    function _trim(bytes memory data, uint256 start, uint256 end) internal pure returns (string memory) {
        while (start < end && _isWhitespace(data[start])) {
            start++;
        }

        while (end > start && _isWhitespace(data[end - 1])) {
            end--;
        }

        bytes memory output = new bytes(end - start);
        for (uint256 i = 0; i < output.length; i++) {
            output[i] = data[start + i];
        }

        return string(output);
    }

    function _isWhitespace(bytes1 char) internal pure returns (bool) {
        return char == " " || char == "\n" || char == "\r" || char == "\t";
    }

    receive() external payable {}
}
