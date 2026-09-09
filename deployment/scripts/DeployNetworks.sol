// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

/**
 * @title DeployNetworks
 * @notice The one place the deploy scripts agree on which chain is which. Two families:
 * the Flare family, where the home accounts live, and the loan chains, where the remote
 * accounts live. Each implementation is written for one family's chain, and a copy deployed
 * and recorded on the other family's chain would look like a legitimate artifact. Registered
 * there, it would run the other chain's logic over every account behind it: wrong behavior at
 * once, and whatever that logic writes before governance re-registers the right implementation
 * is damage the re-registration does not undo. So each deploy script refuses the OTHER family
 * by name.
 *
 * Refusing the other family, rather than allowing only its own, is deliberate: a local
 * development chain has no fixed id, so an allow-list would refuse it. The price is that a
 * chain in neither set passes both guards. That is the local-development allowance and nothing
 * else - a new production chain of either family is added to its set here before anything is
 * deployed to it, which is how the guards learned Sepolia.
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

    /// @notice The network name a chain id records under. A chain in neither family is the
    /// local development chain, `scdev`.
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
            return "scdev";
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
