// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {AuctionRevenueFixture} from "./AuctionRevenue.t.sol";
import {Auction} from "../src/Auction.sol";
import {FakeUSDC} from "../src/FakeUSDC.sol";
import {LotNFT} from "../src/LotNFT.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IVRFCoordinatorV2Plus} from "../src/interfaces/IVRFCoordinatorV2Plus.sol";

contract RevenueMintReceiver is IERC721Receiver {
    address private target;
    bytes[] private attacks;
    bool private rejectMint;
    bool[] public succeeded;
    bytes[] public results;

    function arm(address target_, bytes[] memory attacks_, bool reject_) external {
        target = target_;
        attacks = attacks_;
        rejectMint = reject_;
        delete succeeded;
        delete results;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        for (uint256 i; i < attacks.length; ++i) {
            (bool ok, bytes memory result) = target.call(attacks[i]);
            succeeded.push(ok);
            results.push(result);
        }
        require(!rejectMint, "Receiver rejected mint");
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev Executes the actual transfer before returning false/no data, so tests
/// verify whole-call rollback rather than only mocking the return value.
contract RevenueReturnValueUSDC is FakeUSDC {
    uint8 public mode;

    function setMode(uint8 value) external {
        mode = value;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount);
        return _returnValue();
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);
        return _returnValue();
    }

    function _returnValue() private view returns (bool) {
        if (mode == 1) return false;
        if (mode == 2) assembly ("memory-safe") { return(0, 0) }
        return true;
    }
}

/// @dev Threat model: untrusted callers, NFT recipients and stale authorizations.
/// DEFAULT_ADMIN remains a trusted upgrade/role-grant authority. Production uses
/// standard USDC; tests with unusual return values verify SafeERC20 atomicity,
/// not support for arbitrary malicious, fee-on-transfer or rebasing tokens.
contract AuctionRevenueAdversarialTest is AuctionRevenueFixture {
    function _ids(uint256 first, uint256 count) private pure returns (uint256[] memory ids) {
        ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = first + i;
        }
    }

    function _authorizedBid(bytes32 lot, address bidder, uint256 amount, uint256 debt, Auction.BidType kind) private {
        Auction.BidAuthorization memory a = Auction.BidAuthorization(
            lot,
            bidder,
            amount,
            kind,
            debt,
            2000 * U,
            keccak256(abi.encode("debt-bid", ++nonceCounter)),
            block.timestamp + 1 hours
        );
        bytes32 hash = keccak256(
            abi.encode(
                keccak256(
                    "BidAuthorization(bytes32 lotId,address bidder,uint256 amount,uint8 bidType,uint256 depositDebt,uint256 biddingLimit,bytes32 nonce,uint256 deadline)"
                ),
                a.lotId,
                a.bidder,
                a.amount,
                a.bidType,
                a.depositDebt,
                a.biddingLimit,
                a.nonce,
                a.deadline
            )
        );
        bytes memory signature = _sign(hash, ADMIN_KEY, address(auction), block.chainid);
        vm.prank(bidder);
        if (kind == Auction.BidType.Manual) auction.placeBid(a, signature);
        else auction.setMaxBid(a, signature);
    }

    function testFuzzRevenueMaxCannotSpendManualOrMaxBidCollateralWithAnyDepositDebt(
        uint96 rawManualDebt,
        uint96 rawMaxDebt
    ) public {
        uint256 manualDebt = bound(uint256(rawManualDebt), 0, 100 * U);
        uint256 maxDebt = bound(uint256(rawMaxDebt), 0, 200 * U);
        bytes32 active = _create(1, 10_000, 0);
        bytes32 eligible = _create(2, 100, 0);
        _buy(active, buyer, 1);
        _buy(active, otherBuyer, 1);
        _buy(eligible, buyer, 10);
        vm.prank(admin);
        auction.setBidAuthorizationRequired(true);
        _authorizedBid(active, buyer, 1000 * U, manualDebt, Auction.BidType.Manual);
        _authorizedBid(active, otherBuyer, 2000 * U, maxDebt, Auction.BidType.Maximum);
        _end(eligible);
        assertEq(auction.getMaxWithdraw(), 10 * U);
        _withdraw(10 * U);
        uint256 manualCollateral = 100 * U - manualDebt;
        uint256 maxCollateral = 200 * U - maxDebt;
        assertEq(token.balanceOf(address(auction)), 2 * U + manualCollateral + maxCollateral);
        (uint256 totalDebt, uint256 lotDebt, uint256 standard, uint256 actual) =
            auction.getBidDepositDebt(active, buyer);
        assertEq(totalDebt, manualDebt);
        assertEq(lotDebt, manualDebt);
        assertEq(standard, 100 * U);
        assertEq(actual, manualCollateral);
        uint256 beforeManual = token.balanceOf(buyer);
        uint256 beforeMax = token.balanceOf(otherBuyer);
        vm.prank(operator);
        auction.withdrawAuction(active);
        assertEq(token.balanceOf(buyer), beforeManual + manualCollateral);
        vm.prank(operator);
        auction.refundMaxBid(active, otherBuyer);
        assertEq(token.balanceOf(otherBuyer), beforeMax + maxCollateral);
        assertEq(token.balanceOf(address(auction)), 2 * U);
        (totalDebt, lotDebt, standard, actual) = auction.getBidDepositDebt(active, buyer);
        assertEq(totalDebt + lotDebt + standard + actual, 0);
        (totalDebt, lotDebt, standard, actual) = auction.getBidDepositDebt(active, otherBuyer);
        assertEq(totalDebt + lotDebt + standard + actual, 0);
        vm.prank(buyer);
        auction.claimNFTRefund(active, _ids(1, 1));
        vm.prank(otherBuyer);
        auction.claimNFTRefund(active, _ids(2, 1));
        assertEq(token.balanceOf(address(auction)), 0);
        assertEq(auction.getMaxWithdraw(), 0);
    }

    function testMintReceiverCannotReenterAnyPoolLifecycleEntryPoint() public {
        bytes32 lot = _create(1, 100, 0);
        _deposit(10 * U);
        RevenueMintReceiver receiver = new RevenueMintReceiver();
        bytes32 adminRole = auction.DEFAULT_ADMIN_ROLE();
        bytes32 opRole = auction.OPERATOR_ROLE();
        vm.startPrank(admin);
        auction.grantRole(adminRole, address(receiver));
        auction.grantRole(opRole, address(receiver));
        vm.stopPrank();
        token.mint(address(receiver), 10 * U);
        vm.prank(address(receiver));
        token.approve(address(auction), type(uint256).max);
        Auction.NFTRevenueWithdrawal memory a = _authorization(U);
        a.admin = address(receiver);
        bytes memory signature = _signature(a, SIGNER_KEY, address(auction), block.chainid);
        bytes[] memory attacks = new bytes[](6);
        attacks[0] = abi.encodeCall(auction.buyNFT, (lot, 1));
        attacks[1] = abi.encodeCall(auction.depositNFTRevenue, (U));
        attacks[2] = abi.encodeCall(auction.withdrawNFTRevenue, (a, signature));
        attacks[3] = abi.encodeCall(auction.claimNFTRefund, (lot, _ids(1, 1)));
        attacks[4] = abi.encodeCall(auction.endAuction, (lot));
        attacks[5] = abi.encodeCall(auction.settleAuctionPayment, (lot));
        receiver.arm(address(auction), attacks, false);
        vm.prank(address(receiver));
        auction.buyNFT(lot, 1);
        for (uint256 i; i < attacks.length; ++i) {
            assertFalse(receiver.succeeded(i));
            assertEq(receiver.results(i), abi.encodeWithSelector(Auction.RevenueReentrancy.selector));
        }
        assertFalse(auction.usedNonces(a.nonce));
        assertEq(auction.lotPassRevenue(lot), U);
        assertEq(auction.totalPassRevenue(), U);
        assertEq(auction.totalRevenueDeposited(), 10 * U);
        assertEq(auction.totalRevenueWithdrawn(), 0);
        assertEq(auction.getMaxWithdraw(), 10 * U);
        assertEq(token.balanceOf(address(auction)), 11 * U);
        // A failed nested call must not leave the pool locked.
        _withdraw(10 * U);
        assertEq(token.balanceOf(address(auction)), U);
    }

    function testRejectedMintRollsBackPaymentSupplyAndBothRevenueCounters() public {
        bytes32 lot = _create(1, 100, 0);
        RevenueMintReceiver receiver = new RevenueMintReceiver();
        receiver.arm(address(auction), new bytes[](0), true);
        token.mint(address(receiver), U);
        vm.prank(address(receiver));
        token.approve(address(auction), U);
        vm.expectRevert(bytes("Receiver rejected mint"));
        vm.prank(address(receiver));
        auction.buyNFT(lot, 1);
        assertEq(token.balanceOf(address(receiver)), U);
        assertEq(token.balanceOf(address(auction)), 0);
        assertEq(token.allowance(address(receiver), address(auction)), U);
        assertEq(LotNFT(auction.getAuction(lot).nftCollection).totalMinted(), 0);
        assertEq(auction.lotPassRevenue(lot), 0);
        assertEq(auction.totalPassRevenue(), 0);
        receiver.arm(address(auction), new bytes[](0), false);
        vm.prank(address(receiver));
        auction.buyNFT(lot, 1);
        assertEq(auction.lotPassRevenue(lot), U);
    }

    function testVrfFailureAndMintLimitFailureCannotCreatePhantomRevenue() public {
        bytes32 lot = _create(1, 100, 0);
        vm.mockCallRevert(
            manager.vrfCoordinator(),
            abi.encodeWithSelector(IVRFCoordinatorV2Plus.requestRandomWords.selector),
            "VRF offline"
        );
        uint256 beforeBalance = token.balanceOf(buyer);
        vm.expectRevert();
        vm.prank(buyer);
        auction.buyNFT(lot, 1);
        assertEq(token.balanceOf(buyer), beforeBalance);
        assertEq(token.balanceOf(address(auction)), 0);
        assertEq(LotNFT(auction.getAuction(lot).nftCollection).totalMinted(), 0);
        assertEq(auction.lotPassRevenue(lot), 0);
        assertEq(auction.totalPassRevenue(), 0);
        vm.clearMockedCalls();
        vm.prank(buyer);
        auction.buyNFT(lot, 1);
        vm.expectRevert(LotNFT.MintLimitExceeded.selector);
        vm.prank(buyer);
        auction.buyNFT(lot, 5);
        assertEq(auction.lotPassRevenue(lot), U);
        assertEq(auction.totalPassRevenue(), U);
        assertEq(token.balanceOf(address(auction)), U);
        _end(lot);
        _withdraw(U);
        assertEq(auction.getMaxWithdraw(), 0);
    }

    function testFalseReturningTokenRollsBackTransfersNonceAndAccountingAndNoReturnTokenWorks() public {
        RevenueReturnValueUSDC weird = new RevenueReturnValueUSDC();
        Auction target = Auction(
            address(
                new ERC1967Proxy(
                    address(new Auction()), abi.encodeCall(Auction.initialize, (weird, admin, address(manager)))
                )
            )
        );
        bytes32 signerRole = target.REVENUE_AUTHORIZER_ROLE();
        vm.prank(admin);
        target.grantRole(signerRole, signer);
        weird.mint(admin, 10 * U);
        vm.prank(admin);
        weird.approve(address(target), 10 * U);
        weird.setMode(1);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(weird)));
        vm.prank(admin);
        target.depositNFTRevenue(10 * U);
        assertEq(weird.balanceOf(admin), 10 * U);
        assertEq(weird.balanceOf(address(target)), 0);
        assertEq(target.totalRevenueDeposited(), 0);
        weird.setMode(2);
        vm.prank(admin);
        target.depositNFTRevenue(10 * U);
        assertEq(target.getMaxWithdraw(), 10 * U);
        Auction.NFTRevenueWithdrawal memory a = _authorization(10 * U);
        a.treasury = admin;
        bytes memory signature = _signature(a, SIGNER_KEY, address(target), block.chainid);
        weird.setMode(1);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(weird)));
        vm.prank(admin);
        target.withdrawNFTRevenue(a, signature);
        assertEq(weird.balanceOf(admin), 0);
        assertEq(weird.balanceOf(address(target)), 10 * U);
        assertFalse(target.usedNonces(a.nonce));
        assertEq(target.totalRevenueWithdrawn(), 0);
        weird.setMode(2);
        vm.prank(admin);
        target.withdrawNFTRevenue(a, signature);
        assertEq(weird.balanceOf(admin), 10 * U);
        assertTrue(target.usedNonces(a.nonce));
        assertEq(target.getMaxWithdraw(), 0);
    }

    function testStaleAuthorizationCannotSpendReservedRefundEvenBeforeAnyHolderClaims() public {
        bytes32 lot = _create(1, 100, 0);
        _buy(lot, buyer, 10);
        _end(lot);
        Auction.NFTRevenueWithdrawal memory a = _authorization(10 * U);
        bytes memory signature = _signature(a, SIGNER_KEY, address(auction), block.chainid);
        vm.prank(operator);
        auction.withdrawAuction(lot);
        // Physical funds exist, but have ceased to be withdrawable revenue.
        assertEq(token.balanceOf(address(auction)), 10 * U);
        vm.expectRevert(abi.encodeWithSelector(Auction.InsufficientNFTRevenue.selector, 10 * U, 0));
        vm.prank(admin);
        auction.withdrawNFTRevenue(a, signature);
        assertFalse(auction.usedNonces(a.nonce));
        _deposit(10 * U);
        vm.prank(admin);
        auction.withdrawNFTRevenue(a, signature);
        vm.prank(buyer);
        auction.claimNFTRefund(lot, _ids(1, 10));
        assertEq(token.balanceOf(address(auction)), 0);
        assertEq(auction.getMaxWithdraw(), 0);
    }

    function testWinnerPassTransferAndApprovedOperatorCannotStealRefundOrRefundComplimentaryNft() public {
        bytes32 lot = _create(1, 100, 0);
        _buy(lot, buyer, 2);
        vm.prank(buyer);
        auction.placeBid(lot, 1000 * U);
        _end(lot);
        LotNFT nft = LotNFT(auction.getAuction(lot).nftCollection);
        vm.startPrank(buyer);
        nft.transferFrom(buyer, otherBuyer, 1);
        nft.transferFrom(buyer, otherBuyer, 101);
        vm.stopPrank();
        _withdraw(2 * U);
        // An unsolicited transfer cannot bypass the tracked NAP-1004 guard.
        vm.prank(admin);
        token.transfer(address(auction), 2 * U);
        assertEq(auction.getNFTRefundShortfall(lot), 2 * U);
        vm.expectRevert(abi.encodeWithSelector(Auction.InsufficientNFTRefundFunds.selector, 2 * U, 0));
        vm.prank(operator);
        auction.withdrawAuction(lot);
        _deposit(2 * U);
        uint256 winnerBalance = token.balanceOf(buyer);
        uint256 consignorBalance = token.balanceOf(consignor);
        uint256 treasuryBalance = token.balanceOf(treasury);
        vm.prank(operator);
        auction.withdrawAuction(lot);
        assertEq(token.balanceOf(buyer), winnerBalance);
        assertEq(token.balanceOf(consignor), consignorBalance);
        assertEq(token.balanceOf(treasury), treasuryBalance);
        (uint256 quantity, uint256 refund) = auction.getNFTRefundAmount(lot, otherBuyer);
        assertEq(quantity, 1);
        assertEq(refund, U);
        vm.prank(otherBuyer);
        nft.approve(buyer, 1);
        vm.expectRevert(LotNFT.NotNftOwner.selector);
        vm.prank(buyer);
        auction.claimNFTRefund(lot, _ids(1, 1));
        vm.expectRevert(Auction.WinnerNftNotRefundable.selector);
        vm.prank(otherBuyer);
        auction.claimNFTRefund(lot, _ids(101, 1));
        vm.prank(otherBuyer);
        auction.claimNFTRefund(lot, _ids(1, 1));
        vm.prank(buyer);
        auction.claimNFTRefund(lot, _ids(2, 1));
        (quantity, refund) = auction.getNFTRefundAmount(lot, otherBuyer);
        assertEq(quantity, 0);
        assertEq(refund, 0);
        assertEq(nft.ownerOf(101), otherBuyer);
        assertEq(auction.getMaxWithdraw(), 0);
        assertEq(token.balanceOf(address(auction)), 2 * U, "donations remain unaccounted surplus");
    }

    function testPoolAccountingAndReplayProtectionSurviveUupsUpgrade() public {
        bytes32 lot = _create(1, 100, 0);
        _buy(lot, buyer, 10);
        _end(lot);
        _deposit(5 * U);
        Auction.NFTRevenueWithdrawal memory a = _authorization(U);
        bytes memory signature = _signature(a, SIGNER_KEY, address(auction), block.chainid);
        vm.prank(admin);
        auction.withdrawNFTRevenue(a, signature);
        Auction newImplementation = new Auction();
        vm.expectRevert();
        vm.prank(buyer);
        auction.upgradeToAndCall(address(newImplementation), "");
        vm.prank(admin);
        auction.upgradeToAndCall(address(newImplementation), "");
        assertEq(auction.lotPassRevenue(lot), 10 * U);
        assertEq(auction.totalPassRevenue(), 10 * U);
        assertEq(auction.eligiblePassRevenue(), 10 * U);
        assertEq(auction.totalRevenueDeposited(), 5 * U);
        assertEq(auction.totalRevenueWithdrawn(), U);
        assertEq(auction.getMaxWithdraw(), 14 * U);
        vm.expectRevert(Auction.NonceAlreadyUsed.selector);
        vm.prank(admin);
        auction.withdrawNFTRevenue(a, signature);
        _withdraw(14 * U);
        _deposit(10 * U);
        vm.prank(operator);
        auction.withdrawAuction(lot);
        vm.prank(buyer);
        auction.claimNFTRefund(lot, _ids(1, 10));
        assertEq(token.balanceOf(address(auction)), 0);
    }

    function testFuzzMultipleRoundsAndEstimateEditsCannotOvercountOrOverpayRefunds(uint8 rawFirst, uint8 rawSecond)
        public
    {
        uint256 first = bound(uint256(rawFirst), 1, 5);
        uint256 second = bound(uint256(rawSecond), 1, 5);
        bytes32 lot = _create(1, 100, 0);
        _buy(lot, buyer, first);
        vm.prank(buyer);
        auction.placeBid(lot, 1000 * U);
        vm.prank(buyer);
        token.approve(address(auction), 0);
        _end(lot);
        assertEq(auction.eligiblePassRevenue(), 0);
        vm.warp(auction.auctionPaymentDeadline(lot));
        vm.prank(operator);
        auction.settleAuctionPayment(lot);
        vm.prank(operator);
        auction.updateAuctionDetails(lot, consignor, 1500 * U, 3000 * U, "ipfs://new-estimate");
        assertEq(auction.getAuction(lot).nftPrice, U, "refund price must not change across rounds");
        _buy(lot, otherBuyer, second);
        _end(lot);
        uint256 revenue = (first + second) * U;
        assertEq(auction.lotPassRevenue(lot), revenue);
        assertEq(auction.totalPassRevenue(), revenue);
        assertEq(auction.eligiblePassRevenue(), revenue);
        _withdraw(revenue);
        _deposit(revenue);
        vm.prank(operator);
        auction.withdrawAuction(lot);
        // Blacklisting on default does not confiscate previously purchased passes.
        assertTrue(auction.blacklistedWallets(buyer));
        vm.prank(buyer);
        auction.claimNFTRefund(lot, _ids(1, first));
        vm.prank(otherBuyer);
        auction.claimNFTRefund(lot, _ids(first + 1, second));
        assertEq(token.balanceOf(address(auction)), 0);
        assertEq(auction.getMaxWithdraw(), 0);
    }

    function testFuzzPartialRefundOrderCannotReleaseAnotherLotsReserve(uint8 rawFirst, uint8 rawSecond) public {
        uint256 count = bound(uint256(rawFirst), 1, 10);
        uint256 claimCount = bound(uint256(rawSecond), 1, count);
        bytes32 a = _create(1, 100, 0);
        bytes32 b = _create(2, 100, 0);
        _buy(a, buyer, count);
        _buy(b, otherBuyer, count);
        _end(a);
        _end(b);
        vm.prank(operator);
        auction.withdrawAuction(a);
        vm.prank(buyer);
        auction.claimNFTRefund(a, _ids(1, claimCount));
        assertEq(auction.getMaxWithdraw(), count * U);
        _withdraw(count * U);
        assertEq(auction.getNFTRefundShortfall(b), count * U);
        if (claimCount < count) {
            vm.prank(buyer);
            auction.claimNFTRefund(a, _ids(claimCount + 1, count - claimCount));
        }
        assertEq(token.balanceOf(address(auction)), 0);
        _deposit(count * U);
        vm.prank(operator);
        auction.withdrawAuction(b);
        vm.prank(otherBuyer);
        auction.claimNFTRefund(b, _ids(1, count));
        assertEq(token.balanceOf(address(auction)), 0);
        assertEq(auction.getMaxWithdraw(), 0);
        assertEq(auction.totalPassRevenue(), 2 * count * U);
    }
}
