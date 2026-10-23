// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;
import {AuctionRevenueFixture, signedRevenueDeposit} from "./AuctionRevenue.t.sol";
import {Auction} from "../src/Auction.sol";

contract AuctionRevenueBEAdminTest is AuctionRevenueFixture {
    function testBackendAdminWithoutAnyGovernanceRoleCanDepositAndWithdraw() public {
        assertFalse(auction.hasRole(auction.DEFAULT_ADMIN_ROLE(), buyer));
        assertFalse(auction.hasRole(auction.OPERATOR_ROLE(), buyer));
        (Auction.NFTRevenueDeposit memory a, bytes memory sig) =
            signedRevenueDeposit(auction, buyer, 10 * U, bytes32(uint256(555)));
        vm.prank(buyer);
        auction.depositNFTRevenue(a, sig);
        Auction.NFTRevenueWithdrawal memory w = _authorization(10 * U);
        w.admin = buyer;
        sig = _signature(w, SIGNER_KEY, address(auction), block.chainid);
        vm.prank(buyer);
        auction.withdrawNFTRevenue(w, sig);
        assertEq(token.balanceOf(treasury), 10 * U);
        assertEq(auction.getMaxWithdraw(), 0);
        assertFalse(auction.hasRole(auction.DEFAULT_ADMIN_ROLE(), buyer));
        vm.expectRevert();
        vm.prank(buyer);
        auction.grantRole(bytes32(0), buyer);
    }

    function testEvenGovernanceAdminCannotDepositWithoutBackendSignatureAndLegacySelectorIsDisabled() public {
        Auction.NFTRevenueDeposit memory a =
            Auction.NFTRevenueDeposit(admin, U, bytes32(uint256(1)), block.timestamp + 300);
        vm.expectRevert();
        vm.prank(admin);
        auction.depositNFTRevenue(a, "");
        vm.prank(admin);
        (bool success,) = address(auction).call(abi.encodeWithSignature("depositNFTRevenue(uint256)", U));
        assertFalse(success);
        assertEq(auction.totalRevenueDeposited(), 0);
    }

    function testDepositAuthorizationCannotBypassWithdrawalTwoFactorAndSharesNonceRegistry() public {
        (Auction.NFTRevenueDeposit memory a, bytes memory depositSig) =
            signedRevenueDeposit(auction, buyer, 10 * U, bytes32(uint256(123)));
        Auction.NFTRevenueWithdrawal memory w = _authorization(10 * U);
        w.admin = buyer;
        w.nonce = a.nonce;
        w.deadline = a.deadline;
        vm.expectRevert(Auction.InvalidSigner.selector);
        vm.prank(buyer);
        auction.withdrawNFTRevenue(w, depositSig);
        assertFalse(auction.usedNonces(a.nonce));
        vm.prank(buyer);
        auction.depositNFTRevenue(a, depositSig);
        vm.expectRevert(Auction.NonceAlreadyUsed.selector);
        vm.prank(buyer);
        auction.depositNFTRevenue(a, depositSig);
        bytes memory withdrawSig = _signature(w, SIGNER_KEY, address(auction), block.chainid);
        vm.expectRevert(Auction.NonceAlreadyUsed.selector);
        vm.prank(buyer);
        auction.withdrawNFTRevenue(w, withdrawSig);
        assertEq(auction.getMaxWithdraw(), 10 * U);
    }

    function testDepositBindsCallerAmountNonceDeadlineChainAndProxyAndRevokedSigner() public {
        (Auction.NFTRevenueDeposit memory a, bytes memory sig) =
            signedRevenueDeposit(auction, buyer, U, bytes32(uint256(444)));
        vm.expectRevert(Auction.InvalidRevenueAuthorization.selector);
        vm.prank(otherBuyer);
        auction.depositNFTRevenue(a, sig);
        a.amount++;
        vm.expectRevert(Auction.InvalidSigner.selector);
        vm.prank(buyer);
        auction.depositNFTRevenue(a, sig);
        a.amount--;
        a.nonce = bytes32(uint256(445));
        vm.expectRevert(Auction.InvalidSigner.selector);
        vm.prank(buyer);
        auction.depositNFTRevenue(a, sig);
        a.nonce = bytes32(uint256(444));
        a.deadline++;
        vm.expectRevert(Auction.InvalidSigner.selector);
        vm.prank(buyer);
        auction.depositNFTRevenue(a, sig);
        a.deadline--;
        uint256 originalChain = block.chainid;
        vm.chainId(originalChain + 1);
        vm.expectRevert(Auction.InvalidSigner.selector);
        vm.prank(buyer);
        auction.depositNFTRevenue(a, sig);
        vm.chainId(originalChain);
        (Auction.NFTRevenueDeposit memory foreign, bytes memory foreignSig) =
            signedRevenueDeposit(Auction(address(123)), buyer, U, a.nonce);
        vm.expectRevert(Auction.InvalidSigner.selector);
        vm.prank(buyer);
        auction.depositNFTRevenue(foreign, foreignSig);
        bytes32 role = auction.REVENUE_AUTHORIZER_ROLE();
        vm.prank(admin);
        auction.revokeRole(role, signer);
        vm.expectRevert(Auction.InvalidSigner.selector);
        vm.prank(buyer);
        auction.depositNFTRevenue(a, sig);
        vm.warp(a.deadline + 1);
        vm.expectRevert(Auction.AuthorizationExpired.selector);
        vm.prank(buyer);
        auction.depositNFTRevenue(a, sig);
        assertFalse(auction.usedNonces(a.nonce));
        assertEq(auction.totalRevenueDeposited(), 0);
    }
}
