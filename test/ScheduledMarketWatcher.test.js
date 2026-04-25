import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { AbiCoder, ZeroAddress, id, keccak256, toUtf8Bytes } from "ethers";
import { network } from "hardhat";

const coder = AbiCoder.defaultAbiCoder();

const ADDRESSES = {
  http: "0x0000000000000000000000000000000000000801",
  llm: "0x0000000000000000000000000000000000000802",
  jq: "0x0000000000000000000000000000000000000803",
  scheduler: "0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B",
};

const HTTP_EXECUTOR = "0x1000000000000000000000000000000000000001";
const LLM_EXECUTOR = "0x2000000000000000000000000000000000000002";

function assetId(symbol) {
  return keccak256(toUtf8Bytes(symbol));
}

function shortRunningEnvelope(actualOutput) {
  return coder.encode(["bytes", "bytes"], [toUtf8Bytes("mock-input"), actualOutput]);
}

function httpSettlement(statusCode, body, errorMessage = "") {
  return coder.encode(
    ["uint16", "string[]", "string[]", "bytes", "string"],
    [statusCode, [], [], toUtf8Bytes(body), errorMessage]
  );
}

function jqStringResult(value) {
  return coder.encode(["uint256", "bytes"], [0, toUtf8Bytes(value)]);
}

function llmCompletion(content) {
  const messageData = coder.encode(
    ["string", "string", "string", "uint256", "bytes[]"],
    ["assistant", content, "", 0, []]
  );

  const choiceData = coder.encode(["uint256", "string", "bytes"], [0, "stop", messageData]);

  return coder.encode(
    ["string", "string", "uint256", "string", "string", "string", "uint256", "bytes[]", "bytes"],
    ["mock-id", "chat.completion", 0, "glm", "fp", "assistant", 1, [choiceData], "0x"]
  );
}

function collectErrorDetails(error) {
  return [
    error?.message,
    error?.shortMessage,
    error?.cause?.message,
    error?.data,
    error?.error?.data,
    error?.info?.errorName,
    error?.info?.error?.data,
    error?.revert?.name,
  ].filter((value, index, values) => typeof value === "string" && values.indexOf(value) === index);
}

async function assertRevertsWith(action, expectedError) {
  await assert.rejects(action, (error) => {
    const details = collectErrorDetails(error);
    const expectedSelector = id(`${expectedError}()`).slice(0, 10).toLowerCase();

    assert.ok(
      details.some(
        (value) => value.includes(expectedError) || value.toLowerCase().includes(expectedSelector)
      ),
      `Expected error containing "${expectedError}", received: ${details.join(" | ") || String(error)}`
    );

    return true;
  });
}

async function setRuntimeCode(ethers, networkHelpers, contractName, targetAddress) {
  const factory = await ethers.getContractFactory(contractName);
  const implementation = await factory.deploy();
  await implementation.waitForDeployment();

  const runtimeCode = await ethers.provider.getCode(await implementation.getAddress());
  await networkHelpers.setCode(targetAddress, runtimeCode);

  return factory.attach(targetAddress);
}

async function deployFixture() {
  const connection = await network.create();
  const { ethers, networkHelpers } = connection;
  const [owner, other] = await ethers.getSigners();
  const scheduler = await setRuntimeCode(ethers, networkHelpers, "MockScheduler", ADDRESSES.scheduler);
  const http = await setRuntimeCode(ethers, networkHelpers, "MockRitualPrecompile", ADDRESSES.http);
  const llm = await setRuntimeCode(ethers, networkHelpers, "MockRitualPrecompile", ADDRESSES.llm);
  const jq = await setRuntimeCode(ethers, networkHelpers, "MockRitualPrecompile", ADDRESSES.jq);

  const watcherFactory = await ethers.getContractFactory(
    "contracts/ScheduledMarketWatcher.sol:ScheduledMarketWatcher"
  );
  const watcher = await watcherFactory.deploy();
  await watcher.waitForDeployment();

  return { connection, owner, other, scheduler, http, llm, jq, watcher };
}

async function configureEthWatcher(watcher) {
  await watcher.configureAsset("ETH", "ethereum", HTTP_EXECUTOR, LLM_EXECUTOR);
  return assetId("ETH");
}

describe("ScheduledMarketWatcher", function () {
  it("rejects direct scheduler callbacks from non-scheduler callers", async function () {
    const { watcher } = await deployFixture();
    const ethAssetId = assetId("ETH");

    await assertRevertsWith(() => watcher.executeFetch(0, ethAssetId), "NotScheduler");
    await assertRevertsWith(() => watcher.executeAnalysis(0, ethAssetId), "NotScheduler");
  });

  it("rejects zero-address executors during asset configuration", async function () {
    const { watcher } = await deployFixture();

    await assertRevertsWith(
      () => watcher.configureAsset("ETH", "ethereum", ZeroAddress, LLM_EXECUTOR),
      "InvalidExecutor"
    );
    await assertRevertsWith(
      () => watcher.configureAsset("ETH", "ethereum", HTTP_EXECUTOR, ZeroAddress),
      "InvalidExecutor"
    );
  });

  it("rejects invalid schedule configurations", async function () {
    const { watcher } = await deployFixture();
    const ethAssetId = await configureEthWatcher(watcher);

    await assertRevertsWith(
      () => watcher.scheduleAssetWatcher(ethAssetId, 0, 120, 24, 2_200_000, 240, 10n, 1n),
      "InvalidScheduleConfig"
    );
    await assertRevertsWith(
      () => watcher.scheduleAssetWatcher(ethAssetId, 360, 360, 24, 2_200_000, 240, 10n, 1n),
      "InvalidScheduleConfig"
    );
    await assertRevertsWith(
      () => watcher.scheduleAssetWatcher(ethAssetId, 360, 99, 24, 2_200_000, 240, 10n, 1n),
      "InvalidScheduleConfig"
    );
    await assertRevertsWith(
      () => watcher.scheduleAssetWatcher(ethAssetId, 360, 120, 0, 2_200_000, 240, 10n, 1n),
      "InvalidScheduleConfig"
    );
    await assertRevertsWith(
      () => watcher.scheduleAssetWatcher(ethAssetId, 360, 120, 24, 2_200_000, 179, 10n, 1n),
      "InvalidScheduleConfig"
    );
  });

  it("schedules both recurring phases and only cancels active prior schedules on reschedule", async function () {
    const { watcher, scheduler } = await deployFixture();
    const ethAssetId = await configureEthWatcher(watcher);

    const firstTx = await watcher.scheduleAssetWatcher(ethAssetId, 360, 120, 24, 2_200_000, 240, 10n, 1n);
    const firstReceipt = await firstTx.wait();
    const firstBlockNumber = BigInt(firstReceipt.blockNumber);
    const firstConfig = await watcher.getAssetConfig(ethAssetId);

    assert.equal(firstConfig.fetchScheduleId, 1n);
    assert.equal(firstConfig.analysisScheduleId, 2n);

    const fetchSchedule = await scheduler.getScheduledCall(firstConfig.fetchScheduleId);
    const analysisSchedule = await scheduler.getScheduledCall(firstConfig.analysisScheduleId);

    assert.equal(fetchSchedule.startBlock, firstBlockNumber + 360n);
    assert.equal(fetchSchedule.frequency, 360n);
    assert.equal(fetchSchedule.ttl, 240n);
    assert.equal(analysisSchedule.startBlock, firstBlockNumber + 480n);
    assert.equal(analysisSchedule.frequency, 360n);
    assert.equal(analysisSchedule.ttl, 240n);

    await scheduler.setCallState(firstConfig.fetchScheduleId, 2);
    await scheduler.setCallState(firstConfig.analysisScheduleId, 1);

    await watcher.scheduleAssetWatcher(ethAssetId, 420, 140, 12, 2_100_000, 260, 11n, 2n);

    const updatedConfig = await watcher.getAssetConfig(ethAssetId);
    assert.equal(updatedConfig.fetchScheduleId, 3n);
    assert.equal(updatedConfig.analysisScheduleId, 4n);
    assert.equal(await scheduler.cancelledCallsLength(), 1n);
    assert.equal(await scheduler.cancelledCalls(0), firstConfig.analysisScheduleId);
  });

  it("records failed HTTP fetch responses without making a snapshot available", async function () {
    const { watcher, scheduler, http } = await deployFixture();
    const ethAssetId = await configureEthWatcher(watcher);

    await http.setResponse(shortRunningEnvelope(httpSettlement(500, "", "upstream unavailable")));
    await scheduler.executeFetch(await watcher.getAddress(), 9, ethAssetId);

    const snapshot = await watcher.getMarketSnapshot(ethAssetId);
    assert.equal(snapshot.symbol, "ETH");
    assert.equal(snapshot.summary, "");
    assert.equal(snapshot.statusCode, 500n);
    assert.equal(snapshot.fetchExecutionIndex, 9n);
    assert.equal(snapshot.available, false);
    assert.equal(snapshot.errorMessage, "upstream unavailable");
  });

  it("marks snapshots unavailable when JQ extraction is empty", async function () {
    const { watcher, scheduler, http, jq } = await deployFixture();
    const ethAssetId = await configureEthWatcher(watcher);

    const rawBody = JSON.stringify({
      market_data: {
        current_price: { usd: 3500.12 },
        price_change_percentage_24h: 4.8,
        total_volume: { usd: 18000000000 },
        market_cap: { usd: 420000000000 },
      },
    });

    await http.setResponse(shortRunningEnvelope(httpSettlement(200, rawBody)));
    await jq.setResponse("0x");
    await scheduler.executeFetch(await watcher.getAddress(), 11, ethAssetId);

    const snapshot = await watcher.getMarketSnapshot(ethAssetId);
    assert.equal(snapshot.summary, "");
    assert.equal(snapshot.fetchExecutionIndex, 11n);
    assert.equal(snapshot.available, false);
    assert.equal(snapshot.errorMessage, "JQ extraction returned empty summary");
  });

  it("reverts fetches when the HTTP precompile call itself fails", async function () {
    const { watcher, http } = await deployFixture();
    const ethAssetId = await configureEthWatcher(watcher);

    await http.setRevert("http unavailable");

    await assertRevertsWith(() => watcher.fetchNow(ethAssetId), "PrecompileCallFailed");
  });

  it("stores a normalized market snapshot after a mocked scheduler fetch", async function () {
    const { watcher, scheduler, http, jq } = await deployFixture();
    const ethAssetId = await configureEthWatcher(watcher);

    const rawBody = JSON.stringify({
      market_data: {
        current_price: { usd: 3500.12 },
        price_change_percentage_24h: 4.8,
        total_volume: { usd: 18000000000 },
        market_cap: { usd: 420000000000 },
      },
    });
    const summary = "price_usd=3500.12 price_change_24h=4.8 volume_usd=18000000000 market_cap_usd=420000000000";

    await http.setResponse(shortRunningEnvelope(httpSettlement(200, rawBody)));
    await jq.setResponse(jqStringResult(summary));

    await scheduler.executeFetch(await watcher.getAddress(), 42, ethAssetId);

    const snapshot = await watcher.getMarketSnapshot(ethAssetId);
    assert.equal(snapshot.symbol, "ETH");
    assert.equal(snapshot.summary, summary);
    assert.equal(snapshot.statusCode, 200n);
    assert.equal(snapshot.bodySize, BigInt(toUtf8Bytes(rawBody).length));
    assert.equal(snapshot.bodyHash, keccak256(toUtf8Bytes(rawBody)));
    assert.equal(snapshot.fetchExecutionIndex, 42n);
    assert.equal(snapshot.available, true);
    assert.equal(snapshot.errorMessage, "");
  });

  it("stores analysis errors returned by the mocked LLM settlement", async function () {
    const { watcher, scheduler, http, jq, llm } = await deployFixture();
    const ethAssetId = await configureEthWatcher(watcher);

    const rawBody = JSON.stringify({
      market_data: {
        current_price: { usd: 3500.12 },
        price_change_percentage_24h: 4.8,
        total_volume: { usd: 18000000000 },
        market_cap: { usd: 420000000000 },
      },
    });
    const summary = "price_usd=3500.12 price_change_24h=4.8 volume_usd=18000000000 market_cap_usd=420000000000";
    const llmSettlement = coder.encode(
      ["bool", "bytes", "bytes", "string", "tuple(string platform,string path,string keyRef)"],
      [true, "0x", "0x", "model timeout", ["", "", ""]]
    );

    await http.setResponse(shortRunningEnvelope(httpSettlement(200, rawBody)));
    await jq.setResponse(jqStringResult(summary));
    await scheduler.executeFetch(await watcher.getAddress(), 5, ethAssetId);

    await llm.setResponse(shortRunningEnvelope(llmSettlement));
    await scheduler.executeAnalysis(await watcher.getAddress(), 8, ethAssetId);

    const sentiment = await watcher.getSentimentResult(ethAssetId);
    assert.equal(sentiment.score, 0n);
    assert.equal(sentiment.signal, "ERROR");
    assert.equal(sentiment.reasoning, "");
    assert.equal(sentiment.rawResponse, "");
    assert.equal(sentiment.errorMessage, "model timeout");
    assert.equal(sentiment.fulfilled, true);
    assert.equal(sentiment.hasError, true);
    assert.equal(sentiment.analysisExecutionIndex, 8n);
  });

  it("stores parsed sentiment after a mocked scheduler analysis", async function () {
    const { watcher, scheduler, http, jq, llm } = await deployFixture();
    const ethAssetId = await configureEthWatcher(watcher);

    const rawBody = JSON.stringify({
      market_data: {
        current_price: { usd: 3500.12 },
        price_change_percentage_24h: 4.8,
        total_volume: { usd: 18000000000 },
        market_cap: { usd: 420000000000 },
      },
    });
    const summary = "price_usd=3500.12 price_change_24h=4.8 volume_usd=18000000000 market_cap_usd=420000000000";
    const modelOutput = "SCORE:1 SIGNAL:BUY REASON:Momentum and liquidity remain constructive";
    const llmSettlement = coder.encode(
      ["bool", "bytes", "bytes", "string", "tuple(string platform,string path,string keyRef)"],
      [false, llmCompletion(modelOutput), "0x", "", ["", "", ""]]
    );

    await http.setResponse(shortRunningEnvelope(httpSettlement(200, rawBody)));
    await jq.setResponse(jqStringResult(summary));
    await scheduler.executeFetch(await watcher.getAddress(), 6, ethAssetId);

    await llm.setResponse(shortRunningEnvelope(llmSettlement));
    await scheduler.executeAnalysis(await watcher.getAddress(), 7, ethAssetId);

    const sentiment = await watcher.getSentimentResult(ethAssetId);
    const snapshot = await watcher.getMarketSnapshot(ethAssetId);

    assert.equal(sentiment.symbol, "ETH");
    assert.equal(sentiment.score, 1n);
    assert.equal(sentiment.signal, "BUY");
    assert.equal(sentiment.reasoning, "Momentum and liquidity remain constructive");
    assert.equal(sentiment.rawResponse, modelOutput);
    assert.equal(sentiment.errorMessage, "");
    assert.equal(sentiment.executor, LLM_EXECUTOR);
    assert.equal(sentiment.fulfilled, true);
    assert.equal(sentiment.hasError, false);
    assert.equal(sentiment.analysisExecutionIndex, 7n);
    assert.equal(sentiment.snapshotTimestamp, snapshot.fetchedAt);
  });

  it("reverts analysis when the LLM precompile call itself fails", async function () {
    const { watcher, http, jq, llm } = await deployFixture();
    const ethAssetId = await configureEthWatcher(watcher);

    const rawBody = JSON.stringify({
      market_data: {
        current_price: { usd: 3500.12 },
        price_change_percentage_24h: 4.8,
        total_volume: { usd: 18000000000 },
        market_cap: { usd: 420000000000 },
      },
    });
    const summary = "price_usd=3500.12 price_change_24h=4.8 volume_usd=18000000000 market_cap_usd=420000000000";

    await http.setResponse(shortRunningEnvelope(httpSettlement(200, rawBody)));
    await jq.setResponse(jqStringResult(summary));
    await watcher.fetchNow(ethAssetId);

    await llm.setRevert("llm unavailable");

    await assertRevertsWith(() => watcher.analyzeNow(ethAssetId), "PrecompileCallFailed");
  });

  it("reverts analysis when the LLM returns an empty completion", async function () {
    const { watcher, http, jq, llm } = await deployFixture();
    const ethAssetId = await configureEthWatcher(watcher);

    const rawBody = JSON.stringify({
      market_data: {
        current_price: { usd: 3500.12 },
        price_change_percentage_24h: 4.8,
        total_volume: { usd: 18000000000 },
        market_cap: { usd: 420000000000 },
      },
    });
    const summary = "price_usd=3500.12 price_change_24h=4.8 volume_usd=18000000000 market_cap_usd=420000000000";
    const llmSettlement = coder.encode(
      ["bool", "bytes", "bytes", "string", "tuple(string platform,string path,string keyRef)"],
      [false, llmCompletion(""), "0x", "", ["", "", ""]]
    );

    await http.setResponse(shortRunningEnvelope(httpSettlement(200, rawBody)));
    await jq.setResponse(jqStringResult(summary));
    await watcher.fetchNow(ethAssetId);

    await llm.setResponse(shortRunningEnvelope(llmSettlement));

    await assertRevertsWith(() => watcher.analyzeNow(ethAssetId), "EmptyCompletion");
  });

  it("requires an available market snapshot before analysis", async function () {
    const { watcher } = await deployFixture();
    const ethAssetId = await configureEthWatcher(watcher);

    await assertRevertsWith(() => watcher.analyzeNow(ethAssetId), "SnapshotUnavailable");
  });

  it("transfers ownership safely and rejects zero-address handoff", async function () {
    const { watcher, owner, other } = await deployFixture();

    await assertRevertsWith(() => watcher.transferOwnership(ZeroAddress), "InvalidOwner");

    const transferTx = await watcher.transferOwnership(other.address);
    const transferReceipt = await transferTx.wait();
    const ownershipEvent = transferReceipt.logs
      .flatMap((log) => {
        try {
          return [watcher.interface.parseLog(log)];
        } catch {
          return [];
        }
      })
      .find((log) => log?.name === "OwnershipTransferred");

    assert.equal(ownershipEvent?.args.previousOwner, owner.address);
    assert.equal(ownershipEvent?.args.newOwner, other.address);
    assert.equal(await watcher.owner(), other.address);

    await assertRevertsWith(
      () => watcher.configureAsset("ETH", "ethereum", HTTP_EXECUTOR, LLM_EXECUTOR),
      "NotOwner"
    );

    await watcher.connect(other).configureAsset("ETH", "ethereum", HTTP_EXECUTOR, LLM_EXECUTOR);
    const config = await watcher.getAssetConfig(assetId("ETH"));
    assert.equal(config.configured, true);
    assert.equal(config.httpExecutor, HTTP_EXECUTOR);
    assert.equal(config.llmExecutor, LLM_EXECUTOR);
  });
});