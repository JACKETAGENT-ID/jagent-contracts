// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Binance Agent ID registry (BSC 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F).
interface IAgentRegistry {
    function handleOf(address owner) external view returns (string memory);
    function ownerOf(uint256 tokenId) external view returns (address);
}
