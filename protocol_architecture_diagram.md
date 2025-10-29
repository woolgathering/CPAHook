# Rok Protocol Architecture Diagram

```mermaid
%%{init: {'theme':'base', 'themeVariables': {'fontFamily': 'Arial, sans-serif'}}}%%
graph TB
    %% Core Protocol Components
    CPAManager[CPAManager<br/>Auction Logic & State]
    CPAHook[CPAHook<br/>Pool Control]
    PoolManager[Pool Manager<br/>Asset Pools]
    
    %% Asset Pools
    AssetPools[Asset Pools<br/>A<>USDC, B<>USDC, C<>USDC]
    
    %% Participants
    Auctioneer[Auctioneer]
    Bidders[Bidders]
    Proxies[Proxies]
    Allocators[Allocators]
    
    %% %% Auction Phases
    %% ClockPhase[Clock Phase<br/>Price Discovery]
    %% ProxyPhase[Proxy Phase<br/>Bundle Submission]
    %% AllocationPhase[Allocation Phase<br/>Competition]
    %% SettlementPhase[Settlement Phase<br/>Token Distribution]
    
    %% Core Relationships
    CPAManager -->|controls| CPAHook
    CPAHook -->|attached to| AssetPools
    PoolManager -->|contains| AssetPools
    CPAManager -->|holds assets & numeraire| PoolManager
    
    %% Participant Interactions
    Auctioneer -->|creates| CPAManager
    Bidders -->|bids| CPAManager
    Proxies -->|bundles| CPAManager
    Allocators -->|allocations| CPAManager
    
    %% Privacy System
    Bidders -.->|commit-reveal| Proxies
    
    %% Phase Flow
    %% ClockPhase --> ProxyPhase
    %% ProxyPhase --> AllocationPhase
    %% AllocationPhase --> SettlementPhase
    
    %% Pool Operations
    CPAManager -->|price manipulation| AssetPools
    CPAManager -->|settlement| AssetPools
    
    %% Styling
    classDef core fill:#e1f5fe,stroke:#01579b,stroke-width:3px
    classDef pools fill:#f3e5f5,stroke:#4a148c,stroke-width:2px
    classDef participants fill:#e8f5e8,stroke:#1b5e20,stroke-width:2px
    classDef phases fill:#fce4ec,stroke:#880e4f,stroke-width:2px
    
    class CPAManager,CPAHook,PoolManager core
    class AssetPools pools
    class Auctioneer,Bidders,Proxies,Allocators participants
    class ClockPhase,ProxyPhase,AllocationPhase,SettlementPhase phases
```

## Key Relationships

### Core Architecture
- **CPAManager** manages auction logic and state across multiple concurrent auctions
- **CPAHook** controls asset pools during auctions, blocking normal trading
- **Pool Manager** contains the asset pools that facilitate price discovery and settlement
- Single CPAHook serves all asset pools for efficiency

### Participant Roles
- **Auctioneer**: Creates and configures auctions
- **Bidders**: Participate in price discovery through iterative bidding
- **Proxies**: Submit bundles on behalf of bidders using commit-reveal privacy
- **Allocators**: Compete to find optimal allocations and earn rewards

### Auction Flow
1. **Clock Phase**: Price discovery through iterative bidding
2. **Proxy Phase**: Bundle submission with privacy-preserving commit-reveal
3. **Allocation Phase**: Competitive allocation determination
4. **Settlement Phase**: Token distribution and claiming

### Key Features
- **Privacy-Preserving**: Commit-reveal system maintains bidder-proxy anonymity
- **Multi-Asset**: Support for auctions across multiple token pairs
- **Competitive Allocation**: Allocator competition with on-chain rewards
- **Uniswap V4 Integration**: Built using V4 hooks for pool control
