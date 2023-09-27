pragma experimental ABIEncoderV2;
pragma solidity ^0.5.0;

import {ERC20} from "./ERC20.sol";
import {Ownable} from './Ownable.sol';
import {ConditionalTokens} from './ConditionalTokens.sol';

contract Record is Ownable {

    struct BetRecordItem {
        address conditionToken;
        address market;
        uint256 timestamp;
        uint256 collateralAmount;
        uint256 tokensAmount;
        uint256 outcomeIndex;
        // 0 buy, 1 sell
        uint256 action;
    }

    mapping(address => BetRecordItem[]) userBetRecords;

    mapping(address => bool) associatedContracts;

    // ========================= MODIFIER =========================
    modifier onlyAssociatedContract {
        require(associatedContracts[msg.sender] == true, "Only the associated contract can perform this action");
        _;
    }

    // ========================= SETTING =========================
    function setAssociatedContract(address _associatedContract) external onlyOwner {
        associatedContracts[_associatedContract] = true;
    }

    function removeAssociatedContract(address _associatedContract) external onlyOwner {
        associatedContracts[_associatedContract] = false;
    }

    // ========================= VIEW =========================
    function getRecordsLength(address user) public view returns (uint256) {
        return userBetRecords[user].length;
    }

    function getOneRecord(address user, uint256 index) public view returns (BetRecordItem memory, bool isReportPayouts, bool isRedeem, bool correct) {
        ConditionalTokens conditionalTokens = ConditionalTokens(userBetRecords[user][index].conditionToken);
        bytes32 conditionId = conditionalTokens.getSimpleConditionId();
        uint outcomeSlotCount = conditionalTokens.publicOutcomeSlotCount();
        if (outcomeSlotCount == 0) {
            correct = false;
        } else if (conditionalTokens.payoutNumerators(conditionId, userBetRecords[user][index].outcomeIndex) > 0) {
            correct = true;
        } else {
            correct = false;
        }

        return (userBetRecords[user][index], conditionalTokens.isReportPayouts(), conditionalTokens.userRedeemRecords(user), correct);
    }

    // ========================= ACTION =========================
    function addRecord(address user, address conditionToken, address market, uint256 collateralAmount, uint256 tokensAmount, uint256 outcomeIndex, uint256 action) public onlyAssociatedContract {
        BetRecordItem memory betRecord = BetRecordItem({
        conditionToken : conditionToken,
        timestamp: now,
        market : market,
        collateralAmount : collateralAmount,
        tokensAmount : tokensAmount,
        outcomeIndex : outcomeIndex,
        action : action
        });

        userBetRecords[user].push(betRecord);
    }
}
