// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/**
 * @title CommitReveal
 * @notice Commit-reveal system for maintaining bidder-proxy privacy
 * @author Clock-Proxy Auction Team
 */
library CommitReveal {
	/// @notice Error when commit hash validation fails
	error InvalidCommitHash();
	error InvalidReveal();
	error RevealAlreadyProcessed();

	/**
	 * @notice Generate commit hash using two-salt unlinkability system
	 * @param bidderId The bidder's address
	 * @param proxyAddress The proxy's address
	 * @param saltA First salt (known only to bidder)
	 * @param saltB Second salt (shared between bidder and proxy)
	 * @return commitHash The generated commit hash
	 */
	function generateCommitHash(
		address bidderId,
		address proxyAddress,
		bytes32 saltA,
		bytes32 saltB
	) internal pure returns (bytes32 commitHash) {
		// Inner hash 1: bidder + saltA
		// forge-lint: disable-next-line(asm-keccak256)
		bytes32 innerHash1 = keccak256(abi.encode(bidderId, saltA));

		// Inner hash 2: proxy + saltB
		// forge-lint: disable-next-line(asm-keccak256)
		bytes32 innerHash2 = keccak256(abi.encode(proxyAddress, saltB));

		// Outer hash: innerHash1 + innerHash2
		// forge-lint: disable-next-line(asm-keccak256)
		commitHash = keccak256(abi.encode(innerHash1, innerHash2));
	}

	/**
	 * @notice Validate a reveal by reconstructing the commit hash
	 * @param bidderId The bidder's address
	 * @param proxyAddress The proxy's address
	 * @param saltA First salt
	 * @param saltB Second salt
	 * @param expectedCommitHash The expected commit hash
	 * @return isValid True if the reveal is valid
	 */
	function validateReveal(
		address bidderId,
		address proxyAddress,
		bytes32 saltA,
		bytes32 saltB,
		bytes32 expectedCommitHash
	) internal pure returns (bool isValid) {
		bytes32 reconstructedHash = generateCommitHash(
			bidderId,
			proxyAddress,
			saltA,
			saltB
		);
		
		return reconstructedHash == expectedCommitHash;
	}

	/**
	 * @notice Extract bidder address from reveal (for validation)
	 * @param bidderId The bidder's address
	 * @param saltA First salt
	 * @return bidderHash The hash of bidder + saltA
	 */
	function getBidderHash(
		address bidderId,
		bytes32 saltA
	) internal pure returns (bytes32 bidderHash) {
		// forge-lint: disable-next-line(asm-keccak256)
		return keccak256(abi.encode(bidderId, saltA));
	}

	/**
	 * @notice Extract proxy address from reveal (for validation)
	 * @param proxyAddress The proxy's address
	 * @param saltB Second salt
	 * @return proxyHash The hash of proxy + saltB
	 */
	function getProxyHash(
		address proxyAddress,
		bytes32 saltB
	) internal pure returns (bytes32 proxyHash) {
		// forge-lint: disable-next-line(asm-keccak256)
		return keccak256(abi.encode(proxyAddress, saltB));
	}

	/**
	 * @notice Validate that a commit hash has the correct format
	 * @param commitHash The commit hash to validate
	 * @return isValid True if the commit hash format is valid
	 */
	function isValidCommitHash(
		bytes32 commitHash
	) internal pure returns (bool isValid) {
		// Basic validation: commit hash should not be zero
		return commitHash != bytes32(0);
	}

	/**
	 * @notice Generate a random salt for commit-reveal system
	 * @param seed Additional entropy for salt generation
	 * @return salt A random salt
	 */
	function generateSalt(
		bytes32 seed
	) internal view returns (bytes32 salt) {
		// forge-lint: disable-next-line(asm-keccak256)
		return keccak256(abi.encodePacked(
			block.timestamp,
			block.prevrandao,
			seed,
			msg.sender
		));
	}
}
