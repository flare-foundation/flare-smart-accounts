// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title MockRawReturner
 * @notice Answers every call with fixed raw return data - a stand-in for canonical Morpho's
 * ABI-encoded `Position` / `Market` struct returns (and an oracle's `price`), so a test can
 * prove an interface's declared return schema decodes exactly that encoding.
 */
contract MockRawReturner {
    bytes private _returnData;

    // solhint-disable-next-line payable-fallback, no-complex-fallback
    fallback() external {
        bytes memory data = _returnData;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            return(add(data, 32), mload(data))
        }
    }

    function setReturnData(bytes calldata _data) external {
        _returnData = _data;
    }
}
