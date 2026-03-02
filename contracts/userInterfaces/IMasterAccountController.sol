// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

import {IDiamondCut} from "../diamond/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../diamond/interfaces/IDiamondLoupe.sol";
import {IERC165} from "../diamond/interfaces/IERC165.sol";
import {IERC173} from "../diamond/interfaces/IERC173.sol";

import {IAgentVaultsFacet} from "./facets/IAgentVaultsFacet.sol";
import {IExecutorsFacet} from "./facets/IExecutorsFacet.sol";
import {IInstructionFeesFacet} from "./facets/IInstructionFeesFacet.sol";
import {IInstructionsFacet} from "./facets/IInstructionsFacet.sol";
import {IPaymentProofsFacet} from "./facets/IPaymentProofsFacet.sol";
import {IPersonalAccountsFacet} from "./facets/IPersonalAccountsFacet.sol";
import {ISwapFacet} from "./facets/ISwapFacet.sol";
import {ITimelockFacet} from "./facets/ITimelockFacet.sol";
import {IVaultsFacet} from "./facets/IVaultsFacet.sol";
import {IXrplProviderWalletsFacet} from "./facets/IXrplProviderWalletsFacet.sol";

/**
 * @title IMasterAccountController
 * @notice Interface for the MasterAccountController contract,
 * which manages personal accounts and executes XRPL instructions.
 */
interface IMasterAccountController is
    IDiamondCut,
    IDiamondLoupe,
    IERC165,
    IERC173,
    IAgentVaultsFacet,
    IExecutorsFacet,
    IInstructionFeesFacet,
    IInstructionsFacet,
    IPaymentProofsFacet,
    IPersonalAccountsFacet,
    ISwapFacet,
    ITimelockFacet,
    IVaultsFacet,
    IXrplProviderWalletsFacet
{}
