// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/// @dev Isolated pool bookkeeping shared by Auction and its immutable module.
library NFTRevenueStorage {
    bytes32 private constant SLOT = keccak256("nextvault.auction.nft-revenue.storage.v1");

    struct Layout {
        mapping(bytes32 => uint256) lotRevenue;
        mapping(bytes32 => bool) eligibleLots;
        uint256 totalPassRevenue;
        uint256 eligiblePassRevenue;
        uint256 totalDeposited;
        uint256 totalWithdrawn;
    }

    function layout() internal pure returns (Layout storage s) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") { s.slot := slot }
    }
}
