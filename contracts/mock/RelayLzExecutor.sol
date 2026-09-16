// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ExecutorOptions} from "@layerzerolabs/lz-evm-protocol-v2/contracts/messagelib/libs/ExecutorOptions.sol";
import {RelayLzEndpoint} from "./RelayLzEndpoint.sol";

/**
 * @title RelayLzExecutor
 * @notice Executes the three distinct native/gas budgets in recorded type-3 options, using
 * LayerZero's option decoder and real calls to the destination endpoint and native recipient.
 * @dev This is a test delivery driver, not LayerZero's executor implementation. It models neither
 * quoting, payment settlement, native caps, scheduling nor the live service's failure policy.
 * Each leg is explicit so a failed compose cannot roll back an earlier receive or native drop.
 * Only receive, compose index zero and native-drop options are supported by this fixture.
 */
contract RelayLzExecutor {

    struct Budgets {
        uint256 receiveGas;
        uint256 receiveValue;
        uint256 composeGas;
        uint256 composeValue;
        uint256 dropValue;
    }

    function nativeDrop(
        bytes calldata _options,
        uint256 _gasLimit
    )
        external payable
    {
        Budgets memory budgets = _budgets(_options);
        require(msg.value == budgets.dropValue, "incorrect native-drop funding");
        uint256 cursor = 2;
        while (cursor < _options.length) {
            (uint8 optionType, bytes calldata option, uint256 next) =
                ExecutorOptions.nextExecutorOption(_options, cursor);
            cursor = next;
            if (optionType == ExecutorOptions.OPTION_TYPE_NATIVE_DROP) {
                (uint128 amount, bytes32 recipient) = ExecutorOptions.decodeNativeDropOption(option);
                require(uint256(recipient) >> 160 == 0, "non-EVM native-drop recipient");
                // A real native transfer enters the proxy's receive path; no balance override
                // funds the account whose native acceptance and spending the suite exercises.
                // solhint-disable-next-line avoid-low-level-calls
                (bool success,) = address(uint160(uint256(recipient))).call{value: amount, gas: _gasLimit}("");
                require(success, "native drop failed");
            }
        }
    }

    function deliverReceive(
        RelayLzEndpoint _destination,
        RelayLzEndpoint _source,
        uint256 _packetIndex
    )
        external payable
    {
        RelayLzEndpoint.Packet memory packet = _source.packetAt(_packetIndex);
        Budgets memory budgets = this.readBudgets(packet.options);
        require(msg.value == budgets.receiveValue, "incorrect receive funding");
        _destination.deliverFrom{gas: budgets.receiveGas, value: budgets.receiveValue}(_source, _packetIndex);
    }

    function deliverCompose(
        RelayLzEndpoint _destination,
        address _from,
        address _to,
        bytes32 _guid,
        bytes calldata _message,
        bytes calldata _options
    )
        external payable
    {
        Budgets memory budgets = _budgets(_options);
        require(msg.value == budgets.composeValue, "incorrect compose funding");
        _destination.lzCompose{gas: budgets.composeGas, value: budgets.composeValue}(
            _from, _to, _guid, 0, _message, ""
        );
    }

    function readBudgets(
        bytes calldata _options
    )
        external pure
        returns (Budgets memory)
    {
        return _budgets(_options);
    }

    function _budgets(
        bytes calldata _options
    )
        private pure
        returns (Budgets memory _result)
    {
        require(_options.length >= 2 && bytes2(_options[:2]) == bytes2(uint16(3)), "expected type-3 options");
        uint256 cursor = 2;
        while (cursor < _options.length) {
            require(uint8(_options[cursor]) == ExecutorOptions.WORKER_ID, "unsupported option worker");
            (uint8 optionType, bytes calldata option, uint256 next) =
                ExecutorOptions.nextExecutorOption(_options, cursor);
            cursor = next;
            if (optionType == ExecutorOptions.OPTION_TYPE_LZRECEIVE) {
                (uint128 gasLimit, uint128 value) = ExecutorOptions.decodeLzReceiveOption(option);
                _result.receiveGas += gasLimit;
                _result.receiveValue += value;
            } else if (optionType == ExecutorOptions.OPTION_TYPE_LZCOMPOSE) {
                (uint16 index, uint128 gasLimit, uint128 value) = ExecutorOptions.decodeLzComposeOption(option);
                require(index == 0, "unsupported compose index");
                _result.composeGas += gasLimit;
                _result.composeValue += value;
            } else if (optionType == ExecutorOptions.OPTION_TYPE_NATIVE_DROP) {
                (uint128 amount,) = ExecutorOptions.decodeNativeDropOption(option);
                _result.dropValue += amount;
            } else {
                revert("unsupported executor option");
            }
        }
    }
}
