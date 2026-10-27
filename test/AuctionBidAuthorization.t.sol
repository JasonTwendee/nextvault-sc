// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";
import {Auction} from "../src/Auction.sol";
import {FakeUSDC} from "../src/FakeUSDC.sol";
import {LotNFT} from "../src/LotNFT.sol";
import {NFTDesignManager} from "../src/NFTDesignManager.sol";
import {MockVRFCoordinator} from "./mocks/MockVRFCoordinator.sol";

contract AuctionBidAuthorizationTest is Test {
    Auction private auction;
    FakeUSDC private token;

    uint256 private constant ADMIN_KEY = 0xA11CE;
    address private admin = vm.addr(ADMIN_KEY);
    address private operator = makeAddr("operator");
    address private consignor = makeAddr("consignor");
    address private bidderA = makeAddr("bidderA");
    address private bidderB = makeAddr("bidderB");

    bytes32 private constant LOT_ID = bytes32(uint256(1));
    bytes32 private constant LOT_ID_2 = bytes32(uint256(2));
    uint256 private constant USDC = 1e6;
    uint256 private constant STARTING_BID = 10_000 * USDC;
    uint256 private constant NFT_PRICE = 10 * USDC;

    function setUp() external {
        token = new FakeUSDC();
        MockVRFCoordinator vrf = new MockVRFCoordinator();
        LotNFT lotNFTImplementation = new LotNFT();
        NFTDesignManager designManager = new NFTDesignManager(
            admin, address(lotNFTImplementation), address(vrf), 1, bytes32(uint256(1)), 500_000, 3, false
        );
        Auction implementation = new Auction();
        bytes memory initData = abi.encodeCall(Auction.initialize, (token, admin, address(designManager)));
        auction = Auction(address(new ERC1967Proxy(address(implementation), initData)));

        vm.prank(admin);
        designManager.initializeAuction(address(auction));
        bytes32 operatorRole = auction.OPERATOR_ROLE();
        vm.prank(admin);
        auction.grantRole(operatorRole, operator);

        token.mint(bidderA, 100_000 * USDC);
        token.mint(bidderB, 100_000 * USDC);
        _createActiveAuction();
        _buyNft(bidderA);
        _buyNft(bidderB);
    }

    function testBidAuthorizationIsRequiredByDefault() external {
        vm.prank(bidderA);
        vm.expectRevert(Auction.BidAuthorizationRequired.selector);
        auction.placeBid(LOT_ID, STARTING_BID);

        vm.prank(bidderA);
        vm.expectRevert(Auction.BidAuthorizationRequired.selector);
        auction.setMaxBid(LOT_ID, STARTING_BID);
    }

    function testAuthorizedManualBidUsesSignedAmount() external {
        Auction.BidAuthorization memory authorization =
            _authorization(bidderA, STARTING_BID, Auction.BidType.Manual, "manual");
        bytes memory signature = _signBidAuthorization(authorization, ADMIN_KEY);
        _approveBidDeposit(bidderA, STARTING_BID);

        vm.prank(bidderA);
        auction.placeBid(authorization, signature);

        assertTrue(auction.usedNonces(authorization.nonce));
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 2 + STARTING_BID / 10);
    }

    function testAuthorizedHighestBidderManualBidBecomesMaximumBid() external {
        _approveBidDeposit(bidderA, STARTING_BID);
        _placeAuthorizedBid(LOT_ID, bidderA, STARTING_BID, 0, 0, "leader-current");

        uint256 nextBid = 11_000 * USDC;
        Auction.BidAuthorization memory authorization =
            _authorization(bidderA, nextBid, Auction.BidType.Manual, "leader-next");
        bytes memory signature = _signBidAuthorization(authorization, ADMIN_KEY);
        _approveBidDeposit(bidderA, nextBid);

        vm.prank(bidderA);
        auction.placeBid(authorization, signature);

        (,, uint256 standardDeposit,) = auction.getBidDepositDebt(LOT_ID, bidderA);
        assertEq(standardDeposit, nextBid / 10);

        Auction.AuctionConfig memory config = auction.getAuction(LOT_ID);
        vm.warp(config.endTime);
        vm.prank(operator);
        (address winner, uint256 winningBid,) = auction.endAuction(LOT_ID);

        assertEq(winner, bidderA);
        assertEq(winningBid, STARTING_BID);
    }

    function testManualBidRejectsAmountChangedAfterSigning() external {
        Auction.BidAuthorization memory authorization =
            _authorization(bidderA, STARTING_BID, Auction.BidType.Manual, "tampered-amount");
        bytes memory signature = _signBidAuthorization(authorization, ADMIN_KEY);
        authorization.amount += USDC;

        vm.prank(bidderA);
        vm.expectRevert(Auction.InvalidSigner.selector);
        auction.placeBid(authorization, signature);
    }

    function testManualBidRejectsDifferentCaller() external {
        Auction.BidAuthorization memory authorization =
            _authorization(bidderA, STARTING_BID, Auction.BidType.Manual, "wrong-bidder");
        bytes memory signature = _signBidAuthorization(authorization, ADMIN_KEY);

        vm.prank(bidderB);
        vm.expectRevert(Auction.InvalidBidAuthorization.selector);
        auction.placeBid(authorization, signature);
    }

    function testBidAuthorizationCannotBeReusedOnAnotherAuctionProxy() external {
        Auction.BidAuthorization memory authorization =
            _authorization(bidderA, STARTING_BID, Auction.BidType.Manual, "wrong-proxy");
        bytes memory signature = _signBidAuthorization(authorization, ADMIN_KEY);
        Auction secondImplementation = new Auction();
        Auction secondAuction = Auction(
            address(
                new ERC1967Proxy(
                    address(secondImplementation),
                    abi.encodeCall(Auction.initialize, (token, admin, auction.nftDesignManager()))
                )
            )
        );

        vm.prank(bidderA);
        vm.expectRevert(Auction.InvalidSigner.selector);
        secondAuction.placeBid(authorization, signature);
    }

    function testBidAuthorizationCannotBeReusedOnAnotherChain() external {
        Auction.BidAuthorization memory authorization =
            _authorization(bidderA, STARTING_BID, Auction.BidType.Manual, "wrong-chain");
        bytes memory signature = _signBidAuthorization(authorization, ADMIN_KEY);
        vm.chainId(block.chainid + 1);

        vm.prank(bidderA);
        vm.expectRevert(Auction.InvalidSigner.selector);
        auction.placeBid(authorization, signature);
    }

    function testManualBidAuthorizationCannotBeReplayed() external {
        Auction.BidAuthorization memory authorization =
            _authorization(bidderA, STARTING_BID, Auction.BidType.Manual, "replay");
        bytes memory signature = _signBidAuthorization(authorization, ADMIN_KEY);
        _approveBidDeposit(bidderA, STARTING_BID);

        vm.prank(bidderA);
        auction.placeBid(authorization, signature);

        vm.prank(bidderA);
        vm.expectRevert(Auction.NonceAlreadyUsed.selector);
        auction.placeBid(authorization, signature);
    }

    function testManualBidRejectsExpiredAuthorization() external {
        Auction.BidAuthorization memory authorization =
            _authorization(bidderA, STARTING_BID, Auction.BidType.Manual, "expired");
        authorization.deadline = block.timestamp - 1;
        bytes memory signature = _signBidAuthorization(authorization, ADMIN_KEY);

        vm.prank(bidderA);
        vm.expectRevert(Auction.AuthorizationExpired.selector);
        auction.placeBid(authorization, signature);
    }

    function testAuthorizedMaximumBidKeepsOperatorAutobidFlow() external {
        uint256 maxBid = 15_000 * USDC;
        Auction.BidAuthorization memory authorization =
            _authorization(bidderA, maxBid, Auction.BidType.Maximum, "maximum");
        bytes memory signature = _signBidAuthorization(authorization, ADMIN_KEY);
        _approveBidDeposit(bidderA, maxBid);

        vm.prank(bidderA);
        auction.setMaxBid(authorization, signature);

        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderA, STARTING_BID);

        assertTrue(auction.usedNonces(authorization.nonce));
    }

    function testManualAuthorizationCannotSetMaximumBid() external {
        Auction.BidAuthorization memory authorization =
            _authorization(bidderA, STARTING_BID, Auction.BidType.Manual, "wrong-type");
        bytes memory signature = _signBidAuthorization(authorization, ADMIN_KEY);

        vm.prank(bidderA);
        vm.expectRevert(Auction.InvalidBidAuthorization.selector);
        auction.setMaxBid(authorization, signature);
    }

    function testBidAuthorizationRejectsSignerWithoutOperatorRole() external {
        Auction.BidAuthorization memory authorization =
            _authorization(bidderA, STARTING_BID, Auction.BidType.Manual, "non-operator");
        bytes memory signature = _signBidAuthorization(authorization, 0xB0B);

        vm.prank(bidderA);
        vm.expectRevert(Auction.InvalidSigner.selector);
        auction.placeBid(authorization, signature);
    }

    function testDepositFreeBidTracksDebtWithoutPullingDeposit() external {
        Auction.BidAuthorization memory authorization = _authorizationWithDebt(
            LOT_ID, bidderA, STARTING_BID, Auction.BidType.Manual, STARTING_BID / 10, STARTING_BID, "free"
        );
        bytes memory signature = _signBidAuthorization(authorization, ADMIN_KEY);
        uint256 balanceBefore = token.balanceOf(bidderA);

        vm.prank(bidderA);
        auction.placeBid(authorization, signature);

        (uint256 totalDebt, uint256 auctionDebt, uint256 standardDeposit, uint256 actualDeposit) =
            auction.getBidDepositDebt(LOT_ID, bidderA);
        assertEq(totalDebt, STARTING_BID / 10);
        assertEq(auctionDebt, STARTING_BID / 10);
        assertEq(standardDeposit, STARTING_BID / 10);
        assertEq(actualDeposit, 0);
        assertEq(token.balanceOf(bidderA), balanceBefore);
    }

    function testPartialDepositUsesOnlyCreditRemainingAcrossAuctions() external {
        _createActiveAuctionFor(LOT_ID_2, "create-auction-2");
        _buyNftFor(LOT_ID_2, bidderA);
        uint256 biddingLimit = 15_000 * USDC;

        _placeAuthorizedBid(LOT_ID, bidderA, STARTING_BID, STARTING_BID / 10, biddingLimit, "auction-1");

        uint256 secondDebt = 500 * USDC;
        uint256 secondActualDeposit = STARTING_BID / 10 - secondDebt;
        vm.prank(bidderA);
        token.approve(address(auction), secondActualDeposit);
        _placeAuthorizedBid(LOT_ID_2, bidderA, STARTING_BID, secondDebt, biddingLimit, "auction-2");

        (uint256 totalDebt, uint256 auctionDebt,, uint256 actualDeposit) = auction.getBidDepositDebt(LOT_ID_2, bidderA);
        assertEq(totalDebt, biddingLimit / 10);
        assertEq(auctionDebt, secondDebt);
        assertEq(actualDeposit, secondActualDeposit);
    }

    function testConcurrentStaleAuthorizationsCannotOverspendCredit() external {
        _createActiveAuctionFor(LOT_ID_2, "create-auction-2");
        _buyNftFor(LOT_ID_2, bidderA);

        Auction.BidAuthorization memory first = _authorizationWithDebt(
            LOT_ID, bidderA, STARTING_BID, Auction.BidType.Manual, STARTING_BID / 10, STARTING_BID, "stale-1"
        );
        Auction.BidAuthorization memory second = _authorizationWithDebt(
            LOT_ID_2, bidderA, STARTING_BID, Auction.BidType.Manual, STARTING_BID / 10, STARTING_BID, "stale-2"
        );
        bytes memory firstSignature = _signBidAuthorization(first, ADMIN_KEY);
        bytes memory secondSignature = _signBidAuthorization(second, ADMIN_KEY);

        vm.prank(bidderA);
        auction.placeBid(first, firstSignature);

        vm.prank(bidderA);
        vm.expectRevert(Auction.DepositDebtLimitExceeded.selector);
        auction.placeBid(second, secondSignature);
    }

    function testAuthorizationRejectsTamperedDebtAndLimit() external {
        Auction.BidAuthorization memory authorization = _authorizationWithDebt(
            LOT_ID, bidderA, STARTING_BID, Auction.BidType.Manual, STARTING_BID / 10, STARTING_BID, "tamper-debt"
        );
        bytes memory signature = _signBidAuthorization(authorization, ADMIN_KEY);
        authorization.depositDebt -= 1;

        vm.prank(bidderA);
        vm.expectRevert(Auction.InvalidSigner.selector);
        auction.placeBid(authorization, signature);

        authorization = _authorizationWithDebt(
            LOT_ID, bidderA, STARTING_BID, Auction.BidType.Manual, STARTING_BID / 10, STARTING_BID, "tamper-limit"
        );
        signature = _signBidAuthorization(authorization, ADMIN_KEY);
        authorization.biddingLimit += 1;

        vm.prank(bidderA);
        vm.expectRevert(Auction.InvalidSigner.selector);
        auction.placeBid(authorization, signature);
    }

    function testLoweredLimitGrandfathersDebtButRejectsDebtIncrease() external {
        _placeAuthorizedBid(LOT_ID, bidderA, STARTING_BID, STARTING_BID / 10, STARTING_BID, "initial-debt");

        vm.prank(bidderA);
        token.approve(address(auction), 100 * USDC);
        _placeAuthorizedBid(LOT_ID, bidderA, 11_000 * USDC, STARTING_BID / 10, 5_000 * USDC, "same-debt");

        Auction.BidAuthorization memory increased = _authorizationWithDebt(
            LOT_ID, bidderA, 12_000 * USDC, Auction.BidType.Manual, 1_100 * USDC, 5_000 * USDC, "increase-debt"
        );
        bytes memory signature = _signBidAuthorization(increased, ADMIN_KEY);
        vm.prank(bidderA);
        vm.expectRevert(Auction.DepositDebtLimitExceeded.selector);
        auction.placeBid(increased, signature);
    }

    function testOutbidReleasesOnlyActualDepositAndDebt() external {
        uint256 debt = 500 * USDC;
        uint256 actualDeposit = STARTING_BID / 10 - debt;
        vm.prank(bidderA);
        token.approve(address(auction), actualDeposit);
        _placeAuthorizedBid(LOT_ID, bidderA, STARTING_BID, debt, STARTING_BID, "partial-refund");

        uint256 balanceBefore = token.balanceOf(bidderA);
        _approveBidDeposit(bidderB, 11_000 * USDC);
        _placeAuthorizedBid(LOT_ID, bidderB, 11_000 * USDC, 0, 0, "outbid");

        assertEq(token.balanceOf(bidderA), balanceBefore + actualDeposit);
        (uint256 totalDebt, uint256 auctionDebt,,) = auction.getBidDepositDebt(LOT_ID, bidderA);
        assertEq(totalDebt, 0);
        assertEq(auctionDebt, 0);
    }

    function testManualAndMaxBidShareLargestAuctionExposure() external {
        vm.prank(bidderA);
        token.approve(address(auction), 500 * USDC);
        _placeAuthorizedBid(LOT_ID, bidderA, STARTING_BID, 500 * USDC, 20_000 * USDC, "manual-partial");

        _setAuthorizedMax(LOT_ID, bidderA, 15_000 * USDC, 1_000 * USDC, 20_000 * USDC, "max-partial");

        (uint256 totalDebt, uint256 auctionDebt, uint256 standardDeposit, uint256 actualDeposit) =
            auction.getBidDepositDebt(LOT_ID, bidderA);
        assertEq(totalDebt, 1_000 * USDC);
        assertEq(auctionDebt, 1_000 * USDC);
        assertEq(standardDeposit, 1_500 * USDC);
        assertEq(actualDeposit, 500 * USDC);

        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderA, 11_000 * USDC);
        (totalDebt, auctionDebt, standardDeposit, actualDeposit) = auction.getBidDepositDebt(LOT_ID, bidderA);
        assertEq(totalDebt, 1_000 * USDC);
        assertEq(auctionDebt, 1_000 * USDC);
        assertEq(standardDeposit, 1_500 * USDC);
        assertEq(actualDeposit, 500 * USDC);
    }

    function testMaxBidIncreaseCannotRetroactivelyReduceDeposit() external {
        vm.prank(bidderA);
        token.approve(address(auction), 500 * USDC);
        _setAuthorizedMax(LOT_ID, bidderA, STARTING_BID, 500 * USDC, 20_000 * USDC, "max-first");

        Auction.BidAuthorization memory reducedDeposit = _authorizationWithDebt(
            LOT_ID, bidderA, 15_000 * USDC, Auction.BidType.Maximum, 1_100 * USDC, 20_000 * USDC, "max-reallocate"
        );
        bytes memory signature = _signBidAuthorization(reducedDeposit, ADMIN_KEY);
        vm.prank(bidderA);
        vm.expectRevert(Auction.DepositCannotBeReduced.selector);
        auction.setMaxBid(reducedDeposit, signature);

        _setAuthorizedMax(LOT_ID, bidderA, 15_000 * USDC, 1_000 * USDC, 20_000 * USDC, "max-increase");
        (,,, uint256 actualDeposit) = auction.getBidDepositDebt(LOT_ID, bidderA);
        assertEq(actualDeposit, 500 * USDC);
    }

    function testZeroDepositMaxBidCanBeRefundedAfterWithdraw() external {
        _setAuthorizedMax(LOT_ID, bidderA, STARTING_BID, STARTING_BID / 10, STARTING_BID, "zero-deposit-max");

        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);
        vm.prank(operator);
        auction.refundMaxBid(LOT_ID, bidderA);

        (uint256 totalDebt, uint256 auctionDebt, uint256 standardDeposit, uint256 actualDeposit) =
            auction.getBidDepositDebt(LOT_ID, bidderA);
        assertEq(totalDebt, 0);
        assertEq(auctionDebt, 0);
        assertEq(standardDeposit, 0);
        assertEq(actualDeposit, 0);
    }

    function testWithdrawManualAndMaxRefundsCashAndReleasesAllDebt() external {
        uint256 balanceBefore = token.balanceOf(bidderA);
        vm.prank(bidderA);
        token.approve(address(auction), 500 * USDC);
        _placeAuthorizedBid(LOT_ID, bidderA, STARTING_BID, 500 * USDC, 20_000 * USDC, "withdraw-manual");
        _setAuthorizedMax(LOT_ID, bidderA, 15_000 * USDC, 1_000 * USDC, 20_000 * USDC, "withdraw-max");

        assertEq(token.balanceOf(bidderA), balanceBefore - 500 * USDC);
        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);
        vm.prank(operator);
        auction.refundMaxBid(LOT_ID, bidderA);

        assertEq(token.balanceOf(bidderA), balanceBefore);
        (uint256 totalDebt, uint256 auctionDebt, uint256 standardDeposit, uint256 actualDeposit) =
            auction.getBidDepositDebt(LOT_ID, bidderA);
        assertEq(totalDebt, 0);
        assertEq(auctionDebt, 0);
        assertEq(standardDeposit, 0);
        assertEq(actualDeposit, 0);
    }

    function testManualWinnerPaysDepositDebtExactlyOnce() external {
        uint256 actualDeposit = 400 * USDC;
        uint256 depositDebt = STARTING_BID / 10 - actualDeposit;
        uint256 bidderBalanceBefore = token.balanceOf(bidderA);
        uint256 contractBalanceBefore = token.balanceOf(address(auction));
        uint256 treasuryBalanceBefore = token.balanceOf(admin);

        vm.prank(bidderA);
        token.approve(address(auction), actualDeposit);
        _placeAuthorizedBid(LOT_ID, bidderA, STARTING_BID, depositDebt, STARTING_BID, "manual-winner");
        assertEq(token.balanceOf(address(auction)), contractBalanceBefore + actualDeposit);

        uint256 buyerPremium = STARTING_BID / 10;
        uint256 remainingPayment = STARTING_BID + buyerPremium - actualDeposit;
        vm.prank(bidderA);
        token.approve(address(auction), remainingPayment);
        vm.warp(auction.getAuction(LOT_ID).endTime);
        vm.prank(operator);
        (address winner, uint256 winningBid, bool collected) = auction.endAuction(LOT_ID);

        assertEq(winner, bidderA);
        assertEq(winningBid, STARTING_BID);
        assertTrue(collected);
        assertEq(token.balanceOf(bidderA), bidderBalanceBefore - STARTING_BID - buyerPremium);
        assertEq(token.balanceOf(consignor), 9_000 * USDC);
        assertEq(token.balanceOf(admin), treasuryBalanceBefore + 2_000 * USDC);
        assertEq(token.balanceOf(address(auction)), contractBalanceBefore);
        (uint256 totalDebt, uint256 auctionDebt,,) = auction.getBidDepositDebt(LOT_ID, bidderA);
        assertEq(totalDebt, 0);
        assertEq(auctionDebt, 0);
    }

    function testAutoBidWinnerUsesActualMaxDepositAndCollectsDebtAtSettlement() external {
        uint256 maxBid = 15_000 * USDC;
        uint256 depositDebt = 1_000 * USDC;
        uint256 actualDeposit = maxBid / 10 - depositDebt;
        uint256 bidderBalanceBefore = token.balanceOf(bidderA);

        vm.prank(bidderA);
        token.approve(address(auction), actualDeposit);
        _setAuthorizedMax(LOT_ID, bidderA, maxBid, depositDebt, 20_000 * USDC, "auto-winner-max");
        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderA, STARTING_BID);

        uint256 totalPayment = 11_000 * USDC;
        vm.prank(bidderA);
        token.approve(address(auction), totalPayment - actualDeposit);
        vm.warp(auction.getAuction(LOT_ID).endTime);
        vm.prank(operator);
        (,, bool collected) = auction.endAuction(LOT_ID);

        assertTrue(collected);
        assertEq(token.balanceOf(bidderA), bidderBalanceBefore - totalPayment);
        (uint256 totalDebt, uint256 auctionDebt,,) = auction.getBidDepositDebt(LOT_ID, bidderA);
        assertEq(totalDebt, 0);
        assertEq(auctionDebt, 0);
    }

    function testDefaultForfeitsOnlyActualDepositAndReleasesCredit() external {
        uint256 actualDeposit = 400 * USDC;
        uint256 depositDebt = STARTING_BID / 10 - actualDeposit;
        uint256 bidderBalanceBefore = token.balanceOf(bidderA);
        uint256 treasuryBalanceBefore = token.balanceOf(admin);

        vm.prank(bidderA);
        token.approve(address(auction), actualDeposit);
        _placeAuthorizedBid(LOT_ID, bidderA, STARTING_BID, depositDebt, STARTING_BID, "default-partial");
        vm.warp(auction.getAuction(LOT_ID).endTime);
        vm.prank(operator);
        auction.endAuction(LOT_ID);

        vm.warp(auction.auctionPaymentDeadline(LOT_ID));
        vm.prank(operator);
        assertFalse(auction.settleAuctionPayment(LOT_ID));

        assertEq(token.balanceOf(bidderA), bidderBalanceBefore - actualDeposit);
        assertEq(token.balanceOf(admin), treasuryBalanceBefore + actualDeposit);
        (uint256 totalDebt, uint256 auctionDebt,,) = auction.getBidDepositDebt(LOT_ID, bidderA);
        assertEq(totalDebt, 0);
        assertEq(auctionDebt, 0);
        assertTrue(auction.blacklistedWallets(bidderA));
    }

    function testFinalizedWithdrawalKeepsSettlementAndUnusedMaxAllowanceWithPartialCredit() external {
        // Same proportions as max 500 / hammer 100 / limit 100 / collateral 40.
        uint256 maxBid = STARTING_BID * 5;
        uint256 approved = maxBid * 11 / 10;
        uint256 actualDeposit = STARTING_BID * 4 / 10;
        uint256 debt = maxBid / 10 - actualDeposit;
        vm.prank(bidderA);
        token.approve(address(auction), approved);
        _setAuthorizedMax(LOT_ID, bidderA, maxBid, debt, STARTING_BID, "finalized-revoke-max");
        assertEq(token.allowance(bidderA, address(auction)), approved - actualDeposit);
        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderA, STARTING_BID);
        vm.warp(auction.getAuction(LOT_ID).endTime);
        vm.prank(operator);
        (,, bool collected) = auction.endAuction(LOT_ID);
        assertTrue(collected);
        uint256 totalPaid = STARTING_BID * 11 / 10;
        uint256 unused = approved - actualDeposit - (totalPaid - actualDeposit);
        assertEq(unused, STARTING_BID * 44 / 10);
        assertEq(token.allowance(bidderA, address(auction)), unused);
        uint256 winnerBalance = token.balanceOf(bidderA);
        uint256 consignorBalance = token.balanceOf(consignor);
        uint256 treasuryBalance = token.balanceOf(admin);
        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);
        assertEq(token.balanceOf(bidderA), winnerBalance);
        assertEq(token.balanceOf(consignor), consignorBalance);
        assertEq(token.balanceOf(admin), treasuryBalance);
        assertEq(token.allowance(bidderA, address(auction)), unused);
        vm.prank(bidderA);
        token.approve(address(auction), 0);
        assertEq(token.allowance(bidderA, address(auction)), 0);
    }

    function testNonWinnerMaxRefundDoesNotReleaseDebtFromAnotherAuction() external {
        _createActiveAuctionFor(LOT_ID_2, "refund-second-auction");
        _buyNftFor(LOT_ID_2, bidderA);
        uint256 biddingLimit = 20_000 * USDC;

        vm.prank(bidderA);
        token.approve(address(auction), 500 * USDC);
        _setAuthorizedMax(LOT_ID, bidderA, 15_000 * USDC, 1_000 * USDC, biddingLimit, "refund-max-a");
        _placeAuthorizedBid(LOT_ID_2, bidderA, STARTING_BID, 1_000 * USDC, biddingLimit, "refund-manual-b");

        vm.prank(bidderB);
        token.approve(address(auction), 1_600 * USDC);
        _setAuthorizedMax(LOT_ID, bidderB, 16_000 * USDC, 0, 0, "blocking-max");
        vm.prank(operator);
        auction.refundMaxBid(LOT_ID, bidderA);

        (uint256 totalDebtA, uint256 auctionDebtA,,) = auction.getBidDepositDebt(LOT_ID, bidderA);
        (, uint256 auctionDebtB,,) = auction.getBidDepositDebt(LOT_ID_2, bidderA);
        assertEq(totalDebtA, 1_000 * USDC);
        assertEq(auctionDebtA, 0);
        assertEq(auctionDebtB, 1_000 * USDC);
    }

    function testSettlementClearsOnlyWinningAuctionDebtAndPreservesOtherAuctionCollateral() external {
        _createActiveAuctionFor(LOT_ID_2, "settlement-second-auction");
        _buyNftFor(LOT_ID_2, bidderA);
        uint256 biddingLimit = 20_000 * USDC;

        _placeAuthorizedBid(LOT_ID, bidderA, STARTING_BID, 1_000 * USDC, biddingLimit, "winner-auction");
        vm.prank(bidderA);
        token.approve(address(auction), 500 * USDC);
        _setAuthorizedMax(LOT_ID_2, bidderA, STARTING_BID, 500 * USDC, biddingLimit, "open-auction");

        vm.prank(bidderA);
        token.approve(address(auction), 11_000 * USDC);
        vm.warp(auction.getAuction(LOT_ID).endTime);
        vm.prank(operator);
        (,, bool collected) = auction.endAuction(LOT_ID);

        assertTrue(collected);
        (uint256 totalDebt, uint256 settledAuctionDebt,,) = auction.getBidDepositDebt(LOT_ID, bidderA);
        (, uint256 openAuctionDebt, uint256 openStandardDeposit, uint256 openActualDeposit) =
            auction.getBidDepositDebt(LOT_ID_2, bidderA);
        assertEq(totalDebt, 500 * USDC);
        assertEq(settledAuctionDebt, 0);
        assertEq(openAuctionDebt, 500 * USDC);
        assertEq(openStandardDeposit, 1_000 * USDC);
        assertEq(openActualDeposit, 500 * USDC);

        uint256 bidderBalanceBeforeRefund = token.balanceOf(bidderA);
        vm.prank(operator);
        auction.refundMaxBid(LOT_ID_2, bidderA);
        assertEq(token.balanceOf(bidderA), bidderBalanceBeforeRefund + 500 * USDC);
        (totalDebt, openAuctionDebt,,) = auction.getBidDepositDebt(LOT_ID_2, bidderA);
        assertEq(totalDebt, 0);
        assertEq(openAuctionDebt, 0);
    }

    function testDebtPaydownTransfersExactAdditionalCollateral() external {
        uint256 maxBid = 10_000 * USDC;
        _setAuthorizedMax(LOT_ID, bidderA, maxBid, 1_000 * USDC, 20_000 * USDC, "fully-financed-max");
        uint256 bidderBalanceBefore = token.balanceOf(bidderA);
        uint256 contractBalanceBefore = token.balanceOf(address(auction));

        vm.prank(bidderA);
        token.approve(address(auction), 1_000 * USDC);
        _setAuthorizedMax(LOT_ID, bidderA, 15_000 * USDC, 500 * USDC, 20_000 * USDC, "pay-down-debt");

        assertEq(token.balanceOf(bidderA), bidderBalanceBefore - 1_000 * USDC);
        assertEq(token.balanceOf(address(auction)), contractBalanceBefore + 1_000 * USDC);
        (uint256 totalDebt, uint256 auctionDebt, uint256 standardDeposit, uint256 actualDeposit) =
            auction.getBidDepositDebt(LOT_ID, bidderA);
        assertEq(totalDebt, 500 * USDC);
        assertEq(auctionDebt, 500 * USDC);
        assertEq(standardDeposit, 1_500 * USDC);
        assertEq(actualDeposit, 1_000 * USDC);
    }

    function testZeroSignedLimitCannotCreateDebtOrConsumeNonce() external {
        Auction.BidAuthorization memory authorization =
            _authorizationWithDebt(LOT_ID, bidderA, STARTING_BID, Auction.BidType.Manual, 1, 0, "zero-limit-debt");
        bytes memory signature = _signBidAuthorization(authorization, ADMIN_KEY);
        uint256 bidderBalanceBefore = token.balanceOf(bidderA);
        uint256 contractBalanceBefore = token.balanceOf(address(auction));

        vm.prank(bidderA);
        vm.expectRevert(Auction.DepositDebtLimitExceeded.selector);
        auction.placeBid(authorization, signature);

        assertEq(token.balanceOf(bidderA), bidderBalanceBefore);
        assertEq(token.balanceOf(address(auction)), contractBalanceBefore);
        assertFalse(auction.usedNonces(authorization.nonce));
        (uint256 totalDebt, uint256 auctionDebt,,) = auction.getBidDepositDebt(LOT_ID, bidderA);
        assertEq(totalDebt, 0);
        assertEq(auctionDebt, 0);
    }

    function testInvalidDebtCannotMoveTokensOrConsumeNonce() external {
        Auction.BidAuthorization memory authorization = _authorizationWithDebt(
            LOT_ID,
            bidderA,
            STARTING_BID,
            Auction.BidType.Manual,
            STARTING_BID / 10 + 1,
            STARTING_BID * 2,
            "invalid-debt"
        );
        bytes memory signature = _signBidAuthorization(authorization, ADMIN_KEY);
        uint256 bidderBalanceBefore = token.balanceOf(bidderA);
        uint256 contractBalanceBefore = token.balanceOf(address(auction));

        vm.prank(bidderA);
        vm.expectRevert(Auction.InvalidBidAuthorization.selector);
        auction.placeBid(authorization, signature);

        assertEq(token.balanceOf(bidderA), bidderBalanceBefore);
        assertEq(token.balanceOf(address(auction)), contractBalanceBefore);
        assertFalse(auction.usedNonces(authorization.nonce));
    }

    function testFuzzManualRefundConservesUserFunds(uint96 rawDebt) external {
        uint256 standardDeposit = STARTING_BID / 10;
        uint256 debt = bound(uint256(rawDebt), 0, standardDeposit);
        uint256 actualDeposit = standardDeposit - debt;
        uint256 bidderBalanceBefore = token.balanceOf(bidderA);

        vm.prank(bidderA);
        token.approve(address(auction), actualDeposit);
        _placeAuthorizedBid(LOT_ID, bidderA, STARTING_BID, debt, debt * 10, "fuzz-refund");
        assertEq(token.balanceOf(bidderA), bidderBalanceBefore - actualDeposit);

        _approveBidDeposit(bidderB, 11_000 * USDC);
        _placeAuthorizedBid(LOT_ID, bidderB, 11_000 * USDC, 0, 0, "fuzz-outbid");

        assertEq(token.balanceOf(bidderA), bidderBalanceBefore);
        (uint256 totalDebt, uint256 auctionDebt,,) = auction.getBidDepositDebt(LOT_ID, bidderA);
        assertEq(totalDebt, 0);
        assertEq(auctionDebt, 0);
    }

    function testFuzzWinnerPaysSameTotalForEveryDepositDebt(uint96 rawDebt) external {
        uint256 standardDeposit = STARTING_BID / 10;
        uint256 debt = bound(uint256(rawDebt), 0, standardDeposit);
        uint256 actualDeposit = standardDeposit - debt;
        uint256 totalPayment = 11_000 * USDC;
        uint256 bidderBalanceBefore = token.balanceOf(bidderA);

        vm.prank(bidderA);
        token.approve(address(auction), actualDeposit);
        _placeAuthorizedBid(LOT_ID, bidderA, STARTING_BID, debt, debt * 10, "fuzz-winner");
        vm.prank(bidderA);
        token.approve(address(auction), totalPayment - actualDeposit);
        vm.warp(auction.getAuction(LOT_ID).endTime);
        vm.prank(operator);
        (,, bool collected) = auction.endAuction(LOT_ID);

        assertTrue(collected);
        assertEq(token.balanceOf(bidderA), bidderBalanceBefore - totalPayment);
        (uint256 totalDebt, uint256 auctionDebt,,) = auction.getBidDepositDebt(LOT_ID, bidderA);
        assertEq(totalDebt, 0);
        assertEq(auctionDebt, 0);
    }

    function testFuzzMaxBidLocksOnlyActualDeposit(uint96 rawDebt) external {
        uint256 maxBid = 15_000 * USDC;
        uint256 standardDeposit = maxBid / 10;
        uint256 debt = bound(uint256(rawDebt), 0, standardDeposit);
        uint256 actualDeposit = standardDeposit - debt;
        uint256 bidderBalanceBefore = token.balanceOf(bidderA);

        vm.prank(bidderA);
        token.approve(address(auction), actualDeposit);
        _setAuthorizedMax(LOT_ID, bidderA, maxBid, debt, debt * 10, "fuzz-max");

        assertEq(token.balanceOf(bidderA), bidderBalanceBefore - actualDeposit);
        (uint256 totalDebt, uint256 auctionDebt, uint256 storedStandardDeposit, uint256 storedActualDeposit) =
            auction.getBidDepositDebt(LOT_ID, bidderA);
        assertEq(totalDebt, debt);
        assertEq(auctionDebt, debt);
        assertEq(storedStandardDeposit, standardDeposit);
        assertEq(storedActualDeposit, actualDeposit);
    }

    function testWinnerPaymentFailureKeepsDebtAndSuccessfulRetryReleasesIt() external {
        _placeAuthorizedBid(LOT_ID, bidderA, STARTING_BID, STARTING_BID / 10, STARTING_BID, "winner-deposit-debt");
        uint256 endTime = auction.getAuction(LOT_ID).endTime;
        vm.warp(endTime);

        vm.prank(operator);
        (,, bool collected) = auction.endAuction(LOT_ID);
        assertFalse(collected);
        (uint256 totalDebtBefore,,,) = auction.getBidDepositDebt(LOT_ID, bidderA);
        assertEq(totalDebtBefore, STARTING_BID / 10);

        vm.prank(bidderA);
        token.approve(address(auction), 11_000 * USDC);
        vm.prank(bidderA);
        assertTrue(auction.settleAuctionPayment(LOT_ID));

        (uint256 totalDebtAfter, uint256 auctionDebtAfter,,) = auction.getBidDepositDebt(LOT_ID, bidderA);
        assertEq(totalDebtAfter, 0);
        assertEq(auctionDebtAfter, 0);
    }

    function testOnlyAdminCanDisableRequirementForStagedMigration() external {
        vm.prank(operator);
        vm.expectRevert();
        auction.setBidAuthorizationRequired(false);

        vm.prank(admin);
        auction.setBidAuthorizationRequired(false);
        _approveBidDeposit(bidderA, STARTING_BID);

        vm.prank(bidderA);
        auction.placeBid(LOT_ID, STARTING_BID);

        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 2 + STARTING_BID / 10);
    }

    function _authorization(address bidder, uint256 amount, Auction.BidType bidType, string memory nonceSeed)
        private
        view
        returns (Auction.BidAuthorization memory)
    {
        return Auction.BidAuthorization({
            lotId: LOT_ID,
            bidder: bidder,
            amount: amount,
            bidType: bidType,
            depositDebt: 0,
            biddingLimit: 0,
            nonce: keccak256(bytes(nonceSeed)),
            deadline: block.timestamp + 5 minutes
        });
    }

    function _authorizationWithDebt(
        bytes32 lotId,
        address bidder,
        uint256 amount,
        Auction.BidType bidType,
        uint256 depositDebt,
        uint256 biddingLimit,
        string memory nonceSeed
    ) private view returns (Auction.BidAuthorization memory) {
        return Auction.BidAuthorization({
            lotId: lotId,
            bidder: bidder,
            amount: amount,
            bidType: bidType,
            depositDebt: depositDebt,
            biddingLimit: biddingLimit,
            nonce: keccak256(bytes(nonceSeed)),
            deadline: block.timestamp + 5 minutes
        });
    }

    function _placeAuthorizedBid(
        bytes32 lotId,
        address bidder,
        uint256 amount,
        uint256 depositDebt,
        uint256 biddingLimit,
        string memory nonceSeed
    ) private {
        Auction.BidAuthorization memory authorization = _authorizationWithDebt(
            lotId, bidder, amount, Auction.BidType.Manual, depositDebt, biddingLimit, nonceSeed
        );
        bytes memory signature = _signBidAuthorization(authorization, ADMIN_KEY);
        vm.prank(bidder);
        auction.placeBid(authorization, signature);
    }

    function _setAuthorizedMax(
        bytes32 lotId,
        address bidder,
        uint256 amount,
        uint256 depositDebt,
        uint256 biddingLimit,
        string memory nonceSeed
    ) private {
        Auction.BidAuthorization memory authorization = _authorizationWithDebt(
            lotId, bidder, amount, Auction.BidType.Maximum, depositDebt, biddingLimit, nonceSeed
        );
        bytes memory signature = _signBidAuthorization(authorization, ADMIN_KEY);
        vm.prank(bidder);
        auction.setMaxBid(authorization, signature);
    }

    function _signBidAuthorization(Auction.BidAuthorization memory authorization, uint256 signerKey)
        private
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "BidAuthorization(bytes32 lotId,address bidder,uint256 amount,uint8 bidType,uint256 depositDebt,uint256 biddingLimit,bytes32 nonce,uint256 deadline)"
                ),
                authorization.lotId,
                authorization.bidder,
                authorization.amount,
                authorization.bidType,
                authorization.depositDebt,
                authorization.biddingLimit,
                authorization.nonce,
                authorization.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _domainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("NextVaultAuction")),
                keccak256(bytes("1")),
                block.chainid,
                address(auction)
            )
        );
    }

    function _createActiveAuction() private {
        _createActiveAuctionFor(LOT_ID, "create-auction");
    }

    function _createActiveAuctionFor(bytes32 lotId, string memory nonceSeed) private {
        Auction.CreateAuctionParams memory params = Auction.CreateAuctionParams({
            lotId: lotId,
            consignor: consignor,
            lowEstimate: STARTING_BID,
            highEstimate: 20_000 * USDC,
            startingBid: STARTING_BID,
            previewDurationSeconds: 0,
            auctionDurationSeconds: 7 days,
            variant1Quantity: 50,
            variant2Quantity: 30,
            variant3Quantity: 20,
            nftPriceRatioBps: 1_000,
            nftName: "NextVault Lot 1",
            nftSymbol: "NVL1",
            thumbnailUrl: "ipfs://thumbnail",
            metadataUri: "ipfs://metadata/"
        });
        bytes32 nonce = keccak256(bytes(nonceSeed));
        uint256 deadline = block.timestamp + 1 hours;
        auction.createAuction(params, nonce, deadline, _signCreateAuction(params, nonce, deadline));
    }

    function _signCreateAuction(Auction.CreateAuctionParams memory params, bytes32 nonce, uint256 deadline)
        private
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                auction.CREATE_AUCTION_AUTHORIZATION_TYPEHASH(),
                params.lotId,
                params.consignor,
                params.lowEstimate,
                params.highEstimate,
                params.startingBid,
                params.previewDurationSeconds,
                params.auctionDurationSeconds,
                params.variant1Quantity,
                params.variant2Quantity,
                params.variant3Quantity,
                params.nftPriceRatioBps,
                keccak256(bytes(params.nftName)),
                keccak256(bytes(params.nftSymbol)),
                keccak256(bytes(params.thumbnailUrl)),
                keccak256(bytes(params.metadataUri)),
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ADMIN_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _buyNft(address buyer) private {
        _buyNftFor(LOT_ID, buyer);
    }

    function _buyNftFor(bytes32 lotId, address buyer) private {
        vm.prank(buyer);
        token.approve(address(auction), NFT_PRICE);
        vm.prank(buyer);
        auction.buyNFT(lotId, 1);
    }

    function _approveBidDeposit(address bidder, uint256 amount) private {
        vm.prank(bidder);
        token.approve(address(auction), amount / 10);
    }
}
