// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {AuctionRevenueFixture} from "./AuctionRevenue.t.sol";
import {Auction} from "../src/Auction.sol";
import {FakeUSDC} from "../src/FakeUSDC.sol";
import {LotNFT} from "../src/LotNFT.sol";
import {NFTRevenueModule} from "../src/NFTRevenueModule.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {NFTDesignManager} from "../src/NFTDesignManager.sol";
import {MockVRFCoordinator} from "./mocks/MockVRFCoordinator.sol";

contract OutgoingCallbackUSDC is FakeUSDC {
    address public target;
    bytes public callback;
    bool public attacked;
    bool public succeeded;
    bytes public result;

    function arm(address target_, bytes memory callback_) external {
        target = target_;
        callback = callback_;
        attacked = false;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (!attacked && target != address(0)) {
            attacked = true;
            (succeeded, result) = target.call(callback);
        }
        return super.transfer(to, amount);
    }
}

contract AuctionRevenueSecurityTest is AuctionRevenueFixture {
    function testSignatureCannotBeFrontRunByAnotherAdmin() public {
        _deposit(10 * U);
        bytes32 role = auction.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        auction.grantRole(role, buyer);
        Auction.NFTRevenueWithdrawal memory a = _authorization(U);
        bytes memory sig = _signature(a, SIGNER_KEY, address(auction), block.chainid);
        vm.expectRevert(Auction.InvalidRevenueAuthorization.selector);
        vm.prank(buyer);
        auction.withdrawNFTRevenue(a, sig);
        assertFalse(auction.usedNonces(a.nonce));
        vm.prank(admin);
        auction.withdrawNFTRevenue(a, sig);
        assertEq(token.balanceOf(treasury), U);
    }

    function testRevokedAdminCannotExecuteAnOutstandingSignature() public {
        _deposit(U);
        Auction.NFTRevenueWithdrawal memory a = _authorization(U);
        bytes memory sig = _signature(a, SIGNER_KEY, address(auction), block.chainid);
        bytes32 role = auction.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        auction.grantRole(role, buyer);
        vm.prank(buyer);
        auction.revokeRole(role, admin);
        vm.expectRevert();
        vm.prank(admin);
        auction.withdrawNFTRevenue(a, sig);
        assertFalse(auction.usedNonces(a.nonce));
        assertEq(auction.getMaxWithdraw(), U);
    }

    function testMalformedAndMalleableSignaturesNeverConsumeNonceOrMoney() public {
        _deposit(10 * U);
        Auction.NFTRevenueWithdrawal memory a = _authorization(U);
        bytes memory sig = _signature(a, SIGNER_KEY, address(auction), block.chainid);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        uint256 order = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes[] memory invalid = new bytes[](5);
        invalid[0] = "";
        invalid[1] = hex"1234";
        invalid[2] = new bytes(64);
        invalid[3] = abi.encodePacked(r, bytes32(order - uint256(s)), uint8(v == 27 ? 28 : 27));
        invalid[4] = abi.encodePacked(r, s, uint8(0));
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert();
            vm.prank(admin);
            auction.withdrawNFTRevenue(a, invalid[i]);
            assertFalse(auction.usedNonces(a.nonce));
            assertEq(auction.getMaxWithdraw(), 10 * U);
            assertEq(token.balanceOf(treasury), 0);
        }
        vm.prank(admin);
        auction.withdrawNFTRevenue(a, sig);
        assertEq(auction.getMaxWithdraw(), 9 * U);
    }

    function testNonceDeadlineAndTreasuryCannotBeChangedAfterSigning() public {
        _deposit(10 * U);
        Auction.NFTRevenueWithdrawal memory a = _authorization(U);
        bytes memory sig = _signature(a, SIGNER_KEY, address(auction), block.chainid);
        bytes32 original = a.nonce;
        a.nonce = bytes32(uint256(999));
        vm.expectRevert(Auction.InvalidSigner.selector);
        vm.prank(admin);
        auction.withdrawNFTRevenue(a, sig);
        a.nonce = original;
        a.deadline += 1;
        vm.expectRevert(Auction.InvalidSigner.selector);
        vm.prank(admin);
        auction.withdrawNFTRevenue(a, sig);
        a.deadline -= 1;
        a.treasury = buyer;
        vm.expectRevert(Auction.InvalidRevenueAuthorization.selector);
        vm.prank(admin);
        auction.withdrawNFTRevenue(a, sig);
        assertEq(auction.totalRevenueWithdrawn(), 0);
    }

    function testTwoOutstandingAuthorizationsCannotOverspendPool() public {
        _deposit(10 * U);
        Auction.NFTRevenueWithdrawal memory a = _authorization(8 * U);
        Auction.NFTRevenueWithdrawal memory b = _authorization(8 * U);
        bytes memory sigA = _signature(a, SIGNER_KEY, address(auction), block.chainid);
        bytes memory sigB = _signature(b, SIGNER_KEY, address(auction), block.chainid);
        vm.prank(admin);
        auction.withdrawNFTRevenue(a, sigA);
        vm.expectRevert(abi.encodeWithSelector(Auction.InsufficientNFTRevenue.selector, 8 * U, 2 * U));
        vm.prank(admin);
        auction.withdrawNFTRevenue(b, sigB);
        assertFalse(auction.usedNonces(b.nonce));
        assertEq(token.balanceOf(treasury), 8 * U);
        assertEq(auction.getMaxWithdraw(), 2 * U);
    }

    function testRepeatedDuplicateForeignAndWinnerRefundsCannotDrainPool() public {
        bytes32 lot = _create(1, 100, 0);
        _buy(lot, buyer, 2);
        vm.prank(buyer);
        auction.placeBid(lot, 1000 * U);
        _end(lot);
        vm.prank(operator);
        auction.withdrawAuction(lot);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 1;
        vm.expectRevert();
        vm.prank(buyer);
        auction.claimNFTRefund(lot, ids);
        LotNFT collection = LotNFT(auction.getAuction(lot).nftCollection);
        assertEq(collection.ownerOf(1), buyer, "partial burn must roll back");
        ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert();
        vm.prank(otherBuyer);
        auction.claimNFTRefund(lot, ids);
        ids[0] = 101;
        vm.expectRevert(Auction.WinnerNftNotRefundable.selector);
        vm.prank(buyer);
        auction.claimNFTRefund(lot, ids);
        assertEq(collection.ownerOf(101), buyer);
        ids[0] = 1;
        vm.mockCallRevert(address(token), abi.encodeCall(token.transfer, (buyer, U)), "USDC unavailable");
        vm.expectRevert();
        vm.prank(buyer);
        auction.claimNFTRefund(lot, ids);
        assertEq(collection.ownerOf(1), buyer);
        vm.clearMockedCalls();
        vm.prank(buyer);
        auction.claimNFTRefund(lot, ids);
        vm.expectRevert();
        vm.prank(buyer);
        auction.claimNFTRefund(lot, ids);
        assertEq(token.balanceOf(address(auction)), U);
        assertEq(auction.getMaxWithdraw(), 0);
    }

    function testOutgoingTransferCannotReenterWithAnotherValidAuthorization() public {
        OutgoingCallbackUSDC malicious = new OutgoingCallbackUSDC();
        Auction target = Auction(
            address(
                new ERC1967Proxy(
                    address(new Auction()), abi.encodeCall(Auction.initialize, (malicious, admin, address(manager)))
                )
            )
        );
        bytes32 adminRole = target.DEFAULT_ADMIN_ROLE();
        bytes32 signerRole = target.REVENUE_AUTHORIZER_ROLE();
        vm.startPrank(admin);
        target.grantRole(adminRole, address(malicious));
        target.grantRole(signerRole, signer);
        vm.stopPrank();
        malicious.mint(admin, 10 * U);
        vm.startPrank(admin);
        malicious.approve(address(target), 10 * U);
        target.depositNFTRevenue(10 * U);
        vm.stopPrank();
        // Target treasury starts as admin. Callback token is also an Admin so
        // only the lock, not role/auth rejection, can stop this valid inner call.
        Auction.NFTRevenueWithdrawal memory inner =
            Auction.NFTRevenueWithdrawal(address(malicious), U, admin, bytes32(uint256(42)), block.timestamp + 100);
        bytes memory innerSig = _signature(inner, SIGNER_KEY, address(target), block.chainid);
        malicious.arm(address(target), abi.encodeCall(target.withdrawNFTRevenue, (inner, innerSig)));
        Auction.NFTRevenueWithdrawal memory outer =
            Auction.NFTRevenueWithdrawal(admin, U, admin, bytes32(uint256(43)), block.timestamp + 100);
        bytes memory outerSig = _signature(outer, SIGNER_KEY, address(target), block.chainid);
        vm.prank(admin);
        target.withdrawNFTRevenue(outer, outerSig);
        assertTrue(malicious.attacked());
        assertFalse(malicious.succeeded());
        assertEq(malicious.result(), abi.encodeWithSelector(Auction.RevenueReentrancy.selector));
        assertFalse(target.usedNonces(inner.nonce));
        assertTrue(target.usedNonces(outer.nonce));
        assertEq(target.totalRevenueWithdrawn(), U);
        assertEq(target.getMaxWithdraw(), 9 * U);
    }

    function testDirectModuleWithdrawalCannotSkipEntryPointChecks() public {
        NFTRevenueModule module = new NFTRevenueModule(auction.SIGNATURE_VERIFIER());
        NFTRevenueModule.NFTRevenueWithdrawal memory a =
            NFTRevenueModule.NFTRevenueWithdrawal(admin, U, treasury, bytes32(0), type(uint256).max);
        vm.expectRevert(NFTRevenueModule.InvalidRevenueAuthorization.selector);
        vm.prank(admin);
        module.withdrawNFTRevenue(a, "");
    }

    function testRefundTransferCannotReenterToClaimAnotherOwnedPass() public {
        OutgoingCallbackUSDC malicious = new OutgoingCallbackUSDC();
        manager = new NFTDesignManager(
            admin, address(new LotNFT()), address(new MockVRFCoordinator()), 1, bytes32(uint256(1)), 500_000, 3, false
        );
        auction = Auction(
            address(
                new ERC1967Proxy(
                    address(new Auction()), abi.encodeCall(Auction.initialize, (malicious, admin, address(manager)))
                )
            )
        );
        token = malicious;
        vm.prank(admin);
        manager.initializeAuction(address(auction));
        bytes32 opRole = auction.OPERATOR_ROLE();
        vm.prank(admin);
        auction.grantRole(opRole, operator);
        bytes32 lot = _create(1, 100, 0);
        _buy(lot, buyer, 2);
        LotNFT collection = LotNFT(auction.getAuction(lot).nftCollection);
        vm.prank(buyer);
        collection.transferFrom(buyer, address(malicious), 2);
        vm.prank(operator);
        auction.withdrawAuction(lot);
        uint256[] memory innerIds = new uint256[](1);
        innerIds[0] = 2;
        malicious.arm(address(auction), abi.encodeCall(auction.claimNFTRefund, (lot, innerIds)));
        uint256[] memory outerIds = new uint256[](1);
        outerIds[0] = 1;
        vm.prank(buyer);
        auction.claimNFTRefund(lot, outerIds);
        assertTrue(malicious.attacked());
        assertFalse(malicious.succeeded());
        assertEq(malicious.result(), abi.encodeWithSelector(Auction.RevenueReentrancy.selector));
        assertEq(collection.ownerOf(2), address(malicious));
        assertEq(token.balanceOf(address(auction)), U);
        // The lock is cleared after the outer call; a later legitimate claim works.
        vm.prank(address(malicious));
        auction.claimNFTRefund(lot, innerIds);
        assertEq(token.balanceOf(address(auction)), 0);
    }

    function testSharedNonceRegistryCannotBeReusedAcrossAuthorizationTypes() public {
        _deposit(10 * U);
        Auction.NFTRevenueWithdrawal memory a = _authorization(U);
        a.nonce = keccak256(abi.encode("treasury", treasury));
        assertTrue(auction.usedNonces(a.nonce));
        bytes memory sig = _signature(a, SIGNER_KEY, address(auction), block.chainid);
        vm.expectRevert(Auction.NonceAlreadyUsed.selector);
        vm.prank(admin);
        auction.withdrawNFTRevenue(a, sig);
        assertEq(auction.getMaxWithdraw(), 10 * U);
    }
}

contract RevenueInvariantHandler is Test {
    Auction public immutable auction;
    FakeUSDC public immutable token;
    address public immutable admin;
    address public immutable operator;
    address public immutable buyer;
    uint256 public deposits;
    uint256 public withdrawals;
    uint256 public donations;
    uint256 public eligible = 60e6;
    uint256 public reserve;
    uint256 private nonce;
    bool[3] public withdrawn;
    bool[3] public claimed;
    uint256[3] public claimedCount;

    constructor(Auction a, FakeUSDC t, address ad, address op, address b) {
        auction = a;
        token = t;
        admin = ad;
        operator = op;
        buyer = b;
    }

    function deposit(uint96 raw) external {
        uint256 amount = bound(uint256(raw), 1, 1000e6);
        vm.prank(admin);
        auction.depositNFTRevenue(amount);
        deposits += amount;
    }

    function donate(uint96 raw) external {
        uint256 amount = bound(uint256(raw), 1, 1000e6);
        vm.prank(admin);
        token.transfer(address(auction), amount);
        donations += amount;
    }

    function withdrawRevenue(uint96 raw) external {
        uint256 max = auction.getMaxWithdraw();
        if (max == 0) return;
        uint256 amount = bound(uint256(raw), 1, max);
        Auction.NFTRevenueWithdrawal memory a = Auction.NFTRevenueWithdrawal(
            admin, amount, auction.treasury(), keccak256(abi.encode("invariant", ++nonce)), block.timestamp + 100
        );
        bytes32 hash = keccak256(
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
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("NextVaultAuction"),
                keccak256("1"),
                block.chainid,
                address(auction)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBEEF, keccak256(abi.encodePacked("\x19\x01", domain, hash)));
        vm.prank(admin);
        auction.withdrawNFTRevenue(a, abi.encodePacked(r, s, v));
        withdrawals += amount;
    }

    function withdrawLot(uint8 raw) external {
        uint256 index = raw % 3;
        if (withdrawn[index]) return;
        uint256 amount = (index + 1) * 10e6;
        if (amount > auction.getMaxWithdraw()) {
            vm.expectRevert(
                abi.encodeWithSelector(Auction.InsufficientNFTRefundFunds.selector, amount, auction.getMaxWithdraw())
            );
            vm.prank(operator);
            auction.withdrawAuction(bytes32(index + 1));
            return;
        }
        vm.prank(operator);
        auction.withdrawAuction(bytes32(index + 1));
        withdrawn[index] = true;
        eligible -= amount;
        reserve += amount;
    }

    function claim(uint8 raw) external {
        uint256 index = raw % 3;
        if (!withdrawn[index] || claimed[index]) return;
        _claim(index, (index + 1) * 10 - claimedCount[index]);
    }

    function claimPartial(uint8 raw, uint8 rawCount) external {
        uint256 index = raw % 3;
        if (!withdrawn[index] || claimed[index]) return;
        uint256 remaining = (index + 1) * 10 - claimedCount[index];
        _claim(index, bound(uint256(rawCount), 1, remaining));
    }

    function _claim(uint256 index, uint256 count) private {
        uint256[] memory ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = claimedCount[index] + i + 1;
        }
        vm.prank(buyer);
        auction.claimNFTRefund(bytes32(index + 1), ids);
        claimedCount[index] += count;
        claimed[index] = claimedCount[index] == (index + 1) * 10;
        reserve -= count * 1e6;
    }
}

contract AuctionRevenueInvariantTest is AuctionRevenueFixture {
    RevenueInvariantHandler handler;

    function setUp() public override {
        super.setUp();
        for (uint256 i = 1; i <= 3; ++i) {
            bytes32 lot = _create(i, 100, 0);
            _buy(lot, buyer, i * 10);
        }
        bytes32 active = _create(4, 1_000_000, 0);
        _buy(active, buyer, 10);
        vm.prank(buyer);
        auction.placeBid(active, 1000 * U);
        _end(bytes32(uint256(1)));
        _end(bytes32(uint256(2)));
        _end(bytes32(uint256(3)));
        handler = new RevenueInvariantHandler(auction, token, admin, operator, buyer);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.donate.selector;
        selectors[2] = handler.withdrawRevenue.selector;
        selectors[3] = handler.withdrawLot.selector;
        selectors[4] = handler.claim.selector;
        selectors[5] = handler.claimPartial.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariantPoolSolventAndBidderCollateralUntouched() public view {
        uint256 max = auction.getMaxWithdraw();
        assertEq(auction.eligiblePassRevenue(), handler.eligible());
        assertEq(auction.totalRevenueDeposited(), handler.deposits());
        assertEq(auction.totalRevenueWithdrawn(), handler.withdrawals());
        assertEq(max, handler.eligible() + handler.deposits() - handler.withdrawals());
        // 10 USDC active pass reserve + 100 USDC bidder collateral are never eligible.
        assertEq(token.balanceOf(address(auction)), max + handler.reserve() + 110 * U + handler.donations());
        assertEq(auction.totalPassRevenue(), 70 * U);
    }

    function invariantEveryUnclaimedRefundRemainsReserved() public view {
        uint256 liability;
        for (uint256 i; i < 3; ++i) {
            bytes32 lot = bytes32(i + 1);
            uint256 originalQuantity = (i + 1) * 10;
            assertEq(auction.lotPassRevenue(lot), originalQuantity * U);
            uint256 held = LotNFT(auction.getAuction(lot).nftCollection).balanceOf(buyer);
            assertEq(held, originalQuantity - handler.claimedCount(i));
            if (handler.withdrawn(i)) liability += held * U;
        }
        assertEq(handler.reserve(), liability);
        assertGe(token.balanceOf(address(auction)), liability + 110 * U);
    }
}
