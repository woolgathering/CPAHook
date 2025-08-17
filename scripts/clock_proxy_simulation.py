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
import random

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
    
    print(f"  Generated salts:")
    print(f"    Salts for {bidder_a}: {salt_a1}, {salt_b1}")
    print(f"    Salts for {bidder_b}: {salt_a2}, {salt_b2}")
    print(f"    Salts for {bidder_c}: {salt_a3}, {salt_b3}")
    
    # Register all bidders and proxies during clock phase (before bidding)
    print(f"\nRegistration during clock phase:")
    auction.register_bidder(bidder_a)
    auction.register_bidder(bidder_b)
    auction.register_bidder(bidder_c)  # Register bidder_c in round 1
    auction.register_commit(commit_hash_1, proxy_1) # proxy_1 is the proxy for bidder_a
    auction.register_commit(commit_hash_2, proxy_2) # proxy_2 is the proxy for bidder_b
    auction.register_commit(commit_hash_3, proxy_1) # proxy_1 is the proxy for bidder_c
    print(f"  Registered bidders: {list(auction.active_bidders)}")
    print(f"  Registered commits: {len(auction.commit_proxy)}")
    
    def compute_min_stake(bids) -> int:
        """
        Compute the minimum stake required to bid on the given bids.
        """
        return sum(auction.prices[item] * demand for item, demand in bids.items())
    
    bidder_a_bids = {"pool_1": 1000, "pool_2": 1000}
    bidder_b_bids = {"pool_2": 1000, "pool_3": 2000}
    bidder_c_bids = {"pool_1": 1000, "pool_2": 1000}
    
    print(f"\n--- STARTING CLOCK PHASE ---")
    auction.start_clock_phase()
    end_clock_phase = False
    while not end_clock_phase:
        # Open clock
        auction.open_clock_round()
        # Bidders submit bids
        print(f"\nBidding in round {auction.current_round}:")
        
        bidder_a_stake = max(0, compute_min_stake(bidder_a_bids) - auction.bidder_stake[bidder_a]) # stake must be at least the minimum stake
        bidder_b_stake = max(0, compute_min_stake(bidder_b_bids) - auction.bidder_stake[bidder_b])
        bidder_c_stake = max(0, compute_min_stake(bidder_c_bids) - auction.bidder_stake[bidder_c])
        
        print(f"  Bidding {bidder_a} with {bidder_a_bids} and stake {bidder_a_stake + auction.bidder_stake[bidder_a]}")
        print(f"  Bidding {bidder_b} with {bidder_b_bids} and stake {bidder_b_stake + auction.bidder_stake[bidder_b]}")
        print(f"  Bidding {bidder_c} with {bidder_c_bids} and stake {bidder_c_stake + auction.bidder_stake[bidder_c]}")
        
        bid1 = auction.bid(bidder_a_bids, bidder_a, commit_hash_1, bidder_a_stake)
        bid2 = auction.bid(bidder_b_bids, bidder_b, commit_hash_2, bidder_b_stake)
        bid3 = auction.bid(bidder_c_bids, bidder_c, commit_hash_3, bidder_c_stake)  # bidder_c bids in round 1
        
        print(f"\nClosing round {auction.current_round}:")
        round1_result, end_clock_phase = auction.end_clock_round() # price updates happen here automatically
        print(f"  Round result: {round1_result}")
        print(f"  Updated prices: {auction.prices}")
        print(f"  End clock phase: {end_clock_phase}")
        
        # if the clock phase is not over, we need to reduce the bids of the bidders
        # we reduce all demands but in practice, this needn't be the case. A bidder might want to keep the same demand of an item that does not change price.
        if not end_clock_phase:
            bidder_a_bids = {"pool_1": max(0, bidder_a_bids["pool_1"] - random.randint(1, 100)), "pool_2": max(0, bidder_a_bids["pool_2"] - random.randint(1, 100))}
            bidder_b_bids = {"pool_2": max(0, bidder_b_bids["pool_2"] - random.randint(1, 100)), "pool_3": max(0, bidder_b_bids["pool_3"] - random.randint(1, 100))}
            bidder_c_bids = {"pool_1": max(0, bidder_c_bids["pool_1"] - random.randint(1, 100)), "pool_2": max(0, bidder_c_bids["pool_2"] - random.randint(1, 100))}
    
    
    # End clock phase
    print(f"\n--- ENDING CLOCK PHASE ---")
    auction.end_clock_phase()
    print(f"  Final prices: {auction.prices}")
    
    # Test that registration is now closed
    print(f"\nTesting registration closure:")
    test_commit = auction.generate_commit_hash("test_bidder", "test_proxy", "salt1", "salt2")
    reg_test = auction.register_commit(test_commit, "test_proxy")
    bidder_test = auction.register_bidder("test_bidder")
    print(f"  (SHOULD FAIL) Commit registration after clock phase: {'FAILED' if not reg_test else 'SUCCESS'}")
    print(f"  (SHOULD FAIL) Bidder registration after clock phase: {'FAILED' if not bidder_test else 'SUCCESS'}")
    
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
    for pool in auction.pools.values():
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
    print(f"Bidder stake: {auction.bidder_stake[bidder_id]}")
    print(f"Bidder bidPoints: {auction.get_bid_points(bidder_id)}")
    
    # Register bidder and open clock
    auction.register_bidder(bidder_id)
    auction.open_clock_round()
    
    demands = {"pool_1", "pool_2"}
    bid_success = auction.bid(demands, bidder_id, commit_hash, 50)
    print(f"Bid submission: {'SUCCESS' if bid_success else 'FAILED'}")
    print(f"Bidder bidPoints (unchanged): {auction.get_bid_points(bidder_id)}")
    print(f"Total bids recorded: {len(auction.bids)}")
    
    # Test multiple bids to show bidPoints don't get consumed
    print(f"\nSecond bid with same bidPoints:")
    bid_success2 = auction.bid({"pool_3"}, bidder_id, commit_hash, 30)
    print(f"Second bid submission: {'SUCCESS' if bid_success2 else 'FAILED'}")
    print(f"Bidder bidPoints (still unchanged): {auction.get_bid_points(bidder_id)}")
    print(f"Total bids recorded: {len(auction.bids)}")
    
    # Test dropout functionality
    print(f"\nTesting dropout:")
    dropout_success = auction.dropout(bidder_id)
    print(f"Dropout: {'SUCCESS' if dropout_success else 'FAILED'}")
    print(f"Bidder still has stake: {bidder_id in auction.bidder_stake}")
    print(f"Bidder still has bidPoints: {bidder_id in auction.bidder_stake}")
    
    # Test clock phase functionality
    print(f"\n8. CLOCK PHASE TEST")
    # Re-add bidder for this test
    auction.bidder_stake[bidder_id] = 1000
    
    # Open clock
    auction.open_clock_round()
    
    # Make some bids
    auction.bid({"pool_1"}, bidder_id, commit_hash, 100)
    auction.bid({"pool_2"}, bidder_id, commit_hash, 150)
    
    # Try to bid when clock is closed (should fail)
    auction.end_clock_round()
    failed_bid = auction.bid({"pool_3"}, bidder_id, commit_hash, 200)
    print(f"Bid when clock closed: {'FAILED' if not failed_bid else 'SUCCESS'}")
    
    # Open clock again and bid
    auction.open_clock_round()
    successful_bid = auction.bid({"pool_3"}, bidder_id, commit_hash, 200)
    print(f"Bid when clock opened: {'SUCCESS' if successful_bid else 'FAILED'}")
    
    # Test minimum spending requirement
    print(f"\n7. MINIMUM SPENDING TEST")
    # Re-add bidder for this test
    auction.bidder_stake[bidder_id] = 1000
    
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


def test_clock_phase_flow():
    """Test the complete clock phase flow to identify issues."""
    print("=== CLOCK PHASE FLOW TEST ===\n")
    
    # Create pools
    pools = [
        Pool("pool_1", "token_A", "USDC", 1000, 1.0),
        Pool("pool_2", "token_B", "USDC", 1000, 1.0),
    ]
    
    # Initialize auction
    auction = ClockProxyAuction(pools, min_spending_ratio=0.5)
    
    # Setup bidders
    bidder_a = "bidder_A"
    bidder_b = "bidder_B"
    proxy_1 = "proxy_1"
    proxy_2 = "proxy_2"
    
    # Generate commit hashes
    salt_a1, salt_b1 = secrets.token_hex(16), secrets.token_hex(16)
    salt_a2, salt_b2 = secrets.token_hex(16), secrets.token_hex(16)
    commit_hash_1 = auction.generate_commit_hash(bidder_a, proxy_1, salt_a1, salt_b1)
    commit_hash_2 = auction.generate_commit_hash(bidder_b, proxy_2, salt_a2, salt_b2)
    
    print("1. Starting clock phase...")
    success = auction.start_clock_phase()
    print(f"   start_clock_phase(): {'SUCCESS' if success else 'FAILED'}")
    print(f"   Current phase: {auction.current_phase}")
    print(f"   Clock open: {auction.clock_open}")
    
    print("\n2. Opening first round...")
    success = auction.open_clock_round()
    print(f"   open_clock_round(): {'SUCCESS' if success else 'FAILED'}")
    print(f"   Current round: {auction.current_round}")
    print(f"   Clock open: {auction.clock_open}")
    
    print("\n3. Registering bidders and commits...")
    auction.register_bidder(bidder_a)
    auction.register_bidder(bidder_b)
    auction.register_commit(commit_hash_1, proxy_1)
    auction.register_commit(commit_hash_2, proxy_2)
    auction.bidder_stake[bidder_a] = 1000
    auction.bidder_stake[bidder_b] = 1000
    print(f"   Registered bidders: {list(auction.active_bidders)}")
    
    print("\n4. Attempting to bid...")
    # This will fail because clock_open is still False
    bid1 = auction.bid({"pool_1": 1}, bidder_a, commit_hash_1, 100)
    print(f"   bid() for {bidder_a}: {'SUCCESS' if bid1 else 'FAILED'}")
    print(f"   Clock open: {auction.clock_open}")
    
    print("\n5. Ending round...")
    result = auction.end_clock_round()
    print(f"   end_clock_round(): {result}")
    print(f"   Clock open: {auction.clock_open}")
    
    print("\n6. Attempting to open second round...")
    # This will fail because clock_open is False and open_clock_round doesn't set it
    success = auction.open_clock_round()
    print(f"   open_clock_round() round 2: {'SUCCESS' if success else 'FAILED'}")
    print(f"   Current round: {auction.current_round}")
    print(f"   Clock open: {auction.clock_open}")
    
    return auction


def test_proxy_phase():
    """Test the proxy phase with bundle submissions and reveal phase."""
    print("=== PROXY PHASE TEST ===\n")
    
    # Create pools
    pools = [
        Pool("pool_1", "token_A", "USDC", 1000, 1.0),
        Pool("pool_2", "token_B", "USDC", 1000, 1.0),
        Pool("pool_3", "token_C", "USDC", 1000, 1.0)
    ]
    
    # Initialize auction
    auction = ClockProxyAuction(pools, min_spending_ratio=0.5)
    
    # Setup bidders and proxies
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
    
    print(f"  Generated salts:")
    print(f"    Salts for {bidder_a}: {salt_a1}, {salt_b1}")
    print(f"    Salts for {bidder_b}: {salt_a2}, {salt_b2}")
    print(f"    Salts for {bidder_c}: {salt_a3}, {salt_b3}")
    
    # Register bidders and commits
    print(f"\nRegistration:")
    auction.register_bidder(bidder_a)
    auction.register_bidder(bidder_b)
    auction.register_bidder(bidder_c)
    auction.register_commit(commit_hash_1, proxy_1)
    auction.register_commit(commit_hash_2, proxy_2)
    auction.register_commit(commit_hash_3, proxy_1)
    
    # Add stake to bidders (simulating previous bidding activity)
    auction.bidder_stake[bidder_a] = 2000  # High stake
    auction.bidder_stake[bidder_b] = 1500  # Medium stake  
    auction.bidder_stake[bidder_c] = 800   # Low stake
    
    # Note: No need to simulate previous bidding activity since minimum spending is now based on stake
    print(f"  Registered bidders: {list(auction.active_bidders)}")
    print(f"  Registered commits: {len(auction.commit_proxy)}")
    print(f"  Bidder stakes: {auction.bidder_stake}")
    
    # Skip clock phase and set random prices
    print(f"\n--- SKIPPING CLOCK PHASE ---")
    print(f"Setting random prices...")
    auction.set_pool_price("pool_1", 5)
    auction.set_pool_price("pool_2", 8)
    auction.set_pool_price("pool_3", 3)
    print(f"  Fixed prices: {auction.prices}")
    
    # Start proxy phase
    print(f"\n--- STARTING PROXY PHASE ---")
    auction.start_proxy_phase()  # Move from setup to proxy phase
    print(f"  Current phase: {auction.current_phase}")
    
    # Proxies submit bundles
    print(f"\nBundle submissions:")
    
    # Proxy 1 submits bundle for bidder A
    bundle_a = [
        {"pool_1": 100, "pool_2": 50},
        {"pool_1": 80, "pool_2": 70},
        {"pool_2": 120}
    ]
    success_a = auction.submit_bundle(commit_hash_1, bundle_a)
    print(f"  {proxy_1} bundle for {bidder_a}: {'SUCCESS' if success_a else 'FAILED'}")
    print(f"    Bundle options: {bundle_a}")
    
    # Proxy 2 submits bundle for bidder B
    bundle_b = [
        {"pool_2": 80, "pool_3": 60},
        {"pool_3": 100},
        {"pool_1": 40, "pool_2": 40, "pool_3": 40}
    ]
    success_b = auction.submit_bundle(commit_hash_2, bundle_b)
    print(f"  {proxy_2} bundle for {bidder_b}: {'SUCCESS' if success_b else 'FAILED'}")
    print(f"    Bundle options: {bundle_b}")
    
    # Proxy 1 submits bundle for bidder C
    bundle_c = [
        {"pool_1": 60, "pool_3": 80},
        {"pool_2": 90},
        {"pool_1": 30, "pool_2": 30, "pool_3": 30}
    ]
    success_c = auction.submit_bundle(commit_hash_3, bundle_c)
    print(f"  {proxy_1} bundle for {bidder_c}: {'SUCCESS' if success_c else 'FAILED'}")
    print(f"    Bundle options: {bundle_c}")
    
    # Test duplicate bundle submission (should fail)
    print(f"\nTesting duplicate bundle submission:")
    duplicate_success = auction.submit_bundle(commit_hash_1, [{"pool_1": 999}])
    print(f"  Duplicate bundle for {commit_hash_1[:16]}...: {'FAILED' if not duplicate_success else 'SUCCESS'}")
    
    # Test bundle submission with unregistered commit (should fail)
    print(f"\nTesting unregistered commit bundle submission:")
    fake_commit = "fake_commit_hash_12345"
    fake_success = auction.submit_bundle(fake_commit, [{"pool_1": 999}])
    print(f"  Fake commit bundle: {'FAILED' if not fake_success else 'SUCCESS'}")
    
    print(f"\nBundle submission summary:")
    print(f"  Total bundles submitted: {len(auction.bundles)}")
    print(f"  Bundles:")
    for commit_hash, bundle_data in auction.bundles.items():
        print(f"    Commit {commit_hash[:16]}...:\n\t{bundle_data}")
    
    # ============================================================================
    # REVEAL PHASE
    # ============================================================================
    
    # ============================================================================
    # ALLOCATION PHASE
    # ============================================================================
    
    print(f"\n" + "="*60)
    print(f"ALLOCATION PHASE")
    print(f"="*60)
    
    # Start allocation phase
    print(f"\n--- STARTING ALLOCATION PHASE ---")
    auction.start_allocation_phase()
    print(f"  Current phase: {auction.current_phase}")
    
    # Create random allocation
    print(f"\nCreating random allocation:")
    allocation_success = auction.allocate()
    print(f"  Allocation created: {'SUCCESS' if allocation_success else 'FAILED'}")
    
    # End allocation phase
    print(f"\n--- ENDING ALLOCATION PHASE ---")
    auction.end_allocation_phase()
    print(f"  Current phase: {auction.current_phase}")
    
    # ============================================================================
    # REVEAL PHASE
    # ============================================================================
    
    print(f"\n" + "="*60)
    print(f"REVEAL PHASE")
    print(f"="*60)
    
    # Start reveal phase
    print(f"\n--- STARTING REVEAL PHASE ---")
    print(f"  Current phase: {auction.current_phase}")
    
    # Test reveals using allocation costs
    print(f"\nTesting reveals using allocation costs:")
    
    # Reveal all bidders using their allocated bundle costs
    reveal_a = auction.reveal(bidder_a, salt_a1, proxy_1, salt_b1)
    mapped_bidder_a = auction.revealed_mappings.get(commit_hash_1, "NOT_MAPPED")
    print(f"  {bidder_a}->{commit_hash_1[:16]}... reveal using allocation cost: {'SUCCESS' if reveal_a else 'FAILED'}")
    print(f"    Mapping verification: {bidder_a} -> {mapped_bidder_a}")
    
    reveal_b = auction.reveal(bidder_b, salt_a2, proxy_2, salt_b2)
    mapped_bidder_b = auction.revealed_mappings.get(commit_hash_2, "NOT_MAPPED")
    print(f"  {bidder_b}->{commit_hash_2[:16]}... reveal using allocation cost: {'SUCCESS' if reveal_b else 'FAILED'}")
    print(f"    Mapping verification: {bidder_b} -> {mapped_bidder_b}")
    
    reveal_c = auction.reveal(bidder_c, salt_a3, proxy_1, salt_b3)
    mapped_bidder_c = auction.revealed_mappings.get(commit_hash_3, "NOT_MAPPED")
    print(f"  {bidder_c}->{commit_hash_3[:16]}... reveal using allocation cost: {'SUCCESS' if reveal_c else 'FAILED'}")
    print(f"    Mapping verification: {bidder_c} -> {mapped_bidder_c}")
    
    print(f"\nRevealed mappings:")
    for commit_hash, bidder_id in auction.revealed_mappings.items():
        proxy_address = auction.commit_proxy[commit_hash]
        print(f"  Commit {commit_hash[:16]}...: {bidder_id} -> {proxy_address}")
    
    # Test invalid reveal (wrong bidder)
    print(f"\nTesting invalid reveal:")
    invalid_reveal = auction.reveal("wrong_bidder", salt_a1, proxy_1, salt_b1)
    print(f"  Invalid reveal (wrong bidder): {'REJECTED' if not invalid_reveal else 'ACCEPTED'}")
    
    # End reveal phase
    print(f"\n--- ENDING REVEAL PHASE ---")
    auction.end_reveal_phase()
    print(f"  Current phase: {auction.current_phase}")
    
    # Final summary
    print(f"\n=== PROXY PHASE SUMMARY ===")
    print(f"Current phase: {auction.current_phase}")
    print(f"Fixed prices: {auction.prices}")
    print(f"Total bundles: {len(auction.bundles)}")
    print(f"Registered commits: {len(auction.commit_proxy)}")
    print(f"Active bidders: {list(auction.active_bidders)}")
    
    return auction


def main():
    """Main function to run tests."""
    print("Running setup phase test...\n")
    # test_setup_phase()
    
    print("\n" + "="*50 + "\n")
    
    print("Running clock phase test...\n")
    # test_clock_phase()
    
    print("\n" + "="*50 + "\n")
    
    print("Running proxy phase test...\n")
    test_proxy_phase()
    
    print("\n" + "="*50 + "\n")
    
    print("Running clock phase flow test...\n")
    # test_clock_phase_flow()
    
    print("\n" + "="*50 + "\n")
    
    print("Running core functions test...\n")
    # test_core_functions()


if __name__ == "__main__":
    main()
