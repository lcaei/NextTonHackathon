pragma ton-solidity >=0.35.0;
pragma AbiHeader expire;
pragma AbiHeader time;
pragma AbiHeader pubkey;
import "../Debot.sol";
import "../Terminal.sol";
import "../AddressInput.sol";
import "../AmountInput.sol";
import "../ConfirmInput.sol";
import "../Sdk.sol";
import "../Menu.sol";
import "../Upgradable.sol";
import "../Transferable.sol";

// A copy of structure from multisig contract
struct Transaction {
    // Transaction Id.
    uint64 id;
    // Transaction confirmations from custodians.
    uint32 confirmationsMask;
    // Number of required confirmations.
    uint8 signsRequired;
    // Number of confirmations already received.
    uint8 signsReceived;
    // Public key of custodian queued transaction.
    uint256 creator;
    // Index of custodian.
    uint8 index;
    // Destination address of gram transfer.
    address  dest;
    // Amount of nanograms to transfer.
    uint128 value;
    // Flags for sending internal message (see SENDRAWMSG in TVM spec).
    uint16 sendFlags;
    // Payload used as body of outbound internal message.
    TvmCell payload;
    // Bounce flag for header of outbound internal message.
    bool bounce;
}

struct CustodianInfo {
    uint8 index;
    uint256 pubkey;
}

interface IMultisig {
    function submitTransaction(
        address  dest,
        uint128 value,
        bool bounce,
        bool allBalance,
        TvmCell payload)
    external returns (uint64 transId);

    function confirmTransaction(uint64 transactionId) external;

    function getCustodians() external returns (CustodianInfo[] custodians);
    function getTransactions() external returns (Transaction[] transactions);
}

abstract contract Utility {
    function tonsToStr(uint128 nanotons) internal pure returns (string) {
        (uint64 dec, uint64 float) = _tokens(nanotons);
        string floatStr = format("{}", float);
        while (floatStr.byteLength() < 9) {
            floatStr = "0" + floatStr;
        }
        return format("{}.{}", dec, floatStr);
    }

    function _tokens(uint128 nanotokens) internal pure returns (uint64, uint64) {
        uint64 decimal = uint64(nanotokens / 1e9);
        uint64 float = uint64(nanotokens - (decimal * 1e9));
        return (decimal, float);
    }
}
/// @notice Multisig Debot v1 (with debot interfaces).
contract MsigDebot is Debot, Upgradable, Transferable, Utility {

    address m_wallet;
    uint128 m_balance;
    CustodianInfo[] m_custodians;
    Transaction[] m_transactions;

    bool m_bounce;
    uint128 m_tons;
    address m_dest;
    TvmCell m_payload;
    bytes m_icon;

    // ID of current transaction that wass choosen for confirmation.
    uint64 m_id;
    // Function Id to jump in case of error.
    uint32 m_retryId;
    // Function id to jump in case of successfull onchain transaction.
    uint32 m_continueId;
    // Default constructor

    //
    // Setters
    //

    function setIcon(bytes icon) public {
        require(msg.pubkey() == tvm.pubkey(), 100);
        tvm.accept();
        m_icon = icon;
    }

    //
    // Debot Basic API
    //

    function start() public override {
        _start();
    }

    function _start() private {
        AddressInput.get(tvm.functionId(startChecks), "Select the wallet you will like to use?");
    }

    /// @notice Returns Metadata about DeBot.
    function getDebotInfo() public functionID(0xDEB) override view returns(
        string name, string version, string publisher, string caption, string author,
        address support, string hello, string language, string dabi, bytes icon
    ) {
        name = "Ecommerce";
        version = format("{}.{}.{}", 1,2,0);
        publisher = "swi";
        caption = "DeBot for to pay for transactions";
        author = "swi";
        support = address.makeAddrStd(0, 0xa724ee3415cde0ad7ad677ed1eb2b0a5769007de44bbd33be6860d290406d69b);
        hello = "Hi, I will help you make payments for your purchase.";
        language = "en";
        dabi = m_debotAbi.get();
        icon = m_icon;
    }

    function getRequiredInterfaces() public view override returns (uint256[] interfaces) {
        return [ Terminal.ID, AmountInput.ID, ConfirmInput.ID, AddressInput.ID, Menu.ID ];
    }

    /*
    * Public
    */

    function startChecks(address value) public {
        Sdk.getAccountType(tvm.functionId(checkStatus), value);
        m_wallet = value;
	}

    function checkStatus(int8 acc_type) public {
        if (!_checkActiveStatus(acc_type, "Wallet")) {
            _start();
            return;
        }

        Sdk.getAccountCodeHash(tvm.functionId(checkWalletHash), m_wallet);
    }

    function checkWalletHash(uint256 code_hash) public {
        // safe msig
        if (code_hash != 0x80d6c47c4a25543c9b397b71716f3fae1e2c5d247174c52e2c19bd896442b105 &&
        // surf msig
            code_hash != 0x207dc560c5956de1a2c1479356f8f3ee70a59767db2bf4788b1d61ad42cdad82 &&
        // 24 msig
            code_hash != 0x7d0996943406f7d62a4ff291b1228bf06ebd3e048b58436c5b70fb77ff8b4bf2 &&
        // 24 setcode msig
            code_hash != 0xa491804ca55dd5b28cffdff48cb34142930999621a54acee6be83c342051d884 &&
        // setcode msig
            code_hash != 0xe2b60b6b602c10ced7ea8ede4bdf96342c97570a3798066f3fb50a4b2b27a208) {
            _start();
            return;
        }
        preMain();
    }

    function _checkActiveStatus(int8 acc_type, string obj) private returns (bool) {
        if (acc_type == -1)  {
            Terminal.print(0, obj + " is inactive");
            return false;
        }
        if (acc_type == 0) {
            Terminal.print(0, obj + " is uninitialized");
            return false;
        }
        if (acc_type == 2) {
            Terminal.print(0, obj + " is frozen");
            return false;
        }
        return true;
    }

    function preMain() public  {
        _getTransactions(tvm.functionId(setTransactions));
        _getCustodians(tvm.functionId(setCustodians));
        Sdk.getBalance(tvm.functionId(initWallet), m_wallet);
    }

    function setTransactions(Transaction[] transactions) public {
        m_transactions = transactions;
    }

    function setCustodians(CustodianInfo[] custodians) public {
        m_custodians = custodians;
    }

    function initWallet(uint128 nanotokens) public {
        m_balance = nanotokens;
        mainMenu();
    }

    function mainMenu() public {
        string str = format("This wallet has {} tokens on the balance. It has {} custodian(s) and {} unconfirmed transactions.",
            tonsToStr(m_balance), m_custodians.length, m_transactions.length);
        Terminal.print(0, str);

        _gotoMainMenu();
    }

    function startSubmit(uint32 index) public {
        index = index;
        AddressInput.get(tvm.functionId(setDest), "What is the recipient address?");
    }

    function setDest(address value) public {
        m_dest = value;
        Sdk.getAccountType(tvm.functionId(checkRecipient), value);
    }

    function checkRecipient(int8 acc_type) public {
        if (acc_type == 2) {
            Terminal.print(tvm.functionId(Debot.start), "Recipient is frozen.");
            return;
        }
        if (acc_type == -1 || acc_type == 0) {
            ConfirmInput.get(tvm.functionId(submitToInactive), "Recipient is inactive. Continue?");
            m_bounce = false;
            return;
        } else {
            m_bounce = true;
        }

        AmountInput.get(tvm.functionId(setTons), "How many tokens to send?", 9, 1e7, m_balance);
    }

    function submitToInactive(bool value) public {
        if (!value) {
            Terminal.print(tvm.functionId(Debot.start), "Operation aborted.");
            return;
        }
        AmountInput.get(tvm.functionId(setTons), "How many tokens to send?", 9, 1e7, m_balance);
    }

    function setTons(uint128 value) public {
        m_tons = value;
        string fmt = format("Transaction details:\nRecipient: {}.\nAmount: {} tokens.\nConfirm?", m_dest, tonsToStr(value));
        ConfirmInput.get(tvm.functionId(submit), fmt);
    }

    function callSubmitTransaction() public view {
        optional(uint256) pubkey = 0;
        IMultisig(m_wallet).submitTransaction{
            abiVer: 2,
            extMsg: true,
            sign: true,
            pubkey: pubkey,
            time: uint64(now),
            expire: 0,
            callbackId: tvm.functionId(onSuccess),
            onErrorId: tvm.functionId(onError)
        }(m_dest, m_tons, m_bounce, false, m_payload);
    }

    function submit(bool value) public {
        if (!value) {
            Terminal.print(0, "Ok, maybe next time.");
            _start();
            return;
        }
        TvmCell empty;
        m_payload = empty;
        m_continueId = tvm.functionId(Debot.start);
        m_retryId = tvm.functionId(submit);
        callSubmitTransaction();
    }

    function onError(uint32 sdkError, uint32 exitCode) public {
        // TODO: parse different types of errors: sdkError and exit Code.
        // DeBot can undestand if txn was reejcted by user or if wallet contract throws an exception.
        // DeBot can help user to undestand when keypair is invalid, for example.
        exitCode = exitCode; sdkError = sdkError;
        ConfirmInput.get(m_retryId, "Transaction failed. Do you want to retry transaction?");
    }

    function onSuccess(uint64 transId) public {
        if (m_custodians.length <= 1) {
            Terminal.print(0, "Transaction succeeded.");
        } else {
            string fmt = format("Transaction {} submitted successfully", transId);
            Terminal.print(0, fmt);
        }
        _start();
    }

    function showCustodians(uint32 index) public {
        index = index;
        Terminal.print(0, "Wallet custodian public key(s):");
        for (uint i = 0; i < m_custodians.length; i++) {
            Terminal.print(0, format("{:x}", m_custodians[i].pubkey));
        }
        _gotoMainMenu();
    }

    function showTransactions(uint32 index) public {
        index = index;
        Terminal.print(0, "Unconfirmed transactions:");
        for (uint i = 0; i < m_transactions.length; i++) {
            Transaction txn = m_transactions[i];
            Terminal.print(0, format("ID {:x}\nRecipient: {}\nAmount: {}\nConfirmations received: {}\nConfirmations required: {}\nCreator custodian public key: {:x}",
                txn.id, txn.dest, tonsToStr(txn.value),
                txn.signsReceived, txn.signsRequired, txn.creator));
        }
        _gotoMainMenu();
    }

    function printMenu(uint32 index) public view {
        index = index;
        _gotoMainMenu();
    }

    function confirmMenu(uint32 index) public view {
        index = index;
        _getTransactions(tvm.functionId(printConfirmMenu));
    }

    function printConfirmMenu(Transaction[] transactions) public {
        m_transactions = transactions;
        if (m_transactions.length == 0) {
            _gotoMainMenu();
            return;
        }

        MenuItem[] items;
        for (uint i = 0; i < m_transactions.length; i++) {
            Transaction txn = m_transactions[i];
            items.push( MenuItem(format("ID {:x}", txn.id), "", tvm.functionId(confirmTxn)) );
        }
        items.push( MenuItem("Back", "", tvm.functionId(printMenu)) );
        Menu.select("Choose transaction:", "", items);
    }

    function confirmTxn(uint32 index) public {
        m_id = m_transactions[index].id;
        confirm(true);
    }

    function confirm(bool value) public {
        if (!value) {
            _start();
            return;
        }
        optional(uint256) pubkey = 0;
        m_retryId = tvm.functionId(confirm);
        IMultisig(m_wallet).confirmTransaction{
            abiVer: 2,
            extMsg: true,
            sign: true,
            pubkey: pubkey,
            time: uint64(now),
            expire: 0,
            callbackId: tvm.functionId(onConfirmSuccess),
            onErrorId: tvm.functionId(onError)
        }(m_id);
    }

    function onConfirmSuccess() public {
        Terminal.print(0, "Transaction confirmed.");
        confirmMenu(0);
    }

    function _gotoMainMenu() private view {
        _getTransactions(tvm.functionId(printMainMenu));
    }

    function printMainMenu(Transaction[] transactions) public {
        m_transactions = transactions;
        MenuItem[] items;
        items.push( MenuItem("Submit transaction", "", tvm.functionId(startSubmit)) );
        items.push( MenuItem("Show custodians", "", tvm.functionId(showCustodians)) );
        if (m_transactions.length != 0) {
            items.push( MenuItem("Show transactions", "", tvm.functionId(showTransactions)) );
            items.push( MenuItem("Confirm transaction", "", tvm.functionId(confirmMenu)) );
        }
        Menu.select("What's next?", "", items);
    }

    function _getTransactions(uint32 answerId) private view {
        optional(uint256) none;
        IMultisig(m_wallet).getTransactions{
            abiVer: 2,
            extMsg: true,
            sign: false,
            pubkey: none,
            time: uint64(now),
            expire: 0,
            callbackId: answerId,
            onErrorId: 0
        }();
    }

    function _getCustodians(uint32 answerId) private view {
        optional(uint256) none;
        IMultisig(m_wallet).getCustodians{
            abiVer: 2,
            extMsg: true,
            sign: false,
            pubkey: none,
            time: uint64(now),
            expire: 0,
            callbackId: answerId,
            onErrorId: 0
        }();
    }

    function onCodeUpgrade() internal override {
        tvm.resetStorage();
    }


    //
    // Functions for external or internal invoke.
    //

    function invokeTransaction(address sender, address recipient, uint128 amount, bool bounce, TvmCell payload) public {
        m_dest = recipient;
        m_tons = amount;
        m_bounce = bounce;
        m_payload = payload;
        m_wallet = sender;
        (, uint bits, uint refs) = payload.dataSize(1000);
        ConfirmInput.get(tvm.functionId(retryInvoke), format("Transaction details:\nRecipient address: {}\nAmount: {} tons\nPayload: {}",
            recipient, tonsToStr(amount), (bits == 0 && refs == 0) ? "NO" : "YES"));
    }

    function invokeTransaction2(address value) public {
        m_wallet = value;
        callSubmitTransaction();
    }

    function retryInvoke(bool value) public {
        if (!value) {
            Terminal.print(0, "Transaction aborted.");
            start();
            return;
        }
        m_retryId = tvm.functionId(retryInvoke);
        m_continueId = 0;
        if (m_wallet == address(0)) {
            AddressInput.get(tvm.functionId(invokeTransaction2), "Which wallet do you want to make a transfer from?");
        } else {
            callSubmitTransaction();
        }
    }

    //
    // Getters
    //

    function getInvokeMessage(address sender, address recipient, uint128 amount, bool bounce, TvmCell payload) public pure
        returns(TvmCell message) {
        TvmCell body = tvm.encodeBody(MsigDebot.invokeTransaction, sender, recipient, amount, bounce, payload);
        TvmBuilder message_;
        message_.store(false, true, true, false, address(0), address(this));
        message_.storeTons(0);
        message_.storeUnsigned(0, 1);
        message_.storeTons(0);
        message_.storeTons(0);
        message_.store(uint64(0));
        message_.store(uint32(0));
        message_.storeUnsigned(0, 1); //init: nothing$0
        message_.storeUnsigned(1, 1); //body: right$1
        message_.store(body);
        message = message_.toCell();
    }
}