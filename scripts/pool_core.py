"""
Simple Deposit Pool for Clock-Proxy Auction System.

This module simulates simple deposit pools that represent auction items.
Each pool is just a deposit of tokens that bidders can compete for.
"""

from typing import Dict
import numpy as np


class Pool:
    """Simple deposit pool representing an auction item."""
    
    def __init__(self, pool_id: str, token_x: str, token_y: str, 
                 deposit_amount: int, initial_price: float):
        """
        Initialize a deposit pool.
        
        Args:
            pool_id: Unique identifier for the pool
            token_x: Token being auctioned
            token_y: Numeraire token (common across all pools)
            deposit_amount: Amount of token_x deposited
            initial_price: Initial price of token_x in terms of token_y
        """
        self.pool_id = pool_id
        self.token_x = token_x
        self.token_y = token_y
        self.deposit_amount = deposit_amount
        self.current_price = initial_price
        
    def update_price(self, new_price: float):
        """Update pool price (auctioneer controlled)."""
        self.current_price = new_price
    
    def get_pool_info(self) -> Dict:
        """Get current pool information."""
        return {
            "pool_id": self.pool_id,
            "token_x": self.token_x,
            "token_y": self.token_y,
            "deposit_amount": self.deposit_amount,
            "current_price": self.current_price
        }
