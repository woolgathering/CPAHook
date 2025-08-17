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
    Configuration class for the Clock-Proxy Auction system.
    
    This class holds all the configurable parameters that control the behavior
    of the auction system. It includes settings for bidders, proxies, allocators,
    and the clock mechanism itself. The configuration allows fine-tuning of
    economic incentives, penalty structures, and auction timing parameters.
    
    Parameters
    ----------
    **kwargs : dict
        Configuration parameters with the following possible keys:
        
        pools : List[Pool], optional
            List of pool objects that will participate in the auction.
            Defaults to empty list.
            
        bidder_min_spend_ratio : float, optional
            Minimum ratio of stake that bidders must spend to avoid penalties.
            Expressed as a decimal (e.g., 0.5 means 50% of stake must be spent).
            Defaults to 0.5.
            
        bidder_dropout_slash_ratio : float, optional
            Percentage of stake that is slashed when a bidder drops out.
            Expressed as a decimal (e.g., 0.8 means 80% is slashed, 20% refunded).
            Defaults to 0.8.
            
        bidder_spending_violation_slash_ratio : float, optional
            Percentage of stake that is slashed when a bidder violates minimum
            spending requirements. Defaults to 0.3.
            
        allocator_stake_requirement : int, optional
            Minimum stake required for an allocator to participate in the
            allocation phase. Defaults to 0.
            
        max_rounds : int, optional
            Maximum number of clock rounds before the auction is forced to end.
            Prevents infinite loops in case of persistent excess demand.
            Defaults to 100000.
            
        clock_price_increment : int, optional
            Amount by which prices increase in each clock round when there is
            excess demand. This is a linear increment, not a percentage.
            Defaults to 1.
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
    """
    Main auction system implementing the clock-proxy auction with commit-reveal mechanics.
    
    This class simulates a sophisticated auction system that combines clock auctions
    with proxy bidding and commit-reveal schemes for privacy. The auction operates
    in distinct phases: setup, clock, proxy, allocation, reveal, and settlement.
    
    The system maintains price synchronization between pool objects and internal
    auction prices. Bidders can register, submit bids during clock phases, and
    use proxies to submit bundles during the proxy phase. The allocation phase
    determines final allocations, and the reveal phase validates spending requirements
    and handles financial settlements.
    
    Parameters
    ----------
    pools : List[Pool]
        List of pool objects that define the items available for auction.
        Each pool must have its price set before being passed to the auction.
        
    min_spending_ratio : float, optional
        Minimum ratio of stake that bidders must spend to avoid penalties.
        Defaults to 0.5.
    """
    
    def __init__(self, pools: List[Pool], min_spending_ratio: float = 0.5):
        # Core data structures
        self.pools: Dict[str, Pool] = {pool.pool_id: pool for pool in pools}
        self.prices: Dict[str, int] = {pool.pool_id: pool.current_price for pool in pools}
        self.min_spending_ratio = min_spending_ratio
        
        # Bidder and proxy management
        self.active_bidders: Set[str] = set()
        self.bidder_stake: Dict[str, int] = {}
        self.commit_proxy: Dict[str, str] = {}  # commitHash -> proxyAddress
        self.revealed_mappings: Dict[str, str] = {}  # commitHash -> bidder_id
        
        # Auction state
        self.current_phase: str = "setup"
        self.bids: List[Tuple[str, Dict[str, int], str, int]] = []  # (bidder, demands, commitHash, stakeAmount)
        
        # Clock phase state
        self.clock_open: bool = False
        self.current_round: int = 0
        self.round_bids: List[Tuple[str, Dict[str, int], str, int]] = []
        self.dropped_bidders: Set[str] = set()
        
        # Bundle and allocation state
        self.bundles: Dict[str, List[Dict[str, int]]] = {}  # commitHash -> bundleData
        self.final_allocation: Optional[Dict[str, Dict[str, int]]] = None
        
        # Utility
        self.wallet: Dict[str, int] = {}  # for penalties
    
    # ============================================================================
    # 1. INITIALIZATION & CONFIGURATION
    # ============================================================================
    
    def set_pool_price(self, pool_id: str, price: int) -> None:
        """
        Update the price of a specific pool and synchronize it with the auction's price mirror.
        
        This function ensures that when a pool's price is updated, the auction's
        internal price tracking stays synchronized. This is crucial for maintaining
        consistency between the pool objects and the auction's price calculations.
        The function iterates through all pools to find the matching pool_id and
        updates both the pool object and the auction's price dictionary.
        
        Parameters
        ----------
        pool_id : str
            The unique identifier of the pool whose price should be updated.
            
        price : int
            The new price to set for the specified pool.
            
        Notes
        -----
        This function performs a linear search through all pools to find the
        matching pool_id. In a production system with many pools, this could
        be optimized by maintaining a reverse mapping.
        """
        for pool in self.pools.values():
            if pool.pool_id == pool_id:
                pool.current_price = price
                self.prices[pool_id] = price  # Keep mirror in sync
                break
    
    def update_prices(self) -> None:
        """
        Synchronize auction prices with current pool prices.
        
        This function refreshes the auction's INTERNAL price dictionary by
        reading the current prices from all pool objects. This ensures that
        the auction always has the most up-to-date price information when
        making calculations or processing bids.
        
        Notes
        -----
        This function is typically called at the beginning of each clock round
        to ensure price consistency before processing new bids.
        """
        self.prices = {pool.pool_id: pool.current_price for pool in self.pools.values()}
    
    # ============================================================================
    # 2. PHASE MANAGEMENT
    # ============================================================================
    
    def _change_phase(self, new_phase: str) -> None:
        """
        Internal helper function to change the auction phase and log the transition.
        
        Parameters
        ----------
        new_phase : str
            The new phase to transition to. Valid phases are: "setup", "clock",
            "proxy", "allocation", "reveal", "settlement".
        """
        self.current_phase = new_phase
        print(f"Auction phase changed to: {self.current_phase}")
    
    def start_clock_phase(self) -> bool:
        """
        Transition from setup phase to clock phase.
        
        This function initiates the clock phase of the auction, which is the
        main bidding phase where bidders can submit demands for items at
        current prices. The clock phase continues until there is no excess
        demand for any item, at which point it transitions to the proxy phase.
        
        Returns
        -------
        bool
            True if the transition was successful, False if the auction is
            not currently in the setup phase.
            
        Notes
        -----
        The clock phase is the core mechanism for price discovery in the auction.
        During this phase, prices increase in response to excess demand, and
        bidders can adjust their demands based on the changing prices.
        """
        if self.current_phase != "setup":
            return False
        self._change_phase("clock")
        return True
    
    def end_clock_phase(self) -> bool:
        """
        Transition from clock phase to proxy phase.
        
        This function ends the clock phase and moves the auction into the proxy
        phase. The proxy phase allows bidders to submit bundles of acceptable
        allocations through their registered proxies.
        
        Returns
        -------
        bool
            True if the transition was successful, False if the auction is
            not currently in the clock phase.
            
        Notes
        -----
        The transition to proxy phase typically occurs when there is no longer
        excess demand for any item, indicating that the price discovery process
        has converged.
        """
        if self.current_phase != "clock":
            return False
        self._change_phase("proxy")
        return True
    
    def start_proxy_phase(self) -> bool:
        """
        Transition directly from setup phase to proxy phase, skipping the clock phase.
        
        This function allows the auction to skip the clock phase entirely and
        move directly to the proxy phase. This is useful for scenarios where
        the clock phase is not needed, such as when prices are already known
        or when the auction is being used for allocation only.
        
        Returns
        -------
        bool
            True if the transition was successful, False if the auction is
            not currently in the setup phase.
            
        Notes
        -----
        Skipping the clock phase means that price discovery will not occur
        through the clock mechanism. This should only be used when prices
        are already appropriately set or when the focus is purely on allocation.
        """
        if self.current_phase != "setup":
            return False
        self._change_phase("proxy")
        return True
    
    def start_allocation_phase(self) -> bool:
        """
        Transition from proxy phase to allocation phase.
        
        This function moves the auction into the allocation phase, where
        allocators can submit allocation proposals based on the bundles
        submitted during the proxy phase.
        
        Returns
        -------
        bool
            True if the transition was successful, False if the auction is
            not currently in the proxy phase.
            
        Notes
        -----
        The allocation phase is where the final allocation of items to bidders
        is determined. Allocators evaluate all submitted bundles and choose
        the optimal combination that maximizes some objective function.
        """
        if self.current_phase != "proxy":
            return False
        self._change_phase("allocation")
        return True
    
    def end_allocation_phase(self) -> bool:
        """
        Transition from allocation phase to reveal phase.
        
        This function ends the allocation phase and moves the auction into
        the reveal phase, where bidders reveal their identities and validate
        their spending requirements.
        
        Returns
        -------
        bool
            True if the transition was successful, False if the auction is
            not currently in the allocation phase.
            
        Notes
        -----
        The reveal phase is crucial for the commit-reveal scheme, as it
        allows bidders to prove their identity and validate that they meet
        the minimum spending requirements.
        """
        if self.current_phase != "allocation":
            return False
        self._change_phase("reveal")
        return True
    
    def end_reveal_phase(self) -> bool:
        """
        Transition from reveal phase to settlement phase.
        
        This function ends the reveal phase and moves the auction into the
        final settlement phase, where financial transactions are completed
        and penalties are applied as necessary.
        
        Returns
        -------
        bool
            True if the transition was successful, False if the auction is
            not currently in the reveal phase.
            
        Notes
        -----
        The settlement phase is the final phase of the auction where all
        financial obligations are settled, including payments for allocated
        items and any penalties for violations.
        """
        if self.current_phase != "reveal":
            return False
        self._change_phase("settlement")
        return True
    
    def is_clock_phase(self) -> bool:
        """
        Check if the auction is currently in the clock phase.
        
        Returns
        -------
        bool
            True if the auction is in the clock phase, False otherwise.
        """
        return self.current_phase == "clock"
    
    def is_allocation_phase(self) -> bool:
        """
        Check if the auction is currently in the allocation phase.
        
        Returns
        -------
        bool
            True if the auction is in the allocation phase, False otherwise.
        """
        return self.current_phase == "allocation"
    
    # ============================================================================
    # 3. COMMIT-REVEAL SYSTEM
    # ============================================================================
    
    def generate_commit_hash(self, bidder_id: str, proxy_address: str, salt_a: str, salt_b: str) -> str:
        """
        Generate a commit hash using the improved unlinkability method.
        
        This function implements the commit hash generation algorithm that
        provides unlinkability between bidders and their proxies. The method
        uses two separate salts and nested hashing to ensure that even if
        one component is compromised, the other remains secure.
        
        The commit hash is computed as:
        commitHash = keccak256(abi.encode(
            keccak256(abi.encode(bidderID, saltA)),
            keccak256(abi.encode(proxyAddress, saltB))
        ))
        
        This approach ensures that the bidder's identity cannot be linked
        to their proxy address without knowledge of both salts.
        
        Parameters
        ----------
        bidder_id : str
            The unique identifier of the bidder.
            
        proxy_address : str
            The address of the proxy that will submit bundles on behalf of the bidder.
            
        salt_a : str
            First salt used to obscure the bidder's identity.
            
        salt_b : str
            Second salt used to obscure the proxy's address.
            
        Returns
        -------
        str
            The generated commit hash as a hexadecimal string.
            
        Notes
        -----
        This implementation uses SHA256 instead of keccak256 for simulation
        purposes. In a real blockchain implementation, keccak256 would be used.
        """
        # Simulate keccak256 with SHA256 for this simulation
        inner_hash_1 = hashlib.sha256(f"{bidder_id}{salt_a}".encode()).hexdigest()
        inner_hash_2 = hashlib.sha256(f"{proxy_address}{salt_b}".encode()).hexdigest()
        commit_hash = hashlib.sha256(f"{inner_hash_1}{inner_hash_2}".encode()).hexdigest()
        return commit_hash
    
    def register_commit(self, commit_hash: str, proxy_address: str) -> bool:
        """
        Register a commit hash with its associated proxy address.
        
        This function allows bidders to register their commit hashes during
        the setup or clock phases. The registration creates a mapping between
        the commit hash and the proxy address, which is used later during
        the reveal phase to validate the bidder's identity.
        
        Parameters
        ----------
        commit_hash : str
            The commit hash generated by the bidder using generate_commit_hash().
            
        proxy_address : str
            The address of the proxy that will act on behalf of the bidder.
            
        Returns
        -------
        bool
            True if the commit was successfully registered, False if the
            commit hash was already registered or if registration is not
            allowed in the current phase.
            
        Notes
        -----
        Registration is only allowed during the setup and clock phases.
        Each commit hash can only be registered once.
        """
        # Can register during setup or clock phase
        if self.current_phase not in ["setup", "clock"]:
            return False
            
        if commit_hash in self.commit_proxy:
            return False  # Already registered
            
        self.commit_proxy[commit_hash] = proxy_address
        return True
    
    def _handle_financial_settlement(self, bidder_id: str, actual_purchase_amount: int, bidder_stake: int) -> None:
        """
        Handle the financial settlement after successful spending validation.
        
        This internal function manages the financial aspects of the auction
        settlement, including refunds for excess stake and requests for
        additional payments when the actual purchase amount exceeds the
        original stake.
        
        Parameters
        ----------
        bidder_id : str
            The identifier of the bidder whose settlement is being processed.
            
        actual_purchase_amount : int
            The total cost of the items allocated to the bidder.
            
        bidder_stake : int
            The original stake amount provided by the bidder.
            
        Notes
        -----
        This function updates the bidder's stake in the system to reflect
        the final settlement amount. In a real implementation, this would
        trigger actual financial transfers.
        """
        if actual_purchase_amount < bidder_stake:
            refund_amount = bidder_stake - actual_purchase_amount
            print(f"FINANCIAL SETTLEMENT - REFUND:")
            print(f"  Excess stake: {refund_amount}")
            print(f"  Refunded to bidder: {refund_amount}")
            self.bidder_stake[bidder_id] = actual_purchase_amount
        elif actual_purchase_amount > bidder_stake:
            additional_payment = actual_purchase_amount - bidder_stake
            print(f"FINANCIAL SETTLEMENT - ADDITIONAL PAYMENT REQUIRED:")
            print(f"  Additional payment needed: {additional_payment}")
            print(f"  Requesting payment from bidder: {additional_payment}")
            self.bidder_stake[bidder_id] = actual_purchase_amount
        else:
            print(f"FINANCIAL SETTLEMENT - EXACT MATCH:")
            print(f"  Stake equals purchase amount: {actual_purchase_amount}")
    
    def reveal(self, bidder_id: str, salt_a: str, proxy_address: str, salt_b: str, 
               final_purchase_amount: int = 0) -> bool:
        """
        Reveal a bidder's identity and validate their spending requirements.
        
        This function is the core of the commit-reveal scheme. It allows
        bidders to prove their identity by providing the salts used to
        generate their commit hash. The function validates the commit hash,
        checks minimum spending requirements, and handles financial settlement.
        
        The reveal process involves:
        1. Reconstructing the commit hash using the provided parameters
        2. Validating that the commit hash is registered and matches the proxy
        3. Calculating the allocation cost for the bidder
        4. Checking minimum spending requirements
        5. Applying penalties if requirements are violated
        6. Handling financial settlement
        
        Parameters
        ----------
        bidder_id : str
            The identifier of the bidder revealing their identity.
            
        salt_a : str
            The first salt used in commit hash generation.
            
        proxy_address : str
            The proxy address associated with the commit hash.
            
        salt_b : str
            The second salt used in commit hash generation.
            
        final_purchase_amount : int, optional
            The final amount the bidder is willing to pay. If 0, uses
            the calculated allocation cost. Defaults to 0.
            
        Returns
        -------
        bool
            True if the reveal was successful and all requirements were met,
            False if the reveal failed or requirements were violated.
            
        Notes
        -----
        If minimum spending requirements are violated, a penalty of 30% of
        the original stake is applied, and the bidder's stake is reduced
        accordingly.
        """
        # Reconstruct commit hash
        reconstructed_hash = self.generate_commit_hash(bidder_id, proxy_address, salt_a, salt_b)
        
        # Validate commit hash and proxy
        if reconstructed_hash not in self.commit_proxy or self.commit_proxy[reconstructed_hash] != proxy_address:
            return False
            
        # Get allocation cost and determine actual purchase amount
        allocation_cost = self.get_allocation_cost(reconstructed_hash)
        actual_purchase_amount = final_purchase_amount if final_purchase_amount > 0 else allocation_cost
        
        # Create mapping regardless of financial validation
        self.revealed_mappings[reconstructed_hash] = bidder_id
        
        # Handle financial validation if there's a purchase amount
        if actual_purchase_amount > 0:
            bidder_stake = self.bidder_stake.get(bidder_id, 0)
            minimum_required = int(bidder_stake * self.min_spending_ratio)
            
            print(f"ALLOCATION VALIDATION:")
            print(f"  Allocation cost: {allocation_cost}")
            print(f"  Final purchase amount: {final_purchase_amount}")
            print(f"  Actual purchase amount: {actual_purchase_amount}")
            
            spending_check = self.enforce_minimum_spending(bidder_id, actual_purchase_amount)
            
            if not spending_check:
                print(f"MINIMUM SPENDING VIOLATION:")
                print(f"  Bidder {bidder_id} stake: {bidder_stake}")
                print(f"  Minimum required spending: {minimum_required}")
                print(f"  Actual purchase amount: {final_purchase_amount}")
                print(f"  Shortfall: {minimum_required - final_purchase_amount}")
                
                # Apply penalty
                penalty_amount = int(bidder_stake * 0.3)
                print(f"MINIMUM SPENDING PENALTY APPLIED:")
                print(f"  Original stake: {bidder_stake}")
                print(f"  Penalty: {penalty_amount}")
                print(f"  Refund: {bidder_stake - penalty_amount}")
                
                if bidder_id in self.bidder_stake:
                    del self.bidder_stake[bidder_id]
                return False
            else:
                print(f"MINIMUM SPENDING REQUIREMENT MET:")
                print(f"  Bidder {bidder_id} stake: {bidder_stake}")
                print(f"  Minimum required: {minimum_required}")
                print(f"  Actual purchase: {actual_purchase_amount}")
                
                self._handle_financial_settlement(bidder_id, actual_purchase_amount, bidder_stake)
        
        return True
    
    # ============================================================================
    # 4. REGISTRATION & BIDDING
    # ============================================================================
    
    def register_bidder(self, bidder_id: str) -> bool:
        """
        Register a new bidder in the auction system.
        
        This function allows bidders to register themselves in the auction
        during the setup or clock phases. Registration is required before
        a bidder can submit bids or participate in the auction.
        
        Parameters
        ----------
        bidder_id : str
            The unique identifier of the bidder to register.
            
        Returns
        -------
        bool
            True if the bidder was successfully registered, False if the
            bidder was already registered or if registration is not allowed
            in the current phase.
            
        Notes
        -----
        Registration is only allowed during the setup and clock phases.
        Each bidder can only be registered once. Upon registration, the
        bidder's stake is initialized to 0.
        """
        # Can register during setup or clock phase
        if self.current_phase not in ["setup", "clock"]:
            return False
            
        if bidder_id in self.active_bidders:
            return False  # Already registered
        self.active_bidders.add(bidder_id)
        self.bidder_stake[bidder_id] = 0 # initialize bidder stake to 0
        return True
    
    def bid(self, demands: Dict[str, int], bidder_id: str, commit_hash: str, stake_amount: int) -> bool:
        """
        Submit a bid during the clock phase of the auction.
        
        This function allows bidders to submit their demands for items during
        the clock phase. The bid includes the bidder's demands for each item,
        their identity, a commit hash for privacy, and a stake amount that
        will be converted to bid points.
        
        The function validates that:
        1. The clock phase is currently open for bidding
        2. The bidder is registered (auto-registers if not)
        3. The bidder has sufficient bid points to cover their demand
        4. The total value of the demand doesn't exceed available bid points
        
        Parameters
        ----------
        demands : Dict[str, int]
            Dictionary mapping item IDs to the quantity demanded by the bidder.
            
        bidder_id : str
            The identifier of the bidder submitting the bid.
            
        commit_hash : str
            The commit hash associated with this bid for privacy protection.
            
        stake_amount : int
            Additional stake amount to add to the bidder's bid points.
            This amount is consumed from the bidder's stake and converted
            to bid points for this round.
            
        Returns
        -------
        bool
            True if the bid was accepted, False if the bid was rejected
            due to insufficient funds or other validation failures.
            
        Notes
        -----
        The stake_amount is added to the bidder's total stake and converted
        to bid points on a 1:1 basis. Bid points are consumed during bidding
        and reset each round. The function automatically registers the bidder
        if they are not already registered.
        """
        # Check if clock is open
        if not self.clock_open:
            return False
        
        # check if bidder is registered
        if bidder_id not in self.active_bidders:
            self.register_bidder(bidder_id) # automatically register bidder if not already registered
            
        # Update bidder stake
        self.bidder_stake[bidder_id] += stake_amount # this is equivalent to a transfer from the bidder's wallet to the auction contract
        
        # Get current bid points
        current_bid_points = self.get_bid_points(bidder_id)
        
        # Compute total bid value from demand and current prices
        total_bid_value = sum(self.prices[item] * demand for item, demand in demands.items())
            
        # Check if bidder has enough stake to cover their demand
        if current_bid_points < total_bid_value:
            return False
        
        # Record the bid for this round
        self.round_bids.append((bidder_id, demands, commit_hash, stake_amount))
        
        return True
    
    def get_bid_points(self, bidder_id: str) -> int:
        """
        Get the current bid points available for a bidder.
        
        This function returns the number of bid points that a bidder has
        available for bidding. Currently, bid points are equivalent to
        the bidder's stake on a 1:1 basis, but this could be modified
        to implement more sophisticated point systems.
        
        Parameters
        ----------
        bidder_id : str
            The identifier of the bidder whose bid points should be retrieved.
            
        Returns
        -------
        int
            The number of bid points available to the bidder.
            
        Notes
        -----
        The current implementation uses a simple 1:1 mapping between
        stake and bid points. Future versions could implement more
        sophisticated systems with different conversion rates or
        additional point sources.
        """
        return self.bidder_stake[bidder_id]
    
    # ============================================================================
    # 5. CLOCK PHASE MANAGEMENT
    # ============================================================================
    
    def open_clock_round(self) -> bool:
        """
        Open a new clock round for bidding.
        
        This function initiates a new clock round by opening the bidding
        window, incrementing the round counter, clearing previous round
        bids, and updating prices. Clock rounds are the primary mechanism
        for price discovery in the auction.
        
        Returns
        -------
        bool
            True if the clock round was successfully opened, False if
            the auction is not currently in the clock phase.
            
        Notes
        -----
        Each clock round allows bidders to submit their demands at current
        prices. The round continues until end_clock_round() is called,
        at which point prices are adjusted based on excess demand.
        """
        if not self.is_clock_phase():
            return False
        self.clock_open = True
        self.current_round += 1
        self.round_bids = []  # Clear previous round bids
        self.update_prices()
        
        print(f"Clock round opened for round {self.current_round}")
        return True
    
    def end_clock_round(self) -> Tuple[Dict, bool]:
        """
        Close the current clock round and process the results.
        
        This function ends the current clock round and processes all bids
        submitted during the round. It calculates excess demand, identifies
        dropped bidders, and determines whether the clock phase should
        continue or end.
        
        The function performs several key operations:
        1. Closes the bidding window
        2. Identifies bidders who didn't submit bids (dropped bidders)
        3. Calculates total demand for each item
        4. Increases prices for items with excess demand
        5. Determines if the clock phase should continue
        
        Returns
        -------
        Tuple[Dict, bool]
            A tuple containing:
            - Dictionary with round results including total bids, item demands,
              dropped bidders, and excess demand information
            - Boolean indicating whether the clock phase should end (True
              if no excess demand, False if prices were increased)
              
        Notes
        -----
        If a bidder has stake but doesn't submit a bid in a round, they
        are considered to have dropped out and are penalized accordingly.
        The function automatically calls dropout() for such bidders.
        """
        if not self.clock_open:
            return {"error": "Clock not open"}, False
            
        self.clock_open = False
        
        # get the list of current bidders who submitted bids this round
        bidders_this_round = set()
        for bidder, demands, commit_hash, stake_amount in self.round_bids:
            bidders_this_round.add(bidder)
        
        # Check for dropped bidders (bidders with stakes but no bids this round)
        dropped_this_round = set()
        for bidder_id in self.bidder_stake:
            if bidder_id not in bidders_this_round and bidder_id not in self.dropped_bidders:
                dropped_this_round.add(bidder_id)
                self.active_bidders.remove(bidder_id) # remove bidder from active bidders
                self.dropped_bidders.add(bidder_id)
                dropout_success = self.dropout(bidder_id)
                if not dropout_success:
                    print(f"Dropout failed for bidder {bidder_id}")
                    return {"error": "Dropout failed"}, False
        
        # Add round bids to total bids
        self.bids.extend(self.round_bids)
        
        # Calculate excess demand (simplified - just count total bids per item)
        item_demands = defaultdict(int)
        for bidder, demands, commit_hash, stake_amount in self.round_bids:
            for item in demands:
                item_demands[item] += demands[item]
        
        
        # increase prices as necessary        
        end_clock_phase = self.increase_prices(item_demands)
    
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
        
        return result, end_clock_phase
    
    def increase_prices(self, item_demands: Dict[str, int]) -> bool:
        """
        Increase prices for items with excess demand and determine if clock phase should end.
        
        This function analyzes the demand for each item and increases prices
        for items where demand exceeds supply. The price increase is linear
        (by 1 unit) for each item with excess demand.
        
        Parameters
        ----------
        item_demands : Dict[str, int]
            Dictionary mapping item IDs to the total quantity demanded
            across all bidders in the current round.
            
        Returns
        -------
        bool
            True if the clock phase should end (no excess demand for any item),
            False if prices were increased and the clock phase should continue.
            
        Notes
        -----
        The function increases the price of each item by 1 unit if demand
        exceeds the available supply (deposit_amount) for that item. The
        clock phase ends when there is no excess demand for any item.
        """
        end_clock_phase = True
        for item, demand in item_demands.items():
            if demand > self.pools[item].deposit_amount:
                self.set_pool_price(item, self.pools[item].current_price + 1)
                end_clock_phase = False
        return end_clock_phase
    
    # ============================================================================
    # 6. BUNDLE & ALLOCATION
    # ============================================================================
    
    def submit_bundle(self, commit_hash: str, bundle_data: List[Dict[str, int]]) -> bool:
        """
        Submit a bundle of acceptable allocations during the proxy phase.
        
        This function allows proxies to submit bundles on behalf of bidders
        during the proxy phase. Each bundle contains multiple acceptable
        allocation options that the bidder would be willing to accept.
        
        Bundle data should be submitted as a list of dictionaries, where
        each dictionary represents one acceptable allocation. The keys are
        item IDs and the values are the maximum prices the bidder is willing
        to pay for those items.
        
        Parameters
        ----------
        commit_hash : str
            The commit hash associated with the bidder whose bundle is
            being submitted.
            
        bundle_data : List[Dict[str, int]]
            List of acceptable allocation bundles. Each bundle is a dictionary
            mapping item IDs to maximum willingness-to-pay prices.
            
        Returns
        -------
        bool
            True if the bundle was successfully submitted, False if the
            submission was rejected due to validation failures.
            
        Notes
        -----
        Only one bundle can be submitted per commit hash. The function
        validates that the commit hash is registered and that no bundle
        has already been submitted for this commit hash.
        
        Example
        -------
        bundle_data = [
            {"item_1": 82, "item_2": 89, "item_3": 937},
            {"item_2": 150, "item_3": 100},
            {"item_1": 100, "item_2": 100, "item_3": 100}
        ]
        """
        
        # Check that we are in the proxy phase
        if self.current_phase != "proxy":
            return False
        
        # Check if proxy is registered for this commit
        if commit_hash not in self.commit_proxy:
            return False
            
        # Check if bundle already exists for this commit (one bundle per commitHash)
        if commit_hash in self.bundles:
            return False  # Bundle already submitted for this commit
            
        # For now, just store the bundle data
        # In real implementation, this would validate bundle format
        self.bundles[commit_hash] = bundle_data
        return True
    
    def submit_allocation(self, allocator_id: str, allocation_data: List[Tuple[str, Set[str]]]) -> bool:
        """
        Submit an allocation proposal during the allocation phase.
        
        This function allows allocators to submit proposals for how items
        should be allocated among bidders based on the bundles submitted
        during the proxy phase.
        
        Parameters
        ----------
        allocator_id : str
            The identifier of the allocator submitting the proposal.
            
        allocation_data : List[Tuple[str, Set[str]]]
            List of tuples where each tuple contains a commit hash and
            a set of item IDs to allocate to that commit hash.
            
        Returns
        -------
        bool
            True if the allocation was successfully submitted, False if
            the submission was rejected.
            
        Notes
        -----
        This function is currently a placeholder. In a full implementation,
        it would validate the allocation data and store multiple allocation
        proposals for evaluation.
        """
        # Check that we are in the allocation phase
        if self.current_phase != "allocation":
            return False
        
        # Store the allocation proposal
        self.allocations.append({
            'allocator_id': allocator_id,
            'allocation': allocation_data
        })
        return True
    
    def allocate(self) -> bool:
        """
        Create a random allocation by selecting one bundle from each bidder.
        
        This function implements a simple random allocation strategy where
        one bundle is randomly selected from each bidder's submitted bundles.
        This is a placeholder implementation that could be replaced with
        more sophisticated allocation algorithms.
        
        Returns
        -------
        bool
            True if allocation was successfully created, False if no
            bundles are available for allocation.
            
        Notes
        -----
        This is a simplified allocation strategy that randomly selects
        bundles without considering optimization objectives. In a real
        implementation, this would be replaced with algorithms that
        maximize efficiency, fairness, or other objectives.
        """
        if not self.bundles:
            return False
        
        import random
        
        self.final_allocation = {
            commit_hash: random.choice(bundle_data)
            for commit_hash, bundle_data in self.bundles.items()
            if bundle_data
        }
        
        print(f"RANDOM ALLOCATION CREATED:")
        for commit_hash, bundle in self.final_allocation.items():
            print(f"  Commit {commit_hash[:16]}...: {bundle}")
        
        return True
    
    def get_allocation_cost(self, commit_hash: str) -> int:
        """
        Calculate the total cost of the allocated bundle for a given commit hash.
        
        This function computes the total cost of the items allocated to a
        bidder based on their commit hash. The cost is calculated using
        the current auction prices and the quantities allocated.
        
        Parameters
        ----------
        commit_hash : str
            The commit hash of the bidder whose allocation cost should
            be calculated.
            
        Returns
        -------
        int
            The total cost of the allocated bundle, or 0 if no allocation
            exists for the given commit hash.
            
        Notes
        -----
        The cost is calculated by multiplying the allocated quantity of
        each item by its current price in the auction.
        """
        if not self.final_allocation or commit_hash not in self.final_allocation:
            return 0
        
        allocated_bundle = self.final_allocation[commit_hash]
        return sum(self.prices[item] * quantity for item, quantity in allocated_bundle.items() if item in self.prices)
    
    # ============================================================================
    # 7. VALIDATION & UTILITIES
    # ============================================================================
    

    
    def enforce_minimum_spending(self, bidder_id: str, final_purchase_amount: int) -> bool:
        """
        Check if a bidder meets the minimum spending requirement.
        
        This function validates whether a bidder's final purchase amount
        meets the minimum spending requirement based on their original stake.
        The minimum spending requirement is calculated as a percentage of
        the bidder's stake.
        
        Parameters
        ----------
        bidder_id : str
            The identifier of the bidder whose spending should be validated.
            
        final_purchase_amount : int
            The actual amount the bidder is spending on allocated items.
            
        Returns
        -------
        bool
            True if the bidder meets the minimum spending requirement,
            False otherwise.
            
        Notes
        -----
        The minimum spending requirement is calculated as:
        minimum_required = bidder_stake * min_spending_ratio
        
        If the final purchase amount is less than this minimum, the
        bidder is considered to have violated the spending requirement
        and may face penalties.
        """
        bidder_stake = self.bidder_stake.get(bidder_id, 0)
        minimum_required = int(bidder_stake * self.min_spending_ratio)
        return final_purchase_amount >= minimum_required
    
    def dropout(self, bidder_id: str, refund_percentage: float = 0.8) -> bool:
        """
        Process a bidder's dropout with partial refund and penalty application.
        
        This function handles the dropout of a bidder from the auction,
        applying penalties and processing refunds. When a bidder drops out,
        they forfeit a portion of their stake as a penalty, with the
        remainder being refunded.
        
        The dropout process involves:
        1. Calculating the refund amount based on the refund percentage
        2. Applying the penalty (forfeited stake)
        3. Updating the bidder's stake to reflect the refund
        4. Transferring the penalty to the auction's wallet
        5. Logging the dropout details
        
        Parameters
        ----------
        bidder_id : str
            The identifier of the bidder dropping out.
            
        refund_percentage : float, optional
            The percentage of the original stake to refund to the bidder.
            The remainder is forfeited as a penalty. Defaults to 0.8 (80%).
            
        Returns
        -------
        bool
            True if the dropout was successfully processed, False if
            the bidder was not found in the system.
            
        Notes
        -----
        The penalty amount is transferred to the auction's wallet and
        can be used for various purposes such as covering auction costs
        or providing incentives to other participants.
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
        
        # Remove bidder from stake
        # del self.bidder_stake[bidder_id]
            
        print(f"Bidder {bidder_id} dropped out:")
        print(f"  Original stake: {original_stake}")
        print(f"  Refunded: {refund_amount}")
        print(f"  Penalty: {penalty}")
        
        return True
