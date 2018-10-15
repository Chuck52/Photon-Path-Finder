pragma solidity ^0.4.23;

import "./Token.sol";
import "./Utils.sol";
import "./ECVerify.sol";
import "./SecretRegistry.sol";

/// @title TokenNetwork -- a network of a specific token
/// @author SmartMeshFoundation
/// @notice In our SmartRaiden version 1.0, we prefer an alternative method that just store all tokens in the channel network
/// @notice into one single contract, instead of dividing them into every single channel.
contract TokenNetwork is Utils {

    string constant public contract_version = "0.4._";
    string public constant signature_prefix = '\x19Ethereum Signed Message:\n';
    // Instance of the token used as digital currency by the channels
    Token public token;

    // Instance of SecretRegistry used for storing secrets revealed in a mediating transfer.
    SecretRegistry public secret_registry;

    // punish_block_number is the time (block number) left for any dishonest counterpart to be punished
    // After a pre-set 'settle time' period, node can submit proofs without any concern that he has no chance
    // to submit punish proofs for his counterpart's submitted updatetransfer & unlock at the time of settle.
    // It's much reasonable to set this variable to a larger digit, like 100 in the version of release.
    uint64 constant public punish_block_number = 5;

    // Chain ID as specified by EIP155 used in balance proof signatures to avoid replay attacks
    uint256 public chain_id;

    // Channel identifier is sha3(participant1,participant2,tokenNetworkAddress)
    mapping(bytes32 => Channel) public channels;

    // data structure for Channel Participant
    struct Participant {
        // Total amount of token transferred to this smart contract
        uint256 deposit;

        /*
            locksroot,transferred_amount 的 hash
            主要是出于节省 gas 的目的,真正的locksroot,transferred_amount都通过参数传递,可以较大幅度降低 gas
        */
        // It is the hash for locksroot & transferred_amount.
        //
        bytes24 balance_hash;

        // nonce is used as the transaction serial number.
        // It will increase when a transaction occurs.
        uint64 nonce;

        // The result for unlock.
        mapping(bytes32 => bool) unlocked_locks;
    }

    // data structure for Payment Channel
    struct Channel {

        // time period for channel settlement
        uint64 settle_timeout;

        /*
            通道 settle block number.
        */
        // time period for settle represented by block number.
        uint64 settle_block_number;

        /*
            通道打开时间,主要用于防止重放攻击
            用户关于通道的任何签名都应该包含channel id+open_blocknumber
        */
        // It represents the time period during which a channel is open.
        // Any user signature should contain channel_id + open_block_number.
        uint64 open_block_number;

        // Channel state
        // 1 = open, 2 = closed
        // 0 = non-existent or settled
        uint8 state;

        // a hash table the key of which is address and the value of which is Participant structure.
        mapping(address => Participant) participants;
    }

    // event emitted while channel successfully opened.
    event ChannelOpened(
        bytes32 indexed channel_identifier,
        address participant1,
        address participant2,
        uint64 settle_timeout
    );

    // event emitted while channel opened and some amount of tokens deposited successfully.
    event ChannelOpenedAndDeposit(
        bytes32 indexed channel_identifier,
        address participant1,
        address participant2,
        uint64 settle_timeout,
        uint256 participant1_deposit
    );

    // event emitted while
    event ChannelNewDeposit(
        bytes32 indexed channel_identifier,
        address participant,
        uint256 total_deposit
    );

    // 如果改变 balance_hash, 那么应该通过 event 把balance_hash 中的两个变量都暴露出来.
    // If balance_hash changed, then event should be invoked to reveal these two variables in balance_hash.
    event ChannelClosed(bytes32 indexed channel_identifier, address closing_participant, bytes32 locksroot, uint256 transferred_amount);

    // 如果改变 balance_hash, 那么应该通过 event 把两个个变量都暴露出来.
    // If balance_hash changed, then event
    event ChannelUnlocked(
        bytes32 indexed channel_identifier,
        address payer_participant,
        bytes32 lockhash, //解锁的lock
        uint256 transferred_amount
    );

    // 如果改变 balance_hash, 那么应该通过 event 把相关变量都暴露出来.
    // If balance_hash changed, then event should be invoked to reveal relevant variables.
    event BalanceProofUpdated(
        bytes32 indexed channel_identifier,
        address participant,
        bytes32 locksroot,
        uint256 transferred_amount
    );

    // 通道上发生了惩罚事件,受益人是谁.
    // Event to reveal the beneficiary who will get all the tokens deposited in this channel,
    // when the other node attempts to do fraudulent behavior.
    event ChannelPunished(
        bytes32 indexed channel_identifier,
        address beneficiary
    );

    // event emitted while channel successfully settled.
    event ChannelSettled(
        bytes32 indexed channel_identifier,
        uint256 participant1_amount,
        uint256 participant2_amount
    );

    // event emitted while
    event ChannelCooperativeSettled(
        bytes32 indexed channel_identifier,
        uint256 participant1_amount,
        uint256 participant2_amount
    );

    // event emitted while one participant has intention to withdraw tokens in the channel.
    event ChannelWithdraw(
        bytes32 indexed channel_identifier,
        address participant1,
        uint256 participant1_balance,
        address participant2,
        uint256 participant2_balance
    );

    // notice that certain conditions must be met with settle_timeout.
    modifier settleTimeoutValid(uint64 timeout) {
        require(timeout >= 6 && timeout <= 2700000);
        _;
    }

    /// @notice contract constructor.
    /// @param _token_address       address in which tokens of this contract are from.
    /// @param _secret_registry     address to register secret for this network.
    /// @param _chain_id            no need to explain...
    constructor(address _token_address, address _secret_registry, uint256 _chain_id)
    public
    {
        require(_token_address != 0x0);
        require(_secret_registry != 0x0);
        require(_chain_id > 0);
        require(contractExists(_token_address));
        require(contractExists(_secret_registry));

        token = Token(_token_address);

        secret_registry = SecretRegistry(_secret_registry);
        chain_id = _chain_id;

        // Make sure the contract is indeed a token contract
        require(token.totalSupply() > 0);
    }

    /*
        允许任何人调用,多次调用.
        创建通道:
        1. 允许任意两个不同有效地址之间创建通道
        2. 两地址之间不能有多个通道
        参数数说明:
        participant1,participant2 通道参与双方,都必须是有效地址,且不能相同
        settle_timeout 通道结算等待时间
    */
    /// @notice Function to create channels between two distinct valid addresses. Permitted to any user and multiple invocation.
    /// @dev    these two addresses can't hold multiple channels, only one.
    /// @param  participant1 & participant2 denote these two distinct addresses; settle_timeout time that channel enforcing settle process.
    function openChannel(address participant1, address participant2, uint64 settle_timeout)
    settleTimeoutValid(settle_timeout)
    public
    {
        bytes32 channel_identifier;
        require(participant1 != 0x0);
        require(participant2 != 0x0);
        require(participant1 != participant2);
        channel_identifier = getChannelIdentifier(participant1, participant2);
        Channel storage channel = channels[channel_identifier];

        // ensure that channel has not been created.
        require(channel.state == 0);
        // Store channel information
        channel.settle_timeout = settle_timeout;
        channel.open_block_number = uint64(block.number);
        // Mark channel as opened
        channel.state = 1;

        emit ChannelOpened(channel_identifier, participant1, participant2, settle_timeout);
    }

    /// @notice Function to create channels with some amount of deposits.
    /// @dev    this function combines features of openChannel & deposit together, as a facilitate function.
    /// @param  participant & partner  two parties that this channel connects with.
    /// @param  settle_timeout time period during which channel enforces settle process.
    /// @param  deposit 256 bits unsigned int digits representing deposit.
    function openChannelWithDeposit(address participant, address partner, uint64 settle_timeout, uint256 deposit)
    external
    {
        openChannelWithDepositInternal(participant, partner, settle_timeout, deposit, msg.sender, true);
    }

    /*
        必须在通道 open 状态调用,可以重复调用多次,任何人都可以调用.
        参数说明:
        participant 存钱给谁
        partner 通道另一方
        amount 存多少 token
    */
    /// @notice Function to deposit valuable tokens into this channel.
    /// @dev    this function enable to be invoked after anyone have already opened the channel.
    /// @param  participant the recipient of deposited tokens.
    /// @param  partner     the counterpart corresponding to participant.
    function deposit(address participant, address partner, uint256 amount)
    external
    {
        depositInternal(participant, partner, amount, msg.sender, true);
    }

    /*
        有三种调用途径:
        分别是
        1. 用户直接调用openChannelWithDeposit,
        2. token 是 ERC223,通过 tokenFallback 调用
        3. token 提供了 ApproveAndCall, 通过receiveApproval调用
    */
    /// @notice function to open channel and meanwhile make some deposits inside with certain threshold of settle_timeout.
    /// @dev    parameter settle_timeout has to meet certain threshold in which case this function is able to operate.
    /// @param participant      channel creator
    /// @param partner          the counterpart corresponding to participant.
    /// @param settle_timeout   time period for channel to settle.
    /// @param amount           the amount of tokens to be deposited into this channel.
    /// @param from             another third party address to deposit tokens if need_transfer is true.
    /// @param need_transfer    a boolean value to confirm whether this channel need any token from outside.
    function openChannelWithDepositInternal(address participant, address partner, uint64 settle_timeout, uint256 amount, address from, bool need_transfer)
    settleTimeoutValid(settle_timeout)
    internal
    {
        bytes32 channel_identifier;
        require(participant != 0x0);
        require(partner != 0x0);
        require(participant != partner);
        require(amount > 0);
        channel_identifier = getChannelIdentifier(participant, partner);
        Channel storage channel = channels[channel_identifier];
        Participant storage participant_state = channel.participants[participant];

        // make sure that this channel has not been created.
        require(channel.state == 0);

        // Store channel information
        channel.settle_timeout = settle_timeout;
        channel.open_block_number = uint64(block.number);

        // Mark channel as opened
        channel.state = 1;
        if (need_transfer) {
            require(token.transferFrom(from, address(this), amount));
        }
        participant_state.deposit = amount;
        emit ChannelOpenedAndDeposit(channel_identifier, participant, partner, settle_timeout, amount);
    }

    /*
        必须在通道 open 状态调用,可以重复调用多次,任何人都可以调用.
        参数说明:
        participant 存钱给谁
        partner 通道另一方
        amount 存多少 token
    */
    /// @notice internal function to be invoked when depositing tokens into this channel.
    /// @dev    this function must be invoked when channel has opened yet.
    /// @param participant      channel creator
    /// @param partner          the counterpart corresponding to participant.
    /// @param amount           the amount of tokens deposited in this channel.
    /// @param from             another address that transfers tokens to this channel.
    /// @param need_transfer    a boolean value confirms whether this channel need another source of value.
    function depositInternal(address participant, address partner, uint256 amount, address from, bool need_transfer)
    internal
    {
        /*
        为0,可能会在 TransferFrom 的时候成功,但是没有任何意义.

        */
        require(amount > 0);
        uint256 total_deposit;
        bytes32 channel_identifier;
        channel_identifier = getChannelIdentifier(participant, partner);
        Channel storage channel = channels[channel_identifier];
        Participant storage participant_state = channel.participants[participant];
        total_deposit = participant_state.deposit;
        if (need_transfer) {
            // Do the transfer
            require(token.transferFrom(from, address(this), amount));
        }
        require(channel.state == 1);

        // Update the participant's channel deposit
        total_deposit += amount;
        participant_state.deposit = total_deposit;

        emit ChannelNewDeposit(channel_identifier, participant, total_deposit);
    }

    /*
        erc223 tokenFallback
        允许用户
    */
    /// @notice function to refund tokens to which account they originally belong to.
    /// @dev
    /// @param from     default to 0x0.
    /// @param value    the amount of tokens to be refund.
    /// @param data for callback
    function tokenFallback(address /*from*/, uint value, bytes data) external returns (bool success){
        require(msg.sender == address(token));
        fallback(0, value, data, false);
        return true;
    }

    /*
        常用的 approve and call
     */
    /// @notice receiveApproval
    /// @dev receiveApproval
    /// @param from arg
    /// @param value arg
    /// @param token_ arg
    /// @param data arg
    /// @return success arg
    function receiveApproval(address from, uint256 value, address token_, bytes data) external returns (bool success) {
        require(token_ == address(token));
        fallback(from, value, data, true);
        return true;
    }

    /// @notice arg
    /// @dev arg
    /// @param from  arg
    /// @param value            the amount of tokens to be send back to original address.
    /// @param data arg
    /// @param need_transfer    a boolean value that will be used in internal call under some conditions.
    function fallback(address from, uint256 value, bytes data, bool need_transfer) internal {
        uint256 func;
        address participant;
        address partner;
        uint64 settle_timeout;
        assembly {
            func := mload(add(data, 32))
        }

        if (func == 1) {
            (participant, partner, settle_timeout) = getOpenWithDepositArg(data);
            openChannelWithDepositInternal(participant, partner, settle_timeout, value, from, need_transfer);
        } else if (func == 2) {
            (participant, partner) = getDepositArg(data);
            depositInternal(participant, partner, value, from, need_transfer);
        } else {
            revert();
        }
    }

    /*
       功能:在不关闭通道的情况下提现,任何人都可以调用

       一旦一方提出 withdraw, 实际上和提出 cooperative settle 效果是一样的,就是不能再进行任何交易了.
       必须等待 withdraw 完成才能重置交易数据,重新开始交易
       参数说明:
       participant,partner 通道参与双方
       participant_balance: 取款方的 balance 是多少
       participant_withdraw:取款方需要取多少钱
       participant_signature,partner_signature 双方对这次提现的签名
    */
    /// @notice function to withdraw tokens in this token network.
    /// @param participant arg
    /// @param participant_balance arg
    /// @param participant_withdraw arg
    /// @param partner arg
    /// @param participant_signature arg
    /// @param partner_signature arg
    function withDraw(
        address participant,
        address partner,
        uint256 participant_balance,
        uint256 participant_withdraw,
        bytes participant_signature,
        bytes partner_signature
    )
    public
    {
        uint256 total_deposit;
        bytes32 channel_identifier;
        uint64 open_block_number;
        uint256 partner_balance;
        channel_identifier = getChannelIdentifier(participant, partner);
        Channel storage channel = channels[channel_identifier];
        open_block_number = channel.open_block_number;
        require(channel.state == 1);
        // 验证双方签名有效
        require(participant == recoverAddressFromWithdrawProof(channel_identifier,
            participant,
            participant_balance,
            participant_withdraw,
            open_block_number,
            participant_signature
        ));
        require(partner == recoverAddressFromWithdrawProof(channel_identifier,
            participant,
            participant_balance,
            participant_withdraw,
            open_block_number,
            partner_signature
        ));

        Participant storage participant_state = channel.participants[participant];
        Participant storage partner_state = channel.participants[partner];
        //The sum of the provided deposit must be equal to the total available deposit
        total_deposit = participant_state.deposit + partner_state.deposit;
        partner_balance = total_deposit - participant_balance;


        /*
            谨慎一点,应该先扣钱再转账,尽量按照规范来,如果有的话.
        */

        /*
            提议提现的人,金额一定不能是0,否则就应该调用 cooperative settle
        */
        require(participant_withdraw > 0);
        require(participant_withdraw <= participant_balance);
        //防止溢出
        require(total_deposit >= participant_balance);
        require(total_deposit >= partner_balance);

        participant_state.deposit = participant_balance - participant_withdraw;
        partner_state.deposit = partner_balance;

        // 相当于 通道 settle 又新开了.老的签名都作废了.
        channel.open_block_number = uint64(block.number);
        require(token.transfer(participant, participant_withdraw));


        //channel's status right now
        emit ChannelWithdraw(channel_identifier, participant, participant_balance, partner, partner_balance);

    }


    /*
        只能是通道参与方调用,只能调用一次,必须是在通道打开状态调用.
        参数说明:
        partner 通道的另一方
        transferred_amount 另一方给的直接转账金额
        locksroot 另一方彻底完成交易集合
        nonce 另一方交易编号
        additional_hash 为了辅助实现用
        signature partner 的签名
    */
    /// @notice  function to close currently-opened payment channel.
    /// @dev     It has to be invoked only once, and operator must be channel participants.
    /// @param partner              participant at the other side of this channel.
    /// @param transferred_amount   the amount of tokens partner has transferred.
    /// @param locksroot            transaction set of partner that has been completed.
    /// @param nonce               transaction serial numbers from partner
    /// @param additional_hash      auxiliary hash for implementation.
    /// @param signature            signature from partner
    function closeChannel(
        address partner,
        uint256 transferred_amount,
        bytes32 locksroot,
        uint64 nonce,
        bytes32 additional_hash,
        bytes signature
    )
    public
    {
        bytes32 channel_identifier;
        address recovered_partner_address;
        channel_identifier = getChannelIdentifier(msg.sender, partner);
        Channel storage channel = channels[channel_identifier];
        require(channel.state == 1);
        // Mark the channel as closed and mark the closing participant
        channel.state = 2;
        // This is the block number at which the channel can be settled.
        channel.settle_block_number = channel.settle_timeout + uint64(block.number);
        // Nonce 0 means that the closer never received a transfer, therefore never received a
        // balance proof, or he is intentionally not providing the latest transfer, in which case
        // the closing party is going to lose the tokens that were transferred to him.
        if (nonce > 0) {
            Participant storage partner_state = channel.participants[partner];
            recovered_partner_address = recoverAddressFromBalanceProof(
                channel_identifier,
                transferred_amount,
                locksroot,
                nonce,
                channel.open_block_number,
                additional_hash,
                signature
            );
            require(partner == recovered_partner_address);
            partner_state.balance_hash = calceBalanceHash(transferred_amount, locksroot);
            partner_state.nonce = nonce;
        }
        emit ChannelClosed(channel_identifier, msg.sender, locksroot, transferred_amount);
    }

    /*
        任何人都可以调用,可以调用多次,只要在有效期内.
        包括 closing 方和非 close 方都可以反复调用在,只要能够提供更新的 nonce 即可.
        目的是更新partner的 balance proof
        参数说明:
        partner: 证据待更新一方
        participant: 委托第三方进行对手证据更新一方
        transferred_amount locksroot 的直接转账金额
        locksroot partner 未彻底完成交易集合
        nonce partner 给出交易变化
        additional_hash 实现辅助信息
        partner_signature partner 一方对于给出证据的签名
        participant_signature 委托人对于委托的签名
    */
    /// @notice function to offer delegation service to update BalanceProof of partner onto the chain.
    /// @dev    This is a delegation function so that anyone in this network
    /// @dev    including not not limited to channel participants can invoke it, even multiple times.
    /// @param partner                  one whose BalanceProof needs to be updated.
    /// @param participant              one that delegate another node to update partner's BalanceProof.
    /// @param transferred_amount       the amount of tokens transferred directly.
    /// @param locksroot                transaction set that partner has not completed yet.
    /// @param nonce                   transaction serial number of partner.
    /// @param additional_hash          auxiliary information
    /// @param partner_signature        signature from partner
    /// @param participant_signature    signature from participant
    function updateBalanceProofDelegate(
        address partner,
        address participant,
        uint256 transferred_amount,
        bytes32 locksroot,
        uint64 nonce,
        bytes32 additional_hash,
        bytes partner_signature,
        bytes participant_signature
    )
    public
    {
        bytes32 channel_identifier;
        uint64 settle_block_number;
        channel_identifier = getChannelIdentifier(partner, participant);
        Channel storage channel = channels[channel_identifier];
        Participant storage partner_state = channel.participants[partner];
        require(channel.state == 2);

        /*
            被委托人只能在结算时间的后一半进行
        */
        settle_block_number = channel.settle_block_number;
        require(settle_block_number >= block.number);
        require(block.number >= settle_block_number - channel.settle_timeout / 2);
        require(nonce > partner_state.nonce);

        require(participant == recoverAddressFromBalanceProofDelegate(
            channel_identifier,
            transferred_amount,
            locksroot,
            nonce,
            channel.open_block_number,
            participant_signature
        ));
        require(partner == recoverAddressFromBalanceProof(
            channel_identifier,
            transferred_amount,
            locksroot,
            nonce,
            channel.open_block_number,
            additional_hash,
            partner_signature
        ));
        partner_state.balance_hash = calceBalanceHash(transferred_amount, locksroot);
        partner_state.nonce = nonce;
        emit BalanceProofUpdated(channel_identifier, partner, locksroot, transferred_amount);
    }

    /*
        只能通道参与方调用,不限制 close 和非 close 方,可以调用多次,只要在有效期内.
        包括 closing 方和非 close 方都可以反复调用在,只要能够提供更新的 nonce 即可.
        目的是更新partner 的 balance proof, 只是自己直接调用,不经过第三方委托.
        参数说明:
        partner: 证据待更新一方
        transferred_amount locksroot 的直接转账金额
        locksroot partner 未彻底完成交易集合
        nonce partner 给出交易变化
        additional_hash 实现辅助信息
        partner_signature partner 一方对于给出证据的签名
   */
    /// @notice function to update BalanceProof of the other channel participant.
    /// @dev    only channel participants can invoke this function,
    /// @dev    and within valid period, it can be invoked multiple times.
    /// @param partner              one whose BalanceProof needs to be updated.
    /// @param transferred_amount   the amount of tokens transferred directly.
    /// @param locksroot            the set of incomplete transactions of partner.
    /// @param nonce               transaction serial number given by partner.
    /// @param additional_hash      auxiliary information
    /// @param partner_signature    signature of partner
    function updateBalanceProof(
        address partner,
        uint256 transferred_amount,
        bytes32 locksroot,
        uint64 nonce,
        bytes32 additional_hash,
        bytes partner_signature
    )
    public
    {
        bytes32 channel_identifier;
        channel_identifier = getChannelIdentifier(partner, msg.sender);
        Channel storage channel = channels[channel_identifier];
        Participant storage partner_state = channel.participants[partner];
        require(channel.state == 2);
        require(channel.settle_block_number >= block.number);
        //明确要求,必须有更新的 balance proof, 否则没必要调用
        require(nonce > partner_state.nonce);

        require(partner == recoverAddressFromBalanceProof(
            channel_identifier,
            transferred_amount,
            locksroot,
            nonce,
            channel.open_block_number,
            additional_hash,
            partner_signature
        ));
        partner_state.balance_hash = calceBalanceHash(transferred_amount, locksroot);
        partner_state.nonce = nonce;
        emit BalanceProofUpdated(channel_identifier, partner, locksroot, transferred_amount);
    }

    /*
        任何人都可以调用,可以反复调用多次
        存在第三方和对手串谋 unlock 的可能,导致委托人损失所有金额
        所以必须有委托人签名
        参数说明:
        partner: 通道参与一方,他发出的某个交易没有彻底完成
        participant 通道参与另一方,委托人
        transferred_amount:partner 给出的直接转账金额
        expiration,amount,secret_hash: 交易中未彻底完成的锁
        merkle_proof: 证明此锁包含在 locksroot 中
        participant_signature: 委托第三方的签名
    */
    /// @notice function to unlock delegation service.
    /// @dev    Anyone in this network has ability to invoke it, with possibility that node receiving delegate
    /// @dev    and participant collude to steal tokens in it.
    /// @param  partner                 one that corresponds to participant in this channel, whose transaction has not completed yet.
    /// @param  participant             one that delegate services in the channel.
    /// @param  transferred_amount      the amount of tokens transferred directly from partner.
    /// @param  expiration arg
    /// @param  amount arg
    /// @param  secret_hash arg
    /// @param  merkle_proof            verify that this lock is contained in locksroot.
    /// @param  participant_signature   signature from delegation service.
    function unlockDelegate(
        address partner,
        address participant,
        uint256 transferred_amount,
        uint256 expiration,
        uint256 amount,
        bytes32 secret_hash,
        bytes merkle_proof,
        bytes participant_signature
    ) public {
        bytes32 channel_identifier;
        channel_identifier = getChannelIdentifier(partner, participant);

        // verify that this unlock is delegate by participant .
        require(participant == recoverAddressFromUnlockDelegateProof(
            channel_identifier,
            msg.sender,
            expiration,
            amount,
            secret_hash,
            participant_signature
        ));

        // actual process of unlock.
        unlockInternal(partner, participant, transferred_amount, expiration, amount, secret_hash, merkle_proof);
    }

    /*
        只允许通道参与方可以调用,要在有效期内调用.通道状态必须是关闭,
        并且必须在 settle 之前来调用.只能由通道参与方来调用.
        参数说明:
        partner: 通道参与一方,他发出的某个交易没有彻底完成
        transferred_amount:partner 给出的直接转账金额
        expiration,amount,secret_hash: 交易中未彻底完成的锁
        merkle_proof: 证明此锁包含在 locksroot 中
    */
    /// @notice function to unlock the time hash lock within a transfer.
    /// @param partner arg
    /// @param transferred_amount arg
    /// @param expiration arg
    /// @param amount arg
    /// @param secret_hash arg
    /// @param merkle_proof arg
    function unlock(
        address partner,
        uint256 transferred_amount,
        uint256 expiration,
        uint256 amount,
        bytes32 secret_hash,
        bytes merkle_proof
    ) public
    {
        unlockInternal(partner, msg.sender, transferred_amount, expiration, amount, secret_hash, merkle_proof);
    }

    ///
    function unlockInternal(
        address partner,
        address participant,
        uint256 transferered_amount,
        uint256 expiration,
        uint256 amount,
        bytes32 secret_hash,
        bytes merkle_proof
    )
    internal
    {
        bytes32 channel_identifier;
        bytes32 lockhash_hash;
        bytes32 lockhash;
        uint256 reveal_block;
        bytes32 locksroot;

        channel_identifier = getChannelIdentifier(partner, participant);
        Channel storage channel = channels[channel_identifier];
        Participant storage partner_state = channel.participants[partner];
        /*
            通道状态正确
        */
        require(channel.settle_block_number >= block.number);
        require(channel.state == 2);

        /*
            对应的锁已经注册过,并且没有过期.
        */
        reveal_block = secret_registry.getSecretRevealBlockHeight(secret_hash);
        require(reveal_block > 0 && reveal_block <= expiration);

        /*
            证明这个所包含在 locksroot 中
        */
        lockhash = keccak256(abi.encodePacked(expiration, amount, secret_hash));
        locksroot = computeMerkleRoot(lockhash, merkle_proof);
        require(partner_state.balance_hash == calceBalanceHash(transferered_amount, locksroot));


        // 不允许重复 unlock 同一个锁,同时 nonce 变化以后还可以 再次 unlock 同一个锁
        lockhash_hash = keccak256(abi.encodePacked(partner_state.nonce, lockhash));

        require(partner_state.unlocked_locks[lockhash_hash] == false);
        partner_state.unlocked_locks[lockhash_hash] = true;


        /*
            会不会溢出呢? 两人持续交易?
            正常来说,不会,
            但是如果是恶意的会溢出,但是溢出对于 自身 也没好处啊
        */
        transferered_amount += amount;
        /*
            注意transferered_amount已经更新了,
        */
        partner_state.balance_hash = calceBalanceHash(transferered_amount, locksroot);
        emit ChannelUnlocked(channel_identifier, partner, lockhash, transferered_amount);
    }


    /*
        给 punish 一方留出了专门的 punishBlock 时间,punish 一方可以选择在那个时候提交证据,也可以在这之前.
        参数说明:
        beneficiary 惩罚提出者,也是受益人
        cheater 不诚实的交易一方
        lockhash 欺骗的具体锁
        additional_hash 实现辅助信息
        cheater_signature 不诚实一方对于放弃此锁的签名
    */
    ///
    function punishObsoleteUnlock(
        address beneficiary,
        address cheater,
        bytes32 lockhash,
        bytes32 additional_hash,
        bytes cheater_signature)
    public
    {
        bytes32 channel_identifier;
        bytes32 balance_hash;
        bytes32 lockhash_hash;
        channel_identifier = getChannelIdentifier(beneficiary, cheater);
        Channel storage channel = channels[channel_identifier];
        require(channel.state == 2);
        Participant storage beneficiary_state = channel.participants[beneficiary];
        balance_hash = beneficiary_state.balance_hash;

        // Check that the partner is a channel participant.
        // An empty locksroot means there are no pending locks
        require(balance_hash != 0);
        /*
        the cheater provides his signature of lockhash to annouce that he has already abandon this transfer.
        */
        require(cheater == recoverAddressFromDisposedProof(
            channel_identifier,
            lockhash,
            channel.open_block_number,
            additional_hash,
            cheater_signature
        ));
        Participant storage cheater_state = channel.participants[cheater];

        /*
            证明这个 lockhash 被对方提交了.
        */
        lockhash_hash = keccak256(abi.encodePacked(beneficiary_state.nonce, lockhash));
        require(beneficiary_state.unlocked_locks[lockhash_hash]);
        delete beneficiary_state.unlocked_locks[lockhash_hash];
        /*

        punish the cheater.
        set the transferAmount and locksroot to 0, nonce to max_uint64 and deposit to 0.
        */
        beneficiary_state.balance_hash = bytes24(0);
        beneficiary_state.nonce = 0xffffffffffffffff;
        beneficiary_state.deposit += cheater_state.deposit;
        cheater_state.deposit = 0;
        emit ChannelPunished(channel_identifier, beneficiary);
    }
    /*
        任何人都可以调用,只能调用一次
        目的 结算通道,将在通道中的押金退回到双方账户中
        参数说明:
        participant1,participant2 通道参与双方
        participant1_transferred_amount,participant2_transferred_amount: 双方给出的直接转账金额
        participant1_locksroot,participant2_locksroot 双方的未彻底完成交易集合
    */
    ///
    function settleChannel(
        address participant1,
        uint256 participant1_transferred_amount,
        bytes32 participant1_locksroot,
        address participant2,
        uint256 participant2_transferred_amount,
        bytes32 participant2_locksroot
    )
    public
    {
        uint256 participant1_amount;
        uint256 total_deposit;
        bytes32 channel_identifier;
        channel_identifier = getChannelIdentifier(participant1, participant2);
        Channel storage channel = channels[channel_identifier];
        // Channel must be closed
        require(channel.state == 2);

        /*
            Settlement window must be over
            真正能 settle 并不是 settle block number, 还要加上 punish_block_number,
            这是给对手提交 punish 证据专门留出的时间.
         */
        require(channel.settle_block_number + punish_block_number < block.number);

        Participant storage participant1_state = channel.participants[participant1];
        Participant storage participant2_state = channel.participants[participant2];
        /*
            验证提供的参数是有效的
        */
        require(participant1_state.balance_hash == calceBalanceHash(participant1_transferred_amount, participant1_locksroot));
        require(participant2_state.balance_hash == calceBalanceHash(participant2_transferred_amount, participant2_locksroot));

        total_deposit = participant1_state.deposit + participant2_state.deposit;

        participant1_amount = (
        participant1_state.deposit
        + participant2_transferred_amount
        - participant1_transferred_amount
        );
        // There are 2 cases that require attention here:
        // case1. If participant1 does NOT provide a balance proof or provides an old balance proof
        // case2. If participant2 does NOT provide a balance proof or provides an old balance proof
        // The issue is that we need to react differently in both cases. However, both cases have
        // an end result of participant1_amount > total_available_deposit. Therefore:

        // case1: participant2_transferred_amount can be [0, real_participant2_transferred_amount)
        // This can trigger an underflow -> participant1_amount > total_available_deposit
        // We need to make participant1_amount = 0 in this case, otherwise it can be
        // an attack vector. participant1 must lose all/some of its tokens if it does not
        // provide a valid balance proof.
        if (
            (participant1_state.deposit + participant2_transferred_amount) < participant1_transferred_amount
        ) {
            participant1_amount = 0;
        }

        // case2: participant1_transferred_amount can be [0, real_participant1_transferred_amount)
        // This means participant1_amount > total_available_deposit.
        // We need to limit participant1_amount to total_available_deposit. It is fine if
        // participant1 gets all the available tokens if participant2 has not provided a
        // valid balance proof.
        participant1_amount = min(participant1_amount, total_deposit);
        // At this point `participant1_amount` is between [0,total_deposit], so this is safe.
        // 变量复用是因为局部变量不能超过16个
        participant2_transferred_amount = total_deposit - participant1_amount;

        // Remove the channel data from storage
        delete channel.participants[participant1];
        delete channel.participants[participant2];
        delete channels[channel_identifier];
        // Do the actual token transfers
        if (participant1_amount > 0) {
            require(token.transfer(participant1, participant1_amount));
        }

        if (participant2_transferred_amount > 0) {
            require(token.transfer(participant2, participant2_transferred_amount));
        }

        emit ChannelSettled(
            channel_identifier,
            participant1_amount,
            participant2_transferred_amount
        );
    }

    /*
        任何人都可以调用,只能调用一次.
        功能:双方协商一致关闭通道,将通道中的金额直接退回到双方账户
        参数说明:
        participant1,participant2:通道参与双方
        participant1_balance,participant2_balance:双方关于金额的分配方案
        participant1_signature,participant2_signature 双方对于分配方案的签名
    */
    ///
    function cooperativeSettle(
        address participant1,
        uint256 participant1_balance,
        address participant2,
        uint256 participant2_balance,
        bytes participant1_signature,
        bytes participant2_signature
    )
    public
    {
        uint256 total_deposit;
        bytes32 channel_identifier;
        uint64 open_blocknumber;
        channel_identifier = getChannelIdentifier(participant1, participant2);
        Channel storage channel = channels[channel_identifier];
        // The channel must be open
        require(channel.state == 1);

        open_blocknumber = channel.open_block_number;
        require(participant1 == recoverAddressFromCooperativeSettleSignature(
            channel_identifier,
            participant1,
            participant1_balance,
            participant2,
            participant2_balance,
            open_blocknumber,
            participant1_signature
        ));
        require(participant2 == recoverAddressFromCooperativeSettleSignature(
            channel_identifier,
            participant1,
            participant1_balance,
            participant2,
            participant2_balance,
            open_blocknumber,
            participant2_signature
        ));

        Participant storage participant1_state = channel.participants[participant1];
        Participant storage participant2_state = channel.participants[participant2];


        total_deposit = participant1_state.deposit + participant2_state.deposit;

        // Remove channel data from storage before doing the token transfers
        delete channel.participants[participant1];
        delete channel.participants[participant2];
        delete channels[channel_identifier];
        // Do the token transfers
        if (participant1_balance > 0) {
            require(token.transfer(participant1, participant1_balance));
        }

        if (participant2_balance > 0) {
            require(token.transfer(participant2, participant2_balance));
        }

        // The sum of the provided balances must be equal to the total available deposit
        // 一定要严防双方互相配合,侵占tokennetwork 资产的行为
        require(total_deposit == (participant1_balance + participant2_balance));
        require(total_deposit >= participant1_balance);
        require(total_deposit >= participant2_balance);
        emit ChannelCooperativeSettled(channel_identifier, participant1_balance, participant2_balance);
    }

    /// @notice create a 32-byte channel identifier.
    function getChannelIdentifier(address participant1, address participant2) view internal returns (bytes32){
        if (participant1 < participant2) {
            return keccak256(abi.encodePacked(participant1, participant2, address(this)));
        } else {
            return keccak256(abi.encodePacked(participant2, participant1, address(this)));
        }
    }

    ///
    function calceBalanceHash(uint256 transferred_amount, bytes32 locksroot) pure internal returns (bytes24){
        if (locksroot == 0 && transferred_amount == 0) {
            return 0;
        }
        return bytes24(keccak256(abi.encodePacked(locksroot, transferred_amount)));
    }

    ///
    function getChannelInfo(address participant1, address participant2)
    view
    external
    returns (bytes32, uint64, uint64, uint8, uint64)
    {

        bytes32 channel_identifier;
        channel_identifier = getChannelIdentifier(participant1, participant2);
        Channel storage channel = channels[channel_identifier];

        return (
        channel_identifier,
        channel.settle_block_number,
        channel.open_block_number,
        channel.state,
        channel.settle_timeout
        );
    }

    ///
    function getChannelInfoByChannelIdentifier(bytes32 channel_identifier)
    view
    external
    returns (bytes32, uint64, uint64, uint8, uint64)
    {
        Channel storage channel = channels[channel_identifier];

        return (
        channel_identifier,
        channel.settle_block_number,
        channel.open_block_number,
        channel.state,
        channel.settle_timeout
        );
    }

    ///
    function getChannelParticipantInfo(address participant, address partner)
    view
    external
    returns (uint256, bytes24, uint64)
    {

        bytes32 channel_identifier = getChannelIdentifier(participant, partner);
        Channel storage channel = channels[channel_identifier];
        Participant storage participant_state = channel.participants[participant];

        return (
        participant_state.deposit,
        participant_state.balance_hash,
        participant_state.nonce
        );
    }

    function queryUnlockedLocks(address participant, address partner, bytes32 lockhash)
    view
    external
    returns (bool)
    {
        bytes32 lockhash_hash;
        bytes32 channel_identifier = getChannelIdentifier(participant, partner);
        Channel storage channel = channels[channel_identifier];
        Participant storage participant_state = channel.participants[participant];
        lockhash_hash = keccak256(abi.encodePacked(participant_state.nonce, lockhash));

        return (
        participant_state.unlocked_locks[lockhash_hash]
        );
    }

    /*
     * Internal Functions
     */
    function recoverAddressFromBalanceProof(
        bytes32 channel_identifier,
        uint256 transferred_amount,
        bytes32 locksroot,
        uint64 nonce,
        uint64 open_blocknumber,
        bytes32 additional_hash,
        bytes signature
    )
    view
    internal
    returns (address signature_address)
    {
        //32+32+8+32+32+8+32
        string memory message_length = "176";
        bytes32 message_hash = keccak256(abi.encodePacked(
                signature_prefix,
                message_length,
                transferred_amount,
                locksroot,
                nonce,
                additional_hash,
                channel_identifier,
                open_blocknumber,
                chain_id
            ));

        signature_address = ECVerify.ecverify(message_hash, signature);
    }


    ///
    function recoverAddressFromBalanceProofDelegate(
        bytes32 channel_identifier,
        uint256 transferred_amount,
        bytes32 locksroot,
        uint64 nonce,
        uint64 open_blocknumber,
        bytes non_closing_signature
    )
    view
    internal
    returns (address signature_address)
    {
        //32+32+8+32+8+32
        string memory message_length = "144";
        bytes32 message_hash = keccak256(abi.encodePacked(
                signature_prefix,
                message_length,
                transferred_amount,
                locksroot,
                nonce,
                channel_identifier,
                open_blocknumber,
                chain_id
            ));

        signature_address = ECVerify.ecverify(message_hash, non_closing_signature);
    }

    ///
    function recoverAddressFromCooperativeSettleSignature(
        bytes32 channel_identifier,
        address participant1,
        uint256 participant1_balance,
        address participant2,
        uint256 participant2_balance,
        uint64 open_blocknumber,
        bytes signature
    )
    view
    internal
    returns (address signature_address)
    {
        //20+32+20+32+32+8+32
        string memory message_length = "176";
        bytes32 message_hash = keccak256(abi.encodePacked(
                signature_prefix,
                message_length,
                participant1,
                participant1_balance,
                participant2,
                participant2_balance,
                channel_identifier,
                open_blocknumber,
            //address(this),
                chain_id
            ));

        signature_address = ECVerify.ecverify(message_hash, signature);
    }

    ///
    function recoverAddressFromDisposedProof(
        bytes32 channel_identifier,
        bytes32 lockhash,
        uint64 open_blocknumber,
        bytes32 additional_hash,
        bytes signature
    )
    view
    internal
    returns (address signature_address)
    {
        //32+32+8+32+32
        string memory message_length = "136";
        bytes32 message_hash = keccak256(abi.encodePacked(
                signature_prefix,
                message_length,
                lockhash,
                channel_identifier,
                open_blocknumber,
                chain_id,
                additional_hash
            ));

        signature_address = ECVerify.ecverify(message_hash, signature);
    }

    ///
    function recoverAddressFromWithdrawProof(
        bytes32 channel_identifier,
        address participant,
        uint256 participant_balance,
        uint256 participant_withdraw,
        uint64 open_block_number,
        bytes signature
    )
    view
    internal
    returns (address signature_address)
    {
        //20+32+32+32+8+32
        string memory message_length = "156";
        bytes32 message_hash = keccak256(abi.encodePacked(
                signature_prefix,
                message_length,
                participant,
                participant_balance,
                participant_withdraw,
                channel_identifier,
                open_block_number,
                chain_id
            ));
        signature_address = ECVerify.ecverify(message_hash, signature);
    }

    ///
    function recoverAddressFromUnlockDelegateProof(
        bytes32 channel_identifier,
        address delegatee,
        uint256 expiration,
        uint256 amount,
        bytes32 secret_hash,
        bytes signature
    )
    view
    internal
    returns (address signature_address)
    {
         Channel storage channel = channels[channel_identifier];
        //20+32+32+32+32+8+32
        string memory message_length = "188";
        bytes32 message_hash = keccak256(abi.encodePacked(
                signature_prefix,
                message_length,
                delegatee,
                expiration,
                amount,
                secret_hash,
                channel_identifier,
                channel.open_block_number,
                chain_id
            ));
        signature_address = ECVerify.ecverify(message_hash, signature);
    }
    ///
    function computeMerkleRoot(bytes32 lockhash, bytes merkle_proof)
    pure
    internal
    returns (bytes32)
    {
        require(merkle_proof.length % 32 == 0);

        uint256 i;
        bytes32 el;

        for (i = 32; i <= merkle_proof.length; i += 32) {
            assembly {
                el := mload(add(merkle_proof, i))
            }

            if (lockhash < el) {
                lockhash = keccak256(abi.encodePacked(lockhash, el));
            } else {
                lockhash = keccak256(abi.encodePacked(el, lockhash));
            }
        }

        return lockhash;
    }

    /// @notice function to get all arguments needed in OpenChannelWithDepositInternal.
    /// @dev
    /// @param data
    /// @return a three-value set denoting two addresses and time period for channel settlement.
    function getOpenWithDepositArg(bytes data) pure internal returns (address, address, uint64)  {
        address participant;
        address partner;
        uint64 settle_timeout;
        assembly {
            participant := mload(add(data, 64))
            partner := mload(add(data, 96))
            settle_timeout := mload(add(data, 128))
        }
        return (participant, partner, settle_timeout);
    }

    /// @notice function to get
    /// @param data     a byte array denoting
    /// @return an address pair denoting the channel participants.
    function getDepositArg(bytes data) pure internal returns (address, address)  {
        address participant;
        address partner;
        assembly {
            participant := mload(add(data, 64))
            partner := mload(add(data, 96))
        }
        return (participant, partner);
    }

    /// @notice function to compare unsigned integer a and unsigned integer b.
    /// @param a    an unsigned integer to be compared.
    /// @param b    another unsigned integer to be compared.
    /// @return the smaller one within a and b.
    function min(uint256 a, uint256 b) pure internal returns (uint256)
    {
        return a > b ? b : a;
    }
}