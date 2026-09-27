// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title StakeToken
/// @notice Plain ERC-20 with a fixed supply. 1,000,000 STK is minted once to `holder`
///         in the constructor. There is no owner, no mint and no burn.
contract StakeToken {
    string public constant name = "Stake Token";
    string public constant symbol = "STK";
    uint8 public constant decimals = 18;

    uint256 public immutable totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(address holder) {
        require(holder != address(0), "StakeToken: holder is zero address");
        uint256 supply = 1_000_000 * 10 ** uint256(decimals);
        totalSupply = supply;
        balanceOf[holder] = supply;
        emit Transfer(address(0), holder, supply);
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 current = allowance[from][msg.sender];
        if (current != type(uint256).max) {
            require(current >= value, "StakeToken: insufficient allowance");
            unchecked {
                _approve(from, msg.sender, current - value);
            }
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        require(from != address(0), "StakeToken: transfer from zero address");
        require(to != address(0), "StakeToken: transfer to zero address");
        uint256 fromBalance = balanceOf[from];
        require(fromBalance >= value, "StakeToken: insufficient balance");
        unchecked {
            balanceOf[from] = fromBalance - value;
        }
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }

    function _approve(address owner, address spender, uint256 value) internal {
        require(owner != address(0), "StakeToken: approve from zero address");
        require(spender != address(0), "StakeToken: approve to zero address");
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }
}
