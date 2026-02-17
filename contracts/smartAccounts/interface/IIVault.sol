// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6 <0.9;

// ERC4626-compatible vault
interface IIVault {

    // Firelight
    function deposit(
        uint256 _assets,
        address _receiver
    )
        external
        returns (uint256 _shares);

    // Firelight
    function redeem(
        uint256 _shares,
        address _receiver,
        address _owner
    )
        external
        returns (uint256 _assets);

    // Firelight
    function claimWithdraw(
        uint256 _period
    )
        external
        returns (uint256 _assets);

    // Upshift
    function deposit(
        address _assetIn,
        uint256 _amountIn,
        address _receiverAddr
    )
        external
        returns (uint256 _shares);

    // Upshift
    function requestRedeem(
        uint256 _shares,
        address _receiverAddr
    )
        external
        returns (uint256 _claimableEpoch, uint256 _year, uint256 _month, uint256 _day);

    // Upshift
    function claim(
        uint256 _year,
        uint256 _month,
        uint256 _day,
        address _receiverAddr
    )
        external
        returns (uint256 _shares, uint256 _assetsAfterFee);

    // Upshift
    function lpTokenAddress()
        external
        view
        returns (address);

}
