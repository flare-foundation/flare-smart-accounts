// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9;

/*
 * The subaccount type ids this deployment has allocated. A type is not a protocol concept beyond
 * the reserved zero ({SUBACCOUNT_TYPE_NONE}, declared with the facet that refuses it): the
 * contracts accept any registered non-zero value, and what a type then has is whatever governance
 * gave it, per chain. Every type needs an implementation registered on each chain it lives on. A
 * type that bridges also has a route, and a loan type a market, registered on the loan-chain
 * controller and read back there with `getLoanMarket(type)`; a Flare-only type - the planned
 * withdraw-and-redeem product is one - has neither. So the allocations live here, with the rest of
 * what a deployment decides, rather than in the user interface, and `docs/specs/ApiReference.md`
 * publishes them for integrators. An id appearing here says this repository allocated it, not that
 * any chain has it registered: that is a per-chain question, answered by
 * `implementationForType(type)` on the controller. The TypeScript side mirrors this file in
 * `deployment/utils/implementation-verify.ts`.
 */

/// @dev The loan pair: `MorphoLoanSubaccountRemote` on the loan chain against the Flare
/// `LoanSubaccount`, borrowing on one Morpho market - FXRP against RLUSD at launch, registered
/// write-once. A second market, on Morpho or anywhere else, is a second allocation, since the
/// market a type borrows on can never change under a position; when that happens the two are
/// numbered (`..._MORPHO_LOAN_1`, `..._MORPHO_LOAN_2`), which costs nothing but a source sweep
/// here and in the tooling, no integrator importing this file.
uint256 constant SUBACCOUNT_TYPE_MORPHO_LOAN = 1;
