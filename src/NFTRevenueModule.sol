// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AuctionSignatureVerifier} from "./AuctionSignatureVerifier.sol";
import {NFTRevenueStorage} from "./NFTRevenueStorage.sol";
import {LotNFT} from "./LotNFT.sol";

interface IRevenueAuction {
    struct AuctionConfig {
        bytes32 lotId;
        address consignor;
        address nftCollection;
        uint256 lowEstimate;
        uint256 highEstimate;
        uint256 startingBid;
        uint256 startTime;
        uint256 endTime;
        uint256 previewDurationSeconds;
        uint256 auctionDurationSeconds;
        uint256 nftMaxSupply;
        uint256 nftPriceRatioBps;
        uint256 nftPrice;
        string thumbnailUrl;
        uint256 paymentGracePeriodSeconds;
        uint256 antiSnipeWindowSeconds;
        uint16 buyerPremiumBps;
        uint16 sellerCommissionBps;
    }
    function getAuction(bytes32 lotId) external view returns (AuctionConfig memory);
    function token() external view returns (IERC20);
    function treasury() external view returns (address);
    function hasRole(bytes32 role, address wallet) external view returns (bool);
    function usedNonces(bytes32 nonce) external view returns (bool);
    function consumeRevenueNonce(bytes32 nonce) external;
}

/// @dev Delegatecall module: backend authorizations attest BE Admin membership.
/// The proxy enforces reentrancy checks; callers need no SC governance role.
contract NFTRevenueModule {
    using SafeERC20 for IERC20;
    AuctionSignatureVerifier private immutable VERIFIER;
    address private immutable SELF = address(this);

    struct NFTRevenueWithdrawal {
        address admin;
        uint256 amount;
        address treasury;
        bytes32 nonce;
        uint256 deadline;
    }

    struct NFTRevenueDeposit {
        address admin;
        uint256 amount;
        bytes32 nonce;
        uint256 deadline;
    }

    error InvalidRevenueAuthorization();
    error AuthorizationExpired();
    error NonceAlreadyUsed();
    error InvalidSigner();
    error InvalidAmount();
    error InvalidRevenueDeposit();
    error InsufficientNFTRevenue(uint256 requested, uint256 available);
    error WinnerNftNotRefundable();
    event NFTRefundClaimed(
        bytes32 indexed lotId, address indexed holder, uint256[] tokenIds, uint256 refundAmount, uint256 blockTimestamp
    );
    event NFTRevenueDeposited(address indexed admin, uint256 amount, uint256 blockTimestamp);
    event NFTRevenueWithdrawn(
        address indexed admin, address indexed treasury, uint256 amount, bytes32 indexed nonce, uint256 blockTimestamp
    );

    constructor(AuctionSignatureVerifier verifier) {
        VERIFIER = verifier;
    }

    modifier delegatedOnly() {
        if (address(this) == SELF) revert InvalidRevenueAuthorization();
        _;
    }

    function depositNFTRevenue(NFTRevenueDeposit calldata a, bytes calldata signature) external delegatedOnly {
        if (a.admin != msg.sender) revert InvalidRevenueAuthorization();
        _authorize(
            keccak256(
                abi.encode(
                    keccak256("NFTRevenueDeposit(address admin,uint256 amount,bytes32 nonce,uint256 deadline)"),
                    a.admin,
                    a.amount,
                    a.nonce,
                    a.deadline
                )
            ),
            a.nonce,
            a.deadline,
            signature
        );
        uint256 amount = a.amount;
        if (amount == 0) revert InvalidAmount();
        IERC20 token = IRevenueAuction(address(this)).token();
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) - beforeBalance != amount) revert InvalidRevenueDeposit();
        NFTRevenueStorage.layout().totalDeposited += amount;
        emit NFTRevenueDeposited(msg.sender, amount, block.timestamp);
    }

    /// @dev Auction validates existence, withdrawn status, quantity and its lock
    /// before delegating. Free winner NFTs never contribute to revenue/refunds.
    function claimNFTRefund(bytes32 lotId, uint256[] calldata tokenIds) external delegatedOnly {
        IRevenueAuction self = IRevenueAuction(address(this));
        IRevenueAuction.AuctionConfig memory a = self.getAuction(lotId);
        for (uint256 i; i < tokenIds.length; ++i) {
            if (tokenIds[i] > a.nftMaxSupply) revert WinnerNftNotRefundable();
        }
        LotNFT(a.nftCollection).burnBatchForRefund(msg.sender, tokenIds);
        uint256 amount = a.nftPrice * tokenIds.length;
        self.token().safeTransfer(msg.sender, amount);
        emit NFTRefundClaimed(lotId, msg.sender, tokenIds, amount, block.timestamp);
    }

    function withdrawNFTRevenue(NFTRevenueWithdrawal calldata a, bytes calldata signature) external delegatedOnly {
        IRevenueAuction self = IRevenueAuction(address(this));
        if (a.admin != msg.sender || a.treasury != self.treasury()) revert InvalidRevenueAuthorization();
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
        _authorize(hash, a.nonce, a.deadline, signature);
        if (a.amount == 0) revert InvalidAmount();
        NFTRevenueStorage.Layout storage s = NFTRevenueStorage.layout();
        uint256 available = s.eligiblePassRevenue + s.totalDeposited - s.totalWithdrawn;
        if (a.amount > available) revert InsufficientNFTRevenue(a.amount, available);
        s.totalWithdrawn += a.amount;
        self.token().safeTransfer(a.treasury, a.amount);
        emit NFTRevenueWithdrawn(msg.sender, a.treasury, a.amount, a.nonce, block.timestamp);
    }

    function _authorize(bytes32 hash, bytes32 nonce, uint256 deadline, bytes calldata signature) private {
        IRevenueAuction self = IRevenueAuction(address(this));
        if (deadline < block.timestamp) revert AuthorizationExpired();
        if (self.usedNonces(nonce)) revert NonceAlreadyUsed();
        address signer = VERIFIER.recoverSigner(hash, address(this), signature);
        if (!self.hasRole(keccak256("REVENUE_AUTHORIZER_ROLE"), signer)) revert InvalidSigner();
        self.consumeRevenueNonce(nonce);
    }
}
