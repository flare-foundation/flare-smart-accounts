// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LoanRemoteFixture} from "../utils/LoanRemoteFixture.sol";
import {LegacyPauseRemovalFacet} from "../utils/LegacyPauseRemovalFacet.sol";
import {PauseFacet} from "../../contracts/smartAccounts/facets/PauseFacet.sol";
import {IDiamond} from "../../contracts/diamond/interfaces/IDiamond.sol";
import {IDiamondCut} from "../../contracts/diamond/interfaces/IDiamondCut.sol";
import {NotContractOwner} from "../../contracts/diamond/libraries/LibDiamond.sol";
import {IIPauseFacet} from "../../contracts/smartAccounts/interface/IIPauseFacet.sol";
import {IIComposeTransportFacet} from "../../contracts/smartAccounts/interface/IIComposeTransportFacet.sol";
import {IILoanMarketsFacet} from "../../contracts/smartAccounts/interface/IILoanMarketsFacet.sol";
import {IComposeTransportFacet} from "../../contracts/userInterfaces/facets/IComposeTransportFacet.sol";
import {ILoanMarketsFacet} from "../../contracts/userInterfaces/facets/ILoanMarketsFacet.sol";
import {IPauseFacet} from "../../contracts/userInterfaces/facets/IPauseFacet.sol";
import {ITimelockFacet} from "../../contracts/userInterfaces/facets/ITimelockFacet.sol";

/**
 * @title QueuedPauseMigrationTest
 * @notice Governance calls queued in the timelock across an incident action or a facet upgrade:
 * a clear or a pause does not cancel a queued setter, and a `removeUnpausers` queued under the
 * timelocked facet cannot self-execute once the immediate (`onlyOwner`) facet replaces it.
 */
contract QueuedPauseMigrationTest is LoanRemoteFixture {
    function setUp() public {
        _setUpRemoteFixture();
    }

    /// Proves a pre-cut removal stays queued but cannot self-execute after the immediate-removal
    /// upgrade; the owner can remove the role immediately and cancel the obsolete queue entry.
    function testQueuedRemovalAfterUpgradeRequiresDirectOwnerRecovery() public {
        address unpauser = makeAddr("legacy unpauser");
        address[] memory unpausers = new address[](1);
        unpausers[0] = unpauser;
        vm.prank(owner);
        controller.addUnpausers(unpausers);

        IDiamond.FacetCut[] memory cuts = _removalCut(
            address(new LegacyPauseRemovalFacet())
        );
        vm.prank(owner);
        controller.diamondCut(cuts, address(0), "");
        vm.prank(owner);
        controller.setTimelockDuration(2 days);

        bytes memory removal = abi.encodeCall(
            IIPauseFacet.removeUnpausers,
            (unpausers)
        );
        vm.prank(owner);
        controller.removeUnpausers(unpausers);
        uint256 allowedAfter = controller.getExecuteTimelockedCallTimestamp(
            removal
        );
        assertTrue(controller.isUnpauser(unpauser));
        assertEq(allowedAfter, block.timestamp + 2 days);

        address upgradedFacet = address(new PauseFacet());
        cuts = _removalCut(upgradedFacet);
        bytes memory upgrade = abi.encodeCall(
            IDiamondCut.diamondCut,
            (cuts, address(0), bytes(""))
        );
        vm.prank(owner);
        controller.diamondCut(cuts, address(0), "");
        vm.warp(allowedAfter);
        controller.executeTimelockedCall(upgrade);
        assertEq(
            controller.facetAddress(IIPauseFacet.removeUnpausers.selector),
            upgradedFacet
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                NotContractOwner.selector,
                address(controller),
                owner
            )
        );
        controller.executeTimelockedCall(removal);
        assertTrue(controller.isUnpauser(unpauser));
        assertEq(
            controller.getExecuteTimelockedCallTimestamp(removal),
            allowedAfter
        );

        vm.expectEmit(address(controller));
        emit IPauseFacet.UnpauserRemoved(unpauser);
        vm.prank(owner);
        controller.removeUnpausers(unpausers);
        assertFalse(controller.isUnpauser(unpauser));
        assertEq(
            controller.getExecuteTimelockedCallTimestamp(removal),
            allowedAfter
        );

        vm.prank(owner);
        controller.cancelTimelockedCall(removal);
        vm.expectRevert(ITimelockFacet.TimelockInvalidSelector.selector);
        controller.getExecuteTimelockedCallTimestamp(removal);
    }

    /// Proves clearing transport does not cancel an already queued setter: its original ETA
    /// survives, and permissionless execution restores all four transport fields after that ETA.
    function testQueuedTransportSurvivesImmediateClear() public {
        IComposeTransportFacet.Transport memory expected = controller.getComposeTransport();
        vm.prank(owner);
        controller.setTimelockDuration(2 days);
        bytes memory queued = abi.encodeCall(
            IIComposeTransportFacet.setComposeTransport,
            (expected)
        );
        vm.prank(owner);
        controller.setComposeTransport(expected);
        uint256 allowedAfter = controller.getExecuteTimelockedCallTimestamp(
            queued
        );
        assertEq(allowedAfter, block.timestamp + 2 days);

        vm.prank(owner);
        controller.clearComposeTransport();
        IComposeTransportFacet.Transport memory cleared = controller.getComposeTransport();
        assertEq(cleared.lzEndpoint, address(0));
        assertEq(cleared.oft, address(0));
        assertEq(cleared.originEid, 0);
        assertEq(cleared.originPeer, bytes32(0));
        assertEq(
            controller.getExecuteTimelockedCallTimestamp(queued),
            allowedAfter
        );
        vm.expectRevert(ITimelockFacet.TimelockNotAllowedYet.selector);
        controller.executeTimelockedCall(queued);

        vm.warp(allowedAfter);
        controller.executeTimelockedCall(queued);
        IComposeTransportFacet.Transport memory restored = controller.getComposeTransport();
        assertEq(restored.lzEndpoint, expected.lzEndpoint);
        assertEq(restored.oft, expected.oft);
        assertEq(restored.originEid, expected.originEid);
        assertEq(restored.originPeer, expected.originPeer);
        vm.expectRevert(ITimelockFacet.TimelockInvalidSelector.selector);
        controller.getExecuteTimelockedCallTimestamp(queued);
    }

    /// Proves pause does not cancel a fee-terms proposal or move its ETA; its exact terms can
    /// execute permissionlessly after the original delay while the controller stays paused.
    function testQueuedFeeTermsSurvivePause() public {
        ILoanMarketsFacet.FeeTerms memory original = controller.getLoanFeeTerms(
            1
        );
        ILoanMarketsFacet.FeeTerms memory proposed = ILoanMarketsFacet.FeeTerms({
                feeFloor: 0.12e18,
                feeSpread: 0.03e18,
                feeRecipient: makeAddr("queued collector")
            });
        vm.prank(owner);
        controller.setTimelockDuration(2 days);
        bytes memory queued = abi.encodeCall(
            IILoanMarketsFacet.setLoanFeeTerms,
            (1, proposed)
        );
        vm.prank(owner);
        controller.setLoanFeeTerms(1, proposed);
        uint256 allowedAfter = controller.getExecuteTimelockedCallTimestamp(
            queued
        );
        assertEq(allowedAfter, block.timestamp + 2 days);

        vm.prank(owner);
        controller.pause();
        ILoanMarketsFacet.FeeTerms memory pending = controller.getLoanFeeTerms(
            1
        );
        assertTrue(controller.isPaused());
        assertEq(pending.feeFloor, original.feeFloor);
        assertEq(pending.feeSpread, original.feeSpread);
        assertEq(pending.feeRecipient, original.feeRecipient);
        assertEq(
            controller.getExecuteTimelockedCallTimestamp(queued),
            allowedAfter
        );
        vm.expectRevert(ITimelockFacet.TimelockNotAllowedYet.selector);
        controller.executeTimelockedCall(queued);

        vm.warp(allowedAfter);
        controller.executeTimelockedCall(queued);
        ILoanMarketsFacet.FeeTerms memory applied = controller.getLoanFeeTerms(
            1
        );
        assertEq(applied.feeFloor, proposed.feeFloor);
        assertEq(applied.feeSpread, proposed.feeSpread);
        assertEq(applied.feeRecipient, proposed.feeRecipient);
        assertTrue(controller.isPaused());
        vm.expectRevert(ITimelockFacet.TimelockInvalidSelector.selector);
        controller.getExecuteTimelockedCallTimestamp(queued);
    }

    function _removalCut(
        address _facet
    )
        private pure
        returns (IDiamond.FacetCut[] memory _cuts)
    {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IIPauseFacet.removeUnpausers.selector;
        _cuts = new IDiamond.FacetCut[](1);
        _cuts[0] = IDiamond.FacetCut(
            _facet,
            IDiamond.FacetCutAction.Replace,
            selectors
        );
    }
}
