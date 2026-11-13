# JAGENT — Contracts

Agent ID NFT sale + non-custodial market on BNB Smart Chain (chainId 56). Phase 1 is NFT only; the JAGENT token (Phase 2) will be distributed later by snapshot of NFT holders.

- Website: https://jagent.pages.dev
- NFT (JagentNFT, ERC-721 + sale): deployed via CREATE2 (Arachnid proxy, salt 0) — final address is computed by the deploy build (startDelay targets the sale start below) and published here after deployment.
- Market (JagentMarket, non-custodial, 2.5% fee): deployed right after the NFT contract the same way.
- Agent ID registry: `0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F`
- Payee (free fees, finalized escrow, market fees): `0xB5d7aec297705337F3e09Ec4F802a580EFfEa0D3`

## Sale (starts 15 Nov 2026, 00:00 Beijing time)

- FREE phase: first 500 Agent IDs, 1 NFT each, 0.0001 BNB service fee (forwarded to the payee immediately, never refundable). Lasts 24 hours or until sold out.
- PAID phase: 0.003 BNB per NFT, max 10 per Agent ID, cap 15,000 — organized as 15 batches of 1,000 mints by mint order.
- ESCROW + REFUND GUARANTEE: paid mint payments are held in the NFT contract, not forwarded. If at least 4,000 paid NFTs (4 batches) are sold before the deadline (17 Nov 2026, 00:00 Beijing time), anyone can call `finalize()`: the escrow is released to the payee, paid NFTs unlock (open trade), and minting continues to the cap with payments forwarded immediately. If the deadline passes below the floor, minting stops forever and every paid NFT holder can call `refundPaid(tokenId)` to burn that NFT and reclaim exactly 0.003 BNB.
- Paid NFTs are non-transferable until finalization. No owner, no pause, no upgrade, no admin withdrawal: escrowed funds can only go to the payee (finalize) or back to paid holders (refund).

## Phase 2 token entitlement (snapshot, planned)

- Free-minted NFT: 15,000,000 JAGENT each (500 x 15M = 7,500,000,000).
- Paid-minted NFT, by batch: batch 1 = 50,000,000 JAGENT each, decreasing by 5% of the batch-1 amount (2,500,000) per batch — batch 2 = 47,500,000, batch 3 = 45,000,000, …, batch 15 = 15,000,000. Paid total 487,500,000,000.
- Total supply 1,000,000,000,000 fixed; the remainder (505,000,000,000) goes to the liquidity pool. No burn.

## Build

Solidity 0.8.28, viaIR, optimizer 200 runs. OpenZeppelin contracts (ERC721, ReentrancyGuard). Both contracts are deployed via the Arachnid CREATE2 proxy (salt 0) and verified on Sourcify (exact match).
