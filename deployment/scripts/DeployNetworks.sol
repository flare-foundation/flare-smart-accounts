// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title DeployNetworks
 * @notice The one place the deploy scripts agree on which chain is which. Two families: the
 * Flare family, where the home accounts live, and the loan chains, where the remote accounts
 * live. Each implementation is written for one family's chain, and a copy deployed and recorded
 * on the other family's chain would look like a legitimate artifact. Registered there, it would
 * run the other chain's logic over every account behind it: wrong behavior at once, and whatever
 * that logic writes before governance re-registers the right implementation is damage the
 * re-registration does not undo. So each deploy script allows its own family and nothing else,
 * and a chain in neither family has no name here: the scripts refuse it before anything is
 * deployed or recorded. A new production chain of either family is added to its set here before
 * anything is deployed to it; a rehearsal runs against a fork of the real chain, under its name.
 */
library DeployNetworks {
    /// @notice A chain the home accounts (`PersonalAccount`, `LoanSubaccount`) belong on.
    function isFlareFamily(
        uint256 _chainId
    )
        internal pure
        returns (bool)
    {
        return _chainId == 14 || _chainId == 19 || _chainId == 16 || _chainId == 114;
    }

    /// @notice A chain the remote accounts (`PersonalAccountRemote`, `MorphoLoanSubaccountRemote`)
    /// belong on: Ethereum, and Sepolia as its testnet.
    function isLoanChain(
        uint256 _chainId
    )
        internal pure
        returns (bool)
    {
        return _chainId == 1 || _chainId == 11155111;
    }

    /// @notice The network name a chain id records under. A chain in neither family is refused:
    /// no record, chain config or cut directory exists for it, and the id is printed for the
    /// operator holding the mis-set RPC variable.
    function networkName(
        uint256 _chainId
    )
        internal pure
        returns (string memory)
    {
        if (_chainId == 14) {
            return "flare";
        } else if (_chainId == 19) {
            return "songbird";
        } else if (_chainId == 16) {
            return "coston";
        } else if (_chainId == 114) {
            return "coston2";
        } else if (_chainId == 1) {
            return "ethereum";
        } else if (_chainId == 11155111) {
            return "sepolia";
        } else {
            revert(string.concat("chain id ", Strings.toString(_chainId), " is not a known network"));
        }
    }

    /// @dev The wrapper picks the RPC by network name while the script derives the network
    /// from the chain id; the two must agree, or a mis-set RPC variable would silently
    /// retarget the whole flow to another chain.
    function requireExpectedNetwork(
        string memory _derived,
        string calldata _expected
    )
        internal pure
    {
        require(
            keccak256(bytes(_derived)) == keccak256(bytes(_expected)),
            string.concat("RPC chain is ", _derived, ", not the named network ", _expected)
        );
    }
}
