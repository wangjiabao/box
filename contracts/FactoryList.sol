// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

interface IBlindBoxUserVaultInit {
    function initialize(address owner_, address nft_, address usdt_) external;
}

contract BlindBoxVaultFactory is AccessControl {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    address public immutable implementation; // BlindBoxUserVault 模板实现合约
    address public immutable nft;            // BlindBoxNFT 地址
    address public immutable usdt;           // USDT 地址

    mapping(address => address) public vaultOf; // user => vault

    event VaultCreated(address indexed user, address indexed vault);

    constructor(address implementation_, address nft_, address usdt_) {
        require(implementation_ != address(0), "IMPL_0");
        require(nft_ != address(0), "NFT_0");
        require(usdt_ != address(0), "USDT_0");

        implementation = implementation_;
        nft = nft_;
        usdt = usdt_;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    /// 用户自己创建
    function createVault() external returns (address vault) {
        return _create(msg.sender);
    }

    /// 管理员帮指定用户创建
    function createVaultFor(address user) external onlyRole(ADMIN_ROLE) returns (address vault) {
        require(user != address(0), "USER_0");
        return _create(user);
    }

    function _create(address user) internal returns (address vault) {
        require(vaultOf[user] == address(0), "VAULT_EXISTS");

        vault = Clones.clone(implementation);
        IBlindBoxUserVaultInit(vault).initialize(user, nft, usdt);

        vaultOf[user] = vault;
        emit VaultCreated(user, vault);
    }
}
