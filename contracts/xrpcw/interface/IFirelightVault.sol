
// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6 <0.9;

// Firelight ERC4626-compatible vault
interface IFirelightVault {
    function mint(uint256 _shares, address receiver) external returns (uint256);
    function withdraw(uint256 _assets, address receiver, address owner) external returns (uint256);
    function claimWithdraw(uint256 _period) external returns (uint256);
}
