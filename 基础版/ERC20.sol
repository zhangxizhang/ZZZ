// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

//not-authorized

//contract address:0xbc0bD081F3044091C9572Cb57D9afE8788A8A97b

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address _account) external view returns (uint256);
    function transfer(address _recipient, uint256 _amount) external returns (bool);
    function allowance(address _owner, address _spender) external view returns (uint256);
    function approve(address _spender, uint256 _amount) external returns (bool);
    function transferFrom(address _sender, address _recipient, uint256 _amount) external returns (bool);
    event Transfer(address indexed _from, address indexed _to, uint256 _value);
    event Approval(address indexed _owner,address indexed _spender,uint256 _value);
}

interface IERC20Metadata is IERC20 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

abstract contract Content {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
    function _msgData() internal view virtual returns (bytes calldata) {
        this;
        return msg.data;
    }
}

//通过继承实现其中的函数
contract ERC20 is Content, IERC20, IERC20Metadata {
    //account-->balances
	mapping(address => uint256) private erc20_balances;
	//owner-->spender-->value
    mapping(address => mapping(address => uint256)) private erc20_allowances;
    uint256 private erc20_totalSupply;
    string private erc20_Name;
    string private erc20_Symbol;

    constructor(string memory _name, string memory _symbol) {
        erc20_Name = _name;
        erc20_Symbol = _symbol;
    }
    function name() public view virtual override returns (string memory) {
        return erc20_Name;
    }
    function symbol() public view virtual override returns (string memory) {
        return erc20_Symbol;
    }
    function decimals() public view virtual override returns (uint8) {
        return 8;
    }
    function totalSupply() public view virtual override returns (uint256) {
        return erc20_totalSupply;
    }
    function balanceOf(address _account) public view virtual override returns (uint256) {
        return erc20_balances[_account];
    }
	
	//only for owner
    function transfer(address _recipient, uint256 _amount) public virtual override returns (bool) {
        erc20_transfer(_msgSender(), _recipient, _amount);
        return true;
    }
    function allowance(address _owner, address _spender) public view virtual override returns (uint256) {
        return erc20_allowances[_owner][_spender];
    }
    function approve(address _spender, uint256 _amount) public virtual override returns (bool) {
        erc20_approve(_msgSender(), _spender, _amount);
        return true;
    }
	
	//do by the spender 
    function transferFrom(address _sender, address _recipient, uint256 _amount) public virtual override returns (bool) {
        erc20_transfer(_sender, _recipient, _amount);
        uint256 currentAllowance = erc20_allowances[_sender][_msgSender()];
        require(
            currentAllowance >= _amount,
            "ERC20: transfer amount exceeds allowance"
        );
        erc20_approve(_sender, _msgSender(), currentAllowance - _amount);
        return true;
    }
    function erc20_increaseAllowance(address _spender, uint256 _addedValue) public virtual returns (bool) {
        erc20_approve(
            _msgSender(),
            _spender,
            erc20_allowances[_msgSender()][_spender] + _addedValue
        );
        return true;
    }
    function erc20_decreaseAllowance(address _spender, uint256 _subtractedValue) public virtual returns (bool) {
        uint256 currentAllowance = erc20_allowances[_msgSender()][_spender];
        require(
            currentAllowance >= _subtractedValue,
            "ERC20: decreased allowance below zero"
        );
        erc20_approve(_msgSender(), _spender, currentAllowance - _subtractedValue);
        return true;
    }
    function erc20_transfer(address _sender, address _recipient, uint256 _amount) internal virtual {
        require(_sender != address(0), "ERC20: transfer from the zero address");
        require(_recipient != address(0), "ERC20: transfer to the zero address");
        erc20_beforeTokenTransfer(_sender, _recipient, _amount);
        uint256 senderBalance = erc20_balances[_sender];
        require(
            senderBalance >= _amount,
            "ERC20: transfer amount exceeds balance"
        );
        erc20_balances[_sender] = senderBalance - _amount;
        erc20_balances[_recipient] += _amount;
        emit Transfer(_sender, _recipient, _amount);
    }
	
    function erc20_mint(address _account, uint256 _amount) internal virtual {
        require(_account != address(0), "ERC20: mint to the zero address");
        erc20_beforeTokenTransfer(address(0), _account, _amount);
        erc20_totalSupply += _amount;
        erc20_balances[_account] += _amount;
        emit Transfer(address(0), _account, _amount);
    }
    function erc20_burn(address _account, uint256 _amount) internal virtual {
        require(_account != address(0), "ERC20: burn from the zero address");
        erc20_beforeTokenTransfer(_account, address(0), _amount);
        uint256 accountBalance = erc20_balances[_account];
        require(accountBalance >= _amount, "ERC20: burn amount exceeds balance");
        erc20_balances[_account] = accountBalance - _amount;
        erc20_totalSupply -= _amount;
        emit Transfer(_account, address(0), _amount);
    }
    function erc20_approve(address _owner, address _spender, uint256 _amount) internal virtual {
        require(_owner != address(0), "ERC20: approve from the zero address");
        require(_spender != address(0), "ERC20: approve to the zero address");
        erc20_allowances[_owner][_spender] = _amount;
        emit Approval(_owner, _spender, _amount);
    }
    function erc20_beforeTokenTransfer(address _from, address _to, uint256 _amount) internal virtual {}
}

contract ERC20Token is ERC20 {
    constructor(uint256 initialSupply) ERC20("RWCH", "RWCH") {
        erc20_mint(msg.sender, initialSupply);
    }
}
