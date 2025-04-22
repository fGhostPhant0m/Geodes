// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import  "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "./Support/SafeMath.sol";
import "./Geode.sol";
import "./IStrategy.sol";    

// The Sonic IndeX Geode Miner is a fork of 0xDao Garden by 0xDaov1
// The biggest change made from SushiSwap is using per second instead of per block for rewards
// This is to ensure consistent rewards despite block times
// The other biggest change was the removal of the migration functions
// It also has some view functions for Quality Of Life such as PoolId lookup and a query of all pool addresses.
// Note that it's ownable and the owner wields tremendous power. 
//  
// Have fun reading it. Hopefully it's bug-free. 
contract GeodeMiner is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of Geode
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accGeodePerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accGeodePerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. Geodes to distribute per block.
        uint256 lastRewardTime;  // Last block time that Geodes distribution occurs.
        uint256 accGeodePerShare; // Accumulated Geode per share, times 1e12. See below.
        address strategy;           //Which Protocol strategy is to be used. 
    }

    // such a cool token!
    Geode public Geode;
    address multiSig;
    // Geode tokens created per second.
    uint256 public immutable GeodePerSecond;
    
    uint256 public feeToDAO = 100; // 1% deposit fee
    uint256 public constant MaxAllocPoint = 4000;
    uint256 public ClaimFee;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    mapping(uint256 => mapping(address => uint256)) public pendingRewards;
    mapping (address => uint256) public poolId;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block time when Geode mining starts.
    uint256 public immutable startTime;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(
        Geode _Geode,
        uint256 _GeodePerSecond,
        uint256 _startTime,
        address _multiSig
    ) Ownable(msg.sender){
        Geode = _Geode;
        GeodePerSecond = _GeodePerSecond;
        startTime = _startTime;
        multiSig = _multiSig;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function checkForDuplicate(IERC20 _lpToken) internal view {
        uint256 length = poolInfo.length;
        for (uint256 _pid = 0; _pid < length; _pid++) {
            require(poolInfo[_pid].lpToken != _lpToken, "add: pool already exists!!!!");
        }

    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(uint256 _allocPoint, IERC20 _lpToken, address _strategy) external onlyOwner {
        require(_allocPoint <= MaxAllocPoint, "add: too many alloc points!!");

        checkForDuplicate(_lpToken); // ensure you cant add duplicate pools

        massUpdatePools();

        uint256 lastRewardTime = block.timestamp > startTime ? block.timestamp : startTime;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardTime: lastRewardTime,
            accGeodePerShare: 0,
            strategy: _strategy
        }));
        poolId[address(_lpToken)] = poolInfo.length - 1;
    }

    // Update the given pool's Geode allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint) external onlyOwner {
        require(_allocPoint <= MaxAllocPoint, "add: too many alloc points!!");

        massUpdatePools();

        totalAllocPoint = totalAllocPoint - poolInfo[_pid].allocPoint + _allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
    }
    
    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        _from = _from > startTime ? _from : startTime;
        if (_to < startTime) {
            return 0;
        }
        return _to - _from;
    }

    // View function to see pending Geodes on frontend.
    function pendingGeode(uint256 _pid, address _user) external returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accGeodePerShare = pool.accGeodePerShare;
           address _strategy = poolInfo[_pid].strategy;
        address LP = address(poolInfo[_pid].lpToken); 
        IStrategy strat = IStrategy(_strategy);
        uint256 lpSupply = strat._totalAssets(LP);
        if (block.timestamp > pool.lastRewardTime && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
            uint256 GeodeReward = multiplier.mul(GeodePerSecond).mul(pool.allocPoint).div(totalAllocPoint);
            accGeodePerShare = accGeodePerShare.add(GeodeReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accGeodePerShare).div(1e12).sub(user.rewardDebt);
        }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        address _strategy = poolInfo[_pid].strategy; 
        address lp = address(poolInfo[_pid].lpToken);
          IStrategy strat = IStrategy(_strategy);
        
        uint256  lpSupply  = strat._totalAssets(lp);
        if (lpSupply == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
        uint256 GeodeReward = multiplier.mul(GeodePerSecond).mul(pool.allocPoint).div(totalAllocPoint);

        
        Geode.mint(address(this), GeodeReward);

        pool.accGeodePerShare = pool.accGeodePerShare.add(GeodeReward.mul(1e12).div(lpSupply));
        pool.lastRewardTime = block.timestamp;
    }

        function deposit(uint256 _pid, uint256 _amount) public {
            PoolInfo storage pool = poolInfo[_pid]; 
            UserInfo storage user = userInfo[_pid][msg.sender];
            updatePool(_pid);
            
            // If user has pending rewards, add them to pendingRewards.
            if (user.amount > 0) {
                uint256 pending = user.amount.mul(pool.accGeodePerShare).div(1e12).sub(user.rewardDebt);
                if (pending > 0) {
                    pendingRewards[_pid][msg.sender] = pendingRewards[_pid][msg.sender].add(pending);
                }
            }
            
            // Process deposit
            if (_amount > 0) {
                pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
                
                // Calculate and transfer deposit fee
                uint256 depositFee = _amount.mul(feeToDAO).div(10000);
                pool.lpToken.safeTransfer(multiSig, depositFee);
                
                // Add amount after fee to user balance
                user.amount = user.amount.add(_amount.sub(depositFee));
                
                // Deposit to strategy
                address _strategy = pool.strategy;
                address LP = address(pool.lpToken);
                
                // Reset allowance if needed
                resetAllowance(_strategy, LP);
                
                // Deposit remaining tokens to strategy
                IStrategy(pool.strategy).deposit(LP, _amount.sub(depositFee));
            }
            
            user.rewardDebt = user.amount.mul(pool.accGeodePerShare).div(1e12);
            emit Deposit(msg.sender, _pid, _amount);
        }

    // Withdraw LP tokens from MasterChef.
        function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        
        updatePool(_pid);
        
        // Add pending rewards to the pendingRewards mapping instead of sending immediately
        uint256 pending = user.amount.mul(pool.accGeodePerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            pendingRewards[_pid][msg.sender] = pendingRewards[_pid][msg.sender].add(pending);
        }
        
        // Process withdraw
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            
            address _strategy = pool.strategy;
            address LP = address(pool.lpToken);
            IStrategy(_strategy).withdraw(_amount, LP);
            
           
            pool.lpToken.safeTransfer(msg.sender, _amount);
        }
        
        user.rewardDebt = user.amount.mul(pool.accGeodePerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

   
    function harvestAll() public payable nonReentrant {
        uint256 length = poolInfo.length;
        uint256 totalPending = 0;
        
        // First pass: calculate total pending rewards across all pools
        for (uint256 pid = 0; pid < length; ++pid) {
            UserInfo storage user = userInfo[pid][msg.sender];
            if (user.amount > 0) {
                PoolInfo storage pool = poolInfo[pid];
                updatePool(pid);
                
                // Calculate new pending rewards
                uint256 newPending = user.amount.mul(pool.accGeodePerShare).div(1e12).sub(user.rewardDebt);
                // Add previously accumulated rewards
                uint256 poolPending = newPending.add(pendingRewards[pid][msg.sender]);
                
                // Add to total
                if (poolPending > 0) {
                    totalPending = totalPending.add(poolPending);
                }
            }
        }
        
        // Check minimum threshold
        require(totalPending >= minClaimThreshold, "Claim amount below minimum threshold");
        
        // Calculate fee if enabled
        uint256 sTokenFee = 0;
        if (feeOnClaimEnabled && totalPending > 0) {
            uint256 geodePriceInS = geodeOracle.twap(address(geode), 1e18);
            sTokenFee = (geodePriceInS.mul(totalPending).div(1e18)).mul(feePercentage).div(10000);
            require(msg.value >= sTokenFee, "Insufficient S for fee");
        } else {
            require(msg.value == 0, "Fee not required when disabled");
        }
        
        // Second pass: update reward debts and clear pending rewards
        if (totalPending > 0) {
            // Transfer rewards
            safeGeodeTransfer(msg.sender, totalPending);
            
            // Process fee payment
            if (feeOnClaimEnabled) {
                // Refund excess
                if (msg.value > sTokenFee) {
                    (bool success, ) = msg.sender.call{value: msg.value - sTokenFee}("");
                    require(success, "Refund failed");
                }
                
                // Forward fee to treasury
                if (sTokenFee > 0) {
                    (bool sent, ) = multiSig.call{value: sTokenFee}("");
                    require(sent, "Failed to send fee");
                }
            }
            
            // Update all reward debts and clear pending rewards
            for (uint256 pid = 0; pid < length; ++pid) {
                UserInfo storage user = userInfo[pid][msg.sender];
                if (user.amount > 0) {
                    PoolInfo storage pool = poolInfo[pid];
                    // Reset pending rewards
                    pendingRewards[pid][msg.sender] = 0;
                    // Update reward debt
                    user.rewardDebt = user.amount.mul(pool.accGeodePerShare).div(1e12);
                }
            }
        }
}

        // Fee-on-claim harvest function that accepts S as payment
    function harvest(uint256 _pid) public payable nonReentrant {
    PoolInfo storage pool = poolInfo[_pid]; 
    UserInfo storage user = userInfo[_pid][msg.sender];
    updatePool(_pid);
    
    // Calculate new pending rewards
    uint256 newPending = user.amount.mul(pool.accGeodePerShare).div(1e12).sub(user.rewardDebt);
    
    // Add previously accumulated rewards
    uint256 totalPending = newPending.add(pendingRewards[_pid][msg.sender]);
    
    // Ensure minimum threshold is met
    require(totalPending >= minClaimThreshold, "Claim amount below minimum threshold");
    
    if (totalPending > 0) {
        // Reset pending rewards
        pendingRewards[_pid][msg.sender] = 0;
        
        // Calculate fee if enabled
        uint256 sTokenFee = 0;
        if (feeOnClaimEnabled) {
            uint256 geodePriceInS = geodeOracle.twap(address(geode), 1e18);
            sTokenFee = (geodePriceInS.mul(totalPending).div(1e18)).mul(feePercentage).div(2000);
            require(msg.value >= sTokenFee, "Insufficient S for fee");
        } else {
            require(msg.value == 0, "Fee not required when disabled");
        }
        
        // Transfer rewards
        safeGeodeTransfer(msg.sender, totalPending);
        
        // Handle fee processing
        if (feeOnClaimEnabled) {
            // Refund excess
            if (msg.value > sTokenFee) {
                (bool success, ) = msg.sender.call{value: msg.value - sTokenFee}("");
                require(success, "Refund failed");
            }
            
            // Send fee to treasury
            if (sTokenFee > 0) {
                (bool sent, ) = multiSig.call{value: sTokenFee}("");
                require(sent, "Failed to send fee");
            }
        }
    }
    
    // Update reward debt
    user.rewardDebt = user.amount.mul(pool.accGeodePerShare).div(1e12);
}


    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
         address _strategy = poolInfo[_pid].strategy;
        address LP = address(poolInfo[_pid].lpToken); 
        IStrategy strat = IStrategy(_strategy);
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint oldUserAmount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;

        strat.withdraw(oldUserAmount, LP);
        pool.lpToken.safeTransfer(address(msg.sender), oldUserAmount);
        emit EmergencyWithdraw(msg.sender, _pid, oldUserAmount);

    }

        // Simple setter for fee on claim percentage
        function setFeeOnClaim(uint256 _feeOnClaim) external onlyOwner {
            require(_feeOnClaim <= 5000, "Fee too high"); // Max 50%
            feeOnClaim = _feeOnClaim;
        }

        // Toggle fee on claim on/off
        function setFeeOnClaimEnabled(bool _enabled) external onlyOwner {
            feeOnClaimEnabled = _enabled;
        }

        // Set minimum claim threshold
        function setMinClaimThreshold(uint256 _minClaimThreshold) external onlyOwner {
            minClaimThreshold = _minClaimThreshold;
        }

    // Safe Geode transfer function, just in case if rounding error causes pool to not have enough Geodes.
    function safeGeodeTransfer(address _to, uint256 _amount) internal {
        uint256 GeodeBal = Geode.balanceOf(address(this));
        if (_amount > GeodeBal) {
            Geode.transfer(_to, GeodeBal);
        } else {
            Geode.transfer(_to, _amount);
        }
    }
  
    function resetAllowance(address strat, address lp) internal {
                 IERC20(lp).approve(strat, 0);
              IERC20(lp).approve(strat, type(uint).max);
    }
  
    function getPID(address lp) external view returns (uint256 pid){
        pid = poolId[lp]; 
    }
  
    function readPoolList() external view returns (IERC20[] memory ){
         uint256 length = poolInfo.length;
         IERC20 [] memory result = new IERC20 [](length);
           for (uint256 i = 0; i < length; ++i){
                result[i] = poolInfo[i].lpToken;               
           }
            return result;   
            }
     function getPoolInfo(uint256 pid) external view returns (IERC20 _lpToken, uint256 allocPoint, uint256 lastRewardTime, uint256 accGeodePerShare, address strategy ) {
           _lpToken = poolInfo[pid].lpToken;
        allocPoint = poolInfo[pid].allocPoint;
        lastRewardTime = poolInfo[pid].lastRewardTime;
        accGeodePerShare = poolInfo[pid].accGeodePerShare;
        strategy = poolInfo[pid].strategy; 
        }

            
    }




