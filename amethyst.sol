// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract TaxToken is ERC20, Ownable {
    uint256 public constant TAX_PERCENTAGE = 1000; // 10% tax (in basis points)
    address public taxCollector; // Address where tax is sent
    mapping(address => bool) public excludedFromTax; // Addresses excluded from tax

    event TaxCollectorUpdated(address newTaxCollector);
    event AddressExcludedFromTax(address excludedAddress);

    constructor(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        address _taxCollector
    ) ERC20(name, symbol) Ownable(msg.sender) {
        require(_taxCollector != address(0), "Tax collector cannot be zero address");
        
        taxCollector = _taxCollector;
        
        // Exclude owner and tax collector from tax
        excludedFromTax[msg.sender] = true;
        excludedFromTax[_taxCollector] = true;
        
        // Mint initial supply to the owner
        _mint(msg.sender, initialSupply);
    }
 
    function setTaxCollector(address _taxCollector) external onlyOwner {
        require(_taxCollector != address(0), "Tax collector cannot be zero address");
        if (taxCollector == msg.sender) {
            excludedFromTax[msg.sender] = false;
            }
        taxCollector = _taxCollector;
       
        emit TaxCollectorUpdated(_taxCollector);
    }

    function excludeFromTax(address account) external onlyOwner {
        excludedFromTax[account] = true;
        emit AddressExcludedFromTax(account);
    }

    // Override the transfer and transferFrom functions instead of _transfer
    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        address owner = _msgSender();
        _transferWithTax(owner, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        _transferWithTax(from, to, amount);
        return true;
    }

    // Create a new internal function for transfers with tax
    function _transferWithTax(address from, address to, uint256 amount) internal {
        require(from != address(0), "Transfer from the zero address");
        require(to != address(0), "Transfer to the zero address");

        // If either sender or receiver is excluded from tax, process normal transfer
        if (excludedFromTax[from] || excludedFromTax[to]) {
            _transfer(from, to, amount);
            return;
        }

        // Calculate tax amount (10% of transfer amount)
        uint256 taxAmount = (amount * TAX_PERCENTAGE) / 10000;
        uint256 transferAmount = amount - taxAmount;

        // Transfer tax to collector
        _transfer(from, taxCollector, taxAmount);

        // Transfer remaining amount to recipient
        _transfer(from, to, transferAmount);
    }

        function burn (uint256 amount) external {
            address user = msg.sender;
            _burn(user, amount);
         }

}
