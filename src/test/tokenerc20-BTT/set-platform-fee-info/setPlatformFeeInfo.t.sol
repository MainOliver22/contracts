// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.11;

import "../../utils/BaseTest.sol";

import { TWProxy } from "contracts/infra/TWProxy.sol";

contract MyTokenERC20 is TokenERC20 {}

contract TokenERC20Test_SetPlatformFeeInfo is BaseTest {
    address public implementation;
    address public proxy;
    address internal caller;
    address internal _platformFeeRecipient;
    uint256 internal _platformFeeBps;

    MyTokenERC20 internal tokenContract;

    event PlatformFeeInfoUpdated(address indexed platformFeeRecipient, uint256 platformFeeBps);

    function setUp() public override {
        super.setUp();

        // Deploy implementation.
        implementation = address(new MyTokenERC20());

        caller = getActor(1);
        _platformFeeRecipient = getActor(2);

        // Deploy proxy pointing to implementaion.
        vm.prank(deployer);
        proxy = address(
            new TWProxy(
                implementation,
                abi.encodeCall(
                    TokenERC20.initialize,
                    (
                        deployer,
                        NAME,
                        SYMBOL,
                        CONTRACT_URI,
                        forwarders(),
                        saleRecipient,
                        platformFeeRecipient,
                        platformFeeBps
                    )
                )
            )
        );

        tokenContract = MyTokenERC20(proxy);
    }

    function test_setPlatformFeeInfo_callerNotAuthorized() public {
        vm.prank(address(caller));
        vm.expectRevert(
            abi.encodePacked(
                "AccessControl: account ",
                TWStrings.toHexString(uint160(caller), 20),
                " is missing role ",
                TWStrings.toHexString(uint256(0), 32)
            )
        );
        tokenContract.setPlatformFeeInfo(_platformFeeRecipient, _platformFeeBps);
    }

    modifier whenCallerAuthorized() {
        vm.prank(deployer);
        tokenContract.grantRole(bytes32(0x00), caller);
        _;
    }

    function test_setPlatformFeeInfo_exceedMaxBps() public whenCallerAuthorized {
        _platformFeeBps = 10_001;
        vm.prank(address(caller));
        vm.expectRevert("exceeds MAX_BPS");
        tokenContract.setPlatformFeeInfo(_platformFeeRecipient, _platformFeeBps);
    }

    modifier whenNotExceedMaxBps() {
        _platformFeeBps = 500;
        _;
    }

    function test_setPlatformFeeInfo() public whenCallerAuthorized whenNotExceedMaxBps {
        vm.prank(address(caller));
        tokenContract.setPlatformFeeInfo(_platformFeeRecipient, _platformFeeBps);

        // get platform fee info
        (address _recipient, uint16 _bps) = tokenContract.getPlatformFeeInfo();
        assertEq(_recipient, _platformFeeRecipient);
        assertEq(_bps, uint16(_platformFeeBps));
    }

    function test_setPlatformFeeInfo_event() public whenCallerAuthorized whenNotExceedMaxBps {
        vm.prank(address(caller));
        vm.expectEmit(true, false, false, true);
        emit PlatformFeeInfoUpdated(_platformFeeRecipient, _platformFeeBps);
        tokenContract.setPlatformFeeInfo(_platformFeeRecipient, _platformFeeBps);
    }
}
