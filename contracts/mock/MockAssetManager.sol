// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IReferencedPaymentNonexistence} from "flare-periphery/src/flare/IReferencedPaymentNonexistence.sol";
import {IXRPPaymentNonexistence} from "flare-periphery/src/flare/IXRPPaymentNonexistence.sol";
import {MintableERC20} from "./MintableERC20.sol";

/**
 * @title MockAssetManager
 * @notice Behavioral FAssets asset manager mock for redemption: `redeemAmount` enforces the
 * governance-set minimum, burns the redeemed FAssets from the caller, and can fill partially
 * (as real FAssets does when redemption tickets run out), so tests exercise real balance
 * invariants instead of stubbed return values. An optional callback inside `redeemAmount`
 * models a dependency calling back into the accounts mid-redemption (a failing callback fails
 * the redemption with its own revert data bubbled up). Functions unrelated to redemption are
 * left to `vm.mockCall`.
 */
contract MockAssetManager {

    struct RedemptionRequest {
        address redeemer;
        bool active;
        uint256 amount;
    }

    MintableERC20 public immutable fAssetToken;
    uint256 public minimumRedeemAmount;
    /// @notice Cap on how much a single `redeemAmount` call redeems; 0 means "no cap".
    uint256 public maxRedeemPerCall;
    uint256 public lastRedeemValue;
    /// @notice Token minted to the redeemer on a payment default, standing in for the vault
    /// collateral / pool WNat payout of real FAssets.
    MintableERC20 public defaultPayoutToken;
    uint256 public defaultPayoutAmount;
    uint256 public lastDefaultRequestId;
    address public lastDefaultCaller;

    /// @notice Redemption requests by id, as real FAssets records them.
    mapping(uint256 requestId => RedemptionRequest) public requests;
    uint256 public lastRequestId;
    /// @notice Optional callback made from inside `redeemAmount`, after the request is recorded,
    /// forwarding `callbackValue` (out of the value this mock received).
    address public callbackTarget;
    bytes public callbackData;
    uint256 public callbackValue;

    constructor(MintableERC20 _fAssetToken) {
        fAssetToken = _fAssetToken;
    }

    function redeemAmount(
        uint256 _amountUBA,
        string calldata /* _redeemerUnderlyingAddressString */,
        address payable /* _executor */
    )
        external payable
        returns (uint256 _redeemedAmountUBA)
    {
        require(_amountUBA >= minimumRedeemAmount, "amount too small");

        _redeemedAmountUBA = _amountUBA;
        if (maxRedeemPerCall != 0 && _redeemedAmountUBA > maxRedeemPerCall) {
            // partial fill: only part of the request is redeemed, the rest stays with the caller
            _redeemedAmountUBA = maxRedeemPerCall;
        }
        // the redeemed FAssets are burned from the redeemer, and a request is recorded with
        // the redeemer identity that authorizes a later payment default
        fAssetToken.burn(msg.sender, _redeemedAmountUBA);
        lastRedeemValue = msg.value;
        lastRequestId += 1;
        requests[lastRequestId] =
            RedemptionRequest({redeemer: msg.sender, active: true, amount: _redeemedAmountUBA});

        if (callbackTarget != address(0)) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool ok, bytes memory returndata) = callbackTarget.call{value: callbackValue}(callbackData);
            if (!ok) {
                // bubble the callback's revert data verbatim
                // solhint-disable-next-line no-inline-assembly
                assembly {
                    revert(add(returndata, 32), mload(returndata))
                }
            }
        }
    }

    function redemptionPaymentDefault(
        IReferencedPaymentNonexistence.Proof calldata /* _proof */,
        uint256 _redemptionRequestId
    )
        external
    {
        _payOutDefault(_redemptionRequestId);
    }

    function xrpRedemptionPaymentDefault(
        IXRPPaymentNonexistence.Proof calldata _proof,
        uint256 _redemptionRequestId
    )
        external
    {
        // the XRP-specific path additionally binds the proof to its authorized user; the asset
        // manager's caller is the relay's account, so proofOwner must be zero or that account
        address proofOwner = _proof.data.requestBody.proofOwner;
        require(proofOwner == address(0) || proofOwner == msg.sender, "only proof owner");
        _payOutDefault(_redemptionRequestId);
    }

    function setRedeemCallback(address _target, bytes calldata _data, uint256 _value) external {
        callbackTarget = _target;
        callbackData = _data;
        callbackValue = _value;
    }

    function setDefaultPayout(MintableERC20 _token, uint256 _amount) external {
        defaultPayoutToken = _token;
        defaultPayoutAmount = _amount;
    }

    function setMinimumRedeemAmountUBA(uint256 _minimumRedeemAmount) external {
        minimumRedeemAmount = _minimumRedeemAmount;
    }

    function setMaxRedeemPerCall(uint256 _maxRedeemPerCall) external {
        maxRedeemPerCall = _maxRedeemPerCall;
    }

    function fAsset() external view returns (IERC20) {
        return IERC20(address(fAssetToken));
    }

    function minimumRedeemAmountUBA() external view returns (uint256) {
        return minimumRedeemAmount;
    }

    /// @dev Models the real FAssets checks that matter to these tests: the request must exist
    /// and be active (no replay), the caller must be authorized (only the recorded redeemer is
    /// modeled; the appointed executor and agent owner are not), and the payout goes to the
    /// stored redeemer, not to the caller.
    function _payOutDefault(uint256 _redemptionRequestId) private {
        RedemptionRequest storage request = requests[_redemptionRequestId];
        require(request.active, "invalid request id");
        require(msg.sender == request.redeemer, "only redeemer, executor or agent");
        request.active = false;

        lastDefaultRequestId = _redemptionRequestId;
        lastDefaultCaller = msg.sender;
        if (address(defaultPayoutToken) != address(0)) {
            defaultPayoutToken.mint(request.redeemer, defaultPayoutAmount);
        }
    }
}
