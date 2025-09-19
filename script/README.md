# Deployment Scripts

This directory contains deployment scripts for the Clock-Proxy Auction system.

## DeployCPA.s.sol

Deploys the core CPA contracts with proper V4 hook address mining:
- CPAManager: Main auction manager contract
- CPAHook: V4 hook contract for pool control (with address mining)

### Prerequisites

1. Environment Setup:
   ```bash
   # Copy the example environment file
   cp env.example .env
   
   # Edit .env with your values
   nano .env
   ```

2. Required Environment Variables:
   - `PRIVATE_KEY`: Your private key for deployment
   - `RPC_URL`: RPC endpoint for target network
   - `POOL_MANAGER_ADDRESS`: Uniswap V4 PoolManager address
   - `PROTOCOL_OWNER`: (Optional) Protocol owner address

3. Network Requirements:
   - Uniswap V4 must be deployed on your target network
   - Sufficient ETH for deployment gas costs
   - Access to RPC endpoint

### Quick Start

1. Clone and Setup:
   ```bash
   git clone <repository-url>
   cd v4-template
   cp env.example .env
   # Edit .env with your values
   ```

2. Deploy to Testnet:
   ```bash
   forge script script/DeployCPA.s.sol \
     --rpc-url $RPC_URL \
     --private-key $PRIVATE_KEY \
     --broadcast \
     --verify \
     --etherscan-api-key $ETHERSCAN_API_KEY
   ```

### Environment Configuration

The `.env` file should contain:

```bash
# Required
PRIVATE_KEY=0x...
RPC_URL=https://sepolia.infura.io/v3/YOUR_PROJECT_ID
POOL_MANAGER_ADDRESS=0x...

# Optional
PROTOCOL_OWNER=0x...
ETHERSCAN_API_KEY=YOUR_API_KEY
```

### Deployment Process

The script performs these steps:

1. Load Environment: Reads private key, RPC URL, and PoolManager address
2. Deploy CPAHook: Uses HookMiner for proper V4 hook address mining
3. Deploy CPAManager: Deploys with PoolManager and CPAHook addresses
4. Configure Contracts: Sets auction manager in CPAHook
5. Save Addresses: Writes deployment addresses to `deployments.txt`

### Deployment Commands

#### Testnet Deployment
```bash
# Deploy to Sepolia
forge script script/DeployCPA.s.sol \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

#### Mainnet Deployment
```bash
# Deploy to Ethereum mainnet
forge script script/DeployCPA.s.sol \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

#### Dry Run (Simulation)
```bash
# Simulate without broadcasting
forge script script/DeployCPA.s.sol \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

### Post-Deployment

After successful deployment:

1. Contract Addresses: Saved to `deployments.txt`
2. Verification: Contracts verified on Etherscan
3. Configuration: Contracts properly linked

### Network-Specific Notes

#### Ethereum Sepolia
```bash
RPC_URL=https://sepolia.infura.io/v3/YOUR_PROJECT_ID
POOL_MANAGER_ADDRESS=0x... # V4 PoolManager on Sepolia
```

#### Base Sepolia
```bash
RPC_URL=https://sepolia.base.org
POOL_MANAGER_ADDRESS=0x... # V4 PoolManager on Base Sepolia
```

#### Local Development
```bash
RPC_URL=http://localhost:8545
POOL_MANAGER_ADDRESS=0x... # Local V4 PoolManager
```

### Security Notes

- Never commit `.env` to version control
- Use testnet first before mainnet deployment
- Verify addresses match expected deployment
- Keep private keys secure

### Troubleshooting

It's a large contract and protocol. 

Common Issues:
- Missing PoolManager: Ensure V4 is deployed on your network
- Insufficient funds: Check deployer has enough ETH
- Hook mining fails: Verify PoolManager address is correct
- RPC issues: Verify network connectivity

Gas Optimization:
- Deploy during low congestion periods
- Monitor gas prices before deployment
- Consider gas price optimization tools
