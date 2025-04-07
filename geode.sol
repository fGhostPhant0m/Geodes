// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

interface ITaxToken {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function excludeFromTax(address account) external;
}

contract Geode is ERC20, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    ITaxToken public immutable taxToken;
    
    // Minimum deposit amount to prevent dust attacks
    uint256 public minDepositAmount;
    
    event Deposit(address indexed user, uint256 taxTokenAmount, uint256 wrappedAmount);
    event Withdraw(address indexed user, uint256 wrappedAmount, uint256 taxTokenAmount);
    event MinDepositAmountUpdated(uint256 newMinimum);
    event TokensRescued(address token, address to, uint256 amount);

    constructor(
        address _taxToken,
        string memory name,
        string memory symbol,
        uint256 _minDepositAmount
    ) ERC20(name, symbol) Ownable(msg.sender) {
        require(_taxToken != address(0), "Invalid tax token address");
        taxToken = ITaxToken(_taxToken);
        minDepositAmount = _minDepositAmount;
        
    }

    /**
     * @notice Calculate shares to mint for a given amount of tax tokens
     * @param _amount Amount of tax tokens
     * @return Number of shares to mint
     */
    function _getSharesForDeposit(uint256 _amount) internal view returns (uint256) {
        uint256 totalTokens = taxToken.balanceOf(address(this));
        uint256 totalShares = totalSupply();
        
        // For the first deposit, use 1:1 ratio
        if (totalShares == 0 || totalTokens == 0) {
            return _amount;
        }
        
        // Calculate shares based on current ratio
        return (_amount * totalShares) / totalTokens;
    }

    /**
     * @notice Calculate tax tokens to return for a given amount of shares
     * @param _shares Amount of shares
     * @return Number of tax tokens to return
     */
    function _getTokensForShares(uint256 _shares) internal view returns (uint256) {
        uint256 totalTokens = taxToken.balanceOf(address(this));
        uint256 totalShares = totalSupply();
        
        if (totalShares == 0) {
            return 0;
        }
        
        // Calculate tokens based on current ratio
        return (_shares * totalTokens) / totalShares;
    }

    /**
     * @notice Deposit tax tokens and receive wrapped tokens
     * @param _amount Amount of tax tokens to deposit
     */
    function deposit(uint256 _amount) external nonReentrant whenNotPaused {
        require(_amount >= minDepositAmount, "Amount below minimum");
        
        // Check allowance
        uint256 allowance = taxToken.allowance(msg.sender, address(this));
        require(allowance >= _amount, "Insufficient allowance");
        
        // Get balance before transfer to handle fee-on-transfer tokens correctly
        uint256 balanceBefore = taxToken.balanceOf(address(this));
        
        // Transfer tax tokens to this contract
        SafeERC20.safeTransferFrom(IERC20(address(taxToken)), msg.sender, address(this), _amount);
        
        // Calculate actual amount received (handles potential tax)
        uint256 actualReceived = taxToken.balanceOf(address(this)) - balanceBefore;
        require(actualReceived > 0, "No tokens received");
        
        // Calculate shares
        uint256 shares = _getSharesForDeposit(actualReceived);
        require(shares > 0, "Shares calculation error");
        
        // Mint wrapped tokens to user
        _mint(msg.sender, shares);
        
        emit Deposit(msg.sender, actualReceived, shares);
    }

    /**
     * @notice Withdraw tax tokens by burning wrapped tokens
     * @param _shares Amount of wrapped tokens to burn
     */
    function withdraw(uint256 _shares) external nonReentrant whenNotPaused {
        require(_shares > 0, "Cannot withdraw 0");
        require(balanceOf(msg.sender) >= _shares, "Insufficient balance");
        
        // Calculate tokens to return
        uint256 taxTokenAmount = _getTokensForShares(_shares);
        require(taxTokenAmount > 0, "Amount calculation error");
        
        // Burn wrapped tokens first (checks-effects-interactions pattern)
        _burn(msg.sender, _shares);
        
        // Transfer tax tokens back to user
        SafeERC20.safeTransfer(IERC20(address(taxToken)), msg.sender, taxTokenAmount);
        
        emit Withdraw(msg.sender, _shares, taxTokenAmount);
    }

    /**
     * @notice Get the current exchange rate between wrapper and tax token
     * @return Current exchange rate (in terms of how many tax tokens 1 wrapper token is worth)
     */
    function exchangeRate() external view returns (uint256) {
        uint256 totalTokens = taxToken.balanceOf(address(this));
        uint256 totalShares = totalSupply();
        
        if (totalShares == 0) {
            return 0;
        }
        
        return (totalTokens * 1e18) / totalShares;
    }

    /**
     * @notice Get the amount of tax tokens that would be received for burning shares
     * @param _shares Amount of wrapped tokens
     * @return Amount of tax tokens that would be received
     */
    function previewWithdraw(uint256 _shares) external view returns (uint256) {
        return _getTokensForShares(_shares);
    }

    /**
     * @notice Get the amount of shares that would be minted for depositing tokens
     * @param _amount Amount of tax tokens
     * @return Amount of shares that would be minted
     */
    function previewDeposit(uint256 _amount) external view returns (uint256) {
        return _getSharesForDeposit(_amount);
    }

    /**
     * @notice Set minimum deposit amount
     * @param _minAmount New minimum amount
     */
    function setMinDepositAmount(uint256 _minAmount) external onlyOwner {
        minDepositAmount = _minAmount;
        emit MinDepositAmountUpdated(_minAmount);
    }

    /**
     * @notice Pause deposits and withdrawals
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause deposits and withdrawals
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Rescue tokens accidentally sent to this contract (except taxToken)
     * @param tokenAddress The token address to rescue
     * @param to Address to send the tokens to
     * @param amount Amount of tokens to rescue
     */
    function rescueTokens(address tokenAddress, address to, uint256 amount) external onlyOwner {
        require(tokenAddress != address(taxToken), "Cannot rescue base token");
        require(to != address(0), "Cannot send to zero address");
        
        SafeERC20.safeTransfer(IERC20(tokenAddress), to, amount);
        emit TokensRescued(tokenAddress, to, amount);
    }
}