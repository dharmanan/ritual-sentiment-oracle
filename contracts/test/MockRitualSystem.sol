// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IExecutableWatcher {
    function executeFetch(uint256 executionIndex, bytes32 assetId) external;

    function executeAnalysis(uint256 executionIndex, bytes32 assetId) external;
}

contract MockRitualPrecompile {
    bytes private response;
    bool private shouldRevert;
    string private revertMessage;

    function setResponse(bytes calldata newResponse) external {
        response = newResponse;
        shouldRevert = false;
        revertMessage = "";
    }

    function setRevert(string calldata message) external {
        shouldRevert = true;
        revertMessage = message;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        if (shouldRevert) {
            revert(revertMessage);
        }

        return response;
    }
}

contract MockScheduler {
    struct ScheduledCall {
        bytes data;
        uint32 gasLimit;
        uint32 startBlock;
        uint32 numCalls;
        uint32 frequency;
        uint32 ttl;
        uint256 maxFeePerGas;
        uint256 maxPriorityFeePerGas;
        uint256 value;
        address payer;
    }

    uint256 public nextCallId;
    mapping(uint256 => ScheduledCall) private scheduledCalls;
    mapping(uint256 => uint8) public callStates;
    uint256[] public cancelledCalls;

    function schedule(
        bytes calldata data,
        uint32 gasLimit,
        uint32 startBlock,
        uint32 numCalls,
        uint32 frequency,
        uint32 ttl,
        uint256 maxFeePerGas,
        uint256 maxPriorityFeePerGas,
        uint256 value,
        address payer
    ) external returns (uint256 callId) {
        callId = ++nextCallId;
        scheduledCalls[callId] = ScheduledCall({
            data: data,
            gasLimit: gasLimit,
            startBlock: startBlock,
            numCalls: numCalls,
            frequency: frequency,
            ttl: ttl,
            maxFeePerGas: maxFeePerGas,
            maxPriorityFeePerGas: maxPriorityFeePerGas,
            value: value,
            payer: payer
        });
        callStates[callId] = 1;
    }

    function cancel(uint256 callId) external {
        cancelledCalls.push(callId);
        callStates[callId] = 3;
    }

    function getCallState(uint256 callId) external view returns (uint8 state) {
        return callStates[callId];
    }

    function setCallState(uint256 callId, uint8 state) external {
        callStates[callId] = state;
    }

    function cancelledCallsLength() external view returns (uint256) {
        return cancelledCalls.length;
    }

    function getScheduledCall(
        uint256 callId
    )
        external
        view
        returns (
            bytes memory data,
            uint32 gasLimit,
            uint32 startBlock,
            uint32 numCalls,
            uint32 frequency,
            uint32 ttl,
            uint256 maxFeePerGas,
            uint256 maxPriorityFeePerGas,
            uint256 value,
            address payer
        )
    {
        ScheduledCall storage scheduled = scheduledCalls[callId];
        return (
            scheduled.data,
            scheduled.gasLimit,
            scheduled.startBlock,
            scheduled.numCalls,
            scheduled.frequency,
            scheduled.ttl,
            scheduled.maxFeePerGas,
            scheduled.maxPriorityFeePerGas,
            scheduled.value,
            scheduled.payer
        );
    }

    function executeFetch(address watcher, uint256 executionIndex, bytes32 assetId) external {
        _forward(watcher, abi.encodeWithSelector(IExecutableWatcher.executeFetch.selector, executionIndex, assetId));
    }

    function executeAnalysis(address watcher, uint256 executionIndex, bytes32 assetId) external {
        _forward(watcher, abi.encodeWithSelector(IExecutableWatcher.executeAnalysis.selector, executionIndex, assetId));
    }

    function _forward(address target, bytes memory data) internal {
        (bool success, bytes memory result) = target.call(data);
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }
}