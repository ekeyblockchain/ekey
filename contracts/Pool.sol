// SPDX-License-Identifier: MIT

pragma solidity ^0.7.0;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";

import "./interfaces/IMain.sol";
import "./interfaces/IBox.sol";
import "./interfaces/IEpochalKey.sol";
import "./interfaces/IBoxRanking.sol";
import "./interfaces/ISwapWrapper.sol";
import "./interfaces/IActivityEntrance.sol";

import "./libraries/LockedArray.sol";

contract Pool is Ownable, ReentrancyGuard, Pausable {
    using Math for uint256;
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;
    using LockedArray for LockedArray.Array;

    uint256 public totalWhiteListETH;
    mapping(address => uint256) public whiteListETH;
    address[] public whiteList;
    bool public whiteAddLiquidity;
    uint256 public whiteLP;

    uint256 public startBlock;
    uint256 public secondStageBlock;

    uint8 public constant maxLevel = 13;
    uint8 public constant maxInvitee = 7;
    uint8[maxInvitee] public levels;
    uint256[maxLevel] public levelScale;
    uint256 public constant levelMutiple = 100000;

    IMain public main;

    IERC20 public lp;
    IERC20 public eKey;
    uint256 public tokenPerBlock;
    uint256 public totalOutputToken;

    struct UserInfo {
        uint256 rewardPerTokenPaid;
        uint256 rewards;
        uint256 userID;
        uint256 groupID;
        uint256 selfAmount;
        uint256 extraAmount;
        uint256 flowAmount;
        uint256 groupFlowAmount;
        uint256 inviteeETH;
        uint256 lockedAmount;
    }

    uint256 public constant multiple = 10**18;
    uint256 public constant boxMultiple = multiple / 10;
    uint256 public constant officialBoxMultiple = multiple * 10;

    uint256 public totalAmount;
    uint256 public lastRewardBlock;
    uint256 public rewardPerTokenStored;
    uint256 public lockedBlock;

    mapping(uint256 => UserInfo) public userInfo;
    mapping(uint256 => EnumerableSet.UintSet) private effectiveInvitees;
    mapping(uint256 => mapping(uint256 => uint256)) public effectiveInviteeExtraAmount;
    mapping(uint256 => LockedArray.Array) private lockedAmountDetail;

    event SetReward(uint256 indexed blockNumber, uint256 reward);
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event WithdrawReward(address indexed user, uint256 amount);

    modifier onlyMain() {
        require(address(main) == _msgSender(), "Caller is not the main");
        _;
    }

    constructor(
        uint256 _startBlock,
        uint256 _secondStageBlock,
        address _main,
        address _eKey,
        address _lp,
        uint256 _tokenPerBlock,
        uint256 _lockedBlock
    ) {
        levels = [1, 2, 3, 4, 8, 11, 14];
        levelScale = [10000, 5000, 2500, 1250, 625, 313, 156, 78, 39, 20, 10, 5, 2];

        _pause();

        startBlock = _startBlock;
        secondStageBlock = _secondStageBlock;
        main = IMain(_main);
        eKey = IERC20(_eKey);
        lp = IERC20(_lp);
        tokenPerBlock = _tokenPerBlock;
        lockedBlock = _lockedBlock;
    }

    function apy() public view returns (uint256) {
        ISwapWrapper swapper = ISwapWrapper(main.swapWrapper());
        uint256 price = swapper.getEKeyPrice();
        uint256 totalAssets = swapper.totalAssets();
        return (tokenPerBlock * 10512 * price * 1000) / totalAssets;
    }

    function lpBalance() public view returns (uint256) {
        return lp.balanceOf(address(this));
    }

    function rewards(uint256 _userID) public view returns (uint256) {
        UserInfo storage user = userInfo[_userID];
        return
            user
                .selfAmount
                .add(user.extraAmount)
                .mul(rewardPerToken().sub(user.rewardPerTokenPaid))
                .add(user.rewards)
                .div(multiple);
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalAmount == 0) {
            return rewardPerTokenStored;
        }
        uint256 rewardRate = tokenPerBlock.mul(multiple);
        uint256 store = block.number.sub(lastRewardBlock).mul(rewardRate).div(totalAmount);
        return rewardPerTokenStored.add(store);
    }

    function officialBoxLatest() public view returns (uint256) {
        if (totalAmount == 0) {
            return 0;
        }
        return block.number.sub(lastRewardBlock).mul(tokenPerBlock).mul(officialBoxMultiple).div(multiple);
    }

    function getInfo(uint256 _userID) external view returns (uint256) {
        return userInfo[_userID].selfAmount.add(userInfo[_userID].extraAmount);
    }

    function setRewardPerBlock(uint256 _reward) public onlyOwner {
        updateReward(0);
        tokenPerBlock = _reward;
        emit SetReward(block.number, _reward);
    }

    function setLockedBlock(uint256 _lockedBlock) public onlyOwner {
        lockedBlock = _lockedBlock;
    }

    function getEffectiveInviteeCount(uint256 _userID) public view returns (uint256) {
        return effectiveInvitees[_userID].length();
    }

    function getEffectiveInviteeExtraLP(
        uint256 _userID,
        uint256 _offset,
        uint256 _size
    ) public view returns (uint256[2][] memory) {
        uint256 length = effectiveInvitees[_userID].length();
        if (_offset >= length) {
            return new uint256[2][](0);
        }
        uint256 end = length.min(_offset.add(_size));
        uint256 size = end.sub(_offset);
        uint256[2][] memory results = new uint256[2][](size);
        uint256 count = 0;
        for (uint256 i = _offset; i < end; i++) {
            uint256 invitee = effectiveInvitees[_userID].at(i);
            results[count] = [invitee, effectiveInviteeExtraAmount[_userID][invitee]];
            count++;
        }
        return results;
    }

    function lockedDetail(uint256 _user) public view returns (uint256[2][] memory) {
        return lockedAmountDetail[_user].getAll();
    }

    function intoWhiteList() public payable nonReentrant {
        require(block.number < startBlock, "Finished");
        require(msg.value == 200 * (10**18), "Not 200 ETH");
        (, uint256 userID) = main.getUser(msg.sender);
        require(userID > 0, "Not registed");

        uint256 eth = whiteListETH[msg.sender];
        require(eth == 0, "Already in white list");
        whiteList.push(msg.sender);
        whiteListETH[msg.sender] = msg.value;
        totalWhiteListETH = totalWhiteListETH.add(msg.value);
    }

    function addLiquidity() public nonReentrant onlyOwner {
        require(block.number >= startBlock, "Finished");
        require(!whiteAddLiquidity, "Already added");
        whiteAddLiquidity = true;

        ISwapWrapper swapWrapper = ISwapWrapper(main.swapWrapper());

        uint256 amountETH = totalWhiteListETH.div(2);
        whiteLP = swapWrapper.createLiquidity{ value: totalWhiteListETH - amountETH }(address(this));
        lp = IERC20(swapWrapper.getLP());

        uint256 officialETH = amountETH.div(2);
        main.officialAddr().transfer(officialETH);
        main.projectAddr().transfer(amountETH.sub(officialETH));
    }

    function depositWhiteList(uint256 _amount) public nonReentrant onlyOwner {
        require(whiteAddLiquidity, "Add liquidity first");
        uint256 length = whiteList.length;
        uint256 count = 0;
        for (uint256 i = 0; i < length; i++) {
            address addr = whiteList[i];
            uint256 eth = whiteListETH[addr];
            if (eth > 0) {
                whiteListETH[addr] = 0;

                (, uint256 userID) = main.getUser(addr);
                updateReward(userID);

                uint256 amount = whiteLP.mul(eth).div(totalWhiteListETH);

                addLP(userID, amount, eth);

                emit Deposit(addr, amount);

                count++;
                if (count > _amount) {
                    break;
                }
            }
        }
        if (count == 0) {
            _unpause();
        }
    }

    function depositWithSwap() public payable nonReentrant whenNotPaused {
        require(block.number >= startBlock, "Not started");
        require(block.number <= secondStageBlock, "Closed");
        (, uint256 userID) = main.getUser(msg.sender);
        require(userID > 0, "Not registed");

        ISwapWrapper swapWrapper = ISwapWrapper(main.swapWrapper());

        uint256 amountETH = msg.value / 2;
        uint256 amount = swapWrapper.addLiquidityETH{ value: msg.value - amountETH }(msg.sender, address(this));
        uint256 officialETH = amountETH.div(2);
        main.officialAddr().transfer(officialETH);
        main.projectAddr().transfer(amountETH.sub(officialETH));

        updateReward(userID);

        addLP(userID, amount, msg.value);

        emit Deposit(msg.sender, amount);
    }

    function deposit() public payable nonReentrant whenNotPaused {
        require(block.number > secondStageBlock, "Not started");
        (, uint256 userID) = main.getUser(msg.sender);
        require(userID > 0, "Not registed");

        ISwapWrapper swapWrapper = ISwapWrapper(main.swapWrapper());

        uint256 amount = swapWrapper.addLiquidityETHSwap{ value: msg.value }(msg.sender, address(this));

        updateReward(userID);

        addLP(userID, amount, msg.value);

        emit Deposit(msg.sender, amount);
    }

    function deposit(uint256 _amount) public nonReentrant whenNotPaused {
        require(block.number > secondStageBlock, "Not started");

        (, uint256 userID) = main.getUser(msg.sender);
        require(userID > 0, "Not registed");

        lp.safeTransferFrom(msg.sender, address(this), _amount);

        updateReward(userID);

        addLP(userID, _amount, 0);

        emit Deposit(msg.sender, _amount);
    }

    function withdraw(uint256 _amount) public nonReentrant {
        require(_amount > 0, "amount must be greater than zero");
        (, uint256 userID) = main.getUser(msg.sender);
        require(userID > 0, "Not registed");

        updateReward(userID);

        UserInfo storage user = userInfo[userID];

        releaseLockedAmount(user);

        require(user.selfAmount > 0, "the user did not deposit");
        require(user.selfAmount.sub(user.lockedAmount) >= _amount, "not enough amount");
        lp.safeTransfer(msg.sender, _amount);

        removeLP(userID, _amount);

        emit Withdraw(msg.sender, _amount);
    }

    function withdrawReward() public nonReentrant {
        (, uint256 userID) = main.getUser(msg.sender);
        require(userID > 0, "Not registed");
        updateReward(userID);

        uint256 trueReward = rewards(userID);
        if (trueReward > 0) {
            uint256 realReward = trueReward.min(eKey.balanceOf(address(this)));
            UserInfo storage user = userInfo[userID];
            user.rewards = trueReward.sub(realReward);
            eKey.safeTransfer(msg.sender, realReward);
            totalOutputToken = totalOutputToken.add(realReward);
            IBox(main.box()).mint(msg.sender, trueReward.mul(boxMultiple).div(multiple));
            emit WithdrawReward(msg.sender, trueReward);
        }
    }

    function updateReward(uint256 _userID) internal {
        IBox(main.box()).mintOfficial(officialBoxLatest());
        rewardPerTokenStored = rewardPerToken();
        lastRewardBlock = block.number;
        if (_userID != 0) {
            UserInfo storage user = userInfo[_userID];
            uint256 newRewards = rewards(_userID).mul(multiple);
            user.rewards = newRewards;
            user.rewardPerTokenPaid = rewardPerTokenStored;
        }
    }

    function addLockedAmount(UserInfo storage _user, uint256 _amount) internal {
        if (lockedBlock > 0) {
            LockedArray.Array storage arr = lockedAmountDetail[_user.userID];
            _user.lockedAmount = _user.lockedAmount.add(_amount);
            arr.add(LockedArray.LockedAmount({ amount: _amount, unlockBlock: block.number + lockedBlock }));
        }
    }

    function releaseLockedAmount(UserInfo storage _user) internal {
        LockedArray.Array storage arr = lockedAmountDetail[_user.userID];
        uint256 unlockedAmount = unlockAmount(arr);
        _user.lockedAmount = _user.lockedAmount.sub(unlockedAmount);
    }

    function unlockAmount(LockedArray.Array storage arr) internal returns (uint256) {
        uint256 unlockedAmount;
        uint256 i = arr.length();

        while (i-- > 0) {
            if (arr.get(i).unlockBlock <= block.number) {
                unlockedAmount = unlockedAmount.add(arr.get(i).amount);
                arr.remove(i);
            }
        }
        return unlockedAmount;
    }

    function addLP(
        uint256 _userID,
        uint256 _amount,
        uint256 _eth
    ) internal {
        require(_amount > 0, "Invalid amount");

        UserInfo storage user = userInfo[_userID];
        if (user.userID == 0) {
            user.userID = _userID;
            user.groupID = main.getUserGroupID(_userID);
        }

        UserInfo storage inviter = getInviter(_userID);
        uint256 inviterUserID = inviter.userID;
        if (inviterUserID != 0) {
            if (user.selfAmount == 0) {
                effectiveInvitees[inviter.userID].add(_userID);
            }
            if (_eth > 0) {
                inviter.inviteeETH = inviter.inviteeETH.add(_eth);
                IActivityEntrance(main.activityEntrance()).addInviteeETH(inviterUserID, _eth);
            }
        }

        user.selfAmount = user.selfAmount.add(_amount);
        totalAmount = totalAmount.add(_amount);

        releaseLockedAmount(user);

        addLockedAmount(user, _amount);

        addToInviters(user, inviter, _amount);
    }

    function removeLP(uint256 _userID, uint256 _amount) internal {
        require(_amount > 0, "Invalid amount");

        if (_amount == 0) {
            return;
        }

        UserInfo storage user = userInfo[_userID];

        user.selfAmount = user.selfAmount.sub(_amount);
        totalAmount = totalAmount.sub(_amount);

        UserInfo storage inviter = getInviter(_userID);
        if (user.selfAmount == 0 && inviter.userID != 0) {
            effectiveInvitees[inviter.userID].remove(_userID);
        }

        removeFromInviters(user, inviter, _amount);
    }

    function pause(bool p) public onlyOwner returns (bool) {
        if (p) {
            _pause();
        } else {
            _unpause();
        }
        return true;
    }

    function addToInviters(
        UserInfo storage _user,
        UserInfo storage _inviter,
        uint256 _amount
    ) private {
        uint256 max = _user.selfAmount.mul(3);
        uint256 realAmount = _user.selfAmount.add(_user.extraAmount);
        uint256 amountAdd = 0;

        if (realAmount < max && _user.flowAmount > 0) {
            amountAdd = _user.flowAmount.min(max.sub(realAmount));
            _user.flowAmount = _user.flowAmount.sub(amountAdd);
            _user.extraAmount = _user.extraAmount.add(amountAdd);
        }

        UserInfo storage inviter = _inviter;
        UserInfo storage invitee = _user;

        for (uint8 i = 1; i <= maxLevel; i++) {
            uint256 inviterUserID = inviter.userID;
            if (inviterUserID == 0) {
                break;
            }
            uint256 inviteeUserID = invitee.userID;

            UserInfo storage tempInviter = inviter;

            invitee = inviter;
            inviter = getInviter(inviter.userID);

            uint256 c = effectiveInvitees[inviterUserID].length();
            if (i > levels[c.min(maxInvitee) - 1]) {
                continue;
            }
            uint256 add = _amount.mul(levelScale[i - 1]).div(levelMutiple);
            if (add == 0) {
                break;
            }

            uint256 inviteeExtra = effectiveInviteeExtraAmount[inviterUserID][inviteeUserID];

            if (inviteeExtra == tempInviter.extraAmount || inviteeExtra < tempInviter.extraAmount.mul(70).div(100)) {
                max = tempInviter.selfAmount.mul(3);
                if (max > tempInviter.extraAmount) {
                    c = max.sub(tempInviter.extraAmount).min(add);

                    tempInviter.extraAmount = tempInviter.extraAmount.add(c);
                    effectiveInviteeExtraAmount[inviterUserID][inviteeUserID] = inviteeExtra.add(c);
                    amountAdd = amountAdd.add(c);
                    add = add.sub(c);
                }
                if (add > 0) {
                    tempInviter.flowAmount = tempInviter.flowAmount.add(add);
                }
            } else {
                tempInviter.groupFlowAmount = tempInviter.groupFlowAmount.add(add);
            }
        }

        totalAmount = totalAmount.add(amountAdd);
    }

    function removeFromInviters(
        UserInfo storage _user,
        UserInfo storage _inviter,
        uint256 _amount
    ) private {
        uint256 max = _user.selfAmount.mul(3);
        uint256 realAmount = _user.extraAmount;
        uint256 amountSub = 0;

        if (realAmount > max) {
            amountSub = realAmount.sub(max);
            _user.flowAmount = _user.flowAmount.add(amountSub);
            _user.extraAmount = _user.extraAmount.sub(amountSub);
        }

        UserInfo storage inviter = _inviter;
        UserInfo storage invitee = _user;

        for (uint8 i = 1; i <= maxLevel; i++) {
            uint256 inviterUserID = inviter.userID;
            if (inviterUserID == 0) {
                break;
            }
            uint256 inviteeUserID = invitee.userID;

            uint256 sub = _amount.mul(levelScale[i - 1]).div(levelMutiple);

            if (sub > 0) {
                uint256 s = 0;
                if (inviter.groupFlowAmount > 0) {
                    s = inviter.groupFlowAmount.min(sub);
                    inviter.groupFlowAmount = inviter.groupFlowAmount.sub(s);
                    sub = sub.sub(s);
                }
                if (sub > 0 && inviter.flowAmount > 0) {
                    s = inviter.flowAmount.min(sub);
                    inviter.flowAmount = inviter.flowAmount.sub(s);
                    sub = sub.sub(s);
                }
                if (sub > 0 && inviter.extraAmount > 0) {
                    s = inviter.extraAmount.min(sub);
                    inviter.extraAmount = inviter.extraAmount.sub(s);
                    uint256 inviteeExtra = effectiveInviteeExtraAmount[inviterUserID][inviteeUserID];
                    effectiveInviteeExtraAmount[inviterUserID][inviteeUserID] = inviteeExtra > s
                        ? inviteeExtra.sub(s)
                        : 0;
                    amountSub = amountSub.add(s);
                    sub = sub.sub(s);
                }
            }

            invitee = inviter;
            inviter = getInviter(inviter.userID);
        }

        totalAmount = totalAmount.sub(amountSub);
    }

    function getInviter(uint256 _user) private returns (UserInfo storage) {
        uint256 inviterID = main.getInviter(_user);
        if (inviterID == 0) {
            return userInfo[inviterID];
        }
        UserInfo storage inviter = userInfo[inviterID];
        if (inviter.userID == 0) {
            inviter.userID = inviterID;
            inviter.groupID = main.getUserGroupID(_user);
        }
        return inviter;
    }
}
