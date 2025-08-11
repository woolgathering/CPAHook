"""
Clock-Proxy Auction Simulation for UniV4 Hook System

This simulation aligns with the main logic flow document and implements:
- Commit-reveal unlinkability 
- Proxy registration with stakes
- Bidder-proxy mapping
- Basic clock phase mechanics
"""

from auction_core import ClockProxyAuction
from pool_core import Pool
import secrets


def test_clock_phase():
    """Test the complete clock phase with 2 rounds including registration, bidding, price updates, and dropouts."""
    print("=== CLOCK PHASE TEST ===\n")
    
    # Create 3 pools with initial price=1
    pools = [
        Pool("pool_1", "token_A", "USDC", 1000, 1.0),
        Pool("pool_2", "token_B", "USDC", 1000, 1.0),
        Pool("pool_3", "token_C", "USDC", 1000, 1.0)
    ]
    
    # Initialize auction
    auction = ClockProxyAuction(pools, min_spending_ratio=0.5)
    print(f"Initial auction prices: {auction.prices}")
    
    # Private information (stored as variables)
    bidder_a = "bidder_A"
    bidder_b = "bidder_B"
    bidder_c = "bidder_C"
    proxy_1 = "proxy_1"
    proxy_2 = "proxy_2"
    
    # Generate salts and commit hashes
    salt_a1, salt_b1 = secrets.token_hex(16), secrets.token_hex(16)
    salt_a2, salt_b2 = secrets.token_hex(16), secrets.token_hex(16)
    salt_a3, salt_b3 = secrets.token_hex(16), secrets.token_hex(16)
    
    commit_hash_1 = auction.generate_commit_hash(bidder_a, proxy_1, salt_a1, salt_b1)
    commit_hash_2 = auction.generate_commit_hash(bidder_b, proxy_2, salt_a2, salt_b2)
    commit_hash_3 = auction.generate_commit_hash(bidder_c, proxy_1, salt_a3, salt_b3)
    
    print("Generated commit hashes:")
    print(f"  {bidder_a} -> {proxy_1}: {commit_hash_1[:16]}...")
    print(f"  {bidder_b} -> {proxy_2}: {commit_hash_2[:16]}...")
    print(f"  {bidder_c} -> {proxy_1}: {commit_hash_3[:16]}...")
    
    # Start clock phase
    print(f"\n--- STARTING CLOCK PHASE ---")
    auction.start_clock_phase()
    
    # ROUND 1
    print(f"\n--- ROUND 1 ---")
    
    # Open clock
    auction.open_clock()
    
    # Register some bidders and proxies during clock phase
    print(f"\nRegistration during clock phase:")
    auction.register_bidder(bidder_a)
    auction.register_bidder(bidder_b)
    auction.register_bidder(bidder_c)
    auction.register_commit(commit_hash_1, proxy_1) # proxy_1 is the proxy for bidder_a
    auction.register_commit(commit_hash_2, proxy_2) # proxy_2 is the proxy for bidder_b
    auction.register_commit(commit_hash_3, proxy_1) # proxy_1 is the proxy for bidder_c
    print(f"  Registered bidders: {list(auction.active_bidders)}")
    print(f"  Registered commits: {len(auction.commit_proxy)}")
    
    # Set up bidder stakes and bidPoints
    auction.bidder_stake[bidder_a] = 1000
    auction.bidder_bid_points[bidder_a] = 1000
    auction.bidder_stake[bidder_b] = 800
    auction.bidder_bid_points[bidder_b] = 800
    
    # Bidders submit bids
    print(f"\nBidding in round 1:")
    print(f"  Before bidding - {bidder_a}: stake={auction.bidder_stake[bidder_a]}, bidPoints={auction.bidder_bid_points[bidder_a]}")
    print(f"  Before bidding - {bidder_b}: stake={auction.bidder_stake[bidder_b]}, bidPoints={auction.bidder_bid_points[bidder_b]}")
    
    bid1 = auction.bid({"pool_1", "pool_2"}, bidder_a, commit_hash_1, 300)
    bid2 = auction.bid({"pool_2", "pool_3"}, bidder_b, commit_hash_2, 250)
    
    print(f"  {bidder_a} bid: {'SUCCESS' if bid1 else 'FAILED'}")
    print(f"  {bidder_b} bid: {'SUCCESS' if bid2 else 'FAILED'}")
    
    print(f"  After bidding - {bidder_a}: stake={auction.bidder_stake[bidder_a]}, bidPoints={auction.bidder_bid_points[bidder_a]}")
    print(f"  After bidding - {bidder_b}: stake={auction.bidder_stake[bidder_b]}, bidPoints={auction.bidder_bid_points[bidder_b]}")
    
    # Close clock and process round
    print(f"\nClosing round 1:")
    round1_result = auction.close_clock()
    print(f"  Round result: {round1_result}")
    
    # Update prices based on excess demand
    print(f"\nUpdating prices based on excess demand:")
    if "pool_2" in round1_result["excess_demand"]:
        auction.set_pool_price("pool_2", 1.5)  # Increase price for pool_2
        print(f"  Updated pool_2 price to 1.5")
    print(f"  Current prices: {auction.prices}")
    
    # ROUND 2
    print(f"\n--- ROUND 2 ---")
    
    # Open clock for round 2
    auction.open_clock()
    
    # Register another bidder during round 2
    print(f"\nRegistration during round 2:")
    auction.register_bidder(bidder_c)
    auction.register_commit(commit_hash_3, proxy_1)
    auction.bidder_stake[bidder_c] = 600
    auction.bidder_bid_points[bidder_c] = 600
    print(f"  Registered bidders: {list(auction.active_bidders)}")
    print(f"  Registered commits: {len(auction.commit_proxy)}")
    
    # Bidders submit bids (some may adjust based on new prices)
    print(f"\nBidding in round 2:")
    print(f"  Before bidding - {bidder_a}: stake={auction.bidder_stake[bidder_a]}, bidPoints={auction.bidder_bid_points[bidder_a]}")
    print(f"  Before bidding - {bidder_b}: stake={auction.bidder_stake[bidder_b]}, bidPoints={auction.bidder_bid_points[bidder_b]}")
    print(f"  Before bidding - {bidder_c}: stake={auction.bidder_stake[bidder_c]}, bidPoints={auction.bidder_bid_points[bidder_c]}")
    
    bid3 = auction.bid({"pool_1"}, bidder_a, commit_hash_1, 200)  # Reduced demand
    bid4 = auction.bid({"pool_3"}, bidder_b, commit_hash_2, 150)  # Different demand
    bid5 = auction.bid({"pool_2"}, bidder_c, commit_hash_3, 100)  # New bidder
    
    print(f"  {bidder_a} bid: {'SUCCESS' if bid3 else 'FAILED'}")
    print(f"  {bidder_b} bid: {'SUCCESS' if bid4 else 'FAILED'}")
    print(f"  {bidder_c} bid: {'SUCCESS' if bid5 else 'FAILED'}")
    
    print(f"  After bidding - {bidder_a}: stake={auction.bidder_stake[bidder_a]}, bidPoints={auction.bidder_bid_points[bidder_a]}")
    print(f"  After bidding - {bidder_b}: stake={auction.bidder_stake[bidder_b]}, bidPoints={auction.bidder_bid_points[bidder_b]}")
    print(f"  After bidding - {bidder_c}: stake={auction.bidder_stake[bidder_c]}, bidPoints={auction.bidder_bid_points[bidder_c]}")
    
    # Close clock and process round
    print(f"\nClosing round 2:")
    round2_result = auction.close_clock()
    print(f"  Round result: {round2_result}")
    
    # Update prices based on excess demand
    print(f"\nUpdating prices based on excess demand:")
    if "pool_2" in round2_result["excess_demand"]:
        auction.set_pool_price("pool_2", 2.0)  # Further increase price for pool_2
        print(f"  Updated pool_2 price to 2.0")
    print(f"  Final prices: {auction.prices}")
    
    # End clock phase
    print(f"\n--- ENDING CLOCK PHASE ---")
    auction.end_clock_phase()
    
    # Test that registration is now closed
    print(f"\nTesting registration closure:")
    test_commit = auction.generate_commit_hash("test_bidder", "test_proxy", "salt1", "salt2")
    reg_test = auction.register_commit(test_commit, "test_proxy")
    bidder_test = auction.register_bidder("test_bidder")
    print(f"  Commit registration after clock phase: {'FAILED' if not reg_test else 'SUCCESS'}")
    print(f"  Bidder registration after clock phase: {'FAILED' if not bidder_test else 'SUCCESS'}")
    
    # Final summary
    print(f"\n=== CLOCK PHASE SUMMARY ===")
    print(f"Total rounds: {auction.current_round}")
    print(f"Total bids: {len(auction.bids)}")
    print(f"Active bidders: {list(auction.active_bidders)}")
    print(f"Dropped bidders: {list(auction.dropped_bidders)}")
    print(f"Final prices: {auction.prices}")
    print(f"Current phase: {auction.current_phase}")
    
    return auction


def test_setup_phase():
    """Test the setup phase with 3 pools at price=1."""
    print("=== SETUP PHASE TEST ===\n")
    
    # Create 3 pools with price=1
    pools = [
        Pool("pool_1", "token_A", "USDC", 1000, 1.0),
        Pool("pool_2", "token_B", "USDC", 1000, 1.0),
        Pool("pool_3", "token_C", "USDC", 1000, 1.0)
    ]
    
    print("Created 3 pools:")
    for pool in pools:
        print(f"  {pool.pool_id}: {pool.token_x} -> {pool.token_y} at price {pool.current_price}")
    
    # Initialize auction
    auction = ClockProxyAuction(pools, min_spending_ratio=0.5)
    print(f"\nAuction initialized with min_spending_ratio: {auction.min_spending_ratio}")
    print(f"Initial auction prices: {auction.prices}")
    
    # Test pool price updates
    print(f"\nTesting pool price updates:")
    auction.set_pool_price("pool_1", 1.5)
    print(f"Updated pool_1 price to 1.5: {auction.prices['pool_1']}")
    
    auction.set_pool_price("pool_2", 2.0)
    print(f"Updated pool_2 price to 2.0: {auction.prices['pool_2']}")
    
    print(f"Final auction prices: {auction.prices}")
    
    # Print all configuration and auction parameters
    print(f"\n=== AUCTION CONFIGURATION ===")
    print(f"Min spending ratio: {auction.min_spending_ratio}")
    print(f"Max rounds: {auction.max_rounds}")
    print(f"Clock open: {auction.clock_open}")
    print(f"Current round: {auction.current_round}")
    
    print(f"\n=== POOL CONFIGURATION ===")
    for pool in auction.pools:
        print(f"Pool {pool.pool_id}:")
        print(f"  Token X: {pool.token_x}")
        print(f"  Token Y: {pool.token_y}")
        print(f"  Deposit amount: {pool.deposit_amount}")
        print(f"  Current price: {pool.current_price}")
    
    print(f"\n=== AUCTION STATE ===")
    print(f"Total pools: {len(auction.pools)}")
    print(f"Total prices tracked: {len(auction.prices)}")
    print(f"Total bids: {len(auction.bids)}")
    print(f"Total bundles: {len(auction.bundles)}")
    print(f"Total allocations: {len(auction.allocations)}")
    print(f"Total revealed mappings: {len(auction.revealed_mappings)}")
    print(f"Active bidders: {len(auction.active_bidders)}")
    print(f"Dropped bidders: {len(auction.dropped_bidders)}")
    print(f"Registered commits: {len(auction.commit_proxy)}")
    print(f"Bidder stakes: {len(auction.bidder_stake)}")
    print(f"Bidder bidPoints: {len(auction.bidder_bid_points)}")
    
    return auction


def test_core_functions():
    """Test all the core auction functions."""
    # Create some test pools
    pools = [
        Pool("pool_1", "token_A", "USDC", 1000, 1.0),
        Pool("pool_2", "token_B", "USDC", 500, 2.0),
        Pool("pool_3", "token_C", "USDC", 750, 1.5)
    ]
    
    auction = ClockProxyAuction(pools, min_spending_ratio=0.5)
    
    print("=== CLOCK-PROXY AUCTION SIMULATION ===\n")
    
    # Test commit generation and registration
    print("1. COMMIT PHASE")
    bidder_id = "bidder_A"
    proxy_address = "proxy_1"
    salt_a = secrets.token_hex(16)
    salt_b = secrets.token_hex(16)
    
    commit_hash = auction.generate_commit_hash(bidder_id, proxy_address, salt_a, salt_b)
    print(f"Generated commit hash: {commit_hash[:16]}...")
    
    success = auction.register_commit(commit_hash, proxy_address)
    print(f"Commit registration: {'SUCCESS' if success else 'FAILED'}")
    print(f"Registered proxy: {auction.commit_proxy[commit_hash]}")
    
    # Test bidding
    print("\n2. BIDDING PHASE")
    # Set up bidder stake and bidPoints
    auction.bidder_stake[bidder_id] = 1000
    auction.bidder_bid_points[bidder_id] = 500
    print(f"Bidder stake: {auction.bidder_stake[bidder_id]}")
    print(f"Bidder bidPoints: {auction.bidder_bid_points[bidder_id]}")
    
    # Register bidder and open clock
    auction.register_bidder(bidder_id)
    auction.open_clock()
    
    demands = {"pool_1", "pool_2"}
    bid_success = auction.bid(demands, bidder_id, commit_hash, 50)
    print(f"Bid submission: {'SUCCESS' if bid_success else 'FAILED'}")
    print(f"Bidder bidPoints (unchanged): {auction.bidder_bid_points[bidder_id]}")
    print(f"Total bids recorded: {len(auction.bids)}")
    
    # Test multiple bids to show bidPoints don't get consumed
    print(f"\nSecond bid with same bidPoints:")
    bid_success2 = auction.bid({"pool_3"}, bidder_id, commit_hash, 30)
    print(f"Second bid submission: {'SUCCESS' if bid_success2 else 'FAILED'}")
    print(f"Bidder bidPoints (still unchanged): {auction.bidder_bid_points[bidder_id]}")
    print(f"Total bids recorded: {len(auction.bids)}")
    
    # Test dropout functionality
    print(f"\nTesting dropout:")
    dropout_success = auction.dropout(bidder_id)
    print(f"Dropout: {'SUCCESS' if dropout_success else 'FAILED'}")
    print(f"Bidder still has stake: {bidder_id in auction.bidder_stake}")
    print(f"Bidder still has bidPoints: {bidder_id in auction.bidder_bid_points}")
    
    # Test clock phase functionality
    print(f"\n8. CLOCK PHASE TEST")
    # Re-add bidder for this test
    auction.bidder_stake[bidder_id] = 1000
    auction.bidder_bid_points[bidder_id] = 500
    auction.register_bidder(bidder_id)
    
    # Open clock
    auction.open_clock()
    
    # Make some bids
    auction.bid({"pool_1"}, bidder_id, commit_hash, 100)
    auction.bid({"pool_2"}, bidder_id, commit_hash, 150)
    
    # Try to bid when clock is closed (should fail)
    auction.close_clock()
    failed_bid = auction.bid({"pool_3"}, bidder_id, commit_hash, 200)
    print(f"Bid when clock closed: {'FAILED' if not failed_bid else 'SUCCESS'}")
    
    # Open clock again and bid
    auction.open_clock()
    successful_bid = auction.bid({"pool_3"}, bidder_id, commit_hash, 200)
    print(f"Bid when clock opened: {'SUCCESS' if successful_bid else 'FAILED'}")
    
    # Test minimum spending requirement
    print(f"\n7. MINIMUM SPENDING TEST")
    # Re-add bidder for this test
    auction.bidder_stake[bidder_id] = 1000
    auction.bidder_bid_points[bidder_id] = 500
    
    # Make some bids
    auction.bid({"pool_1"}, bidder_id, commit_hash, 100)
    auction.bid({"pool_2"}, bidder_id, commit_hash, 150)
    auction.bid({"pool_3"}, bidder_id, commit_hash, 200)
    
    total_bid_value = auction.get_bidder_total_bid_value(bidder_id)
    print(f"Total bid value: {total_bid_value}")
    
    # Test insufficient spending
    print(f"\nTesting insufficient spending:")
    insufficient_spending = auction.enforce_minimum_spending(bidder_id, 100)
    print(f"Sufficient spending: {'NO' if not insufficient_spending else 'YES'}")
    
    # Test sufficient spending
    print(f"\nTesting sufficient spending:")
    sufficient_spending = auction.enforce_minimum_spending(bidder_id, 250)
    print(f"Sufficient spending: {'YES' if sufficient_spending else 'NO'}")
    
    # Test bundle submission
    print("\n3. BUNDLE SUBMISSION PHASE")
    bundle_data = {"pools": ["pool_1", "pool_2"], "strategy": "arbitrage"}
    bundle_success = auction.submit_bundle(commit_hash, bundle_data)
    print(f"Bundle submission: {'SUCCESS' if bundle_success else 'FAILED'}")
    print(f"Bundle data: {auction.bundles[commit_hash]}")
    
    # Test allocation submission
    print("\n4. ALLOCATION PHASE")
    allocation_data = [("bidder_A", {"pool_1", "pool_2"}), ("bidder_B", {"pool_3"})]
    alloc_success = auction.submit_allocation("allocator_1", allocation_data)
    print(f"Allocation submission: {'SUCCESS' if alloc_success else 'FAILED'}")
    print(f"Allocation proposals: {len(auction.allocations)}")
    print(f"First allocation: {auction.allocations[0]}")
    
    # Test reveal
    print("\n5. REVEAL PHASE")
    reveal_success = auction.reveal(bidder_id, salt_a, proxy_address, salt_b)
    print(f"Reveal: {'SUCCESS' if reveal_success else 'FAILED'}")
    print(f"Revealed mappings: {auction.revealed_mappings}")
    
    # Test reveal with minimum spending violation
    print(f"\nTesting reveal with spending violation:")
    # Re-add bidder and make some bids
    auction.bidder_stake[bidder_id] = 1000
    auction.bidder_bid_points[bidder_id] = 500
    auction.bid({"pool_1"}, bidder_id, commit_hash, 200)
    auction.bid({"pool_2"}, bidder_id, commit_hash, 300)
    
    # Try to reveal with insufficient spending
    reveal_with_violation = auction.reveal(bidder_id, salt_a, proxy_address, salt_b, final_purchase_amount=100)
    print(f"Reveal with spending violation: {'FAILED' if not reveal_with_violation else 'SUCCESS'}")
    
    # Test invalid operations
    print("\n6. INVALID OPERATIONS TEST")
    invalid_bid = auction.bid({"pool_1"}, "bidder_B", "invalid_hash", 50)
    print(f"Invalid bid (wrong commit): {'REJECTED' if not invalid_bid else 'ACCEPTED'}")
    
    invalid_reveal = auction.reveal("wrong_bidder", salt_a, proxy_address, salt_b)
    print(f"Invalid reveal (wrong bidder): {'REJECTED' if not invalid_reveal else 'ACCEPTED'}")
    
    print("\n=== SIMULATION COMPLETE ===")
    
    return auction


def main():
    """Main function to run tests."""
    print("Running setup phase test...\n")
    test_setup_phase()
    
    print("\n" + "="*50 + "\n")
    
    print("Running clock phase test...\n")
    test_clock_phase()
    
    print("\n" + "="*50 + "\n")
    
    print("Running core functions test...\n")
    # test_core_functions()


if __name__ == "__main__":
    main()
