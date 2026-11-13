// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAgentRegistry} from "./External.sol";

/// @notice JAGENT — Agent ID NFT collection sale with an escrowed paid phase and a refund guarantee.
///
///         Phases (all times from `start`, fixed at deploy as deploy time + startDelay):
///         1. FREE — the first `freeSupply` Agent IDs claim 1 NFT each for a small fixed service fee
///            (`freeFee`, forwarded to PAYEE in the same transaction). Free claims close when the free
///            supply runs out or `freeWindow` elapses, whichever comes first.
///         2. PAID — opens the moment the free phase closes. `price` BNB per NFT, at most
///            `paidPerAgent` per Agent ID, until `paidCap` is sold. Paid payments are ESCROWED in
///            this contract (not forwarded) until the sale is finalized.
///         3. FLOOR / REFUND — if at least `floorPaid` paid NFTs are sold before `deadline`
///            (= start + floorWindow), anyone may call `finalize()`: the full escrow is released to
///            PAYEE and trading opens (paid NFTs become transferable; paid minting may continue to
///            the cap, with later payments forwarded to PAYEE immediately). If the deadline passes
///            with fewer than `floorPaid` paid NFTs sold, the sale has failed: paid minting stops
///            forever and every paid NFT holder can call `refundPaid(tokenId)` to burn that NFT and
///            reclaim exactly `price` BNB. Free NFTs and the free service fee are never refundable.
///
///         Paid NFTs are non-transferable until the sale is finalized ("open trade"); free NFTs are
///         always transferable. No owner, no pause, no upgrade, no admin withdrawal — PAYEE is
///         immutable and escrowed funds can only ever go to PAYEE (via finalize) or back to paid
///         NFT holders (via refundPaid).
contract JagentNFT is ERC721, ReentrancyGuard {
    struct Config {
        string name;
        string symbol;
        string baseURI;
        address registry;
        address payee;
        uint256 price;
        uint256 freeFee;
        uint256 freeSupply;
        uint256 paidCap;
        uint256 freePerAgent;
        uint256 paidPerAgent;
        uint256 startDelay;
        uint256 freeWindow;
        uint256 floorPaid;
        uint256 floorWindow;
    }

    IAgentRegistry public immutable REGISTRY;
    address public immutable PAYEE;
    uint256 public immutable PRICE;
    uint256 public immutable FREE_FEE;
    uint256 public immutable FREE_SUPPLY;
    uint256 public immutable PAID_CAP;
    uint256 public immutable FREE_PER_AGENT;
    uint256 public immutable PAID_PER_AGENT;
    uint256 public immutable START;
    uint256 public immutable FREE_END;
    uint256 public immutable FLOOR_PAID;
    uint256 public immutable DEADLINE;
    string private BASE_URI;

    /// @notice Total NFTs ever minted; token ids are sequential from 1 and never reused.
    uint256 public minted;
    uint256 public freeSold;
    uint256 public paidSold;
    /// @notice True once the floor was met and the escrow released to PAYEE (trading open).
    bool public finalized;
    mapping(uint256 => uint256) public freeByAgent;
    mapping(uint256 => uint256) public paidByAgent;
    /// @notice True for token ids that were paid-minted (escrowed / refundable / transfer-locked
    ///         until finalization). Cleared when the token is refunded.
    mapping(uint256 => bool) public isPaid;

    event FreeMinted(address indexed buyer, uint256 indexed agentId, uint256 tokenId);
    event PaidMinted(address indexed buyer, uint256 indexed agentId, uint256 qty, uint256 firstTokenId, uint256 cost);
    event Finalized(address indexed caller, uint256 amount);
    event Refunded(address indexed holder, uint256 indexed tokenId, uint256 amount);

    constructor(Config memory c) ERC721(c.name, c.symbol) {
        require(c.registry != address(0) && c.payee != address(0), "address");
        require(c.freePerAgent != 0 && c.freePerAgent <= 10, "free per agent");
        require(c.paidPerAgent != 0 && c.paidPerAgent <= 1_000, "paid per agent");
        require(c.freeSupply != 0 && c.paidCap != 0, "supply");
        require(c.floorPaid != 0 && c.floorPaid <= c.paidCap, "floor");
        require(c.floorWindow != 0, "floor window");
        REGISTRY = IAgentRegistry(c.registry);
        PAYEE = c.payee;
        PRICE = c.price;
        FREE_FEE = c.freeFee;
        FREE_SUPPLY = c.freeSupply;
        PAID_CAP = c.paidCap;
        FREE_PER_AGENT = c.freePerAgent;
        PAID_PER_AGENT = c.paidPerAgent;
        START = block.timestamp + c.startDelay;
        FREE_END = START + c.freeWindow;
        FLOOR_PAID = c.floorPaid;
        DEADLINE = START + c.floorWindow;
        BASE_URI = c.baseURI;
    }

    /// @dev BNB only ever flows through the mint functions; anything sent directly would have no way out.
    receive() external payable {
        revert("no direct BNB");
    }

    function owner() external pure returns (address) {
        return address(0);
    }

    /// @dev Agent ID check: handle non-empty and the handle's token owned by `a`.
    function agentOf(address a) public view returns (uint256 id, bool ok) {
        try REGISTRY.handleOf(a) returns (string memory handle) {
            if (bytes(handle).length == 0) return (0, false);
            id = uint256(keccak256(bytes(handle)));
            try REGISTRY.ownerOf(id) returns (address holder) {
                ok = holder == a;
            } catch {
                ok = false;
            }
        } catch {
            ok = false;
        }
        if (!ok) id = 0;
    }

    function freeOpen() public view returns (bool) {
        return block.timestamp >= START && block.timestamp < FREE_END && freeSold < FREE_SUPPLY;
    }

    function floorMet() public view returns (bool) {
        return paidSold >= FLOOR_PAID;
    }

    /// @notice True once the deadline passed without the floor being met and the sale was not
    ///         finalized: the sale failed and paid NFTs are refundable.
    function refundMode() public view returns (bool) {
        return !finalized && block.timestamp >= DEADLINE && !floorMet();
    }

    function paidOpen() public view returns (bool) {
        if (block.timestamp < START || freeOpen()) return false;
        if (paidSold >= PAID_CAP) return false;
        if (refundMode()) return false;
        // Before the deadline minting is open; after it, only while the floor is met / finalized.
        return block.timestamp < DEADLINE || floorMet();
    }

    /// @notice 0 = pending (before start), 1 = free phase, 2 = paid phase, 3 = sold out,
    ///         4 = failed (deadline passed without the floor; refunds open).
    function phase() public view returns (uint256) {
        if (block.timestamp < START) return 0;
        if (freeOpen()) return 1;
        if (refundMode()) return 4;
        if (paidSold < PAID_CAP) return 2;
        return 3;
    }

    function freeQuotaOf(address a) public view returns (uint256) {
        (uint256 id, bool ok) = agentOf(a);
        if (!ok) return 0;
        uint256 used = freeByAgent[id];
        uint256 byAgent = FREE_PER_AGENT > used ? FREE_PER_AGENT - used : 0;
        uint256 bySupply = FREE_SUPPLY - freeSold;
        return byAgent < bySupply ? byAgent : bySupply;
    }

    function quotaOf(address a) public view returns (uint256) {
        (uint256 id, bool ok) = agentOf(a);
        if (!ok) return 0;
        uint256 used = paidByAgent[id];
        return PAID_PER_AGENT > used ? PAID_PER_AGENT - used : 0;
    }

    /// @notice BNB currently escrowed in this contract (paid mint payments not yet released
    ///         to PAYEE and not yet refunded). Free fees never rest here.
    function escrowed() public view returns (uint256) {
        return address(this).balance;
    }

    function status()
        external
        view
        returns (
            uint256 phase_,
            uint256 freeSold_,
            uint256 paidSold_,
            uint256 minted_,
            uint256 price_,
            uint256 freeFee_,
            uint256 start_,
            uint256 freeEnd_,
            uint256 freeRemaining_,
            uint256 paidRemaining_,
            uint256 floorPaid_,
            uint256 deadline_,
            uint256 escrowed_,
            uint256 finalized_,
            uint256 refundMode_
        )
    {
        return (
            phase(),
            freeSold,
            paidSold,
            minted,
            PRICE,
            FREE_FEE,
            START,
            FREE_END,
            FREE_SUPPLY - freeSold,
            PAID_CAP - paidSold,
            FLOOR_PAID,
            DEADLINE,
            escrowed(),
            finalized ? 1 : 0,
            refundMode() ? 1 : 0
        );
    }

    /// @notice Claim the free NFT for your Agent ID, paying only the fixed service fee (to PAYEE).
    function mintFree() external payable nonReentrant returns (uint256 id) {
        (uint256 agentId, bool ok) = agentOf(msg.sender);
        require(ok, "Agent ID required");
        require(freeOpen(), "free closed");
        require(msg.value == FREE_FEE, "fee");
        require(freeByAgent[agentId] < FREE_PER_AGENT, "free quota");
        freeByAgent[agentId]++;
        freeSold++;
        id = ++minted;
        _mint(msg.sender, id);
        (bool sent,) = PAYEE.call{value: msg.value}("");
        require(sent, "payee send");
        emit FreeMinted(msg.sender, agentId, id);
    }

    /// @notice Mint `qty` NFTs at PRICE each. Until finalization the payment is escrowed in this
    ///         contract; after finalization it is forwarded to PAYEE in the same transaction.
    function mint(uint256 qty) external payable nonReentrant returns (uint256 firstId) {
        (uint256 agentId, bool ok) = agentOf(msg.sender);
        require(ok, "Agent ID required");
        require(paidOpen(), "paid closed");
        require(qty != 0, "qty");
        require(paidByAgent[agentId] + qty <= PAID_PER_AGENT, "paid quota");
        require(paidSold + qty <= PAID_CAP, "sold out");
        require(msg.value == PRICE * qty, "value");
        paidByAgent[agentId] += qty;
        paidSold += qty;
        firstId = minted + 1;
        for (uint256 i = 0; i < qty; i++) {
            uint256 id = ++minted;
            isPaid[id] = true;
            _mint(msg.sender, id);
        }
        if (finalized) {
            (bool sent,) = PAYEE.call{value: msg.value}("");
            require(sent, "payee send");
        }
        emit PaidMinted(msg.sender, agentId, qty, firstId, msg.value);
    }

    /// @notice Release the full escrow to PAYEE once the floor is met. Permissionless.
    function finalize() external nonReentrant {
        require(!finalized, "finalized");
        require(floorMet(), "floor not met");
        finalized = true;
        uint256 amount = address(this).balance;
        if (amount != 0) {
            (bool sent,) = PAYEE.call{value: amount}("");
            require(sent, "payee send");
        }
        emit Finalized(msg.sender, amount);
    }

    /// @notice Burn one paid NFT and reclaim its mint price. Only in refund mode (the deadline
    ///         passed without the floor being met). One call per token id.
    function refundPaid(uint256 tokenId) external nonReentrant {
        require(refundMode(), "no refunds");
        require(isPaid[tokenId], "not paid");
        require(ownerOf(tokenId) == msg.sender, "not owner");
        isPaid[tokenId] = false;
        _burn(tokenId);
        (bool sent,) = msg.sender.call{value: PRICE}("");
        require(sent, "refund send");
        emit Refunded(msg.sender, tokenId, PRICE);
    }

    /// @dev Paid NFTs are locked (non-transferable) until the sale is finalized — trading opens
    ///      only once the floor is met and the escrow released. Minting and refund burns are
    ///      always allowed; free NFTs are never locked.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0) && isPaid[tokenId] && !finalized) {
            revert("paid NFT locked until trade opens");
        }
        return super._update(to, tokenId, auth);
    }

    function _baseURI() internal view override returns (string memory) {
        return BASE_URI;
    }
}
