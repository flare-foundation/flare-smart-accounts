// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

/**
 * @title IOftDecimals
 * @notice The one LayerZero OFT getter the configuration guards need that `IOFT` does not
 * declare: the factor `OFTCore` divides an amount by, and multiplies back, to drop what the
 * shared-decimal wire format cannot carry (`_removeDust`). Declared here rather than by importing
 * `OFTCore`, which is an abstract contract, not an interface.
 * @dev A rate of one means the local and shared representations are the same and no send loses
 * anything to truncation. Equal `sharedDecimals()` and token decimals only IMPLY that for the
 * canonical `OFTAdapter` and `OFT`, whose constructors derive local decimals from the token
 * (`OFTAdapter.sol`: `OFTCore(IERC20Metadata(_token).decimals(), ...)`). `OFTCore` itself takes
 * local decimals as a constructor argument and never reads the token, so any other subclass can
 * answer both decimal questions truthfully while still truncating. Reading the rate tests the
 * property directly instead of inferring it.
 */
interface IOftDecimals {
    /**
     * @notice `10 ** (localDecimals - sharedDecimals)` - the amount granularity the OFT can send.
     */
    function decimalConversionRate() external view returns (uint256);
}
