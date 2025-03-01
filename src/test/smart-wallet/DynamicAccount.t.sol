// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

// Test utils
import "../utils/BaseTest.sol";
import "@thirdweb-dev/dynamic-contracts/src/interface/IExtension.sol";
import { IAccountPermissions } from "contracts/extension/interface/IAccountPermissions.sol";
import { AccountPermissions } from "contracts/extension/upgradeable/AccountPermissions.sol";
import { AccountExtension } from "contracts/prebuilts/account/utils/AccountExtension.sol";
import { TWProxy } from "contracts/infra/TWProxy.sol";

// Account Abstraction setup for smart wallets.
import { EntryPoint, IEntryPoint } from "contracts/prebuilts/account/utils/Entrypoint.sol";
import { UserOperation } from "contracts/prebuilts/account/utils/UserOperation.sol";

// Target
import { Account as SimpleAccount } from "contracts/prebuilts/account/non-upgradeable/Account.sol";
import { DynamicAccountFactory, DynamicAccount } from "contracts/prebuilts/account/dynamic/DynamicAccountFactory.sol";

/// @dev This is a dummy contract to test contract interactions with Account.
contract Number {
    uint256 public num;

    function setNum(uint256 _num) public {
        num = _num;
    }

    function doubleNum() public {
        num *= 2;
    }

    function incrementNum() public {
        num += 1;
    }
}

contract NFTRejector {
    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) public virtual returns (bytes4) {
        revert("NFTs not accepted");
    }
}

contract DynamicAccountTest is BaseTest {
    // Target contracts
    EntryPoint private constant entrypoint = EntryPoint(payable(0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789));
    DynamicAccountFactory private accountFactory;

    // Mocks
    Number internal numberContract;

    // Test params
    uint256 private accountAdminPKey = 100;
    address private accountAdmin;

    uint256 private accountSignerPKey = 200;
    address private accountSigner;

    uint256 private nonSignerPKey = 300;
    address private nonSigner;

    bytes internal data = bytes("");

    // UserOp terminology: `sender` is the smart wallet.
    address private sender = 0x96b1d554981298ED415f2D5788A6D093A39eECfF;
    address payable private beneficiary = payable(address(0x45654));

    bytes32 private uidCache = bytes32("random uid");

    address internal factoryImpl;

    event AccountCreated(address indexed account, address indexed accountAdmin);

    function _prepareSignature(IAccountPermissions.SignerPermissionRequest memory _req)
        internal
        view
        returns (bytes32 typedDataHash)
    {
        bytes32 typehashSignerPermissionRequest = keccak256(
            "SignerPermissionRequest(address signer,uint8 isAdmin,address[] approvedTargets,uint256 nativeTokenLimitPerTransaction,uint128 permissionStartTimestamp,uint128 permissionEndTimestamp,uint128 reqValidityStartTimestamp,uint128 reqValidityEndTimestamp,bytes32 uid)"
        );
        bytes32 nameHash = keccak256(bytes("Account"));
        bytes32 versionHash = keccak256(bytes("1"));
        bytes32 typehashEip712 = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        bytes32 domainSeparator = keccak256(abi.encode(typehashEip712, nameHash, versionHash, block.chainid, sender));

        bytes memory encodedRequestStart = abi.encode(
            typehashSignerPermissionRequest,
            _req.signer,
            _req.isAdmin,
            keccak256(abi.encodePacked(_req.approvedTargets)),
            _req.nativeTokenLimitPerTransaction
        );

        bytes memory encodedRequestEnd = abi.encode(
            _req.permissionStartTimestamp,
            _req.permissionEndTimestamp,
            _req.reqValidityStartTimestamp,
            _req.reqValidityEndTimestamp,
            _req.uid
        );

        bytes32 structHash = keccak256(bytes.concat(encodedRequestStart, encodedRequestEnd));
        typedDataHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _signSignerPermissionRequest(IAccountPermissions.SignerPermissionRequest memory _req)
        internal
        view
        returns (bytes memory signature)
    {
        bytes32 typedDataHash = _prepareSignature(_req);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(accountAdminPKey, typedDataHash);
        signature = abi.encodePacked(r, s, v);
    }

    function _setupUserOp(
        uint256 _signerPKey,
        bytes memory _initCode,
        bytes memory _callDataForEntrypoint
    ) internal returns (UserOperation[] memory ops) {
        uint256 nonce = entrypoint.getNonce(sender, 0);

        // Get user op fields
        UserOperation memory op = UserOperation({
            sender: sender,
            nonce: nonce,
            initCode: _initCode,
            callData: _callDataForEntrypoint,
            callGasLimit: 5_000_000,
            verificationGasLimit: 5_000_000,
            preVerificationGas: 5_000_000,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            paymasterAndData: bytes(""),
            signature: bytes("")
        });

        // Sign UserOp
        bytes32 opHash = EntryPoint(entrypoint).getUserOpHash(op);
        bytes32 msgHash = ECDSA.toEthSignedMessageHash(opHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_signerPKey, msgHash);
        bytes memory userOpSignature = abi.encodePacked(r, s, v);

        address recoveredSigner = ECDSA.recover(msgHash, v, r, s);
        address expectedSigner = vm.addr(_signerPKey);
        assertEq(recoveredSigner, expectedSigner);

        op.signature = userOpSignature;

        // Store UserOp
        ops = new UserOperation[](1);
        ops[0] = op;
    }

    function _setupUserOpWithSender(
        bytes memory _initCode,
        bytes memory _callDataForEntrypoint,
        address _sender
    ) internal returns (UserOperation[] memory ops) {
        uint256 nonce = entrypoint.getNonce(_sender, 0);

        // Get user op fields
        UserOperation memory op = UserOperation({
            sender: _sender,
            nonce: nonce,
            initCode: _initCode,
            callData: _callDataForEntrypoint,
            callGasLimit: 5_000_000,
            verificationGasLimit: 5_000_000,
            preVerificationGas: 5_000_000,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            paymasterAndData: bytes(""),
            signature: bytes("")
        });

        // Sign UserOp
        bytes32 opHash = EntryPoint(entrypoint).getUserOpHash(op);
        bytes32 msgHash = ECDSA.toEthSignedMessageHash(opHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(accountAdminPKey, msgHash);
        bytes memory userOpSignature = abi.encodePacked(r, s, v);

        address recoveredSigner = ECDSA.recover(msgHash, v, r, s);
        address expectedSigner = vm.addr(accountAdminPKey);
        assertEq(recoveredSigner, expectedSigner);

        op.signature = userOpSignature;

        // Store UserOp
        ops = new UserOperation[](1);
        ops[0] = op;
    }

    function _setupUserOpExecuteWithSender(
        bytes memory _initCode,
        address _target,
        uint256 _value,
        bytes memory _callData,
        address _sender
    ) internal returns (UserOperation[] memory) {
        bytes memory callDataForEntrypoint = abi.encodeWithSignature(
            "execute(address,uint256,bytes)",
            _target,
            _value,
            _callData
        );

        return _setupUserOpWithSender(_initCode, callDataForEntrypoint, _sender);
    }

    function _setupUserOpExecute(
        uint256 _signerPKey,
        bytes memory _initCode,
        address _target,
        uint256 _value,
        bytes memory _callData
    ) internal returns (UserOperation[] memory) {
        bytes memory callDataForEntrypoint = abi.encodeWithSignature(
            "execute(address,uint256,bytes)",
            _target,
            _value,
            _callData
        );

        return _setupUserOp(_signerPKey, _initCode, callDataForEntrypoint);
    }

    function _setupUserOpExecuteBatch(
        uint256 _signerPKey,
        bytes memory _initCode,
        address[] memory _target,
        uint256[] memory _value,
        bytes[] memory _callData
    ) internal returns (UserOperation[] memory) {
        bytes memory callDataForEntrypoint = abi.encodeWithSignature(
            "executeBatch(address[],uint256[],bytes[])",
            _target,
            _value,
            _callData
        );

        return _setupUserOp(_signerPKey, _initCode, callDataForEntrypoint);
    }

    /// @dev Returns the salt used when deploying an Account.
    function _generateSalt(address _admin, bytes memory _data) internal view virtual returns (bytes32) {
        return keccak256(abi.encode(_admin, _data));
    }

    function setUp() public override {
        super.setUp();

        // Setup signers.
        accountAdmin = vm.addr(accountAdminPKey);
        vm.deal(accountAdmin, 100 ether);

        accountSigner = vm.addr(accountSignerPKey);
        nonSigner = vm.addr(nonSignerPKey);

        // Setup contracts
        address _deployedEntrypoint = address(new EntryPoint());
        vm.etch(address(entrypoint), bytes(_deployedEntrypoint.code));

        // Setting up default extension.
        IExtension.Extension memory defaultExtension;

        defaultExtension.metadata = IExtension.ExtensionMetadata({
            name: "AccountExtension",
            metadataURI: "ipfs://AccountExtension",
            implementation: address(new AccountExtension())
        });

        defaultExtension.functions = new IExtension.ExtensionFunction[](9);

        defaultExtension.functions[0] = IExtension.ExtensionFunction(
            AccountExtension.supportsInterface.selector,
            "supportsInterface(bytes4)"
        );
        defaultExtension.functions[1] = IExtension.ExtensionFunction(
            AccountExtension.execute.selector,
            "execute(address,uint256,bytes)"
        );
        defaultExtension.functions[2] = IExtension.ExtensionFunction(
            AccountExtension.executeBatch.selector,
            "executeBatch(address[],uint256[],bytes[])"
        );
        defaultExtension.functions[3] = IExtension.ExtensionFunction(
            ERC721Holder.onERC721Received.selector,
            "onERC721Received(address,address,uint256,bytes)"
        );
        defaultExtension.functions[4] = IExtension.ExtensionFunction(
            ERC1155Holder.onERC1155Received.selector,
            "onERC1155Received(address,address,uint256,uint256,bytes)"
        );
        defaultExtension.functions[5] = IExtension.ExtensionFunction(
            bytes4(0), // Selector for `receive()` function.
            "receive()"
        );
        defaultExtension.functions[6] = IExtension.ExtensionFunction(
            AccountExtension.isValidSignature.selector,
            "isValidSignature(bytes32,bytes)"
        );
        defaultExtension.functions[7] = IExtension.ExtensionFunction(
            AccountExtension.addDeposit.selector,
            "addDeposit()"
        );
        defaultExtension.functions[8] = IExtension.ExtensionFunction(
            AccountExtension.withdrawDepositTo.selector,
            "withdrawDepositTo(address,uint256)"
        );

        IExtension.Extension[] memory extensions = new IExtension.Extension[](1);
        extensions[0] = defaultExtension;

        // deploy account factory
        factoryImpl = address(new DynamicAccountFactory(extensions));
        accountFactory = DynamicAccountFactory(
            address(
                payable(
                    new TWProxy(
                        factoryImpl,
                        abi.encodeWithSignature("initialize(address,string)", deployer, "https://example.com")
                    )
                )
            )
        );
        // deploy dummy contract
        numberContract = new Number();
    }

    /*///////////////////////////////////////////////////////////////
                        Test: creating an account
    //////////////////////////////////////////////////////////////*/

    function test_revert_initializeImplementation() public {
        vm.expectRevert("Initializable: contract is already initialized");
        DynamicAccountFactory(factoryImpl).initialize(deployer, "https://example.com");
    }

    /// @dev benchmark test for deployment gas cost
    function test_deploy_dynamicAccount() public {
        // Setting up default extension.
        IExtension.Extension memory defaultExtension;

        defaultExtension.metadata = IExtension.ExtensionMetadata({
            name: "AccountExtension",
            metadataURI: "ipfs://AccountExtension",
            implementation: address(new AccountExtension())
        });

        defaultExtension.functions = new IExtension.ExtensionFunction[](7);

        defaultExtension.functions[0] = IExtension.ExtensionFunction(
            AccountExtension.supportsInterface.selector,
            "supportsInterface(bytes4)"
        );
        defaultExtension.functions[1] = IExtension.ExtensionFunction(
            AccountExtension.execute.selector,
            "execute(address,uint256,bytes)"
        );
        defaultExtension.functions[2] = IExtension.ExtensionFunction(
            AccountExtension.executeBatch.selector,
            "executeBatch(address[],uint256[],bytes[])"
        );
        defaultExtension.functions[3] = IExtension.ExtensionFunction(
            ERC721Holder.onERC721Received.selector,
            "onERC721Received(address,address,uint256,bytes)"
        );
        defaultExtension.functions[4] = IExtension.ExtensionFunction(
            ERC1155Holder.onERC1155Received.selector,
            "onERC1155Received(address,address,uint256,uint256,bytes)"
        );
        defaultExtension.functions[5] = IExtension.ExtensionFunction(
            bytes4(0), // Selector for `receive()` function.
            "receive()"
        );
        defaultExtension.functions[6] = IExtension.ExtensionFunction(
            AccountExtension.isValidSignature.selector,
            "isValidSignature(bytes32,bytes)"
        );

        IExtension.Extension[] memory extensions = new IExtension.Extension[](1);
        extensions[0] = defaultExtension;

        // deploy account factory
        address factoryImplementation = address(new DynamicAccountFactory(extensions));
        DynamicAccountFactory factory = DynamicAccountFactory(
            address(
                payable(
                    new TWProxy(
                        factoryImplementation,
                        abi.encodeWithSignature("initialize(address,string)", deployer, "https://example.com")
                    )
                )
            )
        );
    }

    /// @dev Create an account by directly calling the factory.
    function test_state_createAccount_viaFactory() public {
        vm.expectEmit(true, true, false, true);
        emit AccountCreated(sender, accountAdmin);
        accountFactory.createAccount(accountAdmin, data);

        address[] memory allAccounts = accountFactory.getAllAccounts();
        assertEq(allAccounts.length, 1);
        assertEq(allAccounts[0], sender);
    }

    /// @dev Create an account via Entrypoint.
    function test_state_createAccount_viaEntrypointSingle() public {
        bytes memory initCallData = abi.encodeWithSignature("createAccount(address,bytes)", accountAdmin, data);
        bytes memory initCode = abi.encodePacked(abi.encodePacked(address(accountFactory)), initCallData);

        UserOperation[] memory userOpCreateAccount = _setupUserOpExecute(
            accountAdminPKey,
            initCode,
            address(0),
            0,
            bytes("")
        );

        vm.expectEmit(true, true, false, true);
        emit AccountCreated(sender, accountAdmin);
        EntryPoint(entrypoint).handleOps(userOpCreateAccount, beneficiary);

        address[] memory allAccounts = accountFactory.getAllAccounts();
        assertEq(allAccounts.length, 1);
        assertEq(allAccounts[0], sender);
    }

    /// @dev Try registering with factory with a contract not deployed by factory.
    function test_revert_onRegister_nonFactoryChildContract() public {
        vm.prank(address(0x12345));
        vm.expectRevert("AccountFactory: not an account.");
        accountFactory.onRegister(_generateSalt(accountAdmin, ""));
    }

    /// @dev Create more than one accounts with the same admin.
    function test_state_createAccount_viaEntrypoint_multipleAccountSameAdmin() public {
        uint256 amount = 1;

        for (uint256 i = 0; i < amount; i += 1) {
            bytes memory initCallData = abi.encodeWithSignature(
                "createAccount(address,bytes)",
                accountAdmin,
                bytes(abi.encode(i))
            );
            bytes memory initCode = abi.encodePacked(abi.encodePacked(address(accountFactory)), initCallData);

            address expectedSenderAddress = Clones.predictDeterministicAddress(
                accountFactory.accountImplementation(),
                _generateSalt(accountAdmin, bytes(abi.encode(i))),
                address(accountFactory)
            );

            UserOperation[] memory userOpCreateAccount = _setupUserOpExecuteWithSender(
                initCode,
                address(0),
                0,
                bytes(abi.encode(i)),
                expectedSenderAddress
            );

            vm.expectEmit(true, true, false, true);
            emit AccountCreated(expectedSenderAddress, accountAdmin);
            EntryPoint(entrypoint).handleOps(userOpCreateAccount, beneficiary);
        }

        address[] memory allAccounts = accountFactory.getAllAccounts();
        assertEq(allAccounts.length, amount);

        for (uint256 i = 0; i < amount; i += 1) {
            assertEq(
                allAccounts[i],
                Clones.predictDeterministicAddress(
                    accountFactory.accountImplementation(),
                    _generateSalt(accountAdmin, bytes(abi.encode(i))),
                    address(accountFactory)
                )
            );
        }
    }

    /*///////////////////////////////////////////////////////////////
                    Test: performing a contract call
    //////////////////////////////////////////////////////////////*/

    function _setup_executeTransaction() internal {
        bytes memory initCallData = abi.encodeWithSignature("createAccount(address,bytes)", accountAdmin, data);
        bytes memory initCode = abi.encodePacked(abi.encodePacked(address(accountFactory)), initCallData);

        UserOperation[] memory userOpCreateAccount = _setupUserOpExecute(
            accountAdminPKey,
            initCode,
            address(0),
            0,
            bytes("")
        );

        EntryPoint(entrypoint).handleOps(userOpCreateAccount, beneficiary);
    }

    /// @dev Perform a state changing transaction directly via account.
    function test_state_executeTransaction() public {
        _setup_executeTransaction();

        address account = accountFactory.getAddress(accountAdmin, bytes(""));

        assertEq(numberContract.num(), 0);

        vm.prank(accountAdmin);
        SimpleAccount(payable(account)).execute(
            address(numberContract),
            0,
            abi.encodeWithSignature("setNum(uint256)", 42)
        );

        assertEq(numberContract.num(), 42);
    }

    /// @dev Perform many state changing transactions in a batch directly via account.
    function test_state_executeBatchTransaction() public {
        _setup_executeTransaction();

        address account = accountFactory.getAddress(accountAdmin, bytes(""));

        assertEq(numberContract.num(), 0);

        uint256 count = 3;
        address[] memory targets = new address[](count);
        uint256[] memory values = new uint256[](count);
        bytes[] memory callData = new bytes[](count);

        for (uint256 i = 0; i < count; i += 1) {
            targets[i] = address(numberContract);
            values[i] = 0;
            callData[i] = abi.encodeWithSignature("incrementNum()", i);
        }

        vm.prank(accountAdmin);
        SimpleAccount(payable(account)).executeBatch(targets, values, callData);

        assertEq(numberContract.num(), count);
    }

    /// @dev Perform a state changing transaction via Entrypoint.
    function test_state_executeTransaction_viaEntrypoint() public {
        _setup_executeTransaction();

        assertEq(numberContract.num(), 0);

        UserOperation[] memory userOp = _setupUserOpExecute(
            accountAdminPKey,
            bytes(""),
            address(numberContract),
            0,
            abi.encodeWithSignature("setNum(uint256)", 42)
        );

        EntryPoint(entrypoint).handleOps(userOp, beneficiary);

        assertEq(numberContract.num(), 42);
    }

    /// @dev Perform many state changing transactions in a batch via Entrypoint.
    function test_state_executeBatchTransaction_viaEntrypoint() public {
        _setup_executeTransaction();

        assertEq(numberContract.num(), 0);

        uint256 count = 3;
        address[] memory targets = new address[](count);
        uint256[] memory values = new uint256[](count);
        bytes[] memory callData = new bytes[](count);

        for (uint256 i = 0; i < count; i += 1) {
            targets[i] = address(numberContract);
            values[i] = 0;
            callData[i] = abi.encodeWithSignature("incrementNum()", i);
        }

        UserOperation[] memory userOp = _setupUserOpExecuteBatch(
            accountAdminPKey,
            bytes(""),
            targets,
            values,
            callData
        );

        EntryPoint(entrypoint).handleOps(userOp, beneficiary);

        assertEq(numberContract.num(), count);
    }

    /// @dev Perform many state changing transactions in a batch via Entrypoint.
    function test_state_executeBatchTransaction_viaAccountSigner() public {
        _setup_executeTransaction();

        assertEq(numberContract.num(), 0);

        uint256 count = 3;
        address[] memory targets = new address[](count);
        uint256[] memory values = new uint256[](count);
        bytes[] memory callData = new bytes[](count);

        for (uint256 i = 0; i < count; i += 1) {
            targets[i] = address(numberContract);
            values[i] = 0;
            callData[i] = abi.encodeWithSignature("incrementNum()", i);
        }

        address account = accountFactory.getAddress(accountAdmin, bytes(""));

        address[] memory approvedTargets = new address[](1);
        approvedTargets[0] = address(numberContract);

        IAccountPermissions.SignerPermissionRequest memory permissionsReq = IAccountPermissions.SignerPermissionRequest(
            accountSigner,
            0,
            approvedTargets,
            1 ether,
            0,
            type(uint128).max,
            0,
            type(uint128).max,
            uidCache
        );

        vm.prank(accountAdmin);
        bytes memory sig = _signSignerPermissionRequest(permissionsReq);
        SimpleAccount(payable(account)).setPermissionsForSigner(permissionsReq, sig);

        UserOperation[] memory userOp = _setupUserOpExecuteBatch(
            accountSignerPKey,
            bytes(""),
            targets,
            values,
            callData
        );

        EntryPoint(entrypoint).handleOps(userOp, beneficiary);

        assertEq(numberContract.num(), count);
    }

    /// @dev Perform a state changing transaction via Entrypoint and a SIGNER_ROLE holder.
    function test_state_executeTransaction_viaAccountSigner() public {
        _setup_executeTransaction();

        address account = accountFactory.getAddress(accountAdmin, bytes(""));

        address[] memory approvedTargets = new address[](1);
        approvedTargets[0] = address(numberContract);

        IAccountPermissions.SignerPermissionRequest memory permissionsReq = IAccountPermissions.SignerPermissionRequest(
            accountSigner,
            0,
            approvedTargets,
            1 ether,
            0,
            type(uint128).max,
            0,
            type(uint128).max,
            uidCache
        );

        vm.prank(accountAdmin);
        bytes memory sig = _signSignerPermissionRequest(permissionsReq);
        SimpleAccount(payable(account)).setPermissionsForSigner(permissionsReq, sig);

        assertEq(numberContract.num(), 0);

        UserOperation[] memory userOp = _setupUserOpExecute(
            accountSignerPKey,
            bytes(""),
            address(numberContract),
            0,
            abi.encodeWithSignature("setNum(uint256)", 42)
        );

        EntryPoint(entrypoint).handleOps(userOp, beneficiary);

        assertEq(numberContract.num(), 42);
    }

    /// @dev Revert: perform a state changing transaction via Entrypoint without appropriate permissions.
    function test_revert_executeTransaction_nonSigner_viaEntrypoint() public {
        _setup_executeTransaction();

        assertEq(numberContract.num(), 0);

        UserOperation[] memory userOp = _setupUserOpExecute(
            accountSignerPKey,
            bytes(""),
            address(numberContract),
            0,
            abi.encodeWithSignature("setNum(uint256)", 42)
        );

        vm.expectRevert();
        EntryPoint(entrypoint).handleOps(userOp, beneficiary);
    }

    /// @dev Revert: non-admin performs a state changing transaction directly via account contract.
    function test_revert_executeTransaction_nonSigner_viaDirectCall() public {
        _setup_executeTransaction();

        address account = accountFactory.getAddress(accountAdmin, bytes(""));

        address[] memory approvedTargets = new address[](1);
        approvedTargets[0] = address(numberContract);

        IAccountPermissions.SignerPermissionRequest memory permissionsReq = IAccountPermissions.SignerPermissionRequest(
            accountSigner,
            0,
            approvedTargets,
            1 ether,
            0,
            type(uint128).max,
            0,
            type(uint128).max,
            uidCache
        );

        vm.prank(accountAdmin);
        bytes memory sig = _signSignerPermissionRequest(permissionsReq);
        SimpleAccount(payable(account)).setPermissionsForSigner(permissionsReq, sig);
        assertEq(numberContract.num(), 0);

        vm.prank(accountSigner);
        vm.expectRevert("Account: not admin or EntryPoint.");
        SimpleAccount(payable(account)).execute(
            address(numberContract),
            0,
            abi.encodeWithSignature("setNum(uint256)", 42)
        );
    }

    /*///////////////////////////////////////////////////////////////
                Test: receiving and sending native tokens
    //////////////////////////////////////////////////////////////*/

    /// @dev Send native tokens to an account.
    function test_state_accountReceivesNativeTokens() public {
        _setup_executeTransaction();

        address account = accountFactory.getAddress(accountAdmin, bytes(""));

        assertEq(address(account).balance, 0);

        vm.prank(accountAdmin);
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory ret) = payable(account).call{ value: 1000 }("");

        // Silence warning: Return value of low-level calls not used.
        (success, ret) = (success, ret);

        assertEq(address(account).balance, 1000);
    }

    /// @dev Transfer native tokens out of an account.
    function test_state_transferOutsNativeTokens() public {
        _setup_executeTransaction();

        uint256 value = 1000;

        address account = accountFactory.getAddress(accountAdmin, bytes(""));
        vm.prank(accountAdmin);
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory ret) = payable(account).call{ value: value }("");
        assertEq(address(account).balance, value);

        // Silence warning: Return value of low-level calls not used.
        (success, ret) = (success, ret);

        address recipient = address(0x3456);

        UserOperation[] memory userOp = _setupUserOpExecute(accountAdminPKey, bytes(""), recipient, value, bytes(""));

        EntryPoint(entrypoint).handleOps(userOp, beneficiary);
        assertEq(address(account).balance, 0);
        assertEq(recipient.balance, value);
    }

    /// @dev Add and remove a deposit for the account from the Entrypoint.

    function test_state_addAndWithdrawDeposit() public {
        _setup_executeTransaction();

        address account = accountFactory.getAddress(accountAdmin, bytes(""));

        assertEq(EntryPoint(entrypoint).balanceOf(account), 0);

        vm.prank(accountAdmin);
        SimpleAccount(payable(account)).addDeposit{ value: 1000 }();
        assertEq(EntryPoint(entrypoint).balanceOf(account), 1000);

        vm.prank(accountAdmin);
        SimpleAccount(payable(account)).withdrawDepositTo(payable(accountSigner), 500);
        assertEq(EntryPoint(entrypoint).balanceOf(account), 500);
    }

    /*///////////////////////////////////////////////////////////////
                Test: receiving ERC-721 and ERC-1155 NFTs
    //////////////////////////////////////////////////////////////*/

    /// @dev Send an ERC-721 NFT to an account.
    function test_state_receiveERC721NFT() public {
        _setup_executeTransaction();
        address account = accountFactory.getAddress(accountAdmin, bytes(""));

        assertEq(erc721.balanceOf(account), 0);

        erc721.mint(account, 1);

        assertEq(erc721.balanceOf(account), 1);
    }

    /// @dev Send an ERC-1155 NFT to an account.
    function test_state_receiveERC1155NFT() public {
        _setup_executeTransaction();
        address account = accountFactory.getAddress(accountAdmin, bytes(""));

        assertEq(erc1155.balanceOf(account, 0), 0);

        erc1155.mint(account, 0, 1);

        assertEq(erc1155.balanceOf(account, 0), 1);
    }

    /*///////////////////////////////////////////////////////////////
                Test: change an extension on the account
    //////////////////////////////////////////////////////////////*/

    /// @dev Make the account reject ERC-721 NFTs instead of accepting them.
    function test_scenario_changeExtensionForFunction() public {
        _setup_executeTransaction();
        address account = accountFactory.getAddress(accountAdmin, bytes(""));

        // The account can initially receive NFTs.
        assertEq(erc721.balanceOf(account), 0);
        erc721.mint(account, 1);
        assertEq(erc721.balanceOf(account), 1);

        // Make the account reject ERC-721 NFTs going forward.
        IExtension.Extension memory extension;

        extension.metadata = IExtension.ExtensionMetadata({
            name: "NFTRejector",
            metadataURI: "ipfs://NFTRejector",
            implementation: address(new NFTRejector())
        });

        extension.functions = new IExtension.ExtensionFunction[](1);

        extension.functions[0] = IExtension.ExtensionFunction(
            NFTRejector.onERC721Received.selector,
            "onERC721Received(address,address,uint256,bytes)"
        );

        vm.prank(accountAdmin);
        DynamicAccount(payable(account)).disableFunctionInExtension(
            "AccountExtension",
            NFTRejector.onERC721Received.selector
        );

        vm.prank(accountAdmin);
        DynamicAccount(payable(account)).addExtension(extension);

        // Transfer NFTs to the account
        erc721.mint(accountSigner, 1);
        assertEq(erc721.ownerOf(1), accountSigner);
        vm.prank(accountSigner);
        vm.expectRevert("NFTs not accepted");
        erc721.safeTransferFrom(accountSigner, account, 1);
    }
}
