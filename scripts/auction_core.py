"""
Core auction classes for the Clock-Proxy Auction System.

This module contains the main classes that implement the auction mechanics
as described in the main logic flow document.
"""

from collections import defaultdict
from typing import Dict, Set, List, Tuple, Optional
import hashlib
import secrets
import numpy as np
from pool_core import Pool

class ClockProxyAuctionConfig:
    """
    Config for the ClockProxyAuction. Not currently used but may be later.
    """
    def __init__(self, **kwargs):
        ## setup config
        self.pools = kwargs.get("pools", [])
        
        ## bidder config
        self.bidder_min_spend_ratio = kwargs.get("bidder_min_spend_ratio", 0.5)
        self.bidder_dropout_slash_ratio = kwargs.get("bidder_dropout_slash_ratio", 0.8) 
        self.bidder_spending_violation_slash_ratio = kwargs.get("bidder_spending_violation_slash_ratio", 0.3)
        
        ## proxy config
        
        ## allocator config
        self.allocator_stake_requirement = kwargs.get("allocator_stake_requirement", 0)
        
        ## clock config
        self.max_rounds = kwargs.get("max_rounds", 100000)
        self.clock_price_increment = kwargs.get("clock_price_increment", 1) # not a ratio so the price increases are linear
        


class ClockProxyAuction:
    """Simulates the clock-proxy auction system with commit-reveal mechanics.
    
    Pool objects must be created with prices set BEFORE passing to auction init.
    Auction prices mirror pool prices and stay in sync via set_pool_price().
    """
    
    def __init__(self, pools: List[Pool], min_spending_ratio: float = 0.5):
        self.wallet = {} # for simplicity, we will just "transfer" penalties to this wallet
        
        # On-chain data structures (as per mainLogicFlow.md)
        self.commit_proxy: Dict[str, str] = {}  # commitHash -> proxyAddress
        self.bidder_stake: Dict[str, int] = {}  # bidder -> staked amount
        self.bidder_bid_points: Dict[str, int] = {}  # bidder -> bidPoints
        self.pools = pools
        
        # Auction configuration (set during setup phase)
        self.min_spending_ratio = min_spending_ratio
        
        # Auction state
        # self.prices: Dict[str, int] = {}  # item(pool_id) -> price 
        self.prices = {pool.pool_id: pool.current_price for pool in self.pools}
        self.bids: List[Tuple[str, Set[str], str, int]] = []  # (bidder, bundle, commitHash, stakeAmount)
        
        # Commit-reveal state
        self.commits: Dict[str, Dict] = {}  # commitHash -> {bidder_id, proxy_address, salt_a, salt_b}
        
        # Bundle and allocation state
        self.bundles: Dict[str, Dict] = {}  # commitHash -> bundleData
        self.allocations: List[Dict] = []  # List of allocation proposals
        self.revealed_mappings: Dict[str, Dict] = {}  # commitHash -> {bidder_id, proxy_address}
        
        # Auction phase tracking
        self.current_phase: str = "setup"  # "setup", "clock", "proxy", "allocation", "reveal"
        
        # Clock phase state
        self.clock_open: bool = False
        self.current_round: int = 0
        self.round_bids: List[Tuple[str, Set[str], str, int]] = []  # Bids for current round
        self.active_bidders: Set[str] = set()  # Bidders who have participated (this is where bidders register)
        self.dropped_bidders: Set[str] = set()  # Bidders who dropped out
        self.max_rounds = 100000 # placeholder
        
    def start_clock_phase(self) -> bool:
        """
        Start the clock phase. Only callable from setup phase.
        
        Returns True if successful, False if not in setup phase
        """
        if self.current_phase != "setup":
            return False
        self.current_phase = "clock"
        print(f"Auction phase changed to: {self.current_phase}")
        return True
    
    def end_clock_phase(self) -> bool:
        """
        End the clock phase and move to proxy phase.
        
        Returns True if successful, False if not in clock phase
        """
        if self.current_phase != "clock":
            return False
        self.current_phase = "proxy"
        print(f"Auction phase changed to: {self.current_phase}")
        return True
    
    def is_clock_phase(self) -> bool:
        """
        Check if we're currently in the clock phase.
        """
        return self.current_phase == "clock"
    
    def set_pool_price(self, pool_id: str, price: int):
        """
        Set the price of a pool. Updates both pool object and auction price mirror.
        """
        for pool in self.pools:
            if pool.pool_id == pool_id:
                pool.current_price = price
                self.prices[pool_id] = price  # Keep mirror in sync
                break
        
    def generate_commit_hash(self, bidder_id: str, proxy_address: str, salt_a: str, salt_b: str) -> str:
        """
        Generate commit hash using the improved unlinkability method from mainLogicFlow.md
        
        commitHash = keccak256(abi.encode(
            keccak256(abi.encode(bidderID, saltA)),
            keccak256(abi.encode(proxyAddress, saltB))
        ))
        """
        # Simulate keccak256 with SHA256 for this simulation
        inner_hash_1 = hashlib.sha256(f"{bidder_id}{salt_a}".encode()).hexdigest()
        inner_hash_2 = hashlib.sha256(f"{proxy_address}{salt_b}".encode()).hexdigest()
        commit_hash = hashlib.sha256(f"{inner_hash_1}{inner_hash_2}".encode()).hexdigest()
        return commit_hash
    
    def register_commit(self, commit_hash: str, proxy_address: str) -> bool:
        """
        Simulate registerCommit(commitHash) from mainLogicFlow.md
        
        Returns True if successful, False if already registered
        """
        # Can register during setup or clock phase
        if self.current_phase not in ["setup", "clock"]:
            return False
            
        if commit_hash in self.commit_proxy:
            return False  # Already registered
            
        self.commit_proxy[commit_hash] = proxy_address
        return True
    
    def register_bidder(self, bidder_id: str) -> bool:
        """
        Simulate registerBidder(bidderId) from mainLogicFlow.md
        
        Returns True if successful, False if already registered
        """
        # Can register during setup or clock phase
        if self.current_phase not in ["setup", "clock"]:
            return False
            
        if bidder_id in self.active_bidders:
            return False  # Already registered
        self.active_bidders.add(bidder_id)
        return True
    
    def bid(self, demands: Set[str], bidder_id: str, commit_hash: str, stake_amount: int) -> bool:
        """
        Simulate bid(demands, bidderId, commitHash, stakeAmount) from mainLogicFlow.md
        
        The stake_amount is consumed from the bidder's stake and converted to bid points.
        Bid points are consumed during bidding and reset each round.
        
        Returns True if bid accepted, False if rejected
        """
        # Check if clock is open
        if not self.clock_open:
            return False
        
        # check if bidder is registered
        if bidder_id not in self.active_bidders:
            return False
            
        # Check if commit is registered
        if commit_hash not in self.commit_proxy:
            return False
            
        # Check if bidder has enough stake to cover the stake_amount
        current_stake = self.bidder_stake.get(bidder_id, 0)
        if current_stake < stake_amount:
            return False
            
        # Calculate bidPoints = stakeAmount (1:1 ratio)
        bid_points = stake_amount
        
        # Check if bidder has enough bidPoints (bidPoints reset each round)
        current_bid_points = self.bidder_bid_points.get(bidder_id, 0)
        if current_bid_points < bid_points:
            return False
            
        # Consume stake and bid points
        self.bidder_stake[bidder_id] -= stake_amount
        self.bidder_bid_points[bidder_id] -= bid_points
        
        # Record the bid for this round
        self.round_bids.append((bidder_id, demands, commit_hash, stake_amount))
        self.active_bidders.add(bidder_id)
        
        return True
    
    def submit_bundle(self, commit_hash: str, bundle_data: Dict) -> bool:
        """
        Simulate submitBundle(commitHash, bundleData) from mainLogicFlow.md
        
        Returns True if bundle accepted, False if rejected
        """
        # Check if proxy is registered for this commit
        if commit_hash not in self.commit_proxy:
            return False
            
        # For now, just store the bundle data
        # In real implementation, this would validate bundle format
        self.bundles[commit_hash] = bundle_data
        return True
    
    def submit_allocation(self, allocator_id: str, allocation_data: List[Tuple[str, Set[str]]]) -> bool:
        """
        Simulate submitAllocation(allocationData) from mainLogicFlow.md
        
        Returns True if allocation accepted, False if rejected
        """
        # Store the allocation proposal
        self.allocations.append({
            'allocator_id': allocator_id,
            'allocation': allocation_data
        })
        return True
    
    def reveal(self, bidder_id: str, salt_a: str, proxy_address: str, salt_b: str, 
               final_purchase_amount: int = 0) -> bool:
        """
        Simulate reveal(bidderID, saltA, proxyAddress, saltB) from mainLogicFlow.md
        
        Args:
            bidder_id: The bidder revealing
            salt_a: Bidder's salt
            proxy_address: Proxy address
            salt_b: Proxy's salt
            final_purchase_amount: Amount actually spent on purchase (for minimum spending check)
            
        Returns True if reveal successful, False if invalid
        """
        # Reconstruct commit hash
        reconstructed_hash = self.generate_commit_hash(bidder_id, proxy_address, salt_a, salt_b)
        
        # Check if this commit hash exists and matches the proxy
        if reconstructed_hash not in self.commit_proxy:
            return False
            
        if self.commit_proxy[reconstructed_hash] != proxy_address:
            return False
            
        # Check minimum spending requirement
        if final_purchase_amount > 0:
            spending_check = self.enforce_minimum_spending(bidder_id, final_purchase_amount)
            if not spending_check:
                # Apply penalty for minimum spending violation
                original_stake = self.bidder_stake.get(bidder_id, 0)
                penalty_amount = int(original_stake * 0.3)  # 30% penalty for spending violation
                refund_amount = original_stake - penalty_amount
                
                print(f"MINIMUM SPENDING PENALTY APPLIED:")
                print(f"  Original stake: {original_stake}")
                print(f"  Penalty: {penalty_amount}")
                print(f"  Refund: {refund_amount}")
                
                # Remove bidder from stake and bidPoints
                if bidder_id in self.bidder_stake:
                    del self.bidder_stake[bidder_id]
                if bidder_id in self.bidder_bid_points:
                    del self.bidder_bid_points[bidder_id]
                
                return False  # Reveal failed due to spending violation
            
        # Reveal successful - link bidder to proxy
        self.revealed_mappings[reconstructed_hash] = {
            'bidder_id': bidder_id,
            'proxy_address': proxy_address
        }
        
        return True
    
    def open_clock(self) -> bool:
        """
        Open the clock phase for bidding.
        
        Returns True if clock opened successfully, False if already open
        """
        if self.clock_open:
            return False
            
        self.clock_open = True
        self.current_round += 1
        self.round_bids = []  # Clear previous round bids
        
        # Reset bid points for all active bidders (bid points reset each round)
        self.reset_bid_points()
        
        print(f"Clock opened for round {self.current_round}")
        return True
    
    def reset_bid_points(self) -> None:
        """
        Reset bid points for all active bidders.
        Bid points are reset to match their current stake at the start of each round.
        """
        for bidder_id in self.active_bidders:
            if bidder_id in self.bidder_stake:
                # Reset bid points to match current stake
                self.bidder_bid_points[bidder_id] = self.bidder_stake[bidder_id]
    
    def close_clock(self) -> Dict:
        """
        Close the clock phase and process the round.
        
        Returns:
            Dict with round results including excess demand and dropout info
        """
        if not self.clock_open:
            return {"error": "Clock not open"}
            
        self.clock_open = False
        
        # Check for dropped bidders (bidders with stakes but no bids this round)
        dropped_this_round = set()
        for bidder_id in self.bidder_stake:
            if bidder_id not in self.active_bidders and bidder_id not in self.dropped_bidders:
                dropped_this_round.add(bidder_id)
                del self.active_bidders[bidder_id] # remove bidder from active bidders
                self.dropped_bidders.add(bidder_id)
                dropout_success = self.dropout(bidder_id)
                if not dropout_success:
                    print(f"Dropout failed for bidder {bidder_id}")
                    return {"error": "Dropout failed"}
        
        # Calculate excess demand (simplified - just count total bids per item)
        item_demands = defaultdict(int)
        for bidder, demands, commit_hash, stake_amount in self.round_bids:
            for item in demands:
                item_demands[item] += 1
        
        # Add round bids to total bids
        self.bids.extend(self.round_bids)
        
        # Reset active bidders for next round
        self.active_bidders.clear()
        
        result = {
            "round": self.current_round,
            "total_bids": len(self.round_bids),
            "item_demands": dict(item_demands),
            "dropped_bidders": list(dropped_this_round),
            "excess_demand": {item: count for item, count in item_demands.items() if count > 1}
        }
        
        print(f"Clock closed for round {self.current_round}")
        print(f"  Total bids: {result['total_bids']}")
        print(f"  Item demands: {result['item_demands']}")
        print(f"  Dropped bidders: {result['dropped_bidders']}")
        print(f"  Excess demand: {result['excess_demand']}")
        
        return result
    
    def get_bidder_total_bid_value(self, bidder_id: str) -> int:
        """
        Calculate total value of all bids made by a bidder.
        This represents the minimum amount they must spend.
        """
        total_value = 0
        for bidder, demands, commit_hash, stake_amount in self.bids:
            if bidder == bidder_id:
                total_value += stake_amount
        return total_value
    
    def enforce_minimum_spending(self, bidder_id: str, final_purchase_amount: int) -> bool:
        """
        Enforce minimum spending requirement.
        
        Args:
            bidder_id: The bidder making the purchase
            final_purchase_amount: Amount actually spent on purchase
            
        Returns:
            True if requirement met, False if violated
        """
        total_bid_value = self.get_bidder_total_bid_value(bidder_id)
        minimum_required = int(total_bid_value * self.min_spending_ratio)
        
        if final_purchase_amount < minimum_required:
            print(f"MINIMUM SPENDING VIOLATION:")
            print(f"  Bidder {bidder_id} total bid value: {total_bid_value}")
            print(f"  Minimum required spending: {minimum_required}")
            print(f"  Actual purchase amount: {final_purchase_amount}")
            print(f"  Shortfall: {minimum_required - final_purchase_amount}")
            return False
            
        print(f"MINIMUM SPENDING REQUIREMENT MET:")
        print(f"  Bidder {bidder_id} total bid value: {total_bid_value}")
        print(f"  Minimum required: {minimum_required}")
        print(f"  Actual purchase: {final_purchase_amount}")
        return True
    
    def dropout(self, bidder_id: str, refund_percentage: float = 0.8) -> bool:
        """
        Simulate bidder dropout with partial refund.
        
        Args:
            bidder_id: The bidder dropping out
            refund_percentage: Percentage of stake to refund (default 80%)
            
        Returns:
            True if dropout successful, False if bidder not found
        """
        if bidder_id not in self.bidder_stake:
            return False
            
        original_stake = self.bidder_stake[bidder_id]
        refund_amount = int(original_stake * refund_percentage)
        penalty = original_stake - refund_amount
        self.bidder_stake[bidder_id] = refund_amount # update bidder stake to the refund amount. This would be transferred out irl
        
        # transfer penalty to wallet
        if bidder_id not in self.wallet:
            self.wallet[bidder_id] = 0
        self.wallet[bidder_id] += penalty
        
        # Remove bidder from stake and bidPoints
        # del self.bidder_stake[bidder_id]
        if bidder_id in self.bidder_bid_points:
            del self.bidder_bid_points[bidder_id]
            
        print(f"Bidder {bidder_id} dropped out:")
        print(f"  Original stake: {original_stake}")
        print(f"  Refunded: {refund_amount}")
        print(f"  Penalty: {penalty}")
        
        return True
