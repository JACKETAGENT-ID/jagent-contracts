// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice Non-custodial market for JAGENT NFTs only. A listing never takes the NFT: the NFT stays in
///         the seller's wallet until buy() moves it straight seller -> buyer in the same transaction that
///         splits the exact price between the seller and PAYEE (market fee). Listing therefore needs the
///         standard ERC-721 approval of this contract (single-token approve or setApprovalForAll) — the
///         approval only ever lets the market complete a sale at the listed price, or move nothing at all.
///         No owner, no pause, no upgrade, no admin withdrawal; the fee rate and PAYEE are fixed at deploy.
///
/// @dev FEE_BPS is set at deployment to 250 (2.5%), as decided by the project owner; it cannot be
///      changed afterwards.
contract JagentMarket is ReentrancyGuard {
    uint256 private constant BPS = 10_000;

    IERC721 public immutable NFT;
    address public immutable PAYEE;
    uint256 public immutable FEE_BPS;

    struct Listing {
        address seller;
        uint256 price;
    }

    mapping(uint256 => Listing) public listings;

    event Listed(address indexed seller, uint256 indexed tokenId, uint256 price);
    event Bought(address indexed buyer, address indexed seller, uint256 indexed tokenId, uint256 price, uint256 fee);
    event Cancelled(address indexed seller, uint256 indexed tokenId);

    constructor(address nft_, address payee_, uint256 feeBps_) {
        require(nft_ != address(0) && payee_ != address(0), "address");
        require(feeBps_ <= 1_000, "fee");
        NFT = IERC721(nft_);
        PAYEE = payee_;
        FEE_BPS = feeBps_;
    }

    /// @dev BNB only ever flows through buy(); anything sent directly would have no way out.
    receive() external payable {
        revert("no direct BNB");
    }

    function owner() external pure returns (address) {
        return address(0);
    }

    /// @notice List your NFT at `price` BNB (wei). The NFT stays in your wallet; this contract must be
    ///         approved for it (approve or setApprovalForAll) so buy() can settle the sale.
    function list(uint256 tokenId, uint256 price) external {
        require(price != 0, "price");
        require(NFT.ownerOf(tokenId) == msg.sender, "not NFT owner");
        require(
            NFT.getApproved(tokenId) == address(this) || NFT.isApprovedForAll(msg.sender, address(this)), "market not approved"
        );
        listings[tokenId] = Listing({seller: msg.sender, price: price});
        emit Listed(msg.sender, tokenId, price);
    }

    /// @notice Buy a listed NFT paying its exact price: the fee goes to PAYEE, the rest to the seller,
    ///         and the NFT moves seller -> buyer atomically. Reverts if the seller no longer owns the
    ///         NFT or revoked the market's approval (the stale listing then just stays until cancelled).
    function buy(uint256 tokenId) external payable nonReentrant {
        Listing memory listing = listings[tokenId];
        require(listing.price != 0, "not listed");
        require(msg.value == listing.price, "value");
        delete listings[tokenId];
        uint256 fee = listing.price * FEE_BPS / BPS;
        uint256 sellerAmount = listing.price - fee;
        NFT.transferFrom(listing.seller, msg.sender, tokenId);
        (bool sentSeller,) = listing.seller.call{value: sellerAmount}("");
        require(sentSeller, "seller send");
        if (fee != 0) {
            (bool sentFee,) = PAYEE.call{value: fee}("");
            require(sentFee, "fee send");
        }
        emit Bought(msg.sender, listing.seller, tokenId, listing.price, fee);
    }

    /// @notice Only the seller can cancel their listing. The NFT never moved, so nothing else is needed.
    function cancelListing(uint256 tokenId) external {
        require(listings[tokenId].seller == msg.sender, "not seller");
        delete listings[tokenId];
        emit Cancelled(msg.sender, tokenId);
    }
}
