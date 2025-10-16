// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6 <0.9;

// ERC4626-compatible vault
interface IIVault {

    // Firelight and Upshift
    function deposit(
        uint256 _assets,
        address _receiver
    )
        external
        returns (uint256 _shares);

    // Firelight
    function withdraw(
        uint256 _assets,
        address _receiver,
        address _owner
    )
        external
        returns (uint256 _shares);

    // Firelight
    function claimWithdraw(
        uint256 _period
    )
        external
        returns (uint256 _assets);

    // Upshift
    function requestRedeem(
        uint256 _shares,
        address _receiverAddr,
        address _holderAddr
    )
        external
        returns (uint256 _assets, uint256 _claimableEpoch);

    // Upshift
    function claim(
        uint256 _year,
        uint256 _month,
        uint256 _day,
        address _receiverAddr
    )
        external
        returns (uint256 _shares, uint256 _assets);

    // Firelight and Upshift
    function asset() external view returns (address);
}
