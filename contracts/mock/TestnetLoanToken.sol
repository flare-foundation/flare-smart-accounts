// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TestnetLoanToken
 * @notice The loan token of the Sepolia rehearsal market: an ordinary ERC-20 whose supply only
 * its owner can mint. The rehearsal's evidence is drawn from that market, so nobody else may be
 * able to distort it - neither by minting, nor by burning what Morpho holds, which is why there
 * is no burn at all. Deployed to a public testnet, never to a production chain.
 */
contract TestnetLoanToken is ERC20, Ownable {
    uint8 private immutable _tokenDecimals;

    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        address _owner
    )
        ERC20(_name, _symbol)
        Ownable(_owner)
    {
        _tokenDecimals = _decimals;
    }

    /// @notice Mints `_amount` to `_to`; the owner's alone.
    function mint(
        address _to,
        uint256 _amount
    )
        external onlyOwner
    {
        _mint(_to, _amount);
    }

    function decimals()
        public view override
        returns (uint8)
    {
        return _tokenDecimals;
    }
}
