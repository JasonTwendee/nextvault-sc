// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";
import {Auction} from "../src/Auction.sol";
import {FakeUSDC} from "../src/FakeUSDC.sol";
import {LotNFT} from "../src/LotNFT.sol";
import {NFTDesignManager} from "../src/NFTDesignManager.sol";
import {MockVRFCoordinator} from "./mocks/MockVRFCoordinator.sol";

contract AuctionEndWithdrawTest is Test {
    Auction private auction;
    FakeUSDC private token;
    MockVRFCoordinator private vrf;
    NFTDesignManager private designManager;

    uint256 private adminKey = 0xA11CE;
    uint256 private operatorKey = 0x0B0B;
    uint256 private strangerKey = 0xBAD;
    address private admin = vm.addr(adminKey);
    address private operator = vm.addr(operatorKey);
    address private consignor = makeAddr("consignor");
    address private bidderA = makeAddr("bidderA");
    address private bidderB = makeAddr("bidderB");
    address private bidderC = makeAddr("bidderC");
    address private stranger = vm.addr(strangerKey);

    bytes32 private constant LOT_ID = bytes32(uint256(1));
    bytes32 private constant LOT_ID_2 = bytes32(uint256(2));
    bytes32 private constant UNKNOWN_LOT_ID = bytes32(uint256(999));
    uint256 private constant USDC = 1e6;
    uint256 private constant STARTING_BID = 10_000 * USDC;
    uint256 private constant NFT_PRICE = 10 * USDC;
    uint256 private constant STARTING_BALANCE = 100_000 * USDC;

    event AuctionEnded(
        bytes32 indexed lotId, address indexed winner, uint256 winningBid, bool paymentCollected, uint256 blockTimestamp
    );
    event WinnerPaymentCollected(
        bytes32 indexed lotId, address indexed winner, uint256 winningBid, bool paymentCollected, uint256 blockTimestamp
    );
    event AuctionWithdrawn(bytes32 indexed lotId, address indexed highestBidder, uint256 blockTimestamp);
    event NFTRefundClaimed(
        bytes32 indexed lotId, address indexed holder, uint256[] tokenIds, uint256 refundAmount, uint256 blockTimestamp
    );
    event BidRefunded(bytes32 indexed lotId, address indexed bidder, uint256 amount, uint256 blockTimestamp);
    event MaxBidRefunded(bytes32 indexed lotId, address indexed bidder, uint256 amount, uint256 blockTimestamp);
    event WalletBlacklistUpdated(address indexed wallet, bool blacklisted, uint256 blockTimestamp);
    event AuctionTimingConfigUpdated(
        uint256 paymentGracePeriodSeconds, uint256 antiSnipeWindowSeconds, uint256 blockTimestamp
    );
    event SettlementConfigUpdated(
        address indexed treasury, uint16 buyerPremiumBps, uint16 sellerCommissionBps, uint256 blockTimestamp
    );
    event AuctionTimingUpdated(
        bytes32 indexed lotId, uint256 paymentGracePeriodSeconds, uint256 antiSnipeWindowSeconds, uint256 blockTimestamp
    );
    event AuctionSettlementConfigUpdated(
        bytes32 indexed lotId, uint16 buyerPremiumBps, uint16 sellerCommissionBps, uint256 blockTimestamp
    );
    event AuctionRestarted(
        bytes32 indexed lotId,
        uint256 indexed previousRound,
        uint256 indexed newRound,
        address defaultedWinner,
        uint256 forfeitedDeposit,
        uint256 startTime,
        uint256 endTime,
        uint256 blockTimestamp
    );

    function setUp() external {
        token = new FakeUSDC();
        vrf = new MockVRFCoordinator();
        LotNFT lotNFTImplementation = new LotNFT();
        designManager = new NFTDesignManager(
            admin, address(lotNFTImplementation), address(vrf), 1, bytes32(uint256(1)), 500_000, 3, false
        );
        Auction implementation = new Auction();
        bytes memory initData = abi.encodeCall(Auction.initialize, (token, admin, address(designManager)));
        auction = Auction(address(new ERC1967Proxy(address(implementation), initData)));

        vm.prank(admin);
        auction.setBidAuthorizationRequired(false);

        vm.prank(admin);
        designManager.initializeAuction(address(auction));

        bytes32 operatorRole = auction.OPERATOR_ROLE();
        vm.prank(admin);
        auction.grantRole(operatorRole, operator);

        token.mint(bidderA, STARTING_BALANCE);
        token.mint(bidderB, STARTING_BALANCE);
        token.mint(bidderC, STARTING_BALANCE);
    }

    function testEndAuctionWithoutBidsReturnsEmptyWinner() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        vm.warp(config.endTime);

        vm.expectEmit(true, true, false, true, address(auction));
        emit AuctionEnded(LOT_ID, address(0), 0, false, block.timestamp);

        vm.prank(operator);
        (address winner, uint256 winningBid, bool paymentCollected) = auction.endAuction(LOT_ID);

        assertEq(winner, address(0));
        assertEq(winningBid, 0);
        assertFalse(paymentCollected);
        assertTrue(auction.endedAuctions(LOT_ID));
        assertFalse(auction.auctionPaymentCollected(LOT_ID));
        assertEq(uint256(auction.currentStatus(LOT_ID)), uint256(Auction.AuctionStatus.Ended));
    }

    function testAuctionTimingConfigUsesDefaultsAndCanBeUpdatedByOperator() external {
        assertEq(auction.paymentGracePeriodSeconds(), 1 hours);
        assertEq(auction.antiSnipeWindowSeconds(), 5 minutes);

        vm.expectEmit(false, false, false, true, address(auction));
        emit AuctionTimingConfigUpdated(30 minutes, 2 minutes, block.timestamp);
        _setAuctionTimingConfig(30 minutes, 2 minutes, keccak256("timing-config"), bidderA);

        assertEq(auction.paymentGracePeriodSeconds(), 30 minutes);
        assertEq(auction.antiSnipeWindowSeconds(), 2 minutes);
    }

    function testSettlementConfigUsesDefaultsAndCanBeRelayedByWallet() external {
        assertEq(auction.buyerPremiumBps(), 1_000);
        assertEq(auction.sellerCommissionBps(), 1_000);

        vm.expectEmit(true, false, false, true, address(auction));
        emit SettlementConfigUpdated(admin, 1_500, 750, block.timestamp);
        _setSettlementConfig(admin, 1_500, 750, keccak256("financial-config"), bidderA);

        assertEq(auction.buyerPremiumBps(), 1_500);
        assertEq(auction.sellerCommissionBps(), 750);

        Auction.AuctionConfig memory config = _createAuction(0);
        assertEq(config.buyerPremiumBps, 1_500);
        assertEq(config.sellerCommissionBps, 750);
    }

    function testSettlementConfigRejectsInvalidSigner() external {
        Auction.SettlementConfigAuthorization memory authorization =
            _settlementConfigAuthorization(admin, 1_500, 750, keccak256("invalid-signer"));
        bytes memory signature = _signSettlementConfigAuthorization(authorization, strangerKey);

        vm.prank(bidderA);
        vm.expectRevert(Auction.InvalidSigner.selector);
        auction.setSettlementConfig(authorization, signature);
    }

    function testSettlementConfigRejectsInvalidValues() external {
        Auction.SettlementConfigAuthorization memory authorization =
            _settlementConfigAuthorization(address(0), 1_500, 750, keccak256("zero-treasury"));
        vm.expectRevert(Auction.InvalidSettlementConfig.selector);
        auction.setSettlementConfig(authorization, "");

        authorization = _settlementConfigAuthorization(admin, 10_001, 750, keccak256("buyer-premium"));
        vm.expectRevert(Auction.InvalidSettlementConfig.selector);
        auction.setSettlementConfig(authorization, "");

        authorization = _settlementConfigAuthorization(admin, 1_500, 10_001, keccak256("seller-fee"));
        vm.expectRevert(Auction.InvalidSettlementConfig.selector);
        auction.setSettlementConfig(authorization, "");
    }

    function testSettlementConfigRejectsExpiredAndReplayedAuthorization() external {
        Auction.SettlementConfigAuthorization memory authorization =
            _settlementConfigAuthorization(admin, 1_500, 750, keccak256("expired-config"));
        authorization.deadline = block.timestamp - 1;
        bytes memory signature = _signSettlementConfigAuthorization(authorization, operatorKey);

        vm.expectRevert(Auction.AuthorizationExpired.selector);
        auction.setSettlementConfig(authorization, signature);

        authorization = _settlementConfigAuthorization(admin, 1_500, 750, keccak256("replayed-config"));
        signature = _signSettlementConfigAuthorization(authorization, operatorKey);
        auction.setSettlementConfig(authorization, signature);

        vm.expectRevert(Auction.NonceAlreadyUsed.selector);
        auction.setSettlementConfig(authorization, signature);
    }

    function testSettlementConfigRejectsModifiedPayload() external {
        Auction.SettlementConfigAuthorization memory authorization =
            _settlementConfigAuthorization(admin, 1_500, 750, keccak256("modified-config"));
        bytes memory signature = _signSettlementConfigAuthorization(authorization, operatorKey);
        authorization.buyerPremiumBps = 1_600;

        vm.expectRevert(Auction.InvalidSigner.selector);
        auction.setSettlementConfig(authorization, signature);
    }

    function testAuctionTermsAreSnapshottedAtCreation() external {
        Auction.AuctionConfig memory original = _createAuction(0);

        _setSettlementConfig(admin, 2_000, 500, keccak256("snapshot-existing"), bidderA);
        _setAuctionTimingConfig(30 minutes, 2 minutes, keccak256("snapshot-existing-timing"), bidderA);

        Auction.AuctionConfig memory stored = auction.getAuction(LOT_ID);
        assertEq(stored.paymentGracePeriodSeconds, 1 hours);
        assertEq(stored.antiSnipeWindowSeconds, 5 minutes);
        assertEq(stored.buyerPremiumBps, 1_000);
        assertEq(stored.sellerCommissionBps, 1_000);
        assertEq(stored.startTime, original.startTime);
        assertEq(stored.endTime, original.endTime);
    }

    function testNewAuctionSnapshotsLatestTimingAndFeeConfig() external {
        _setSettlementConfig(admin, 2_000, 500, keccak256("snapshot-new"), bidderA);
        _setAuctionTimingConfig(30 minutes, 2 minutes, keccak256("snapshot-new-timing"), bidderA);

        Auction.AuctionConfig memory config = _createAuction(0);
        assertEq(config.paymentGracePeriodSeconds, 30 minutes);
        assertEq(config.antiSnipeWindowSeconds, 2 minutes);
        assertEq(config.buyerPremiumBps, 2_000);
        assertEq(config.sellerCommissionBps, 500);
    }

    function testAuctionTimingConfigRejectsInvalidSignerAndZeroValues() external {
        Auction.AuctionTimingConfigAuthorization memory authorization =
            _auctionTimingConfigAuthorization(30 minutes, 2 minutes, keccak256("invalid-timing-signer"));
        bytes memory signature = _signAuctionTimingConfigAuthorization(authorization, strangerKey);

        vm.expectRevert(Auction.InvalidSigner.selector);
        auction.setAuctionTimingConfig(authorization, signature);

        authorization = _auctionTimingConfigAuthorization(0, 2 minutes, keccak256("zero-grace"));
        vm.expectRevert(Auction.InvalidAuctionTimingConfig.selector);
        auction.setAuctionTimingConfig(authorization, "");
        authorization = _auctionTimingConfigAuthorization(30 minutes, 0, keccak256("zero-anti-snipe"));
        vm.expectRevert(Auction.InvalidAuctionTimingConfig.selector);
        auction.setAuctionTimingConfig(authorization, "");
    }

    function testAuctionTimingConfigRejectsExpiredReplayedAndModifiedAuthorization() external {
        Auction.AuctionTimingConfigAuthorization memory authorization =
            _auctionTimingConfigAuthorization(30 minutes, 2 minutes, keccak256("expired-timing"));
        authorization.deadline = block.timestamp - 1;
        bytes memory signature = _signAuctionTimingConfigAuthorization(authorization, operatorKey);

        vm.expectRevert(Auction.AuthorizationExpired.selector);
        auction.setAuctionTimingConfig(authorization, signature);

        authorization = _auctionTimingConfigAuthorization(30 minutes, 2 minutes, keccak256("replayed-timing"));
        signature = _signAuctionTimingConfigAuthorization(authorization, operatorKey);
        auction.setAuctionTimingConfig(authorization, signature);

        vm.expectRevert(Auction.NonceAlreadyUsed.selector);
        auction.setAuctionTimingConfig(authorization, signature);

        authorization = _auctionTimingConfigAuthorization(30 minutes, 2 minutes, keccak256("modified-timing"));
        signature = _signAuctionTimingConfigAuthorization(authorization, operatorKey);
        authorization.paymentGracePeriodSeconds = 1 hours;

        vm.expectRevert(Auction.InvalidSigner.selector);
        auction.setAuctionTimingConfig(authorization, signature);
    }

    function testOperatorCanUpdateTimingForAuctionBeforeItStarts() external {
        _createAuction(1 days);
        _createAuctionFor(LOT_ID_2, 1 days, STARTING_BID);

        _setAuctionTimingConfig(30 minutes, 2 minutes, keccak256("preview-timing"), bidderA);

        bytes32[] memory lotIds = new bytes32[](2);
        lotIds[0] = LOT_ID;
        lotIds[1] = LOT_ID_2;

        vm.expectEmit(true, false, false, true, address(auction));
        emit AuctionTimingUpdated(LOT_ID, 30 minutes, 2 minutes, block.timestamp);
        vm.prank(operator);
        auction.updateAuctionTimingConfigs(lotIds);

        Auction.AuctionConfig memory config = auction.getAuction(LOT_ID);
        assertEq(config.paymentGracePeriodSeconds, 30 minutes);
        assertEq(config.antiSnipeWindowSeconds, 2 minutes);

        config = auction.getAuction(LOT_ID_2);
        assertEq(config.paymentGracePeriodSeconds, 30 minutes);
        assertEq(config.antiSnipeWindowSeconds, 2 minutes);
    }

    function testAuctionTimingUpdateRejectsUnauthorizedEmptyAndStartedAuction() external {
        Auction.AuctionConfig memory config = _createAuction(1 days);
        bytes32[] memory lotIds = new bytes32[](1);
        lotIds[0] = LOT_ID;

        vm.prank(stranger);
        vm.expectRevert();
        auction.updateAuctionTimingConfigs(lotIds);

        bytes32[] memory emptyLotIds = new bytes32[](0);
        vm.prank(operator);
        vm.expectRevert(Auction.InvalidAmount.selector);
        auction.updateAuctionTimingConfigs(emptyLotIds);

        bytes32[] memory oversizedLotIds = new bytes32[](11);
        vm.prank(operator);
        vm.expectRevert(Auction.InvalidAmount.selector);
        auction.updateAuctionTimingConfigs(oversizedLotIds);

        vm.warp(config.startTime);
        vm.prank(operator);
        vm.expectRevert(Auction.AuctionDetailsLocked.selector);
        auction.updateAuctionTimingConfigs(lotIds);
    }

    function testAuctionTimingUpdateRejectsUnknownAuction() external {
        bytes32[] memory lotIds = new bytes32[](1);
        lotIds[0] = LOT_ID;

        vm.prank(operator);
        vm.expectRevert(Auction.AuctionNotFound.selector);
        auction.updateAuctionTimingConfigs(lotIds);
    }

    function testOperatorCanUpdateSettlementConfigForAuctionsBeforeTheyStart() external {
        _createAuction(1 days);
        _createAuctionFor(LOT_ID_2, 1 days, STARTING_BID);
        _setSettlementConfig(admin, 2_000, 500, keccak256("batch-settlement"), bidderA);

        bytes32[] memory lotIds = new bytes32[](2);
        lotIds[0] = LOT_ID;
        lotIds[1] = LOT_ID_2;

        vm.expectEmit(true, false, false, true, address(auction));
        emit AuctionSettlementConfigUpdated(LOT_ID, 2_000, 500, block.timestamp);
        vm.prank(operator);
        auction.updateAuctionSettlementConfigs(lotIds);

        Auction.AuctionConfig memory config = auction.getAuction(LOT_ID);
        assertEq(config.buyerPremiumBps, 2_000);
        assertEq(config.sellerCommissionBps, 500);

        config = auction.getAuction(LOT_ID_2);
        assertEq(config.buyerPremiumBps, 2_000);
        assertEq(config.sellerCommissionBps, 500);
    }

    function testAuctionSettlementConfigUpdateRejectsUnauthorizedInvalidBatchAndStartedAuction() external {
        Auction.AuctionConfig memory config = _createAuction(1 days);
        bytes32[] memory lotIds = new bytes32[](1);
        lotIds[0] = LOT_ID;

        vm.prank(stranger);
        vm.expectRevert();
        auction.updateAuctionSettlementConfigs(lotIds);

        vm.prank(operator);
        vm.expectRevert(Auction.InvalidAmount.selector);
        auction.updateAuctionSettlementConfigs(new bytes32[](0));

        vm.prank(operator);
        vm.expectRevert(Auction.InvalidAmount.selector);
        auction.updateAuctionSettlementConfigs(new bytes32[](11));

        vm.warp(config.startTime);
        vm.prank(operator);
        vm.expectRevert(Auction.AuctionDetailsLocked.selector);
        auction.updateAuctionSettlementConfigs(lotIds);
    }

    function testAuctionSettlementConfigUpdateRejectsUnknownAuction() external {
        bytes32[] memory lotIds = new bytes32[](1);
        lotIds[0] = UNKNOWN_LOT_ID;

        vm.prank(operator);
        vm.expectRevert(Auction.AuctionNotFound.selector);
        auction.updateAuctionSettlementConfigs(lotIds);
    }

    function testEndAuctionWithWinnerStartsPaymentPendingWhenAllowanceIsMissing() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        vm.warp(config.endTime);

        vm.expectEmit(true, true, false, true, address(auction));
        emit AuctionEnded(LOT_ID, bidderA, STARTING_BID, false, block.timestamp);

        vm.prank(operator);
        (address winner, uint256 winningBid, bool paymentCollected) = auction.endAuction(LOT_ID);

        assertEq(winner, bidderA);
        assertEq(winningBid, STARTING_BID);
        assertFalse(paymentCollected);
        assertTrue(auction.endedAuctions(LOT_ID));
        assertFalse(auction.auctionPaymentCollected(LOT_ID));
        assertEq(token.balanceOf(address(auction)), NFT_PRICE + STARTING_BID / 10);
    }

    function testEndAuctionCollectsPaymentAndDistributesSettlementImmediately() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        _approveRemainingPayment(bidderA, STARTING_BID);
        vm.warp(config.endTime);

        vm.prank(operator);
        (address winner, uint256 winningBid, bool paymentCollected) = auction.endAuction(LOT_ID);

        assertEq(winner, bidderA);
        assertEq(winningBid, STARTING_BID);
        assertTrue(paymentCollected);
        assertTrue(auction.auctionPaymentCollected(LOT_ID));
        assertEq(uint256(auction.currentStatus(LOT_ID)), uint256(Auction.AuctionStatus.Finalized));
        assertEq(token.balanceOf(consignor), 9_000 * USDC);
        assertEq(token.balanceOf(admin), 2_000 * USDC);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE);
    }

    function testFeeConfigChangeDoesNotAffectExistingAuctionSettlement() external {
        Auction.AuctionConfig memory config = _createAuction(0);

        _setSettlementConfig(admin, 2_000, 500, keccak256("settlement-existing"), bidderA);

        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        _approveRemainingPayment(bidderA, STARTING_BID);
        vm.warp(config.endTime);

        vm.prank(operator);
        (,, bool paymentCollected) = auction.endAuction(LOT_ID);

        assertTrue(paymentCollected);
        assertEq(token.balanceOf(consignor), 9_000 * USDC);
        assertEq(token.balanceOf(admin), 2_000 * USDC);
    }

    function testEndAuctionUsesMaxBidDepositWhenHammerPriceIsLowerThanMaxBid() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNft(bidderA);
        _setMaxBidAndPlaceFor(bidderA, 12_000 * USDC, 11_000 * USDC);

        uint256 remainingPayment = 10_900 * USDC;
        vm.prank(bidderA);
        token.approve(address(auction), remainingPayment);
        vm.warp(config.endTime);

        vm.prank(operator);
        (address winner, uint256 winningBid, bool paymentCollected) = auction.endAuction(LOT_ID);

        assertEq(winner, bidderA);
        assertEq(winningBid, 11_000 * USDC);
        assertTrue(paymentCollected);
        assertEq(token.balanceOf(consignor), 9_900 * USDC);
        assertEq(token.balanceOf(admin), 2_200 * USDC);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE);
    }

    function testEndAuctionUsesExactTicketMaxBidDepositNumbers() external {
        Auction.AuctionConfig memory config = _createAuctionWithStartingBid(0, 1_000 * USDC);
        _buyNft(bidderA);
        _setMaxBidAndPlaceFor(bidderA, 1_200 * USDC, 1_100 * USDC);

        uint256 bidderBalanceBeforeEnd = token.balanceOf(bidderA);
        uint256 remainingPayment = 1_090 * USDC;
        vm.prank(bidderA);
        token.approve(address(auction), remainingPayment);
        vm.warp(config.endTime);

        vm.prank(operator);
        (address winner, uint256 winningBid, bool paymentCollected) = auction.endAuction(LOT_ID);

        assertEq(winner, bidderA);
        assertEq(winningBid, 1_100 * USDC);
        assertTrue(paymentCollected);
        assertEq(bidderBalanceBeforeEnd - token.balanceOf(bidderA), remainingPayment);
        assertEq(token.balanceOf(consignor), 990 * USDC);
        assertEq(token.balanceOf(admin), 220 * USDC);
        assertEq(token.balanceOf(address(auction)), 1 * USDC);
    }

    function testEndAuctionRefundsExcessMaxBidDepositWhenDepositExceedsTotalPayment() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNft(bidderA);
        _setMaxBidAndPlaceFor(bidderA, 120_000 * USDC, STARTING_BID);
        uint256 bidderBalanceBeforeEnd = token.balanceOf(bidderA);
        vm.warp(config.endTime);

        vm.expectEmit(true, true, false, true, address(auction));
        emit MaxBidRefunded(LOT_ID, bidderA, 1_000 * USDC, block.timestamp);
        vm.prank(operator);
        (address winner, uint256 winningBid, bool paymentCollected) = auction.endAuction(LOT_ID);

        assertEq(winner, bidderA);
        assertEq(winningBid, STARTING_BID);
        assertTrue(paymentCollected);
        assertEq(token.balanceOf(bidderA), bidderBalanceBeforeEnd + 1_000 * USDC);
        assertEq(token.balanceOf(consignor), 9_000 * USDC);
        assertEq(token.balanceOf(admin), 2_000 * USDC);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE);
    }

    function testSettleAuctionPaymentSucceedsForOperatorAfterInitialEndFailure() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        vm.warp(config.endTime);

        vm.prank(operator);
        auction.endAuction(LOT_ID);

        _approveRemainingPayment(bidderA, STARTING_BID);

        vm.expectEmit(true, true, false, true, address(auction));
        emit WinnerPaymentCollected(LOT_ID, bidderA, STARTING_BID, true, block.timestamp);
        vm.prank(operator);
        bool paymentCollected = auction.settleAuctionPayment(LOT_ID);

        assertTrue(paymentCollected);
        assertTrue(auction.auctionPaymentCollected(LOT_ID));
        assertFalse(auction.blacklistedWallets(bidderA));
        assertEq(uint256(auction.currentStatus(LOT_ID)), uint256(Auction.AuctionStatus.Finalized));
    }

    function testOperatorPaymentRetryFailureBlacklistsWinnerAndRestartsAuction() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        _buyNft(bidderB);
        vm.warp(config.endTime);

        vm.prank(operator);
        (,, bool initiallyCollected) = auction.endAuction(LOT_ID);

        assertFalse(initiallyCollected);
        assertFalse(auction.blacklistedWallets(bidderA));
        uint256 treasuryBalanceBefore = token.balanceOf(admin);

        _expirePaymentGrace();

        vm.expectEmit(true, false, false, true, address(auction));
        emit WalletBlacklistUpdated(bidderA, true, block.timestamp);
        vm.prank(operator);
        bool paymentCollected = auction.settleAuctionPayment(LOT_ID);

        assertFalse(paymentCollected);
        assertFalse(auction.auctionPaymentCollected(LOT_ID));
        assertTrue(auction.blacklistedWallets(bidderA));
        assertFalse(auction.endedAuctions(LOT_ID));
        assertEq(auction.auctionBidRound(LOT_ID), 1);
        assertEq(token.balanceOf(admin) - treasuryBalanceBefore, STARTING_BID / 10);
        assertEq(uint256(auction.currentStatus(LOT_ID)), uint256(Auction.AuctionStatus.Active));

        Auction.AuctionConfig memory restartedAuction = auction.getAuction(LOT_ID);
        assertEq(restartedAuction.startTime, block.timestamp);
        assertEq(restartedAuction.endTime, block.timestamp + restartedAuction.auctionDurationSeconds);
        assertEq(restartedAuction.previewDurationSeconds, 0);

        vm.prank(bidderB);
        token.approve(address(auction), STARTING_BID / 10);
        vm.prank(bidderB);
        auction.placeBid(LOT_ID, STARTING_BID);

        vm.warp(restartedAuction.endTime);
        vm.prank(operator);
        (address restartedWinner, uint256 restartedWinningBid,) = auction.endAuction(LOT_ID);
        assertEq(restartedWinner, bidderB);
        assertEq(restartedWinningBid, STARTING_BID);
    }

    function testRestartEmitsRoundWindowAndForfeitedDeposit() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        vm.warp(config.endTime);

        vm.startPrank(operator);
        auction.endAuction(LOT_ID);

        _expirePaymentGrace();

        uint256 restartedAt = block.timestamp;
        vm.expectEmit(true, true, false, true, address(auction));
        emit WalletBlacklistUpdated(bidderA, true, restartedAt);
        vm.expectEmit(true, true, true, true, address(auction));
        emit AuctionRestarted(
            LOT_ID,
            0,
            1,
            bidderA,
            STARTING_BID / 10,
            restartedAt,
            restartedAt + config.auctionDurationSeconds,
            restartedAt
        );
        auction.settleAuctionPayment(LOT_ID);
        vm.stopPrank();

        Auction.AuctionConfig memory restartedAuction = auction.getAuction(LOT_ID);
        assertEq(restartedAuction.startTime, restartedAt);
        assertEq(restartedAuction.endTime, restartedAt + config.auctionDurationSeconds);
        assertEq(restartedAuction.previewDurationSeconds, 0);
        assertEq(auction.auctionBidRound(LOT_ID), 1);
    }

    function testRestartBlocksDefaultedWinnerAndAllowsAnotherBidderFromStartingBid() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        _buyNft(bidderB);
        vm.warp(config.endTime);

        vm.startPrank(operator);
        auction.endAuction(LOT_ID);
        _expirePaymentGrace();
        auction.settleAuctionPayment(LOT_ID);
        vm.stopPrank();

        vm.startPrank(bidderA);
        vm.expectRevert(Auction.BlacklistedWallet.selector);
        auction.placeBid(LOT_ID, STARTING_BID);
        vm.expectRevert(Auction.BlacklistedWallet.selector);
        auction.setMaxBid(LOT_ID, STARTING_BID + 1_000 * USDC);
        vm.expectRevert(Auction.BlacklistedWallet.selector);
        auction.buyNFT(LOT_ID, 1);
        vm.stopPrank();

        vm.prank(bidderB);
        token.approve(address(auction), STARTING_BID / 10);
        vm.prank(bidderB);
        auction.placeBid(LOT_ID, STARTING_BID);

        Auction.AuctionConfig memory restartedAuction = auction.getAuction(LOT_ID);
        vm.warp(restartedAuction.endTime);
        vm.prank(operator);
        (address winner, uint256 winningBid,) = auction.endAuction(LOT_ID);
        assertEq(winner, bidderB);
        assertEq(winningBid, STARTING_BID);
    }

    function testRestartRejectsSkippedManualBidButAcceptsFreshMaxBid() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        _buyNft(bidderB);
        vm.warp(config.endTime);

        vm.startPrank(operator);
        auction.endAuction(LOT_ID);
        _expirePaymentGrace();
        auction.settleAuctionPayment(LOT_ID);
        vm.stopPrank();

        vm.prank(bidderB);
        token.approve(address(auction), 2_000 * USDC);
        vm.prank(bidderB);
        vm.expectRevert(Auction.InvalidBidAmount.selector);
        auction.placeBid(LOT_ID, STARTING_BID + 1_000 * USDC);

        _setMaxBid(bidderB, 12_000 * USDC);
        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderB, STARTING_BID);

        Auction.AuctionConfig memory restartedAuction = auction.getAuction(LOT_ID);
        vm.warp(restartedAuction.endTime);
        vm.prank(operator);
        (address winner, uint256 winningBid,) = auction.endAuction(LOT_ID);
        assertEq(winner, bidderB);
        assertEq(winningBid, STARTING_BID);
    }

    function testManualBidCanOutbidFreshAutoBidAfterRestart() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        _buyNft(bidderB);
        _buyNft(bidderC);
        vm.warp(config.endTime);

        vm.startPrank(operator);
        auction.endAuction(LOT_ID);
        _expirePaymentGrace();
        auction.settleAuctionPayment(LOT_ID);
        vm.stopPrank();

        _setMaxBidAndPlaceFor(bidderB, 12_000 * USDC, 12_000 * USDC);

        vm.prank(bidderC);
        token.approve(address(auction), 1_300 * USDC);
        vm.prank(bidderC);
        auction.placeBid(LOT_ID, 13_000 * USDC);

        uint256 bidderBBalanceBeforeRefund = token.balanceOf(bidderB);
        vm.prank(operator);
        auction.refundMaxBid(LOT_ID, bidderB);
        assertEq(token.balanceOf(bidderB) - bidderBBalanceBeforeRefund, 1_200 * USDC);

        Auction.AuctionConfig memory restartedAuction = auction.getAuction(LOT_ID);
        vm.warp(restartedAuction.endTime);
        vm.prank(operator);
        (address winner, uint256 winningBid,) = auction.endAuction(LOT_ID);
        assertEq(winner, bidderC);
        assertEq(winningBid, 13_000 * USDC);
    }

    function testAuctionCanRestartTwiceWithIndependentWinnersAndDeposits() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        _buyNft(bidderB);
        _buyNft(bidderC);
        vm.warp(config.endTime);

        uint256 treasuryBalanceBefore = token.balanceOf(admin);
        vm.startPrank(operator);
        auction.endAuction(LOT_ID);
        _expirePaymentGrace();
        auction.settleAuctionPayment(LOT_ID);
        vm.stopPrank();

        vm.prank(bidderB);
        token.approve(address(auction), STARTING_BID / 10);
        vm.prank(bidderB);
        auction.placeBid(LOT_ID, STARTING_BID);

        Auction.AuctionConfig memory roundOne = auction.getAuction(LOT_ID);
        vm.warp(roundOne.endTime);
        vm.startPrank(operator);
        auction.endAuction(LOT_ID);
        _expirePaymentGrace();
        auction.settleAuctionPayment(LOT_ID);
        vm.stopPrank();

        assertEq(auction.auctionBidRound(LOT_ID), 2);
        assertTrue(auction.blacklistedWallets(bidderA));
        assertTrue(auction.blacklistedWallets(bidderB));
        assertEq(token.balanceOf(admin) - treasuryBalanceBefore, STARTING_BID / 5);

        vm.prank(bidderC);
        token.approve(address(auction), STARTING_BID / 10);
        vm.prank(bidderC);
        auction.placeBid(LOT_ID, STARTING_BID);

        Auction.AuctionConfig memory roundTwo = auction.getAuction(LOT_ID);
        vm.warp(roundTwo.endTime);
        vm.prank(operator);
        (address winner, uint256 winningBid,) = auction.endAuction(LOT_ID);
        assertEq(winner, bidderC);
        assertEq(winningBid, STARTING_BID);
    }

    function testSuccessfulPaymentAfterRestartFinalizesWithoutAnotherRound() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        _buyNft(bidderB);
        vm.warp(config.endTime);

        vm.startPrank(operator);
        auction.endAuction(LOT_ID);
        _expirePaymentGrace();
        auction.settleAuctionPayment(LOT_ID);
        vm.stopPrank();

        vm.prank(bidderB);
        token.approve(address(auction), STARTING_BID / 10);
        vm.prank(bidderB);
        auction.placeBid(LOT_ID, STARTING_BID);
        _approveRemainingPayment(bidderB, STARTING_BID);

        Auction.AuctionConfig memory restartedAuction = auction.getAuction(LOT_ID);
        vm.warp(restartedAuction.endTime);
        vm.prank(operator);
        (address winner, uint256 winningBid, bool paymentCollected) = auction.endAuction(LOT_ID);

        assertEq(winner, bidderB);
        assertEq(winningBid, STARTING_BID);
        assertTrue(paymentCollected);
        assertEq(auction.auctionBidRound(LOT_ID), 1);
        assertTrue(auction.endedAuctions(LOT_ID));
        assertTrue(auction.auctionPaymentCollected(LOT_ID));
        assertEq(uint256(auction.currentStatus(LOT_ID)), uint256(Auction.AuctionStatus.Finalized));
    }

    function testWinnerPaymentRetryFailureDoesNotBlacklistWinner() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        vm.warp(config.endTime);

        vm.prank(operator);
        auction.endAuction(LOT_ID);

        vm.prank(bidderA);
        bool paymentCollected = auction.settleAuctionPayment(LOT_ID);

        assertFalse(paymentCollected);
        assertFalse(auction.auctionPaymentCollected(LOT_ID));
        assertFalse(auction.blacklistedWallets(bidderA));
    }

    function testRestartSlashesFullAutoBidDepositAndClearsWinnerMaxBid() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNft(bidderA);
        _setMaxBidAndPlaceFor(bidderA, 12_000 * USDC, STARTING_BID);
        vm.warp(config.endTime);

        vm.prank(operator);
        auction.endAuction(LOT_ID);
        uint256 treasuryBalanceBefore = token.balanceOf(admin);

        _expirePaymentGrace();

        vm.prank(operator);
        auction.settleAuctionPayment(LOT_ID);

        assertEq(token.balanceOf(admin) - treasuryBalanceBefore, 1_200 * USDC);
        vm.prank(operator);
        vm.expectRevert(Auction.InvalidAmount.selector);
        auction.refundMaxBid(LOT_ID, bidderA);
    }

    function testBackendRefundsNonWinnerMaxBidAfterEndBeforeRestart() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        _buyNft(bidderB);
        _setMaxBid(bidderB, 11_000 * USDC);
        uint256 bidderBalanceBeforeRefund = token.balanceOf(bidderB);
        vm.warp(config.endTime);

        vm.prank(operator);
        auction.endAuction(LOT_ID);

        vm.prank(operator);
        auction.refundMaxBid(LOT_ID, bidderB);
        assertEq(token.balanceOf(bidderB) - bidderBalanceBeforeRefund, 1_100 * USDC);

        _expirePaymentGrace();

        vm.prank(operator);
        auction.settleAuctionPayment(LOT_ID);

        vm.prank(operator);
        vm.expectRevert(Auction.InvalidBidAmount.selector);
        auction.placeBidFor(LOT_ID, bidderB, 11_000 * USDC);
    }

    function testSettleAuctionPaymentSucceedsForWinnerAfterInitialEndFailure() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        vm.warp(config.endTime);

        vm.prank(operator);
        auction.endAuction(LOT_ID);

        _approveRemainingPayment(bidderA, STARTING_BID);

        vm.prank(bidderA);
        bool paymentCollected = auction.settleAuctionPayment(LOT_ID);

        assertTrue(paymentCollected);
        assertTrue(auction.auctionPaymentCollected(LOT_ID));
        assertEq(uint256(auction.currentStatus(LOT_ID)), uint256(Auction.AuctionStatus.Finalized));
    }

    function testSettleAuctionPaymentRevertsForUnauthorizedCaller() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        vm.warp(config.endTime);

        vm.prank(operator);
        auction.endAuction(LOT_ID);

        vm.prank(stranger);
        vm.expectRevert(Auction.UnauthorizedPaymentCollector.selector);
        auction.settleAuctionPayment(LOT_ID);
    }

    function testOperatorFailedRetryCannotSettleAgainUntilRestartedAuctionEnds() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        vm.warp(config.endTime);

        vm.startPrank(operator);
        auction.endAuction(LOT_ID);
        _expirePaymentGrace();
        bool firstRetry = auction.settleAuctionPayment(LOT_ID);
        vm.expectRevert(Auction.AuctionNotEnded.selector);
        auction.settleAuctionPayment(LOT_ID);
        vm.stopPrank();

        assertFalse(firstRetry);
        assertFalse(auction.auctionPaymentCollected(LOT_ID));
        assertEq(token.balanceOf(address(auction)), NFT_PRICE);
    }

    function testOperatorFailedRetryCannotRestartBeforePaymentGraceDeadline() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        vm.warp(config.endTime);

        vm.prank(operator);
        auction.endAuction(LOT_ID);

        uint256 deadline = config.endTime + 1 hours;
        assertEq(auction.auctionPaymentDeadline(LOT_ID), deadline);

        vm.warp(deadline - 1);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Auction.AuctionPaymentGracePeriodActive.selector, deadline));
        auction.settleAuctionPayment(LOT_ID);

        assertTrue(auction.endedAuctions(LOT_ID));
        assertFalse(auction.blacklistedWallets(bidderA));
    }

    function testPaymentDeadlineKeepsConfigFromAuctionEnd() external {
        Auction.AuctionConfig memory config = _createAuction(0);

        _setAuctionTimingConfig(10 minutes, 5 minutes, keccak256("deadline-timing-1"), bidderA);

        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        vm.warp(config.endTime);

        vm.prank(operator);
        auction.endAuction(LOT_ID);
        uint256 originalDeadline = config.endTime + 1 hours;

        _setAuctionTimingConfig(2 hours, 5 minutes, keccak256("deadline-timing-2"), bidderA);

        assertEq(auction.auctionPaymentDeadline(LOT_ID), originalDeadline);
    }

    function testEndAuctionAcceptsExactEndTimestamp() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        vm.warp(config.endTime);

        vm.prank(operator);
        auction.endAuction(LOT_ID);

        assertTrue(auction.endedAuctions(LOT_ID));
    }

    function testEndAuctionRevertsBeforeEndTimestamp() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        vm.warp(config.endTime - 1);

        vm.prank(operator);
        vm.expectRevert(Auction.AuctionNotEnded.selector);
        auction.endAuction(LOT_ID);
    }

    function testEndAuctionRevertsWhenCalledTwice() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        vm.warp(config.endTime);

        vm.startPrank(operator);
        auction.endAuction(LOT_ID);
        vm.expectRevert(Auction.AuctionAlreadyEnded.selector);
        auction.endAuction(LOT_ID);
        vm.stopPrank();
    }

    function testEndAuctionRevertsForCancelledAuction() external {
        _createAuction(0);
        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);

        vm.prank(operator);
        vm.expectRevert(Auction.AuctionIsCancelled.selector);
        auction.endAuction(LOT_ID);
    }

    function testEndAuctionRevertsForNonOperator() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        vm.warp(config.endTime);

        vm.prank(stranger);
        vm.expectRevert();
        auction.endAuction(LOT_ID);
    }

    function testEndAuctionRevertsForUnknownAuction() external {
        vm.prank(operator);
        vm.expectRevert(Auction.AuctionNotFound.selector);
        auction.endAuction(UNKNOWN_LOT_ID);
    }

    function testSettleAuctionPaymentRevertsBeforeAuctionIsEnded() external {
        _createAuction(0);

        vm.prank(operator);
        vm.expectRevert(Auction.AuctionNotEnded.selector);
        auction.settleAuctionPayment(LOT_ID);
    }

    function testSettleAuctionPaymentRevertsWhenAuctionHasNoWinner() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        vm.warp(config.endTime);

        vm.startPrank(operator);
        auction.endAuction(LOT_ID);
        vm.expectRevert(Auction.AuctionHasNoWinner.selector);
        auction.settleAuctionPayment(LOT_ID);
        vm.stopPrank();
    }

    function testSettleAuctionPaymentRevertsAfterPaymentWasCollected() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        _approveRemainingPayment(bidderA, STARTING_BID);
        vm.warp(config.endTime);

        vm.startPrank(operator);
        auction.endAuction(LOT_ID);
        vm.expectRevert(Auction.AuctionPaymentAlreadyCollected.selector);
        auction.settleAuctionPayment(LOT_ID);
        vm.stopPrank();
    }

    function testWithdrawActiveAuctionWithoutBids() external {
        _createAuction(0);

        vm.expectEmit(true, true, false, true, address(auction));
        emit AuctionWithdrawn(LOT_ID, address(0), block.timestamp);
        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);

        assertTrue(auction.cancelledAuctions(LOT_ID));
        assertEq(uint256(auction.currentStatus(LOT_ID)), uint256(Auction.AuctionStatus.Cancelled));
    }

    function testWithdrawRefundsCurrentManualBidImmediately() external {
        _createAuction(0);
        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        uint256 bidderBalanceBeforeWithdraw = token.balanceOf(bidderA);

        vm.expectEmit(true, true, false, true, address(auction));
        emit AuctionWithdrawn(LOT_ID, bidderA, block.timestamp);
        vm.expectEmit(true, true, false, true, address(auction));
        emit BidRefunded(LOT_ID, bidderA, STARTING_BID / 10, block.timestamp);
        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);

        assertEq(token.balanceOf(bidderA), bidderBalanceBeforeWithdraw + STARTING_BID / 10);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE);
    }

    function testHolderCanClaimBulkNftRefundAfterWithdraw() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNft(bidderA);
        _buyNft(bidderA);
        LotNFT nftCollection = LotNFT(config.nftCollection);
        uint256 bidderBalanceBeforeClaim = token.balanceOf(bidderA);

        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 2;
        vm.expectEmit(true, true, false, true, address(auction));
        emit NFTRefundClaimed(LOT_ID, bidderA, tokenIds, NFT_PRICE * 2, block.timestamp);
        vm.prank(bidderA);
        auction.claimNFTRefund(LOT_ID, tokenIds);

        assertEq(token.balanceOf(bidderA), bidderBalanceBeforeClaim + NFT_PRICE * 2);
        assertEq(token.balanceOf(address(auction)), 0);
        vm.expectRevert();
        nftCollection.ownerOf(1);
        vm.expectRevert();
        nftCollection.ownerOf(2);
    }

    function testGetNftRefundAmountTracksWithdrawAndClaims() external {
        _createAuction(0);
        _buyNft(bidderA);
        _buyNft(bidderA);

        (uint256 quantityBeforeWithdraw, uint256 amountBeforeWithdraw) = auction.getNFTRefundAmount(LOT_ID, bidderA);
        assertEq(quantityBeforeWithdraw, 2);
        assertEq(amountBeforeWithdraw, 0);

        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);

        (uint256 refundableQuantity, uint256 refundableAmount) = auction.getNFTRefundAmount(LOT_ID, bidderA);
        assertEq(refundableQuantity, 2);
        assertEq(refundableAmount, NFT_PRICE * 2);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        vm.prank(bidderA);
        auction.claimNFTRefund(LOT_ID, tokenIds);

        (uint256 remainingQuantity, uint256 remainingAmount) = auction.getNFTRefundAmount(LOT_ID, bidderA);
        assertEq(remainingQuantity, 1);
        assertEq(remainingAmount, NFT_PRICE);
    }

    function testCurrentHolderCanClaimNftRefundAfterTransfer() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNft(bidderA);
        LotNFT nftCollection = LotNFT(config.nftCollection);
        vm.prank(bidderA);
        nftCollection.transferFrom(bidderA, bidderB, 1);
        uint256 bidderBalanceBeforeClaim = token.balanceOf(bidderB);

        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        vm.prank(bidderB);
        auction.claimNFTRefund(LOT_ID, tokenIds);

        assertEq(token.balanceOf(bidderB), bidderBalanceBeforeClaim + NFT_PRICE);
        assertEq(token.balanceOf(address(auction)), 0);
    }

    function testBlacklistedHolderCanClaimExistingNftRefund() external {
        _createAuction(0);
        _buyNft(bidderA);
        vm.startPrank(operator);
        auction.setWalletBlacklist(bidderA, true);
        auction.withdrawAuction(LOT_ID);
        vm.stopPrank();

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        vm.prank(bidderA);
        auction.claimNFTRefund(LOT_ID, tokenIds);

        assertEq(token.balanceOf(bidderA), STARTING_BALANCE);
    }

    function testNftRefundRevertsBeforeWithdraw() external {
        _createAuction(0);
        _buyNft(bidderA);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;

        vm.prank(bidderA);
        vm.expectRevert(Auction.AuctionNotWithdrawn.selector);
        auction.claimNFTRefund(LOT_ID, tokenIds);
    }

    function testNftRefundRejectsEmptyListAndNonOwner() external {
        _createAuction(0);
        _buyNft(bidderA);
        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);

        uint256[] memory emptyTokenIds = new uint256[](0);
        vm.prank(bidderA);
        vm.expectRevert(Auction.InvalidQuantity.selector);
        auction.claimNFTRefund(LOT_ID, emptyTokenIds);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        vm.prank(bidderB);
        vm.expectRevert(LotNFT.NotNftOwner.selector);
        auction.claimNFTRefund(LOT_ID, tokenIds);
    }

    function testNftRefundCannotBeClaimedTwice() external {
        _createAuction(0);
        _buyNft(bidderA);
        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        vm.startPrank(bidderA);
        auction.claimNFTRefund(LOT_ID, tokenIds);
        vm.expectRevert();
        auction.claimNFTRefund(LOT_ID, tokenIds);
        vm.stopPrank();
    }

    function testWithdrawLeavesAutoBidDepositForBackendRefund() external {
        _createAuction(0);
        _buyNft(bidderA);
        _setMaxBidAndPlaceFor(bidderA, 15_000 * USDC, 15_000 * USDC);
        uint256 bidderBalanceBeforeWithdraw = token.balanceOf(bidderA);
        uint256 contractBalanceBeforeWithdraw = token.balanceOf(address(auction));

        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);

        assertEq(token.balanceOf(bidderA), bidderBalanceBeforeWithdraw);
        assertEq(token.balanceOf(address(auction)), contractBalanceBeforeWithdraw);
        assertTrue(auction.cancelledAuctions(LOT_ID));
    }

    function testBackendCanRefundAutoBidLeaderAfterWithdraw() external {
        _createAuction(0);
        _buyNft(bidderA);
        _setMaxBidAndPlaceFor(bidderA, 15_000 * USDC, 15_000 * USDC);

        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);

        vm.expectEmit(true, true, false, true, address(auction));
        emit MaxBidRefunded(LOT_ID, bidderA, 1_500 * USDC, block.timestamp);
        vm.prank(operator);
        auction.refundMaxBid(LOT_ID, bidderA);

        assertEq(token.balanceOf(bidderA), STARTING_BALANCE - NFT_PRICE);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE);
    }

    function testBackendCanRefundMultipleMaxBiddersAfterWithdraw() external {
        _createAuction(0);
        _buyNft(bidderA);
        _buyNft(bidderB);
        _setMaxBid(bidderA, 15_000 * USDC);
        _setMaxBid(bidderB, 16_000 * USDC);

        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);

        vm.startPrank(operator);
        auction.refundMaxBid(LOT_ID, bidderA);
        auction.refundMaxBid(LOT_ID, bidderB);
        vm.stopPrank();

        assertEq(token.balanceOf(bidderA), STARTING_BALANCE - NFT_PRICE);
        assertEq(token.balanceOf(bidderB), STARTING_BALANCE - NFT_PRICE);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 2);
    }

    function testRefundMaxBidCurrentLeaderStillRevertsBeforeWithdraw() external {
        _createAuction(0);
        _buyNft(bidderA);
        _setMaxBidAndPlaceFor(bidderA, 15_000 * USDC, STARTING_BID);

        vm.prank(operator);
        vm.expectRevert(Auction.CurrentLeaderCannotWithdrawDeposit.selector);
        auction.refundMaxBid(LOT_ID, bidderA);
    }

    function testRefundMaxBidCannotRunTwiceAfterWithdraw() external {
        _createAuction(0);
        _buyNft(bidderA);
        _setMaxBid(bidderA, 15_000 * USDC);

        vm.startPrank(operator);
        auction.withdrawAuction(LOT_ID);
        auction.refundMaxBid(LOT_ID, bidderA);
        vm.expectRevert(Auction.InvalidAmount.selector);
        auction.refundMaxBid(LOT_ID, bidderA);
        vm.stopPrank();
    }

    function testWithdrawDuringPreviewRemainsCancelledAfterStartTime() external {
        Auction.AuctionConfig memory config = _createAuction(1 hours);

        assertEq(uint256(auction.currentStatus(LOT_ID)), uint256(Auction.AuctionStatus.Preview));
        vm.expectEmit(true, true, false, true, address(auction));
        emit AuctionWithdrawn(LOT_ID, address(0), block.timestamp);
        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);

        assertTrue(auction.cancelledAuctions(LOT_ID));
        assertEq(uint256(auction.currentStatus(LOT_ID)), uint256(Auction.AuctionStatus.Cancelled));

        vm.warp(config.startTime);
        assertEq(uint256(auction.currentStatus(LOT_ID)), uint256(Auction.AuctionStatus.Cancelled));
    }

    function testWithdrawAtEndTimestampBeforeEndWorkerRuns() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        vm.warp(config.endTime);

        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);
        assertEq(token.balanceOf(bidderA), STARTING_BALANCE - NFT_PRICE);
        vm.prank(operator);
        vm.expectRevert(Auction.AuctionIsCancelled.selector);
        auction.endAuction(LOT_ID);
    }

    function testWithdrawDuringGraceWaivesPaymentAndPreventsDefault() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        vm.warp(config.endTime);
        vm.prank(operator);
        auction.endAuction(LOT_ID);
        assertGt(auction.auctionPaymentDeadline(LOT_ID), 0);

        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);
        assertEq(auction.auctionPaymentDeadline(LOT_ID), 0);
        assertEq(token.balanceOf(bidderA), STARTING_BALANCE - NFT_PRICE);

        _approveRemainingPayment(bidderA, STARTING_BID);
        vm.warp(config.endTime + config.paymentGracePeriodSeconds + 1);
        vm.prank(operator);
        vm.expectRevert(Auction.AuctionIsCancelled.selector);
        auction.settleAuctionPayment(LOT_ID);
        vm.prank(bidderA);
        vm.expectRevert(Auction.AuctionIsCancelled.selector);
        auction.settleAuctionPayment(LOT_ID);
        assertFalse(auction.blacklistedWallets(bidderA));
        assertEq(auction.auctionBidRound(LOT_ID), 0);
        assertEq(token.balanceOf(bidderA), STARTING_BALANCE - NFT_PRICE);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(bidderA);
        auction.claimNFTRefund(LOT_ID, ids);
        assertEq(token.balanceOf(bidderA), STARTING_BALANCE);
    }

    function testWithdrawDuringGraceAllowsAutoBidDepositRefund() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNft(bidderA);
        _setMaxBidAndPlaceFor(bidderA, 15_000 * USDC, STARTING_BID);
        vm.warp(config.endTime);
        vm.startPrank(operator);
        auction.endAuction(LOT_ID);
        auction.withdrawAuction(LOT_ID);
        auction.refundMaxBid(LOT_ID, bidderA);
        vm.stopPrank();
        assertEq(token.balanceOf(bidderA), STARTING_BALANCE - NFT_PRICE);
        assertEq(auction.auctionPaymentDeadline(LOT_ID), 0);
        assertFalse(auction.blacklistedWallets(bidderA));
    }

    function testWithdrawGraceMax400Actual100Refunds40AndLeaves400UnusedAllowance() external {
        Auction.AuctionConfig memory config = _createAuctionWithStartingBid(0, 100 * USDC);
        _buyNft(bidderA);
        // Shared ERC20 allowance also reserves 330 for unrelated auctions.
        vm.startPrank(bidderA);
        token.approve(address(auction), 770 * USDC);
        auction.setMaxBid(LOT_ID, 400 * USDC);
        assertEq(token.allowance(bidderA, address(auction)), 730 * USDC);
        token.transfer(stranger, token.balanceOf(bidderA));
        vm.stopPrank();
        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderA, 100 * USDC);
        vm.warp(config.endTime);
        vm.prank(operator);
        (,, bool paid) = auction.endAuction(LOT_ID);
        assertFalse(paid);
        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);
        // Max-bid escrow is refunded through the backend operator flow.
        vm.expectEmit(true, true, false, true, address(auction));
        emit MaxBidRefunded(LOT_ID, bidderA, 40 * USDC, block.timestamp);
        vm.prank(operator);
        auction.refundMaxBid(LOT_ID, bidderA);
        assertEq(token.balanceOf(bidderA), 40 * USDC);
        assertEq(token.allowance(bidderA, address(auction)), 730 * USDC);
        assertEq(token.balanceOf(address(auction)), config.nftPrice);
        vm.prank(operator);
        vm.expectRevert(Auction.InvalidAmount.selector);
        auction.refundMaxBid(LOT_ID, bidderA);
        // Returning collateral does not restore allowance consumed by transferFrom.
        vm.prank(bidderA);
        token.approve(address(auction), 730 * USDC - 400 * USDC);
        assertEq(token.allowance(bidderA, address(auction)), 330 * USDC);
        vm.warp(config.endTime + config.paymentGracePeriodSeconds + 1);
        vm.expectRevert(Auction.AuctionIsCancelled.selector);
        auction.settleAuctionPayment(LOT_ID);
        assertFalse(auction.blacklistedWallets(bidderA));
        assertEq(auction.auctionPaymentDeadline(LOT_ID), 0);
        assertEq(token.balanceOf(bidderA), 40 * USDC);
    }

    function testWithdrawBoughtInRefundsPasses() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNft(bidderA);
        vm.warp(config.endTime);
        vm.startPrank(operator);
        auction.endAuction(LOT_ID);
        auction.withdrawAuction(LOT_ID);
        vm.stopPrank();
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(bidderA);
        auction.claimNFTRefund(LOT_ID, ids);
        assertEq(token.balanceOf(bidderA), STARTING_BALANCE);
    }

    function testWithdrawFinalizedPreservesSettlementAndWinnerNft() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        _approveRemainingPayment(bidderA, STARTING_BID);
        vm.warp(config.endTime);
        vm.prank(operator);
        auction.endAuction(LOT_ID);
        assertTrue(auction.auctionPaymentCollected(LOT_ID));
        uint256 buyerBalance = token.balanceOf(bidderA);
        uint256 consignorBalance = token.balanceOf(consignor);
        uint256 treasuryBalance = token.balanceOf(admin);

        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);
        assertEq(uint256(auction.currentStatus(LOT_ID)), uint256(Auction.AuctionStatus.Cancelled));
        assertTrue(auction.auctionPaymentCollected(LOT_ID));
        assertEq(token.balanceOf(bidderA), buyerBalance);
        assertEq(token.balanceOf(consignor), consignorBalance);
        assertEq(token.balanceOf(admin), treasuryBalance);

        LotNFT collection = LotNFT(config.nftCollection);
        uint256 winnerId = config.nftMaxSupply + 1;
        assertEq(collection.ownerOf(winnerId), bidderA);
        (uint256 count, uint256 amount) = auction.getNFTRefundAmount(LOT_ID, bidderA);
        assertEq(count, 1);
        assertEq(amount, NFT_PRICE);

        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = winnerId;
        vm.prank(bidderA);
        vm.expectRevert(Auction.WinnerNftNotRefundable.selector);
        auction.claimNFTRefund(LOT_ID, ids);
        assertEq(collection.ownerOf(1), bidderA);

        ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(bidderA);
        auction.claimNFTRefund(LOT_ID, ids);
        assertEq(token.balanceOf(bidderA), buyerBalance + NFT_PRICE);
        assertEq(collection.ownerOf(winnerId), bidderA);

        vm.prank(bidderA);
        collection.transferFrom(bidderA, bidderB, winnerId);
        (count, amount) = auction.getNFTRefundAmount(LOT_ID, bidderB);
        assertEq(count, 0);
        assertEq(amount, 0);
        ids[0] = winnerId;
        vm.prank(bidderB);
        vm.expectRevert(Auction.WinnerNftNotRefundable.selector);
        auction.claimNFTRefund(LOT_ID, ids);
    }

    function testPassRefundCanRetryAfterContractIsFunded() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNft(bidderA);
        vm.warp(config.endTime);
        vm.prank(operator);
        auction.endAuction(LOT_ID);
        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);

        // Simulate a missing refund reserve, then a USDC top-up. A failed
        // refund must roll back the burn so the holder can retry safely.
        vm.prank(address(auction));
        token.transfer(admin, NFT_PRICE);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(bidderA);
        vm.expectRevert();
        auction.claimNFTRefund(LOT_ID, ids);
        assertEq(LotNFT(config.nftCollection).ownerOf(1), bidderA);
        vm.prank(admin);
        token.transfer(address(auction), NFT_PRICE);
        vm.prank(bidderA);
        auction.claimNFTRefund(LOT_ID, ids);
        assertEq(token.balanceOf(bidderA), STARTING_BALANCE);
    }

    function testWithdrawFinalizedAutoBidDoesNotRefundSettledDeposit() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNft(bidderA);
        _setMaxBidAndPlaceFor(bidderA, 15_000 * USDC, STARTING_BID);
        _approveRemainingPayment(bidderA, STARTING_BID);
        vm.warp(config.endTime);
        vm.prank(operator);
        auction.endAuction(LOT_ID);
        assertTrue(auction.auctionPaymentCollected(LOT_ID));
        uint256 balanceBefore = token.balanceOf(bidderA);
        vm.startPrank(operator);
        auction.withdrawAuction(LOT_ID);
        vm.expectRevert(Auction.InvalidAmount.selector);
        auction.refundMaxBid(LOT_ID, bidderA);
        vm.stopPrank();
        assertEq(token.balanceOf(bidderA), balanceBefore);
    }

    function testWithdrawRevertsWhenCalledTwice() external {
        _createAuction(0);

        vm.startPrank(operator);
        auction.withdrawAuction(LOT_ID);
        vm.expectRevert(Auction.AuctionAlreadyCancelled.selector);
        auction.withdrawAuction(LOT_ID);
        vm.stopPrank();
    }

    function testWithdrawRevertsForNonOperatorAndUnknownAuction() external {
        _createAuction(0);

        vm.prank(stranger);
        vm.expectRevert();
        auction.withdrawAuction(LOT_ID);

        vm.prank(operator);
        vm.expectRevert(Auction.AuctionNotFound.selector);
        auction.withdrawAuction(UNKNOWN_LOT_ID);
    }

    function testWithdrawPreventsFurtherNftPurchasesAndBids() external {
        _createAuction(0);
        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);

        vm.startPrank(bidderA);
        token.approve(address(auction), NFT_PRICE + STARTING_BID / 10);
        vm.expectRevert(Auction.AuctionIsCancelled.selector);
        auction.buyNFT(LOT_ID, 1);
        vm.expectRevert(Auction.AuctionIsCancelled.selector);
        auction.placeBid(LOT_ID, STARTING_BID);
        vm.stopPrank();
    }

    function _createAuction(uint256 previewDuration) private returns (Auction.AuctionConfig memory) {
        return _createAuctionWithStartingBid(previewDuration, STARTING_BID);
    }

    function _createAuctionWithStartingBid(uint256 previewDuration, uint256 startingBid)
        private
        returns (Auction.AuctionConfig memory)
    {
        return _createAuctionFor(LOT_ID, previewDuration, startingBid);
    }

    function _createAuctionFor(bytes32 lotId, uint256 previewDuration, uint256 startingBid)
        private
        returns (Auction.AuctionConfig memory)
    {
        Auction.CreateAuctionParams memory params = Auction.CreateAuctionParams({
            lotId: lotId,
            consignor: consignor,
            lowEstimate: startingBid,
            highEstimate: 20_000 * USDC,
            startingBid: startingBid,
            previewDurationSeconds: previewDuration,
            auctionDurationSeconds: 1 hours,
            variant1Quantity: 50,
            variant2Quantity: 30,
            variant3Quantity: 20,
            nftPriceRatioBps: 1_000,
            nftName: "NextVault Lot 1",
            nftSymbol: "NVL1",
            thumbnailUrl: "ipfs://thumbnail",
            metadataUri: "ipfs://metadata/"
        });
        bytes32 nonce = keccak256(abi.encode("lifecycle", lotId));
        uint256 deadline = block.timestamp + 1 hours;
        auction.createAuction(params, nonce, deadline, _sign(params, nonce, deadline));
        return auction.getAuction(lotId);
    }

    function _buyNft(address bidder) private {
        vm.prank(bidder);
        token.approve(address(auction), NFT_PRICE);
        vm.prank(bidder);
        auction.buyNFT(LOT_ID, 1);
    }

    function _buyNftAndPlaceManualBid(address bidder, uint256 amount) private {
        _buyNft(bidder);
        vm.prank(bidder);
        token.approve(address(auction), amount / 10);
        vm.prank(bidder);
        auction.placeBid(LOT_ID, amount);
    }

    function _setMaxBid(address bidder, uint256 amount) private {
        vm.prank(bidder);
        token.approve(address(auction), amount / 10);
        vm.prank(bidder);
        auction.setMaxBid(LOT_ID, amount);
    }

    function _setMaxBidAndPlaceFor(address bidder, uint256 maxBid, uint256 bidAmount) private {
        _setMaxBid(bidder, maxBid);
        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidder, bidAmount);
    }

    function _approveRemainingPayment(address winner, uint256 winningBid) private {
        uint256 buyerPremium = winningBid / 10;
        uint256 remainingPayment = winningBid + buyerPremium - winningBid / 10;
        vm.prank(winner);
        token.approve(address(auction), remainingPayment);
    }

    function _expirePaymentGrace() private {
        vm.warp(auction.auctionPaymentDeadline(LOT_ID));
    }

    function _setSettlementConfig(
        address treasury_,
        uint16 buyerPremiumBps_,
        uint16 sellerCommissionBps_,
        bytes32 nonce,
        address relayer
    ) private {
        Auction.SettlementConfigAuthorization memory authorization =
            _settlementConfigAuthorization(treasury_, buyerPremiumBps_, sellerCommissionBps_, nonce);
        bytes memory signature = _signSettlementConfigAuthorization(authorization, operatorKey);

        vm.prank(relayer);
        auction.setSettlementConfig(authorization, signature);
    }

    function _settlementConfigAuthorization(
        address treasury_,
        uint16 buyerPremiumBps_,
        uint16 sellerCommissionBps_,
        bytes32 nonce
    ) private view returns (Auction.SettlementConfigAuthorization memory) {
        return Auction.SettlementConfigAuthorization({
            treasury: treasury_,
            buyerPremiumBps: buyerPremiumBps_,
            sellerCommissionBps: sellerCommissionBps_,
            nonce: nonce,
            deadline: block.timestamp + 1 hours
        });
    }

    function _signSettlementConfigAuthorization(
        Auction.SettlementConfigAuthorization memory authorization,
        uint256 signerKey
    ) private view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "SettlementConfigAuthorization(address treasury,uint16 buyerPremiumBps,uint16 sellerCommissionBps,bytes32 nonce,uint256 deadline)"
                ),
                authorization.treasury,
                authorization.buyerPremiumBps,
                authorization.sellerCommissionBps,
                authorization.nonce,
                authorization.deadline
            )
        );
        return _signTypedData(structHash, signerKey);
    }

    function _setAuctionTimingConfig(
        uint256 paymentGracePeriodSeconds_,
        uint256 antiSnipeWindowSeconds_,
        bytes32 nonce,
        address relayer
    ) private {
        Auction.AuctionTimingConfigAuthorization memory authorization =
            _auctionTimingConfigAuthorization(paymentGracePeriodSeconds_, antiSnipeWindowSeconds_, nonce);
        bytes memory signature = _signAuctionTimingConfigAuthorization(authorization, operatorKey);

        vm.prank(relayer);
        auction.setAuctionTimingConfig(authorization, signature);
    }

    function _auctionTimingConfigAuthorization(
        uint256 paymentGracePeriodSeconds_,
        uint256 antiSnipeWindowSeconds_,
        bytes32 nonce
    ) private view returns (Auction.AuctionTimingConfigAuthorization memory) {
        return Auction.AuctionTimingConfigAuthorization({
            paymentGracePeriodSeconds: paymentGracePeriodSeconds_,
            antiSnipeWindowSeconds: antiSnipeWindowSeconds_,
            nonce: nonce,
            deadline: block.timestamp + 1 hours
        });
    }

    function _signAuctionTimingConfigAuthorization(
        Auction.AuctionTimingConfigAuthorization memory authorization,
        uint256 signerKey
    ) private view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "AuctionTimingConfigAuthorization(uint256 paymentGracePeriodSeconds,uint256 antiSnipeWindowSeconds,bytes32 nonce,uint256 deadline)"
                ),
                authorization.paymentGracePeriodSeconds,
                authorization.antiSnipeWindowSeconds,
                authorization.nonce,
                authorization.deadline
            )
        );
        return _signTypedData(structHash, signerKey);
    }

    function _signTypedData(bytes32 structHash, uint256 signerKey) private view returns (bytes memory) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("NextVaultAuction")),
                keccak256(bytes("1")),
                block.chainid,
                address(auction)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _sign(Auction.CreateAuctionParams memory params, bytes32 nonce, uint256 deadline)
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
        return _signTypedData(structHash, adminKey);
    }
}
