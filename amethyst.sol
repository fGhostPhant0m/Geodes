// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract TaxToken is ERC20, Ownable {
    uint256 public taxPercentage; // Tax percentage (in basis points, 100 = 1%)
    address public taxCollector; // Address where tax is sent
    mapping(address => bool) public excludedFromTax; // Addresses excluded from tax

 
    event TaxCollectorUpdated(address newTaxCollector);
    event AddressExcludedFromTax(address excludedAddress);
    event AddressIncludedInTax(address includedAddress);

    constructor(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        uint256 _taxPercentage,
        address _taxCollector
    ) ERC20(name, symbol) Ownable(msg.sender) {
        require(_taxPercentage <= 2000, "Tax cannot exceed 20%");
        require(_taxCollector != address(0), "Tax collector cannot be zero address");
        
        taxPercentage = _taxPercentage;
        taxCollector = _taxCollector;
        
        // Exclude owner and tax collector from tax
        excludedFromTax[msg.sender] = true;
        excludedFromTax[_taxCollector] = true;
        
        // Mint initial supply to the owner
        _mint(msg.sender, initialSupply * 10 ** decimals());
    }

    function setTaxPercentage(uint256 _taxPercentage) external onlyOwner {
        require(_taxPercentage <= 2000, "Tax cannot exceed 20%");
        taxPercentage = _taxPercentage;
        emit TaxPercentageUpdated(_taxPercentage);
    }

    function setTaxCollector(address _taxCollector) external onlyOwner {
        require(_taxCollector != address(0), "Tax collector cannot be zero address");
        taxCollector = _taxCollector;
        emit TaxCollectorUpdated(_taxCollector);
    }

    function excludeFromTax(address account) external onlyOwner {
        excludedFromTax[account] = true;
        emit AddressExcludedFromTax(account);
    }

    function includeInTax(address account) external onlyOwner {
        excludedFromTax[account] = false;
        emit AddressIncludedInTax(account);
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal  virtual override {
        // If either sender or receiver is excluded from tax, or tax is 0, process normal transfer
        if (excludedFromTax[from] || excludedFromTax[to] || taxPercentage == 0) {
            super._transfer(from, to, amount);
            return;
        }

        // Calculate tax amount
        uint256 taxAmount = (amount * taxPercentage) / 10000;
        uint256 transferAmount = amount - taxAmount;

        // Transfer tax to collector
        if (taxAmount > 0) {
            super._transfer(from, taxCollector, taxAmount);
        }

        // Transfer remaining amount to recipient
        super._transfer(from, to, transferAmount);
    }
}