// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AuctionSignatureVerifier} from "./AuctionSignatureVerifier.sol";
import {LotNFT} from "./LotNFT.sol";
import {INFTDesignManager} from "./interfaces/INFTDesignManager.sol";

contract Auction is AccessControlUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint16 internal constant DEFAULT_BUYER_PREMIUM_BPS = 1_000;
    uint16 internal constant DEFAULT_SELLER_COMMISSION_BPS = 1_000;
    uint256 internal constant DEFAULT_PAYMENT_GRACE_PERIOD_SECONDS = 1 hours;
    uint256 internal constant DEFAULT_ANTI_SNIPE_WINDOW_SECONDS = 5 minutes;
    uint256 private constant MAX_AUCTION_CONFIG_UPDATE_BATCH_SIZE = 10;
    string internal constant NFT_COLLECTION_NAME = "NextVault Auctions";
    string internal constant NFT_COLLECTION_SYMBOL = "NV";
    bytes32 public constant CREATE_AUCTION_AUTHORIZATION_TYPEHASH = keccak256(
        "CreateAuctionAuthorization(bytes32 lotId,address consignor,uint256 lowEstimate,uint256 highEstimate,uint256 startingBid,uint256 previewDurationSeconds,uint256 auctionDurationSeconds,uint256 variant1Quantity,uint256 variant2Quantity,uint256 variant3Quantity,uint256 nftPriceRatioBps,string nftName,string nftSymbol,string thumbnailUrl,string metadataUri,bytes32 nonce,uint256 deadline)"
    );
    bytes32 internal constant SETTLEMENT_CONFIG_AUTHORIZATION_TYPEHASH = keccak256(
        "SettlementConfigAuthorization(address treasury,uint16 buyerPremiumBps,uint16 sellerCommissionBps,bytes32 nonce,uint256 deadline)"
    );
    bytes32 internal constant AUCTION_TIMING_CONFIG_AUTHORIZATION_TYPEHASH = keccak256(
        "AuctionTimingConfigAuthorization(uint256 paymentGracePeriodSeconds,uint256 antiSnipeWindowSeconds,bytes32 nonce,uint256 deadline)"
    );
    bytes32 internal constant WALLET_DISABLED_AUTHORIZATION_TYPEHASH =
        keccak256("WalletDisabledAuthorization(address wallet,bool disabled,bytes32 nonce,uint256 deadline)");
    bytes32 internal constant BID_AUTHORIZATION_TYPEHASH = keccak256(
        "BidAuthorization(bytes32 lotId,address bidder,uint256 amount,uint8 bidType,uint256 depositDebt,uint256 biddingLimit,bytes32 nonce,uint256 deadline)"
    );

    enum AuctionStatus {
        Preview,
        Active,
        Ended,
        Cancelled,
        Finalized
    }

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

    struct CreateAuctionParams {
        bytes32 lotId;
        address consignor;
        uint256 lowEstimate;
        uint256 highEstimate;
        uint256 startingBid;
        uint256 previewDurationSeconds;
        uint256 auctionDurationSeconds;
        uint256 variant1Quantity;
        uint256 variant2Quantity;
        uint256 variant3Quantity;
        uint256 nftPriceRatioBps;
        string nftName;
        string nftSymbol;
        string thumbnailUrl;
        string metadataUri;
    }

    struct BidderState {
        uint256 deposit;
        bool activeMaxBid;
    }

    enum BidType {
        Manual,
        Maximum
    }

    struct BidAuthorization {
        bytes32 lotId;
        address bidder;
        uint256 amount;
        BidType bidType;
        uint256 depositDebt;
        uint256 biddingLimit;
        bytes32 nonce;
        uint256 deadline;
    }

    struct DepositDebtLedger {
        uint256 totalDebt;
        mapping(bytes32 => uint256) debtByAuction;
    }

    struct SettlementConfigAuthorization {
        address treasury;
        uint16 buyerPremiumBps;
        uint16 sellerCommissionBps;
        bytes32 nonce;
        uint256 deadline;
    }

    struct AuctionTimingConfigAuthorization {
        uint256 paymentGracePeriodSeconds;
        uint256 antiSnipeWindowSeconds;
        bytes32 nonce;
        uint256 deadline;
    }

    struct WalletDisabledAuthorization {
        address wallet;
        bool disabled;
        bytes32 nonce;
        uint256 deadline;
    }

    error InvalidToken();
    error InvalidLotId();
    error LotAlreadyRegistered();
    error InvalidConsignor();
    error InvalidEstimate();
    error InvalidStartingBid();
    error InvalidAuctionDuration();
    error InvalidNftConfig();
    error InvalidNftPriceRatio();
    error InvalidVariantAllocation();
    error AuctionNotFound();
    error AuctionAlreadyCancelled();
    error AuctionNotWithdrawn();
    error AuctionAlreadyEnded();
    error AuctionPaymentAlreadyCollected();
    error AuctionIsCancelled();
    error AuctionHasNoWinner();
    error UnauthorizedPaymentCollector();
    error AuctionNotEnded();
    error AuctionNotActive();
    error InvalidQuantity();
    error NotEligibleToBid();
    error InvalidConfig();
    error InvalidBidAmount();
    error CurrentLeaderCannotWithdrawDeposit();
    error InvalidSigner();
    error InvalidAmount();
    error InvalidNftCollection();
    error AuthorizationExpired();
    error NonceAlreadyUsed();
    error InvalidSettlementConfig();
    error InvalidAuctionTimingConfig();
    error AuctionPaymentGracePeriodActive(uint256 deadline);
    error AuctionDetailsLocked();
    error InvalidDesignManager();
    error BlacklistedWallet();
    error DisabledWallet();
    error BidAuthorizationRequired();
    error InvalidBidAuthorization();
    error DepositDebtLimitExceeded();
    error DepositCannotBeReduced();
    error ConsignorCannotParticipate();
    error WinnerNftNotRefundable();

    event AuctionCreated(bytes32 indexed lotId, address indexed nftCollection, uint256 blockTimestamp);
    event AuctionDetailsUpdated(
        bytes32 indexed lotId,
        address indexed consignor,
        uint256 lowEstimate,
        uint256 highEstimate,
        string thumbnailUrl,
        uint256 blockTimestamp
    );
    event AuctionWithdrawn(bytes32 indexed lotId, address indexed highestBidder, uint256 blockTimestamp);
    event AuctionEnded(
        bytes32 indexed lotId, address indexed winner, uint256 winningBid, bool paymentCollected, uint256 blockTimestamp
    );
    event WinnerPaymentCollected(
        bytes32 indexed lotId, address indexed winner, uint256 winningBid, bool paymentCollected, uint256 blockTimestamp
    );
    event SettlementConfigUpdated(
        address indexed treasury, uint16 buyerPremiumBps, uint16 sellerCommissionBps, uint256 blockTimestamp
    );
    event AuctionTimingConfigUpdated(
        uint256 paymentGracePeriodSeconds, uint256 antiSnipeWindowSeconds, uint256 blockTimestamp
    );
    event AuctionTimingUpdated(
        bytes32 indexed lotId, uint256 paymentGracePeriodSeconds, uint256 antiSnipeWindowSeconds, uint256 blockTimestamp
    );
    event AuctionSettlementConfigUpdated(
        bytes32 indexed lotId, uint16 buyerPremiumBps, uint16 sellerCommissionBps, uint256 blockTimestamp
    );
    event NFTDesignManagerUpdated(
        address indexed previousDesignManager, address indexed newDesignManager, uint256 blockTimestamp
    );
    event AuctionSettled(
        bytes32 indexed lotId,
        address indexed winner,
        address indexed consignor,
        uint256 hammerPrice,
        uint256 buyerPremium,
        uint256 sellerCommission,
        uint256 consignorProceeds,
        uint256 platformRevenue,
        uint256 blockTimestamp
    );
    event NFTPurchased(
        bytes32 indexed lotId,
        address indexed buyer,
        uint256 quantity,
        uint256 totalPrice,
        uint256 lastTokenId,
        uint256 blockTimestamp
    );
    event NFTRefundClaimed(
        bytes32 indexed lotId, address indexed holder, uint256[] tokenIds, uint256 refundAmount, uint256 blockTimestamp
    );
    event BidPlaced(
        bytes32 indexed lotId,
        address indexed bidder,
        uint256 previousBid,
        uint256 amount,
        uint256 depositAmount,
        uint256 depositDebt,
        uint256 blockTimestamp
    );
    event AuctionExtended(bytes32 indexed lotId, uint256 newEndTime);
    event BidRefunded(bytes32 indexed lotId, address indexed bidder, uint256 amount, uint256 blockTimestamp);
    event MaxBidSet(
        bytes32 indexed lotId, address indexed bidder, uint256 amount, uint256 depositAmount, uint256 blockTimestamp
    );
    event MaxBidRefunded(bytes32 indexed lotId, address indexed bidder, uint256 amount, uint256 blockTimestamp);
    event LotNFTTransferred(
        bytes32 indexed lotId,
        address indexed nftCollection,
        address indexed from,
        address to,
        uint256 tokenId,
        uint256 blockTimestamp
    );
    event NFTVariantUpdated(
        bytes32 indexed lotId,
        address indexed nftCollection,
        uint256 indexed tokenId,
        uint8 variant,
        uint256 blockTimestamp
    );
    event WalletBlacklistUpdated(address indexed wallet, bool blacklisted, uint256 blockTimestamp);
    event WalletDisabledUpdated(address indexed wallet, bool disabled, uint256 blockTimestamp);
    event BidAuthorizationRequirementUpdated(bool required, uint256 blockTimestamp);
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

    IERC20 public token;
    uint256 private tokenDecimal;

    mapping(bytes32 => AuctionConfig) private auctions;
    mapping(bytes32 => bool) public auctionExists;
    mapping(bytes32 => bool) public cancelledAuctions;

    mapping(bytes32 => bool) public usedNonces;
    mapping(bytes32 => bool) public endedAuctions;
    mapping(bytes32 => bool) public auctionPaymentCollected;

    address public treasury;
    uint16 public buyerPremiumBps;
    uint16 public sellerCommissionBps;

    mapping(bytes32 => uint256) private itemToCurrentBid;
    mapping(bytes32 => address) private itemToCurrentBidder;
    mapping(bytes32 => bool) private itemToAutoBid;

    mapping(bytes32 => mapping(address => uint256)) private itemBidderToMaxBid;
    mapping(bytes32 => uint256) private itemToMaxBid;
    mapping(bytes32 => address) private itemToMaxBidder;
    mapping(bytes32 => uint256) public auctionBidRound;

    address public nftDesignManager;
    mapping(address => bool) public blacklistedWallets;

    uint256 public paymentGracePeriodSeconds;
    uint256 public antiSnipeWindowSeconds;
    mapping(bytes32 => uint256) public auctionPaymentDeadline;
    mapping(address => bool) public disabledWallets;
    bool public bidAuthorizationRequired;

    // Append-only upgrade storage. A zero debt preserves the legacy full-deposit behaviour.
    mapping(address => DepositDebtLedger) private bidderDepositDebt;

    AuctionSignatureVerifier public immutable SIGNATURE_VERIFIER;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        SIGNATURE_VERIFIER = new AuctionSignatureVerifier();
        _disableInitializers();
    }

    function initialize(IERC20 token_, address admin, address designManager) external initializer {
        if (address(token_) == address(0)) revert InvalidToken();
        if (admin == address(0)) revert InvalidConfig();
        if (designManager == address(0)) revert InvalidDesignManager();
        token = token_;
        nftDesignManager = designManager;
        tokenDecimal = 10 ** IERC20Metadata(address(token_)).decimals();

        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);

        treasury = admin;
        buyerPremiumBps = DEFAULT_BUYER_PREMIUM_BPS;
        sellerCommissionBps = DEFAULT_SELLER_COMMISSION_BPS;
        paymentGracePeriodSeconds = DEFAULT_PAYMENT_GRACE_PERIOD_SECONDS;
        antiSnipeWindowSeconds = DEFAULT_ANTI_SNIPE_WINDOW_SECONDS;
        bidAuthorizationRequired = true;
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        // Upgrade authorization is handled by AccessControl.
    }

    function setSettlementConfig(SettlementConfigAuthorization calldata authorization, bytes calldata signature)
        external
    {
        if (
            authorization.treasury == address(0) || authorization.buyerPremiumBps > BPS_DENOMINATOR
                || authorization.sellerCommissionBps > BPS_DENOMINATOR
        ) revert InvalidSettlementConfig();

        _validateOperatorAuthorization(
            _hashSettlementConfigAuthorization(authorization), authorization.nonce, authorization.deadline, signature
        );

        treasury = authorization.treasury;
        buyerPremiumBps = authorization.buyerPremiumBps;
        sellerCommissionBps = authorization.sellerCommissionBps;

        emit SettlementConfigUpdated(
            authorization.treasury, authorization.buyerPremiumBps, authorization.sellerCommissionBps, block.timestamp
        );
    }

    function setAuctionTimingConfig(AuctionTimingConfigAuthorization calldata authorization, bytes calldata signature)
        external
    {
        if (authorization.paymentGracePeriodSeconds == 0 || authorization.antiSnipeWindowSeconds == 0) {
            revert InvalidAuctionTimingConfig();
        }

        _validateOperatorAuthorization(
            _hashAuctionTimingConfigAuthorization(authorization), authorization.nonce, authorization.deadline, signature
        );

        paymentGracePeriodSeconds = authorization.paymentGracePeriodSeconds;
        antiSnipeWindowSeconds = authorization.antiSnipeWindowSeconds;

        emit AuctionTimingConfigUpdated(
            authorization.paymentGracePeriodSeconds, authorization.antiSnipeWindowSeconds, block.timestamp
        );
    }

    function setNFTDesignManager(address designManager) external onlyRole(OPERATOR_ROLE) {
        if (designManager == address(0) || INFTDesignManager(designManager).auction() != address(this)) {
            revert InvalidDesignManager();
        }

        address previousDesignManager = nftDesignManager;
        nftDesignManager = designManager;
        emit NFTDesignManagerUpdated(previousDesignManager, designManager, block.timestamp);
    }

    function updateAuctionTimingConfigs(bytes32[] calldata lotIds) external onlyRole(OPERATOR_ROLE) {
        if (lotIds.length == 0 || lotIds.length > MAX_AUCTION_CONFIG_UPDATE_BATCH_SIZE) revert InvalidAmount();

        uint256 paymentGracePeriodSeconds_ = paymentGracePeriodSeconds;
        uint256 antiSnipeWindowSeconds_ = antiSnipeWindowSeconds;

        for (uint256 i; i < lotIds.length; ++i) {
            bytes32 lotId = lotIds[i];
            if (!auctionExists[lotId]) revert AuctionNotFound();

            AuctionConfig storage auction = auctions[lotId];
            if (block.timestamp >= auction.startTime) revert AuctionDetailsLocked();

            auction.paymentGracePeriodSeconds = paymentGracePeriodSeconds_;
            auction.antiSnipeWindowSeconds = antiSnipeWindowSeconds_;

            emit AuctionTimingUpdated(lotId, paymentGracePeriodSeconds_, antiSnipeWindowSeconds_, block.timestamp);
        }
    }

    function updateAuctionSettlementConfigs(bytes32[] calldata lotIds) external onlyRole(OPERATOR_ROLE) {
        if (lotIds.length == 0 || lotIds.length > MAX_AUCTION_CONFIG_UPDATE_BATCH_SIZE) revert InvalidAmount();

        uint16 buyerPremiumBps_ = buyerPremiumBps;
        uint16 sellerCommissionBps_ = sellerCommissionBps;

        for (uint256 i; i < lotIds.length; ++i) {
            bytes32 lotId = lotIds[i];
            if (!auctionExists[lotId]) revert AuctionNotFound();

            AuctionConfig storage auction = auctions[lotId];
            if (block.timestamp >= auction.startTime) revert AuctionDetailsLocked();

            auction.buyerPremiumBps = buyerPremiumBps_;
            auction.sellerCommissionBps = sellerCommissionBps_;

            emit AuctionSettlementConfigUpdated(lotId, buyerPremiumBps_, sellerCommissionBps_, block.timestamp);
        }
    }

    function setWalletBlacklist(address wallet, bool blacklisted) external onlyRole(OPERATOR_ROLE) {
        _setWalletBlacklist(wallet, blacklisted);
    }

    function _setWalletBlacklist(address wallet, bool blacklisted) internal {
        if (wallet == address(0)) revert InvalidConfig();

        blacklistedWallets[wallet] = blacklisted;
        emit WalletBlacklistUpdated(wallet, blacklisted, block.timestamp);
    }

    function setWalletDisabled(WalletDisabledAuthorization calldata authorization, bytes calldata signature) external {
        if (authorization.wallet == address(0)) revert InvalidConfig();

        _validateOperatorAuthorization(
            _hashWalletDisabledAuthorization(authorization), authorization.nonce, authorization.deadline, signature
        );

        disabledWallets[authorization.wallet] = authorization.disabled;
        emit WalletDisabledUpdated(authorization.wallet, authorization.disabled, block.timestamp);
    }

    function setBidAuthorizationRequired(bool required) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bidAuthorizationRequired = required;
        emit BidAuthorizationRequirementUpdated(required, block.timestamp);
    }

    function getBidDepositDebt(bytes32 lotId, address bidder)
        external
        view
        returns (uint256 totalDebt, uint256 auctionDebt, uint256 standardDeposit, uint256 actualDeposit)
    {
        DepositDebtLedger storage ledger = bidderDepositDebt[bidder];
        totalDebt = ledger.totalDebt;
        auctionDebt = ledger.debtByAuction[lotId];
        standardDeposit = _bidderExposure(lotId, bidder) / 10;
        actualDeposit = standardDeposit - auctionDebt;
    }

    function createAuction(
        CreateAuctionParams calldata params,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external returns (bytes32) {
        _validateOperatorAuthorization(
            _hashCreateAuctionAuthorization(params, nonce, deadline), nonce, deadline, signature
        );

        if (params.lotId == bytes32(0)) revert InvalidLotId();
        if (auctionExists[params.lotId]) revert LotAlreadyRegistered();
        if (params.consignor == address(0)) revert InvalidConsignor();
        if (params.lowEstimate == 0 || params.highEstimate < params.lowEstimate) {
            revert InvalidEstimate();
        }
        if (params.startingBid == 0 || params.startingBid > params.lowEstimate) {
            revert InvalidStartingBid();
        }
        if (params.auctionDurationSeconds == 0) revert InvalidAuctionDuration();
        if (params.nftPriceRatioBps == 0) revert InvalidNftPriceRatio();

        uint256 nftMaxSupply = params.variant1Quantity + params.variant2Quantity + params.variant3Quantity;
        if (nftMaxSupply == 0) revert InvalidVariantAllocation();

        uint256 nftPrice = (params.lowEstimate * params.nftPriceRatioBps) / BPS_DENOMINATOR / nftMaxSupply;
        if (nftPrice == 0) revert InvalidNftConfig();

        uint256 startTime = block.timestamp + params.previewDurationSeconds;
        uint256 endTime = startTime + params.auctionDurationSeconds;
        address nftCollection = INFTDesignManager(nftDesignManager)
            .createLotNFT(
                NFT_COLLECTION_NAME,
                NFT_COLLECTION_SYMBOL,
                params.metadataUri,
                params.lotId,
                nftMaxSupply,
                params.variant1Quantity,
                params.variant2Quantity,
                params.variant3Quantity
            );

        auctions[params.lotId] = AuctionConfig({
            lotId: params.lotId,
            consignor: params.consignor,
            nftCollection: nftCollection,
            lowEstimate: params.lowEstimate,
            highEstimate: params.highEstimate,
            startingBid: params.startingBid,
            startTime: startTime,
            endTime: endTime,
            previewDurationSeconds: params.previewDurationSeconds,
            auctionDurationSeconds: params.auctionDurationSeconds,
            nftMaxSupply: nftMaxSupply,
            nftPriceRatioBps: params.nftPriceRatioBps,
            nftPrice: nftPrice,
            thumbnailUrl: params.thumbnailUrl,
            paymentGracePeriodSeconds: paymentGracePeriodSeconds,
            antiSnipeWindowSeconds: antiSnipeWindowSeconds,
            buyerPremiumBps: buyerPremiumBps,
            sellerCommissionBps: sellerCommissionBps
        });
        auctionExists[params.lotId] = true;

        emit AuctionCreated(params.lotId, nftCollection, block.timestamp);

        return params.lotId;
    }

    function updateAuctionDetails(
        bytes32 lotId,
        address consignor,
        uint256 lowEstimate,
        uint256 highEstimate,
        string calldata thumbnailUrl
    ) external onlyRole(OPERATOR_ROLE) {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        if (consignor == address(0)) revert InvalidConsignor();
        if (lowEstimate == 0 || highEstimate < lowEstimate) revert InvalidEstimate();

        AuctionConfig storage auction = auctions[lotId];
        if (auction.startingBid > lowEstimate) revert InvalidStartingBid();

        AuctionStatus status = _currentStatus(auction.startTime, auction.previewDurationSeconds, auction.endTime);
        if (
            cancelledAuctions[lotId] || endedAuctions[lotId] || auctionPaymentCollected[lotId]
                || (status != AuctionStatus.Preview && status != AuctionStatus.Active)
        ) {
            revert AuctionDetailsLocked();
        }

        auction.consignor = consignor;
        auction.lowEstimate = lowEstimate;
        auction.highEstimate = highEstimate;
        auction.thumbnailUrl = thumbnailUrl;

        emit AuctionDetailsUpdated(lotId, consignor, lowEstimate, highEstimate, thumbnailUrl, block.timestamp);
    }

    function buyNFT(bytes32 lotId, uint256 quantity) external {
        _checkWalletCanAct(msg.sender);
        if (!auctionExists[lotId]) revert AuctionNotFound();
        AuctionConfig storage auction = auctions[lotId];
        _checkNotConsignor(auction.consignor, msg.sender);

        if (cancelledAuctions[lotId]) revert AuctionIsCancelled();
        if (_currentStatus(auction.startTime, auction.previewDurationSeconds, auction.endTime) != AuctionStatus.Active)
        {
            revert AuctionNotActive();
        }

        if (quantity == 0) revert InvalidQuantity();

        uint256 totalPrice = auction.nftPrice * quantity;
        token.safeTransferFrom(msg.sender, address(this), totalPrice);

        uint256 lastTokenId = LotNFT(auction.nftCollection).mintBatch(msg.sender, quantity);
        uint256 firstTokenId = lastTokenId - quantity + 1;
        INFTDesignManager(LotNFT(auction.nftCollection).designManager())
            .requestVariants(lotId, msg.sender, auction.nftCollection, firstTokenId, quantity);

        emit NFTPurchased(lotId, msg.sender, quantity, totalPrice, lastTokenId, block.timestamp);
    }

    function placeBid(bytes32 lotId, uint256 amount) external {
        if (bidAuthorizationRequired) revert BidAuthorizationRequired();
        _placeBid(lotId, msg.sender, amount, 0, 0, false);
    }

    function placeBid(BidAuthorization calldata authorization, bytes calldata signature) external {
        _validateBidAuthorization(authorization, BidType.Manual, signature);
        _placeBid(
            authorization.lotId,
            msg.sender,
            authorization.amount,
            authorization.depositDebt,
            authorization.biddingLimit,
            true
        );
    }

    function _placeBid(
        bytes32 lotId,
        address bidder,
        uint256 amount,
        uint256 newDebt,
        uint256 biddingLimit,
        bool enforceDebtLimit
    ) internal {
        _checkWalletCanAct(bidder);
        if (!auctionExists[lotId]) revert AuctionNotFound();
        if (cancelledAuctions[lotId]) revert AuctionIsCancelled();
        AuctionConfig storage auction = auctions[lotId];
        _checkNotConsignor(auction.consignor, bidder);
        if (_currentStatus(auction.startTime, auction.previewDurationSeconds, auction.endTime) != AuctionStatus.Active)
        {
            revert AuctionNotActive();
        }
        if (LotNFT(auction.nftCollection).balanceOf(bidder) == 0) revert NotEligibleToBid();

        // A leader cannot raise the visible price against themselves. Treat any
        // valid ladder amount they submit through the manual entry point as a
        // maximum bid and leave the current bid unchanged until a competitor
        // challenges it.
        if (itemToCurrentBidder[lotId] == bidder) {
            _applyMaxBid(lotId, bidder, amount, newDebt, biddingLimit, enforceDebtLimit);
            return;
        }

        uint256 currentBid = itemToCurrentBid[lotId];
        uint256 expectedBid = currentBid == 0 ? auction.startingBid : currentBid + _bidIncrementFor(currentBid);
        if (amount != expectedBid) revert InvalidBidAmount();
        if (amount < itemToMaxBid[lotId]) revert InvalidBidAmount();

        uint256 newExposure = _max(amount, itemBidderToMaxBid[lotId][bidder]);
        (uint256 oldActualDeposit, uint256 newActualDeposit) =
            _validateDebtChange(lotId, bidder, newExposure, newDebt, biddingLimit, enforceDebtLimit);
        if (newActualDeposit > oldActualDeposit) {
            token.safeTransferFrom(bidder, address(this), newActualDeposit - oldActualDeposit);
        }

        if (itemToCurrentBidder[lotId] != bidder) _refundBid(lotId);

        itemToCurrentBidder[lotId] = bidder;
        itemToCurrentBid[lotId] = amount;
        itemToAutoBid[lotId] = false;
        _setDepositDebt(lotId, bidder, newDebt);

        emit BidPlaced(lotId, bidder, currentBid, amount, newActualDeposit, newDebt, block.timestamp);
        _extendAuctionIfNeeded(lotId);
    }

    function placeBidFor(bytes32 lotId, address bidder, uint256 amount) external onlyRole(OPERATOR_ROLE) {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        if (cancelledAuctions[lotId]) revert AuctionIsCancelled();
        AuctionConfig storage auction = auctions[lotId];
        _checkNotConsignor(auction.consignor, bidder);
        if (_currentStatus(auction.startTime, auction.previewDurationSeconds, auction.endTime) != AuctionStatus.Active)
        {
            revert AuctionNotActive();
        }
        if (LotNFT(auction.nftCollection).balanceOf(bidder) == 0) revert NotEligibleToBid();

        uint256 currentBid = _validateBidOnLadder(lotId, auction.startingBid, amount);

        if (amount > itemBidderToMaxBid[lotId][bidder]) revert InvalidBidAmount();

        _refundBid(lotId);

        itemToCurrentBidder[lotId] = bidder;
        itemToCurrentBid[lotId] = amount;
        itemToAutoBid[lotId] = true;

        uint256 previousBid = currentBid == 0 ? auction.startingBid : currentBid;
        uint256 debt = bidderDepositDebt[bidder].debtByAuction[lotId];
        uint256 actualDeposit = itemBidderToMaxBid[lotId][bidder] / 10 - debt;

        emit BidPlaced(lotId, bidder, previousBid, amount, actualDeposit, debt, block.timestamp);
        _extendAuctionIfNeeded(lotId);
    }

    function setMaxBid(bytes32 lotId, uint256 amount) external {
        if (bidAuthorizationRequired) revert BidAuthorizationRequired();
        _setMaxBid(lotId, msg.sender, amount, 0, 0, false);
    }

    function setMaxBid(BidAuthorization calldata authorization, bytes calldata signature) external {
        _validateBidAuthorization(authorization, BidType.Maximum, signature);
        _setMaxBid(
            authorization.lotId,
            msg.sender,
            authorization.amount,
            authorization.depositDebt,
            authorization.biddingLimit,
            true
        );
    }

    function _setMaxBid(
        bytes32 lotId,
        address bidder,
        uint256 amount,
        uint256 newDebt,
        uint256 biddingLimit,
        bool enforceDebtLimit
    ) internal {
        _checkWalletCanAct(bidder);
        if (!auctionExists[lotId]) revert AuctionNotFound();
        if (cancelledAuctions[lotId]) revert AuctionIsCancelled();
        AuctionConfig memory auction = auctions[lotId];
        _checkNotConsignor(auction.consignor, bidder);
        if (_currentStatus(auction.startTime, auction.previewDurationSeconds, auction.endTime) != AuctionStatus.Active)
        {
            revert AuctionNotActive();
        }
        if (LotNFT(auction.nftCollection).balanceOf(bidder) == 0) revert NotEligibleToBid();

        _applyMaxBid(lotId, bidder, amount, newDebt, biddingLimit, enforceDebtLimit);
    }

    function _applyMaxBid(
        bytes32 lotId,
        address bidder,
        uint256 amount,
        uint256 newDebt,
        uint256 biddingLimit,
        bool enforceDebtLimit
    ) internal {
        _validateBidOnLadder(lotId, auctions[lotId].startingBid, amount);

        if (itemToCurrentBid[lotId] > amount) revert InvalidBidAmount();

        uint256 previousMaxBid = itemBidderToMaxBid[lotId][bidder];
        if (amount <= previousMaxBid) revert InvalidBidAmount();
        if (itemToMaxBidder[lotId] != address(0) && itemToMaxBidder[lotId] != bidder && amount <= itemToMaxBid[lotId]) {
            revert InvalidBidAmount();
        }

        uint256 newExposure = _max(_manualBidAmount(lotId, bidder), amount);
        (uint256 oldActualDeposit, uint256 newActualDeposit) =
            _validateDebtChange(lotId, bidder, newExposure, newDebt, biddingLimit, enforceDebtLimit);
        if (newActualDeposit > oldActualDeposit) {
            token.safeTransferFrom(bidder, address(this), newActualDeposit - oldActualDeposit);
        }

        itemBidderToMaxBid[lotId][bidder] = amount;
        _setDepositDebt(lotId, bidder, newDebt);
        if (amount > itemToMaxBid[lotId]) {
            itemToMaxBid[lotId] = amount;
            itemToMaxBidder[lotId] = bidder;
        }

        emit MaxBidSet(lotId, bidder, amount, newActualDeposit, block.timestamp);
    }

    function _refundBid(bytes32 lotId) internal {
        address currentBidder = itemToCurrentBidder[lotId];
        if (currentBidder == address(0)) return;
        if (itemToAutoBid[lotId]) return;

        uint256 oldExposure = _bidderExposure(lotId, currentBidder);
        uint256 oldDebt = bidderDepositDebt[currentBidder].debtByAuction[lotId];
        uint256 newExposure = itemBidderToMaxBid[lotId][currentBidder];
        uint256 newDebt = _min(oldDebt, newExposure / 10);
        uint256 refundAmount = oldExposure / 10 - oldDebt - (newExposure / 10 - newDebt);
        _setDepositDebt(lotId, currentBidder, newDebt);

        if (refundAmount > 0) token.safeTransfer(currentBidder, refundAmount);
        emit BidRefunded(lotId, currentBidder, refundAmount, block.timestamp);
    }

    function refundMaxBid(bytes32 lotId, address bidder) external onlyRole(OPERATOR_ROLE) {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        if (!cancelledAuctions[lotId]) {
            if (itemToCurrentBidder[lotId] == bidder) revert CurrentLeaderCannotWithdrawDeposit();
        }

        uint256 maxBidAmount = itemBidderToMaxBid[lotId][bidder];
        if (maxBidAmount == 0) revert InvalidAmount();
        uint256 oldExposure = _bidderExposure(lotId, bidder);
        uint256 oldDebt = bidderDepositDebt[bidder].debtByAuction[lotId];
        uint256 newExposure = _manualBidAmount(lotId, bidder);
        uint256 newDebt = _min(oldDebt, newExposure / 10);
        uint256 refundAmount = oldExposure / 10 - oldDebt - (newExposure / 10 - newDebt);

        itemBidderToMaxBid[lotId][bidder] = 0;
        _setDepositDebt(lotId, bidder, newDebt);
        if (itemToMaxBidder[lotId] == bidder) {
            itemToMaxBidder[lotId] = address(0);
            itemToMaxBid[lotId] = 0;
        }
        if (refundAmount > 0) token.safeTransfer(bidder, refundAmount);

        emit MaxBidRefunded(lotId, bidder, refundAmount, block.timestamp);
    }

    function endAuction(bytes32 lotId)
        external
        onlyRole(OPERATOR_ROLE)
        returns (address winner, uint256 winningBid, bool paymentCollected)
    {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        if (cancelledAuctions[lotId]) revert AuctionIsCancelled();
        if (endedAuctions[lotId]) revert AuctionAlreadyEnded();
        if (block.timestamp < auctions[lotId].endTime) revert AuctionNotEnded();

        endedAuctions[lotId] = true;
        winner = itemToCurrentBidder[lotId];
        winningBid = itemToCurrentBid[lotId];
        paymentCollected = _trySettleAuctionPayment(lotId, winner, winningBid);
        auctionPaymentCollected[lotId] = paymentCollected;
        AuctionConfig storage auction = auctions[lotId];
        auctionPaymentDeadline[lotId] =
            winner != address(0) && !paymentCollected ? auction.endTime + auction.paymentGracePeriodSeconds : 0;

        emit AuctionEnded(lotId, winner, winningBid, paymentCollected, block.timestamp);
    }

    function _trySettleAuctionPayment(bytes32 lotId, address winner, uint256 winningBid) internal returns (bool) {
        if (winner == address(0)) return false;
        if (treasury == address(0)) revert InvalidSettlementConfig();
        AuctionConfig storage auction = auctions[lotId];
        uint256 buyerPremium = (winningBid * auction.buyerPremiumBps) / BPS_DENOMINATOR;
        uint256 totalPayment = winningBid + buyerPremium;
        uint256 deposited = _actualBidDeposit(lotId, winner);
        uint256 remainingPayment = totalPayment > deposited ? totalPayment - deposited : 0;
        uint256 excessDeposit = deposited > totalPayment ? deposited - totalPayment : 0;
        if (token.balanceOf(winner) < remainingPayment || token.allowance(winner, address(this)) < remainingPayment) {
            return false;
        }

        if (remainingPayment > 0) {
            try token.transferFrom(winner, address(this), remainingPayment) returns (bool transferred) {
                if (!transferred) return false;
            } catch {
                return false;
            }
        }
        if (excessDeposit > 0) {
            token.safeTransfer(winner, excessDeposit);
            emit MaxBidRefunded(lotId, winner, excessDeposit, block.timestamp);
        }

        uint256 sellerCommission = (winningBid * auction.sellerCommissionBps) / BPS_DENOMINATOR;
        uint256 consignorProceeds = winningBid - sellerCommission;
        uint256 platformRevenue = buyerPremium + sellerCommission;

        token.safeTransfer(auction.consignor, consignorProceeds);
        token.safeTransfer(treasury, platformRevenue);

        INFTDesignManager(LotNFT(auction.nftCollection).designManager())
            .mintWinnerVariant(lotId, auction.nftCollection, winner);

        _clearWinnerDepositDebt(lotId, winner);

        emit AuctionSettled(
            lotId,
            winner,
            auction.consignor,
            winningBid,
            buyerPremium,
            sellerCommission,
            consignorProceeds,
            platformRevenue,
            block.timestamp
        );
        return true;
    }

    function settleAuctionPayment(bytes32 lotId) external returns (bool paymentCollected) {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        if (cancelledAuctions[lotId]) revert AuctionIsCancelled();
        if (!endedAuctions[lotId]) revert AuctionNotEnded();
        if (auctionPaymentCollected[lotId]) revert AuctionPaymentAlreadyCollected();

        address winner = itemToCurrentBidder[lotId];
        if (winner == address(0)) revert AuctionHasNoWinner();
        if (msg.sender != winner && !hasRole(OPERATOR_ROLE, msg.sender)) revert UnauthorizedPaymentCollector();

        uint256 winningBid = itemToCurrentBid[lotId];
        paymentCollected = _trySettleAuctionPayment(lotId, winner, winningBid);
        auctionPaymentCollected[lotId] = paymentCollected;

        if (paymentCollected) auctionPaymentDeadline[lotId] = 0;

        emit WinnerPaymentCollected(lotId, winner, winningBid, paymentCollected, block.timestamp);

        if (!paymentCollected && hasRole(OPERATOR_ROLE, msg.sender)) {
            if (block.timestamp < auctionPaymentDeadline[lotId]) {
                revert AuctionPaymentGracePeriodActive(auctionPaymentDeadline[lotId]);
            }
            _setWalletBlacklist(winner, true);
            _restartAuction(lotId, winner);
        }
    }

    function _restartAuction(bytes32 lotId, address defaultedWinner) internal {
        uint256 forfeitedDeposit = _actualBidDeposit(lotId, defaultedWinner);

        _clearWinnerDepositDebt(lotId, defaultedWinner);
        if (forfeitedDeposit > 0) token.safeTransfer(treasury, forfeitedDeposit);

        uint256 previousRound = auctionBidRound[lotId];
        uint256 newRound = previousRound + 1;
        AuctionConfig storage auction = auctions[lotId];

        itemToCurrentBid[lotId] = 0;
        itemToCurrentBidder[lotId] = address(0);
        itemToAutoBid[lotId] = false;
        itemToMaxBid[lotId] = 0;
        itemToMaxBidder[lotId] = address(0);
        auctionBidRound[lotId] = newRound;

        auction.startTime = block.timestamp;
        auction.endTime = block.timestamp + auction.auctionDurationSeconds;
        auction.previewDurationSeconds = 0;
        endedAuctions[lotId] = false;
        auctionPaymentCollected[lotId] = false;
        auctionPaymentDeadline[lotId] = 0;
        cancelledAuctions[lotId] = false;

        emit AuctionRestarted(
            lotId,
            previousRound,
            newRound,
            defaultedWinner,
            forfeitedDeposit,
            auction.startTime,
            auction.endTime,
            block.timestamp
        );
    }

    function withdrawAuction(bytes32 lotId) external onlyRole(OPERATOR_ROLE) {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        if (cancelledAuctions[lotId]) revert AuctionAlreadyCancelled();

        cancelledAuctions[lotId] = true;
        auctionPaymentDeadline[lotId] = 0;

        emit AuctionWithdrawn(lotId, itemToCurrentBidder[lotId], block.timestamp);

        // Settled deposits have already paid the consignor/platform. They must
        // never be refunded a second time when withdrawing a finalized lot.
        if (!auctionPaymentCollected[lotId] && itemToCurrentBidder[lotId] != address(0)) {
            _refundBid(lotId);
        }
        itemToCurrentBid[lotId] = 0;
        itemToCurrentBidder[lotId] = address(0);
        itemToAutoBid[lotId] = false;
    }

    function claimNFTRefund(bytes32 lotId, uint256[] calldata tokenIds) external {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        if (!cancelledAuctions[lotId]) revert AuctionNotWithdrawn();

        uint256 quantity = tokenIds.length;
        if (quantity == 0) revert InvalidQuantity();

        AuctionConfig storage auction = auctions[lotId];
        LotNFT nftCollection = LotNFT(auction.nftCollection);
        // Passes occupy IDs 1..maxSupply. The complimentary winner NFT is
        // maxSupply + 1 and stays with its holder, including after transfer.
        for (uint256 i; i < quantity; ++i) {
            if (tokenIds[i] > auction.nftMaxSupply) revert WinnerNftNotRefundable();
        }
        nftCollection.burnBatchForRefund(msg.sender, tokenIds);

        uint256 refundAmount = auction.nftPrice * quantity;
        token.safeTransfer(msg.sender, refundAmount);

        emit NFTRefundClaimed(lotId, msg.sender, tokenIds, refundAmount, block.timestamp);
    }

    function getNFTRefundAmount(bytes32 lotId, address holder)
        external
        view
        returns (uint256 quantity, uint256 refundAmount)
    {
        if (!auctionExists[lotId]) revert AuctionNotFound();

        AuctionConfig storage auction = auctions[lotId];
        LotNFT collection = LotNFT(auction.nftCollection);
        quantity = collection.balanceOf(holder);
        try collection.ownerOf(auction.nftMaxSupply + 1) returns (address winnerNftHolder) {
            if (winnerNftHolder == holder) quantity--;
        } catch {
            // The winner NFT has not been minted yet.
        }
        if (cancelledAuctions[lotId]) refundAmount = quantity * auction.nftPrice;
    }

    function onLotNFTTransfer(bytes32 lotId, address from, address to, uint256 tokenId) external {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        if (auctions[lotId].nftCollection != msg.sender) revert InvalidNftCollection();

        emit LotNFTTransferred(lotId, msg.sender, from, to, tokenId, block.timestamp);
    }

    function onLotNFTVariantAssigned(bytes32 lotId, uint256 tokenId, uint8 variant) external {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        if (auctions[lotId].nftCollection != msg.sender) revert InvalidNftCollection();

        emit NFTVariantUpdated(lotId, msg.sender, tokenId, variant, block.timestamp);
    }

    function getAuction(bytes32 lotId) external view returns (AuctionConfig memory) {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        return auctions[lotId];
    }

    function currentStatus(bytes32 lotId) external view returns (AuctionStatus) {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        if (cancelledAuctions[lotId]) {
            return AuctionStatus.Cancelled;
        }
        if (auctionPaymentCollected[lotId]) {
            return AuctionStatus.Finalized;
        }
        if (endedAuctions[lotId]) {
            return AuctionStatus.Ended;
        }
        return
            _currentStatus(auctions[lotId].startTime, auctions[lotId].previewDurationSeconds, auctions[lotId].endTime);
    }

    function _hashCreateAuctionAuthorization(CreateAuctionParams calldata params, bytes32 nonce, uint256 deadline)
        internal
        pure
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                CREATE_AUCTION_AUTHORIZATION_TYPEHASH,
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

        return structHash;
    }

    function _hashSettlementConfigAuthorization(SettlementConfigAuthorization calldata authorization)
        internal
        pure
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                SETTLEMENT_CONFIG_AUTHORIZATION_TYPEHASH,
                authorization.treasury,
                authorization.buyerPremiumBps,
                authorization.sellerCommissionBps,
                authorization.nonce,
                authorization.deadline
            )
        );

        return structHash;
    }

    function _hashAuctionTimingConfigAuthorization(AuctionTimingConfigAuthorization calldata authorization)
        internal
        pure
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                AUCTION_TIMING_CONFIG_AUTHORIZATION_TYPEHASH,
                authorization.paymentGracePeriodSeconds,
                authorization.antiSnipeWindowSeconds,
                authorization.nonce,
                authorization.deadline
            )
        );

        return structHash;
    }

    function _hashWalletDisabledAuthorization(WalletDisabledAuthorization calldata authorization)
        internal
        pure
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                WALLET_DISABLED_AUTHORIZATION_TYPEHASH,
                authorization.wallet,
                authorization.disabled,
                authorization.nonce,
                authorization.deadline
            )
        );

        return structHash;
    }

    function _hashBidAuthorization(BidAuthorization calldata authorization) internal pure returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                BID_AUTHORIZATION_TYPEHASH,
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

        return structHash;
    }

    function _validateBidAuthorization(
        BidAuthorization calldata authorization,
        BidType expectedBidType,
        bytes calldata signature
    ) internal {
        if (authorization.bidder != msg.sender || authorization.bidType != expectedBidType) {
            revert InvalidBidAuthorization();
        }

        _validateOperatorAuthorization(
            _hashBidAuthorization(authorization), authorization.nonce, authorization.deadline, signature
        );
    }

    function _validateDebtChange(
        bytes32 lotId,
        address bidder,
        uint256 newExposure,
        uint256 newDebt,
        uint256 biddingLimit,
        bool enforceDebtLimit
    ) internal view returns (uint256 oldActualDeposit, uint256 newActualDeposit) {
        DepositDebtLedger storage ledger = bidderDepositDebt[bidder];
        uint256 oldDebt = ledger.debtByAuction[lotId];
        uint256 oldStandardDeposit = _bidderExposure(lotId, bidder) / 10;
        uint256 newStandardDeposit = newExposure / 10;

        if (newDebt > newStandardDeposit) revert InvalidBidAuthorization();
        if (!enforceDebtLimit && newDebt != 0) revert InvalidBidAuthorization();

        oldActualDeposit = oldStandardDeposit - oldDebt;
        newActualDeposit = newStandardDeposit - newDebt;
        if (newActualDeposit < oldActualDeposit) revert DepositCannotBeReduced();

        if (newDebt > oldDebt) {
            uint256 debtIncrease = newDebt - oldDebt;
            uint256 standardIncrease =
                newStandardDeposit > oldStandardDeposit ? newStandardDeposit - oldStandardDeposit : 0;
            if (debtIncrease > standardIncrease) revert DepositCannotBeReduced();
            if (ledger.totalDebt - oldDebt + newDebt > biddingLimit / 10) revert DepositDebtLimitExceeded();
        }
    }

    function _setDepositDebt(bytes32 lotId, address bidder, uint256 newDebt) internal {
        DepositDebtLedger storage ledger = bidderDepositDebt[bidder];
        uint256 oldDebt = ledger.debtByAuction[lotId];
        ledger.debtByAuction[lotId] = newDebt;
        ledger.totalDebt = ledger.totalDebt - oldDebt + newDebt;
    }

    function _manualBidAmount(bytes32 lotId, address bidder) internal view returns (uint256) {
        if (itemToCurrentBidder[lotId] != bidder || itemToAutoBid[lotId]) return 0;
        return itemToCurrentBid[lotId];
    }

    function _bidderExposure(bytes32 lotId, address bidder) internal view returns (uint256) {
        return _max(_manualBidAmount(lotId, bidder), itemBidderToMaxBid[lotId][bidder]);
    }

    function _actualBidDeposit(bytes32 lotId, address bidder) internal view returns (uint256) {
        return _bidderExposure(lotId, bidder) / 10 - bidderDepositDebt[bidder].debtByAuction[lotId];
    }

    function _clearWinnerDepositDebt(bytes32 lotId, address bidder) internal {
        itemBidderToMaxBid[lotId][bidder] = 0;
        _setDepositDebt(lotId, bidder, 0);
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _validateOperatorAuthorization(
        bytes32 structHash,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) internal {
        if (block.timestamp > deadline) revert AuthorizationExpired();
        if (usedNonces[nonce]) revert NonceAlreadyUsed();
        address signer = SIGNATURE_VERIFIER.recoverSigner(structHash, address(this), signature);
        if (!hasRole(OPERATOR_ROLE, signer)) revert InvalidSigner();

        usedNonces[nonce] = true;
    }

    function _checkWalletCanAct(address wallet) internal view {
        if (blacklistedWallets[wallet]) revert BlacklistedWallet();
        if (disabledWallets[wallet]) revert DisabledWallet();
    }

    function _checkNotConsignor(address consignor, address participant) internal pure {
        if (consignor == participant) revert ConsignorCannotParticipate();
    }

    function _currentStatus(uint256 startTime, uint256 previewDurationSeconds, uint256 endTime)
        internal
        view
        returns (AuctionStatus)
    {
        if (previewDurationSeconds == 0 || block.timestamp >= startTime) {
            if (block.timestamp >= endTime) {
                return AuctionStatus.Ended;
            }
            return AuctionStatus.Active;
        }
        return AuctionStatus.Preview;
    }

    function _bidIncrementFor(uint256 amount) internal view returns (uint256) {
        uint256 offset;

        if (amount < 2_000 * tokenDecimal) return 100 * tokenDecimal;
        if (amount < 5_000 * tokenDecimal) {
            offset = amount % (1_000 * tokenDecimal);
            if (offset == 0) return 200 * tokenDecimal;
            if (offset == 200 * tokenDecimal) return 300 * tokenDecimal;
            if (offset == 500 * tokenDecimal) return 300 * tokenDecimal;
            return 200 * tokenDecimal;
        }
        if (amount < 10_000 * tokenDecimal) return 500 * tokenDecimal;
        if (amount < 20_000 * tokenDecimal) return 1_000 * tokenDecimal;
        if (amount < 50_000 * tokenDecimal) {
            offset = amount % (10_000 * tokenDecimal);
            if (offset == 0) return 2_000 * tokenDecimal;
            if (offset == 2_000 * tokenDecimal) return 3_000 * tokenDecimal;
            if (offset == 5_000 * tokenDecimal) return 3_000 * tokenDecimal;
            return 2_000 * tokenDecimal;
        }
        if (amount < 100_000 * tokenDecimal) return 5_000 * tokenDecimal;
        if (amount < 200_000 * tokenDecimal) return 10_000 * tokenDecimal;
        if (amount < 500_000 * tokenDecimal) {
            offset = amount % (100_000 * tokenDecimal);
            if (offset == 0) return 20_000 * tokenDecimal;
            if (offset == 20_000 * tokenDecimal) return 30_000 * tokenDecimal;
            if (offset == 50_000 * tokenDecimal) return 30_000 * tokenDecimal;
            return 20_000 * tokenDecimal;
        }
        if (amount < 1_000_000 * tokenDecimal) return 50_000 * tokenDecimal;
        if (amount < 2_000_000 * tokenDecimal) return 100_000 * tokenDecimal;
        if (amount < 5_000_000 * tokenDecimal) {
            offset = amount % (1_000_000 * tokenDecimal);
            if (offset == 0) return 200_000 * tokenDecimal;
            if (offset == 200_000 * tokenDecimal) return 300_000 * tokenDecimal;
            if (offset == 500_000 * tokenDecimal) return 300_000 * tokenDecimal;
            return 200_000 * tokenDecimal;
        }
        return 500_000 * tokenDecimal;
    }

    function _validateBidOnLadder(bytes32 lotId, uint256 startingBid, uint256 amount) internal view returns (uint256) {
        uint256 currentBid = itemToCurrentBid[lotId];
        uint256 validBid = currentBid == 0 ? startingBid : currentBid + _bidIncrementFor(currentBid);
        if (amount < validBid) revert InvalidBidAmount();

        while (validBid < amount) {
            validBid += _bidIncrementFor(validBid);
        }
        if (validBid != amount) revert InvalidBidAmount();

        return currentBid;
    }

    function _extendAuctionIfNeeded(bytes32 lotId) internal {
        AuctionConfig storage auction = auctions[lotId];
        if (block.timestamp + auction.antiSnipeWindowSeconds < auction.endTime) return;
        uint256 newEndTime = block.timestamp + auction.antiSnipeWindowSeconds;
        auction.endTime = newEndTime;
        emit AuctionExtended(lotId, newEndTime);
    }
}
