pragma solidity ^0.5.1;

import {SafeMath} from "openzeppelin-solidity/contracts/math/SafeMath.sol";
import {IERC20} from "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import {ConditionalTokens} from "./ConditionalTokens.sol";
import {CTHelpers} from "@gnosis.pm/conditional-tokens-contracts/contracts/CTHelpers.sol";
import {ERC1155TokenReceiver} from "@gnosis.pm/conditional-tokens-contracts/contracts/ERC1155/ERC1155TokenReceiver.sol";
import {Record} from "./Record.sol";

import {ERC20} from "./ERC20.sol";
import {Ownable} from './Ownable.sol';


library CeilDiv {
    // calculates ceil(x/y)
    function ceildiv(uint x, uint y) internal pure returns (uint) {
        if (x > 0) return ((x - 1) / y) + 1;
        return x / y;
    }
}


contract FIFAMarketMaker is ERC20, ERC1155TokenReceiver, Ownable {
    event FPMMFundingAdded(
        address indexed funder,
        uint[] amountsAdded,
        uint sharesMinted
    );
    event FPMMFundingRemoved(
        address indexed funder,
        uint[] amountsRemoved,
        uint collateralRemovedFromFeePool,
        uint sharesBurnt
    );
    event FPMMBuy(
        address indexed buyer,
        uint investmentAmount,
        uint feeAmount,
        uint indexed outcomeIndex,
        uint outcomeTokensBought
    );
    event FPMMSell(
        address indexed seller,
        uint returnAmount,
        uint feeAmount,
        uint indexed outcomeIndex,
        uint outcomeTokensSold
    );

    enum Stage {
        Running,
        Paused,
        Closed
    }

    using SafeMath for uint;
    using CeilDiv for uint;

    uint constant ONE = 10 ** 18;

    uint[] outcomeSlotCounts;
    bytes32[][] collectionIds;
    uint[] public positionIds;
    mapping(address => uint256) withdrawnFees;
    uint internal totalWithdrawnFees;

    bytes32[] countrys;
    ConditionalTokens public conditionalTokens;
    IERC20 public collateralToken;
    bytes32[] conditionIds;
    uint public fee;
    uint internal feePoolWeight;

    bytes32 questionId;

    Stage public stage;
    Record public record;

    uint public endTime;

    struct BetRecord {
        uint256 timestamp;
        uint256 collateralAmount;
        uint256 outcomeTokensToBuy;
        uint256 positionId;
        uint256 outcomeIndex;
    }

    mapping(address => BetRecord[]) userBetRecords;

    /*
    *  Modifiers
    */
    modifier atStage(Stage _stage) {
        // Contract has to be in given stage
        require(stage == _stage);
        _;
    }

    constructor(
        bytes32[] memory _countrys,
        ConditionalTokens _conditionalTokens,
        IERC20 _collateralToken,
        bytes32[] memory _conditionIds,
        uint _fee,
        string memory _name,
        string memory _symbol,
        uint _endTime,
        bytes32 _questionId)
    public ERC20(_name, _symbol) {

        countrys = _countrys;
        conditionalTokens = _conditionalTokens;
        collateralToken = _collateralToken;
        conditionIds = _conditionIds;
        fee = _fee;
        endTime = _endTime;
        questionId = _questionId;

        uint atomicOutcomeSlotCount = 1;
        outcomeSlotCounts = new uint[](conditionIds.length);
        for (uint i = 0; i < conditionIds.length; i++) {
            uint outcomeSlotCount = conditionalTokens.getOutcomeSlotCount(conditionIds[i]);
            atomicOutcomeSlotCount *= outcomeSlotCount;
            outcomeSlotCounts[i] = outcomeSlotCount;
        }
        require(atomicOutcomeSlotCount > 1, "conditions must be valid");

        collectionIds = new bytes32[][](conditionIds.length);
        _recordCollectionIDsForAllConditions(conditionIds.length, bytes32(0));
        require(positionIds.length == atomicOutcomeSlotCount, "position IDs construction failed!?");

        stage = Stage.Paused;
    }

    function _recordCollectionIDsForAllConditions(uint conditionsLeft, bytes32 parentCollectionId) private {
        if (conditionsLeft == 0) {
            positionIds.push(CTHelpers.getPositionId(collateralToken, parentCollectionId));
            return;
        }

        conditionsLeft--;

        uint outcomeSlotCount = outcomeSlotCounts[conditionsLeft];

        collectionIds[conditionsLeft].push(parentCollectionId);
        for (uint i = 0; i < outcomeSlotCount; i++) {
            _recordCollectionIDsForAllConditions(
                conditionsLeft,
                CTHelpers.getCollectionId(
                    parentCollectionId,
                    conditionIds[conditionsLeft],
                    1 << i
                )
            );
        }
    }

    // ================================ VIEW ================================
    function getCountrys() public view returns (bytes32[] memory) {
        return countrys;
    }

    function getPoolBalances() public view returns (uint[] memory) {
        address[] memory thises = new address[](positionIds.length);
        for (uint i = 0; i < positionIds.length; i++) {
            thises[i] = address(this);
        }
        return conditionalTokens.balanceOfBatch(thises, positionIds);
    }

    function generateBasicPartition(uint outcomeSlotCount) private pure returns (uint[] memory partition) {
        partition = new uint[](outcomeSlotCount);
        for (uint i = 0; i < outcomeSlotCount; i++) {
            partition[i] = 1 << i;
        }
    }

    function collectedFees() external view returns (uint) {
        return feePoolWeight.sub(totalWithdrawnFees);
    }

    function feesWithdrawableBy(address account) public view returns (uint) {
        uint rawAmount = feePoolWeight.mul(balanceOf(account)) / totalSupply();
        return rawAmount.sub(withdrawnFees[account]);
    }

    // todo 测试 investmentAmount = 10， outcomeIndex = 0
    function calcBuyAmount(uint investmentAmount, uint outcomeIndex) public view returns (uint) {
        require(outcomeIndex < positionIds.length, "invalid outcome index");

        // todo 测试
        // 50 100
        uint[] memory poolBalances = getPoolBalances();
        // 费率0，所以investmentAmountMinusFees = 10
        uint investmentAmountMinusFees = investmentAmount.sub(investmentAmount.mul(fee) / ONE);
        // buyTokenPoolBalance = 50
        uint buyTokenPoolBalance = poolBalances[outcomeIndex];
        uint endingOutcomeBalance = buyTokenPoolBalance.mul(ONE);
        for (uint i = 0; i < poolBalances.length; i++) {
            // i == 1时执行
            if (i != outcomeIndex) {
                // poolBalance = 100
                uint poolBalance = poolBalances[i];
                // 50 * 100 / （100 + 10）= 45.45
                endingOutcomeBalance = endingOutcomeBalance.mul(poolBalance).ceildiv(
                    poolBalance.add(investmentAmountMinusFees)
                );
            }
        }
        require(endingOutcomeBalance > 0, "must have non-zero balances");

        // （50 + 10）- 45.45 = 14.55
        return buyTokenPoolBalance.add(investmentAmountMinusFees).sub(endingOutcomeBalance.ceildiv(ONE));
    }

    // 获取所有筹码的价格
    function summaryCalBuyAmount(uint investmentAmount) public view returns (uint[] memory) {
        uint[] memory prices = new uint[](positionIds.length);
        for (uint i = 0; i < positionIds.length; i++) {
            prices[i] = calcBuyAmount(investmentAmount, i);
        }
        return prices;
    }

    function calcSellAmount(uint returnAmount, uint outcomeIndex) public view returns (uint outcomeTokenSellAmount) {
        require(outcomeIndex < positionIds.length, "invalid outcome index");

        uint[] memory poolBalances = getPoolBalances();
        uint returnAmountPlusFees = returnAmount.mul(ONE) / ONE.sub(fee);
        uint sellTokenPoolBalance = poolBalances[outcomeIndex];
        uint endingOutcomeBalance = sellTokenPoolBalance.mul(ONE);
        for (uint i = 0; i < poolBalances.length; i++) {
            if (i != outcomeIndex) {
                uint poolBalance = poolBalances[i];
                endingOutcomeBalance = endingOutcomeBalance.mul(poolBalance).ceildiv(
                    poolBalance.sub(returnAmountPlusFees)
                );
            }
        }
        require(endingOutcomeBalance > 0, "must have non-zero balances");

        return returnAmountPlusFees.add(endingOutcomeBalance.ceildiv(ONE)).sub(sellTokenPoolBalance);
    }

    function getUserBetRecordLength(address account) public view returns (uint256 length) {
        return userBetRecords[account].length;
    }

    function getUserBetRecords(address account, uint256 index) public view returns (
        uint256 time,
        uint256 inAmount,
        uint256 outAmount,
        uint256 positionId,
        uint256 outcomeIndex,
        bool redeem) {
        return (
        userBetRecords[account][index].timestamp,
        userBetRecords[account][index].collateralAmount,
        userBetRecords[account][index].outcomeTokensToBuy,
        userBetRecords[account][index].positionId,
        userBetRecords[account][index].outcomeIndex,
        conditionalTokens.userRedeemRecords(account)
        );
    }

    function callOdds(uint256 amount) public view returns (uint256 odd1, uint256 odd2, uint256 odd3) {
        odd1 = calcBuyAmount(amount, 0) * ONE / amount;
        odd2 = calcBuyAmount(amount, 1) * ONE / amount;
        odd3 = calcBuyAmount(amount, 2) * ONE / amount;
    }

    function calPrice(uint256 index) public view returns (uint256) {
        uint256 collateralAmount = collateralToken.balanceOf(address(conditionalTokens));
        uint256[] memory tokenBalances = getPoolBalances();
        return tokenBalances[index] * ONE / collateralAmount;
    }

    // ================================ SETTING ================================
    function pause() public onlyOwner atStage(Stage.Running) {
        stage = Stage.Paused;
    }

    function resume() public onlyOwner atStage(Stage.Paused) {
        stage = Stage.Running;
    }

    function setEndTime(uint _endTime) public onlyOwner {
        endTime = _endTime;
    }

    function setRecordContract(Record _record) public onlyOwner {
        record = _record;
    }

    // ================================ ACTION ================================
    function addFunding(uint addedFunds, uint[] calldata distributionHint) external onlyOwner {
        require(addedFunds > 0, "funding must be non-zero");

        uint[] memory sendBackAmounts = new uint[](positionIds.length);
        uint poolShareSupply = totalSupply();
        uint mintAmount;
        if (poolShareSupply > 0) {
            require(distributionHint.length == 0, "cannot use distribution hint after initial funding");
            uint[] memory poolBalances = getPoolBalances();
            uint poolWeight = 0;
            for (uint i = 0; i < poolBalances.length; i++) {
                uint balance = poolBalances[i];
                if (poolWeight < balance)
                    poolWeight = balance;
            }

            for (uint i = 0; i < poolBalances.length; i++) {
                uint remaining = addedFunds.mul(poolBalances[i]) / poolWeight;
                sendBackAmounts[i] = addedFunds.sub(remaining);
            }

            mintAmount = addedFunds.mul(poolShareSupply) / poolWeight;
        } else {
            if (distributionHint.length > 0) {
                require(distributionHint.length == positionIds.length, "hint length off");
                uint maxHint = 0;
                for (uint i = 0; i < distributionHint.length; i++) {
                    uint hint = distributionHint[i];
                    if (maxHint < hint)
                        maxHint = hint;
                }

                // [20, 30]
                // maxHint = 30
                for (uint i = 0; i < distributionHint.length; i++) {
                    // 1、 100 * 20 / 30
                    // 2、 100
                    uint remaining = addedFunds.mul(distributionHint[i]) / maxHint;
                    require(remaining > 0, "must hint a valid distribution");
                    // 1、 100 - （100 * 20 / 30) = 33.33
                    // 2、 0
                    sendBackAmounts[i] = addedFunds.sub(remaining);
                }
            }

            mintAmount = addedFunds;
        }

        require(collateralToken.transferFrom(msg.sender, address(this), addedFunds), "funding transfer failed");
        require(collateralToken.approve(address(conditionalTokens), addedFunds), "approval for splits failed");
        splitPositionThroughAllConditions(addedFunds);

        _mint(msg.sender, mintAmount);

        // [33.33, 0]
        conditionalTokens.safeBatchTransferFrom(address(this), msg.sender, positionIds, sendBackAmounts, "");

        // transform sendBackAmounts to array of amounts added
        for (uint i = 0; i < sendBackAmounts.length; i++) {
            sendBackAmounts[i] = addedFunds.sub(sendBackAmounts[i]);
        }

        emit FPMMFundingAdded(msg.sender, sendBackAmounts, mintAmount);
    }

    function removeFunding(uint sharesToBurn) external onlyOwner {
        uint[] memory poolBalances = getPoolBalances();

        uint[] memory sendAmounts = new uint[](poolBalances.length);

        uint poolShareSupply = totalSupply();
        for (uint i = 0; i < poolBalances.length; i++) {
            sendAmounts[i] = poolBalances[i].mul(sharesToBurn) / poolShareSupply;
        }

        uint collateralRemovedFromFeePool = collateralToken.balanceOf(address(this));

        _burn(msg.sender, sharesToBurn);
        collateralRemovedFromFeePool = collateralRemovedFromFeePool.sub(
            collateralToken.balanceOf(address(this))
        );

        conditionalTokens.safeBatchTransferFrom(address(this), msg.sender, positionIds, sendAmounts, "");

        emit FPMMFundingRemoved(msg.sender, sendAmounts, collateralRemovedFromFeePool, sharesToBurn);
    }

    // investmentAmount的单位是质押的token
    function buy(uint investmentAmount, uint outcomeIndex, uint minOutcomeTokensToBuy) external atStage(Stage.Running) {
        require(now < endTime, "bet closed");
        uint outcomeTokensToBuy = calcBuyAmount(investmentAmount, outcomeIndex);
        require(outcomeTokensToBuy >= minOutcomeTokensToBuy, "minimum buy amount not reached");

        require(collateralToken.transferFrom(msg.sender, address(this), investmentAmount), "cost transfer failed");

        uint feeAmount = investmentAmount.mul(fee) / ONE;
        feePoolWeight = feePoolWeight.add(feeAmount);
        uint investmentAmountMinusFees = investmentAmount.sub(feeAmount);
        require(collateralToken.approve(address(conditionalTokens), investmentAmountMinusFees), "approval for splits failed");
        splitPositionThroughAllConditions(investmentAmountMinusFees);

        conditionalTokens.safeTransferFrom(address(this), msg.sender, positionIds[outcomeIndex], outcomeTokensToBuy, "");

        BetRecord memory betRecord = BetRecord({
        timestamp : block.timestamp,
        collateralAmount : investmentAmount,
        outcomeTokensToBuy : outcomeTokensToBuy,
        positionId : positionIds[outcomeIndex],
        outcomeIndex : outcomeIndex
        });

        userBetRecords[msg.sender].push(betRecord);

        // 记录用户的投注记录(买)
        record.addRecord(msg.sender, address(conditionalTokens), address(this), investmentAmount, outcomeTokensToBuy, outcomeIndex, 0);

        emit FPMMBuy(msg.sender, investmentAmount, feeAmount, outcomeIndex, outcomeTokensToBuy);
    }

    // returnAmount的单位是下注的token, 比如PHM
    function sell(uint returnAmount, uint outcomeIndex, uint maxOutcomeTokensToSell) external atStage(Stage.Running) {
        require(now < endTime, "bet closed");
        uint outcomeTokensToSell = calcSellAmount(returnAmount, outcomeIndex);
        require(outcomeTokensToSell <= maxOutcomeTokensToSell, "maximum sell amount exceeded");

        conditionalTokens.safeTransferFrom(msg.sender, address(this), positionIds[outcomeIndex], outcomeTokensToSell, "");

        uint feeAmount = returnAmount.mul(fee) / (ONE.sub(fee));
        feePoolWeight = feePoolWeight.add(feeAmount);
        uint returnAmountPlusFees = returnAmount.add(feeAmount);
        mergePositionsThroughAllConditions(returnAmountPlusFees);

        require(collateralToken.transfer(msg.sender, returnAmount), "return transfer failed");

        // 记录用户的投注记录(卖)
        record.addRecord(msg.sender, address(conditionalTokens), address(this), returnAmount, outcomeTokensToSell, outcomeIndex, 1);

        emit FPMMSell(msg.sender, returnAmount, feeAmount, outcomeIndex, outcomeTokensToSell);
    }

    function splitPositionThroughAllConditions(uint amount) private {
        for (uint i = conditionIds.length - 1; int(i) >= 0; i--) {
            uint[] memory partition = generateBasicPartition(outcomeSlotCounts[i]);
            for (uint j = 0; j < collectionIds[i].length; j++) {
                conditionalTokens.splitPosition(collateralToken, collectionIds[i][j], conditionIds[i], partition, amount);
            }
        }
    }

    function mergePositionsThroughAllConditions(uint amount) private {
        for (uint i = 0; i < conditionIds.length; i++) {
            uint[] memory partition = generateBasicPartition(outcomeSlotCounts[i]);
            for (uint j = 0; j < collectionIds[i].length; j++) {
                conditionalTokens.mergePositions(collateralToken, collectionIds[i][j], conditionIds[i], partition, amount);
            }
        }
    }

    function withdrawFees(address account) public {
        uint rawAmount = feePoolWeight.mul(balanceOf(account)) / totalSupply();
        uint withdrawableAmount = rawAmount.sub(withdrawnFees[account]);
        if (withdrawableAmount > 0) {
            withdrawnFees[account] = rawAmount;
            totalWithdrawnFees = totalWithdrawnFees.add(withdrawableAmount);
            require(collateralToken.transfer(account, withdrawableAmount), "withdrawal transfer failed");
        }
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal {
        if (from != address(0)) {
            withdrawFees(from);
        }

        uint totalSupply = totalSupply();
        uint withdrawnFeesTransfer = totalSupply == 0 ?
        amount :
        feePoolWeight.mul(amount) / totalSupply;

        if (from != address(0)) {
            withdrawnFees[from] = withdrawnFees[from].sub(withdrawnFeesTransfer);
            totalWithdrawnFees = totalWithdrawnFees.sub(withdrawnFeesTransfer);
        } else {
            feePoolWeight = feePoolWeight.add(withdrawnFeesTransfer);
        }
        if (to != address(0)) {
            withdrawnFees[to] = withdrawnFees[to].add(withdrawnFeesTransfer);
            totalWithdrawnFees = totalWithdrawnFees.add(withdrawnFeesTransfer);
        } else {
            feePoolWeight = feePoolWeight.sub(withdrawnFeesTransfer);
        }
    }


    function onERC1155Received(
        address operator,
        address from,
        uint256 id,
        uint256 value,
        bytes calldata data
    ) external returns (bytes4) {
        if (operator == address(this)) {
            return this.onERC1155Received.selector;
        }
        return 0x0;
    }

    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    ) external returns (bytes4) {
        if (operator == address(this) && from == address(0)) {
            return this.onERC1155BatchReceived.selector;
        }
        return 0x0;
    }
}
