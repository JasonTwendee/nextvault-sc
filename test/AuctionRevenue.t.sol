// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Auction} from "../src/Auction.sol";
import {FakeUSDC} from "../src/FakeUSDC.sol";
import {LotNFT} from "../src/LotNFT.sol";
import {NFTDesignManager} from "../src/NFTDesignManager.sol";
import {MockVRFCoordinator} from "./mocks/MockVRFCoordinator.sol";
import {NFTRevenueModule} from "../src/NFTRevenueModule.sol";

contract RevenueCallbackUSDC is FakeUSDC {
    address public callbackTarget;
    bool public callbackSucceeded;
    bool public takeFee;

    function configure(address target, bool fee) external {
        callbackTarget = target;
        takeFee = fee;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        address target = callbackTarget;
        callbackTarget = address(0);
        if (target != address(0)) {
            (callbackSucceeded,) = target.call(abi.encodeCall(Auction.depositNFTRevenue, (1)));
        }
        bool success = super.transferFrom(from, to, amount);
        if (takeFee) _burn(to, 1);
        return success;
    }
}

abstract contract AuctionRevenueFixture is Test {
    Auction auction;
    FakeUSDC token;
    NFTDesignManager manager;
    uint256 constant ADMIN_KEY = 0xA11CE;
    uint256 constant SIGNER_KEY = 0xBEEF;
    uint256 constant U = 1e6;
    address admin;
    address signer;
    address operator = makeAddr("operator");
    address buyer = makeAddr("buyer");
    address otherBuyer = makeAddr("otherBuyer");
    address consignor = makeAddr("consignor");
    address treasury = makeAddr("treasury");
    uint256 nonceCounter;

    function setUp() public virtual {
        admin = vm.addr(ADMIN_KEY);
        signer = vm.addr(SIGNER_KEY);
        token = new FakeUSDC();
        MockVRFCoordinator vrf = new MockVRFCoordinator();
        manager =
            new NFTDesignManager(admin, address(new LotNFT()), address(vrf), 1, bytes32(uint256(1)), 500_000, 3, false);
        auction = Auction(
            address(
                new ERC1967Proxy(
                    address(new Auction()), abi.encodeCall(Auction.initialize, (token, admin, address(manager)))
                )
            )
        );
        vm.startPrank(admin);
        manager.initializeAuction(address(auction));
        auction.setBidAuthorizationRequired(false);
        auction.grantRole(auction.OPERATOR_ROLE(), operator);
        auction.grantRole(auction.REVENUE_AUTHORIZER_ROLE(), signer);
        vm.stopPrank();
        _setTreasury(treasury);
        for (uint256 i; i < 3; ++i) {
            address wallet = i == 0 ? admin : i == 1 ? buyer : otherBuyer;
            token.mint(wallet, 1_000_000 * U);
            vm.prank(wallet);
            token.approve(address(auction), type(uint256).max);
        }
    }

    function _sign(bytes32 hash, uint256 key, address target, uint256 chain) internal pure returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("NextVaultAuction"),
                keccak256("1"),
                chain,
                target
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, hash)));
        return abi.encodePacked(r, s, v);
    }

    function _create(uint256 id, uint256 duration, uint256 preview) internal returns (bytes32 lot) {
        lot = bytes32(id);
        Auction.CreateAuctionParams memory p = Auction.CreateAuctionParams({
            lotId: lot,
            consignor: consignor,
            lowEstimate: 1000 * U,
            highEstimate: 2000 * U,
            startingBid: 1000 * U,
            previewDurationSeconds: preview,
            auctionDurationSeconds: duration,
            variant1Quantity: 50,
            variant2Quantity: 30,
            variant3Quantity: 20,
            nftPriceRatioBps: 1000,
            nftName: "Pass",
            nftSymbol: "PASS",
            thumbnailUrl: "ipfs://image",
            metadataUri: "ipfs://metadata/"
        });
        bytes32 nonce = keccak256(abi.encode("create", id));
        uint256 deadline = block.timestamp + 1 days;
        bytes32 hash = keccak256(
            abi.encode(
                auction.CREATE_AUCTION_AUTHORIZATION_TYPEHASH(),
                p.lotId,
                p.consignor,
                p.lowEstimate,
                p.highEstimate,
                p.startingBid,
                p.previewDurationSeconds,
                p.auctionDurationSeconds,
                p.variant1Quantity,
                p.variant2Quantity,
                p.variant3Quantity,
                p.nftPriceRatioBps,
                keccak256(bytes(p.nftName)),
                keccak256(bytes(p.nftSymbol)),
                keccak256(bytes(p.thumbnailUrl)),
                keccak256(bytes(p.metadataUri)),
                nonce,
                deadline
            )
        );
        auction.createAuction(p, nonce, deadline, _sign(hash, ADMIN_KEY, address(auction), block.chainid));
        assertEq(auction.getAuction(lot).nftPrice, U);
    }

    function _buy(bytes32 lot, address wallet, uint256 quantity) internal {
        // Initial mints are capped per wallet; aggregate passes into the test holder.
        LotNFT collection = LotNFT(auction.getAuction(lot).nftCollection);
        uint256 limit = collection.initialMintLimit();
        while (quantity > 0) {
            uint256 count = quantity < limit ? quantity : limit;
            address minter = address(uint160(0x10000 + ++nonceCounter));
            token.mint(minter, count * U);
            uint256 firstId = collection.totalMinted() + 1;
            vm.startPrank(minter);
            token.approve(address(auction), count * U);
            auction.buyNFT(lot, count);
            for (uint256 i; i < count; ++i) {
                collection.transferFrom(minter, wallet, firstId + i);
            }
            vm.stopPrank();
            quantity -= count;
        }
    }

    function _end(bytes32 lot) internal {
        vm.warp(auction.getAuction(lot).endTime);
        vm.prank(operator);
        auction.endAuction(lot);
    }

    function _deposit(uint256 amount) internal {
        vm.prank(admin);
        auction.depositNFTRevenue(amount);
    }

    function _authorization(uint256 amount) internal returns (Auction.NFTRevenueWithdrawal memory a) {
        a = Auction.NFTRevenueWithdrawal(
            admin, amount, treasury, keccak256(abi.encode("revenue", ++nonceCounter)), block.timestamp + 1 hours
        );
    }

    function _signature(Auction.NFTRevenueWithdrawal memory a, uint256 key, address target, uint256 chain)
        internal
        pure
        returns (bytes memory)
    {
        return _sign(
            keccak256(
                abi.encode(
                    keccak256(
                        "NFTRevenueWithdrawal(address admin,uint256 amount,address treasury,bytes32 nonce,uint256 deadline)"
                    ),
                    a.admin,
                    a.amount,
                    a.treasury,
                    a.nonce,
                    a.deadline
                )
            ),
            key,
            target,
            chain
        );
    }

    function _withdraw(uint256 amount) internal {
        Auction.NFTRevenueWithdrawal memory a = _authorization(amount);
        bytes memory signature = _signature(a, SIGNER_KEY, address(auction), block.chainid);
        vm.prank(admin);
        auction.withdrawNFTRevenue(a, signature);
    }

    function _setTreasury(address value) internal {
        Auction.SettlementConfigAuthorization memory a = Auction.SettlementConfigAuthorization(
            value, 1000, 1000, keccak256(abi.encode("treasury", value)), block.timestamp + 1 days
        );
        bytes32 hash = keccak256(
            abi.encode(
                keccak256(
                    "SettlementConfigAuthorization(address treasury,uint16 buyerPremiumBps,uint16 sellerCommissionBps,bytes32 nonce,uint256 deadline)"
                ),
                a.treasury,
                a.buyerPremiumBps,
                a.sellerCommissionBps,
                a.nonce,
                a.deadline
            )
        );
        auction.setSettlementConfig(a, _sign(hash, ADMIN_KEY, address(auction), block.chainid));
        treasury = value;
    }
}

contract AuctionRevenueTest is AuctionRevenueFixture {
    function testCustomerElevenStepExample() public {
        bytes32 a = _create(1, 100, 0);
        bytes32 b = _create(2, 100, 0);
        bytes32 c = _create(3, 1000, 0);
        bytes32 d = _create(4, 100, 0);
        _buy(a, buyer, 100);
        _buy(b, buyer, 50);
        _buy(c, buyer, 30);
        _buy(d, otherBuyer, 40);
        vm.prank(buyer);
        auction.placeBid(a, 1000 * U);
        vm.prank(otherBuyer);
        auction.placeBid(d, 1000 * U);
        vm.prank(otherBuyer);
        token.approve(address(auction), 0);
        _end(a);
        _end(b);
        _end(d);
        assertTrue(auction.auctionPaymentCollected(a));
        assertEq(auction.totalPassRevenue(), 220 * U);
        assertEq(auction.eligiblePassRevenue(), 150 * U);
        assertEq(auction.getMaxWithdraw(), 150 * U);
        _withdraw(120 * U);
        assertEq(auction.getMaxWithdraw(), 30 * U);
        _deposit(50 * U);
        assertEq(auction.getMaxWithdraw(), 80 * U);
        vm.prank(operator);
        auction.withdrawAuction(c);
        uint256[] memory ids = new uint256[](30);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = i + 1;
        }
        vm.prank(buyer);
        auction.claimNFTRefund(c, ids);
        assertEq(auction.getMaxWithdraw(), 80 * U);
        vm.warp(auction.auctionPaymentDeadline(d));
        vm.prank(operator);
        auction.settleAuctionPayment(d);
        assertEq(auction.auctionBidRound(d), 1);
        assertEq(auction.getMaxWithdraw(), 80 * U);
        _buy(d, buyer, 20);
        vm.prank(buyer);
        auction.placeBid(d, 1000 * U);
        _end(d);
        assertEq(auction.lotPassRevenue(d), 60 * U);
        assertEq(auction.eligiblePassRevenue(), 210 * U);
        assertEq(auction.getMaxWithdraw(), 140 * U);
        _withdraw(140 * U);
        assertEq(auction.getMaxWithdraw(), 0);
        assertEq(auction.getNFTRefundShortfall(a), 100 * U);
        vm.expectRevert(abi.encodeWithSelector(Auction.InsufficientNFTRefundFunds.selector, 100 * U, 0));
        vm.prank(operator);
        auction.withdrawAuction(a);
        _deposit(40 * U);
        assertEq(auction.getNFTRefundShortfall(a), 60 * U);
        _deposit(60 * U);
        assertEq(auction.getNFTRefundShortfall(a), 0);
        vm.prank(operator);
        auction.withdrawAuction(a);
        assertEq(auction.eligiblePassRevenue(), 110 * U);
        assertEq(auction.getMaxWithdraw(), 0);
        assertEq(auction.getNFTRefundShortfall(b), 50 * U);
        ids = new uint256[](100);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = i + 1;
        }
        vm.prank(buyer);
        auction.claimNFTRefund(a, ids);
        assertEq(auction.getMaxWithdraw(), 0);
        assertEq(LotNFT(auction.getAuction(a).nftCollection).ownerOf(101), buyer);
        _deposit(200 * U);
        assertEq(auction.getMaxWithdraw(), 200 * U);
        _withdraw(200 * U);
        assertEq(auction.getMaxWithdraw(), 0);
        assertEq(auction.totalRevenueWithdrawn(), 460 * U);
        assertEq(auction.totalRevenueDeposited(), 350 * U);
    }

    function testBoughtInShortfallAndReserveBeforeClaim() public {
        bytes32 lot = _create(1, 100, 0);
        _buy(lot, buyer, 10);
        _end(lot);
        _withdraw(10 * U);
        assertEq(auction.getNFTRefundShortfall(lot), 10 * U);
        _deposit(10 * U);
        vm.prank(operator);
        auction.withdrawAuction(lot);
        assertEq(auction.getMaxWithdraw(), 0);
        // Refunded money is reserved immediately, not only when holders claim.
        Auction.NFTRevenueWithdrawal memory a = _authorization(U);
        bytes memory signature = _signature(a, SIGNER_KEY, address(auction), block.chainid);
        vm.expectRevert(abi.encodeWithSelector(Auction.InsufficientNFTRevenue.selector, U, 0));
        vm.prank(admin);
        auction.withdrawNFTRevenue(a, signature);
        assertFalse(auction.usedNonces(a.nonce));
        uint256[] memory ids = new uint256[](10);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = i + 1;
        }
        vm.prank(buyer);
        auction.claimNFTRefund(lot, ids);
        assertEq(token.balanceOf(address(auction)), 0);
    }

    function testCollateralAndActiveRevenueCannotBeWithdrawn() public {
        bytes32 lot = _create(1, 100, 0);
        _buy(lot, buyer, 10);
        vm.prank(buyer);
        auction.placeBid(lot, 1000 * U);
        assertEq(token.balanceOf(address(auction)), 110 * U);
        assertEq(auction.getMaxWithdraw(), 0);
        _deposit(5 * U);
        _withdraw(5 * U);
        assertEq(token.balanceOf(address(auction)), 110 * U);
        assertEq(auction.getNFTRefundShortfall(lot), 0);
        vm.prank(operator);
        auction.withdrawAuction(lot);
        assertEq(token.balanceOf(address(auction)), 10 * U);
    }

    function testUnsolicitedTransfersDoNotIncreaseEntitlement() public {
        vm.prank(admin);
        token.transfer(address(auction), 500 * U);
        assertEq(auction.getMaxWithdraw(), 0);
        assertEq(auction.totalRevenueDeposited(), 0);
    }

    function testPreviewAndProcessingPaymentAreNotEligible() public {
        bytes32 lot = _create(1, 100, 100);
        assertEq(auction.getNFTRefundShortfall(lot), 0);
        vm.warp(auction.getAuction(lot).startTime);
        _buy(lot, buyer, 10);
        vm.prank(buyer);
        auction.placeBid(lot, 1000 * U);
        vm.prank(buyer);
        token.approve(address(auction), 0);
        _end(lot);
        assertEq(auction.eligiblePassRevenue(), 0);
        assertEq(auction.getNFTRefundShortfall(lot), 0);
        vm.prank(operator);
        auction.withdrawAuction(lot);
        assertEq(auction.getMaxWithdraw(), 0);
    }

    function testLaterPaymentAddsRevenueExactlyOnce() public {
        bytes32 lot = _create(1, 100, 0);
        _buy(lot, buyer, 10);
        vm.prank(buyer);
        auction.placeBid(lot, 1000 * U);
        vm.prank(buyer);
        token.approve(address(auction), 0);
        _end(lot);
        assertEq(auction.getMaxWithdraw(), 0);
        vm.prank(buyer);
        token.approve(address(auction), type(uint256).max);
        vm.prank(buyer);
        auction.settleAuctionPayment(lot);
        assertEq(auction.getMaxWithdraw(), 10 * U);
        assertEq(auction.lotPassRevenue(lot), 10 * U);
        vm.expectRevert(Auction.AuctionPaymentAlreadyCollected.selector);
        vm.prank(buyer);
        auction.settleAuctionPayment(lot);
        assertEq(auction.getMaxWithdraw(), 10 * U);
    }

    function testOnlyAdminCanDepositOrWithdrawEvenWithAuthorization() public {
        _deposit(10 * U);
        Auction.NFTRevenueWithdrawal memory a = _authorization(U);
        bytes memory signature = _signature(a, SIGNER_KEY, address(auction), block.chainid);
        for (uint256 i; i < 3; ++i) {
            address caller = i == 0 ? buyer : i == 1 ? operator : signer;
            vm.expectRevert();
            vm.prank(caller);
            auction.depositNFTRevenue(U);
            vm.expectRevert();
            vm.prank(caller);
            auction.withdrawNFTRevenue(a, signature);
        }
    }

    function testReplayExpiryAndRevokedSigner() public {
        _deposit(10 * U);
        Auction.NFTRevenueWithdrawal memory a = _authorization(U);
        bytes memory signature = _signature(a, SIGNER_KEY, address(auction), block.chainid);
        vm.prank(admin);
        auction.withdrawNFTRevenue(a, signature);
        vm.expectRevert(Auction.NonceAlreadyUsed.selector);
        vm.prank(admin);
        auction.withdrawNFTRevenue(a, signature);
        a = _authorization(U);
        signature = _signature(a, SIGNER_KEY, address(auction), block.chainid);
        vm.warp(a.deadline + 1);
        vm.expectRevert(Auction.AuthorizationExpired.selector);
        vm.prank(admin);
        auction.withdrawNFTRevenue(a, signature);
        a = _authorization(U);
        signature = _signature(a, SIGNER_KEY, address(auction), block.chainid);
        bytes32 role = auction.REVENUE_AUTHORIZER_ROLE();
        vm.prank(admin);
        auction.revokeRole(role, signer);
        vm.expectRevert(Auction.InvalidSigner.selector);
        vm.prank(admin);
        auction.withdrawNFTRevenue(a, signature);
    }

    function testAdminAndOperatorSignaturesCannotBypass2FAAuthorizer() public {
        _deposit(10 * U);
        Auction.NFTRevenueWithdrawal memory a = _authorization(U);
        bytes memory signature = _signature(a, ADMIN_KEY, address(auction), block.chainid);
        vm.expectRevert(Auction.InvalidSigner.selector);
        vm.prank(admin);
        auction.withdrawNFTRevenue(a, signature);
        assertFalse(auction.hasRole(auction.REVENUE_AUTHORIZER_ROLE(), admin));
        bytes32 operatorRole = auction.OPERATOR_ROLE();
        vm.prank(admin);
        auction.grantRole(operatorRole, vm.addr(0xCAFE));
        signature = _signature(a, 0xCAFE, address(auction), block.chainid);
        vm.expectRevert(Auction.InvalidSigner.selector);
        vm.prank(admin);
        auction.withdrawNFTRevenue(a, signature);
    }

    function testAuthorizationBindsAmountWalletTreasuryChainAndProxy() public {
        _deposit(100 * U);
        Auction.NFTRevenueWithdrawal memory original = _authorization(U);
        bytes memory signature = _signature(original, SIGNER_KEY, address(auction), block.chainid);
        Auction.NFTRevenueWithdrawal memory changed = _authorization(2 * U);
        changed.nonce = original.nonce;
        vm.expectRevert(Auction.InvalidSigner.selector);
        vm.prank(admin);
        auction.withdrawNFTRevenue(changed, signature);
        original.admin = buyer;
        vm.expectRevert(Auction.InvalidRevenueAuthorization.selector);
        vm.prank(admin);
        auction.withdrawNFTRevenue(original, signature);
        original.admin = admin;
        signature = _signature(original, SIGNER_KEY, address(auction), block.chainid + 1);
        vm.expectRevert(Auction.InvalidSigner.selector);
        vm.prank(admin);
        auction.withdrawNFTRevenue(original, signature);
        signature = _signature(original, SIGNER_KEY, address(123), block.chainid);
        vm.expectRevert(Auction.InvalidSigner.selector);
        vm.prank(admin);
        auction.withdrawNFTRevenue(original, signature);
        signature = _signature(original, SIGNER_KEY, address(auction), block.chainid);
        _setTreasury(makeAddr("new treasury"));
        vm.expectRevert(Auction.InvalidRevenueAuthorization.selector);
        vm.prank(admin);
        auction.withdrawNFTRevenue(original, signature);
    }

    function testRejectZeroAndOverMaxAndRollbackOnFailedTransfer() public {
        vm.expectRevert(Auction.InvalidAmount.selector);
        vm.prank(admin);
        auction.depositNFTRevenue(0);
        _deposit(10 * U);
        Auction.NFTRevenueWithdrawal memory a = _authorization(11 * U);
        bytes memory signature = _signature(a, SIGNER_KEY, address(auction), block.chainid);
        vm.expectRevert(abi.encodeWithSelector(Auction.InsufficientNFTRevenue.selector, 11 * U, 10 * U));
        vm.prank(admin);
        auction.withdrawNFTRevenue(a, signature);
        a = _authorization(0);
        signature = _signature(a, SIGNER_KEY, address(auction), block.chainid);
        vm.expectRevert(Auction.InvalidAmount.selector);
        vm.prank(admin);
        auction.withdrawNFTRevenue(a, signature);
        a = _authorization(U);
        signature = _signature(a, SIGNER_KEY, address(auction), block.chainid);
        vm.mockCallRevert(address(token), abi.encodeCall(token.transfer, (treasury, U)), "USDC failure");
        vm.expectRevert();
        vm.prank(admin);
        auction.withdrawNFTRevenue(a, signature);
        assertFalse(auction.usedNonces(a.nonce));
        assertEq(auction.totalRevenueWithdrawn(), 0);
        assertEq(auction.getMaxWithdraw(), 10 * U);
        vm.clearMockedCalls();
        vm.prank(admin);
        token.approve(address(auction), 0);
        vm.expectRevert();
        vm.prank(admin);
        auction.depositNFTRevenue(U);
        assertEq(auction.totalRevenueDeposited(), 10 * U);
    }

    function testFuzzDepositAndWithdraw(uint96 rawDeposit, uint96 rawWithdraw) public {
        uint256 deposit = bound(uint256(rawDeposit), 1, 1_000_000 * U);
        uint256 amount = bound(uint256(rawWithdraw), 1, deposit);
        _deposit(deposit);
        _withdraw(amount);
        assertEq(auction.getMaxWithdraw(), deposit - amount);
        assertEq(token.balanceOf(treasury), amount);
        assertEq(token.balanceOf(address(auction)), deposit - amount);
    }

    function testDepositRejectsCallbacksAndFeeOnTransferAndRollsBack() public {
        RevenueCallbackUSDC malicious = new RevenueCallbackUSDC();
        Auction target = Auction(
            address(
                new ERC1967Proxy(
                    address(new Auction()), abi.encodeCall(Auction.initialize, (malicious, admin, address(manager)))
                )
            )
        );
        bytes32 adminRole = target.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        target.grantRole(adminRole, address(malicious));
        malicious.mint(admin, 10 * U);
        vm.prank(admin);
        malicious.approve(address(target), type(uint256).max);
        malicious.configure(address(target), false);
        vm.prank(admin);
        target.depositNFTRevenue(U);
        assertFalse(malicious.callbackSucceeded());
        assertEq(target.totalRevenueDeposited(), U);
        malicious.configure(address(0), true);
        vm.expectRevert(Auction.InvalidRevenueDeposit.selector);
        vm.prank(admin);
        target.depositNFTRevenue(U);
        assertEq(target.totalRevenueDeposited(), U);
        assertEq(malicious.balanceOf(address(target)), U);
    }

    function testRevenueEventsIdentifyAdminTreasuryAndNonce() public {
        vm.recordLogs();
        _deposit(10 * U);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory deposited = logs[logs.length - 1];
        assertEq(deposited.topics[0], keccak256("NFTRevenueDeposited(address,uint256,uint256)"));
        assertEq(deposited.topics[1], bytes32(uint256(uint160(admin))));
        assertEq(deposited.data, abi.encode(10 * U, block.timestamp));
        Auction.NFTRevenueWithdrawal memory a = _authorization(3 * U);
        bytes memory signature = _signature(a, SIGNER_KEY, address(auction), block.chainid);
        vm.recordLogs();
        vm.prank(admin);
        auction.withdrawNFTRevenue(a, signature);
        logs = vm.getRecordedLogs();
        Vm.Log memory withdrawn = logs[logs.length - 1];
        assertEq(withdrawn.topics[0], keccak256("NFTRevenueWithdrawn(address,address,uint256,bytes32,uint256)"));
        assertEq(withdrawn.topics[1], bytes32(uint256(uint160(admin))));
        assertEq(withdrawn.topics[2], bytes32(uint256(uint160(treasury))));
        assertEq(withdrawn.topics[3], a.nonce);
        assertEq(withdrawn.data, abi.encode(3 * U, block.timestamp));
    }

    function testModuleCannotBeCalledDirectlyAndNonceCannotBeConsumedExternally() public {
        NFTRevenueModule module = new NFTRevenueModule(auction.SIGNATURE_VERIFIER());
        vm.expectRevert(NFTRevenueModule.InvalidRevenueAuthorization.selector);
        vm.prank(admin);
        module.depositNFTRevenue(U);
        vm.expectRevert(NFTRevenueModule.InvalidRevenueAuthorization.selector);
        vm.prank(admin);
        module.claimNFTRefund(bytes32(uint256(1)), new uint256[](1));
        vm.expectRevert(Auction.InvalidRevenueAuthorization.selector);
        vm.prank(admin);
        auction.consumeRevenueNonce(bytes32(uint256(1)));
        assertFalse(auction.usedNonces(bytes32(uint256(1))));
    }

    function testImplementationFitsEIP170() public view {
        address implementation = address(
            uint160(uint256(vm.load(address(auction), bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1))))
        );
        assertLe(implementation.code.length, 24_576);
    }
}
