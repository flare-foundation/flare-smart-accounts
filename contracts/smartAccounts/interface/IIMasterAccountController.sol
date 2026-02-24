// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

import {IDiamondCut} from "../../diamond/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../../diamond/interfaces/IDiamondLoupe.sol";
import {IERC165} from "../../diamond/interfaces/IERC165.sol";
import {IERC173} from "../../diamond/interfaces/IERC173.sol";

import {IIAgentVaultsFacet} from "./IIAgentVaultsFacet.sol";
import {IIExecutorsFacet} from "./IIExecutorsFacet.sol";
import {IIInstructionFeesFacet} from "./IIInstructionFeesFacet.sol";
import {IIInstructionsFacet} from "./IIInstructionsFacet.sol";
import {IIPaymentProofsFacet} from "./IIPaymentProofsFacet.sol";
import {IIPersonalAccountsFacet} from "./IIPersonalAccountsFacet.sol";
import {IISwapFacet} from "./IISwapFacet.sol";
import {IITimelockFacet} from "./IITimelockFacet.sol";
import {IIVaultsFacet} from "./IIVaultsFacet.sol";
import {IIXrplProviderWalletsFacet} from "./IIXrplProviderWalletsFacet.sol";

/**
 * @title IIMasterAccountController
 * @notice Internal interface for the MasterAccountController contract,
 * which manages personal accounts and executes XRPL instructions.
 */
interface IIMasterAccountController is
    IDiamondCut,
    IDiamondLoupe,
    IERC165,
    IERC173,
    IIAgentVaultsFacet,
    IIExecutorsFacet,
    IIInstructionFeesFacet,
    IIInstructionsFacet,
    IIPaymentProofsFacet,
    IIPersonalAccountsFacet,
    IISwapFacet,
    IITimelockFacet,
    IIVaultsFacet,
    IIXrplProviderWalletsFacet
{}
