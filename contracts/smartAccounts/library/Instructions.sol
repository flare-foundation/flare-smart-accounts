// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ContractRegistry} from "flare-periphery/src/flare/ContractRegistry.sol";
import {IIPersonalAccount} from "../interface/IIPersonalAccount.sol";
import {IInstructionsFacet} from "../../userInterfaces/facets/IInstructionsFacet.sol";
import {FXrp} from "./FXrp.sol";
import {Vault} from "./Vault.sol";
import {Vaults} from "./Vaults.sol";
import {PaymentReferenceParser} from "./PaymentReferenceParser.sol";

library Instructions {

    struct State {
        /// @notice Indicates if payment instruction has already been executed.
        mapping(bytes32 transactionId => bool) usedPaymentHashes;
        /// @notice Mapping from collateral reservation ID to XRPL transaction ID - used for deposit after minting
        mapping(uint256 collateralReservationId => bytes32 transactionId) collateralReservationIdToTransactionId;
    }

    bytes32 internal constant STATE_POSITION = keccak256("smartAccounts.Instructions.State");

    function executeInstruction(
        uint256 _instructionType,
        uint256 _instructionCommand,
        bytes32 _paymentReference,
        IIPersonalAccount _personalAccount
    )
        internal
    {
        if (_instructionType == 0 && _instructionCommand == 1) { // transfer FXRP
            uint256 amount = PaymentReferenceParser.getValue(_paymentReference);
            address recipient = PaymentReferenceParser.getAddress(_paymentReference);
            FXrp.transfer(_personalAccount, recipient, amount);
        } else if (_instructionType == 0 && _instructionCommand == 2) { // redeem FXRP
            uint256 lots = PaymentReferenceParser.getValue(_paymentReference);
            FXrp.redeem(_personalAccount, lots);
        } else if ((_instructionType == 1 || _instructionType == 2) && _instructionCommand == 1) { // deposit
            uint256 amount = PaymentReferenceParser.getValue(_paymentReference);
            address vault = Vaults.getVaultAddress(_paymentReference);
            Vault.deposit(_personalAccount, vault, amount);
        } else if (_instructionType == 1 && _instructionCommand == 2) { // redeem
            address vault = Vaults.getVaultAddress(_paymentReference);
            uint256 shares = PaymentReferenceParser.getValue(_paymentReference);
            Vault.redeem(_personalAccount, vault, shares);
        } else if (_instructionType == 1 && _instructionCommand == 3) { // claim withdraw
            uint256 period = PaymentReferenceParser.getValue(_paymentReference);
            address vault = Vaults.getVaultAddress(_paymentReference);
            Vault.claimWithdrawal(_personalAccount, vault, period);
        } else if (_instructionType == 1 && _instructionCommand == 4) { // claim withdraw and redeem FXRP
            uint256 period = PaymentReferenceParser.getValue(_paymentReference);
            address vault = Vaults.getVaultAddress(_paymentReference);
            uint256 amount = Vault.claimWithdrawal(_personalAccount, vault, period);
            uint256 lots = FXrp.amountToLots(amount);
            FXrp.redeem(_personalAccount, lots);
        } else if (_instructionType == 2 && _instructionCommand == 2) { // requestRedeem
            uint256 shares = PaymentReferenceParser.getValue(_paymentReference);
            address vault = Vaults.getVaultAddress(_paymentReference);
            Vault.requestRedeem(_personalAccount, vault, shares);
        } else if (_instructionType == 2 && _instructionCommand == 3) { // claim
            uint256 date = PaymentReferenceParser.getValue(_paymentReference);
            address vault = Vaults.getVaultAddress(_paymentReference);
            Vault.claim(_personalAccount, vault, date);
        } else if (_instructionType == 2 && _instructionCommand == 4) { // claim and redeem FXRP
            uint256 date = PaymentReferenceParser.getValue(_paymentReference);
            address vault = Vaults.getVaultAddress(_paymentReference);
            uint256 amount = Vault.claim(_personalAccount, vault, date);
            uint256 lots = FXrp.amountToLots(amount);
            FXrp.redeem(_personalAccount, lots);
        } else {
            revert IInstructionsFacet.InvalidInstruction(_instructionType, _instructionCommand);
        }
    }

    function getState()
        internal pure
        returns (State storage _state)
    {
        bytes32 position = STATE_POSITION;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            _state.slot := position
        }
    }
}
