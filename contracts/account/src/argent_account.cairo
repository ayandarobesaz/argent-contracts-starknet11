use lib::{OutsideExecution, Version};
use account::{Escape, EscapeStatus};
use starknet::{ClassHash};

#[starknet::interface]
trait IExecuteFromOutside<TContractState> {
    fn execute_from_outside(
        ref self: TContractState, outside_execution: OutsideExecution, signature: Array<felt252>
    ) -> Array<Span<felt252>>;

    fn get_outside_execution_message_hash(
        self: @TContractState, outside_execution: OutsideExecution
    ) -> felt252;
}

#[starknet::interface]
trait IArgentAccount<TContractState> {
    fn __validate_deploy__(
        self: @TContractState,
        class_hash: felt252,
        contract_address_salt: felt252,
        owner: felt252,
        guardian: felt252
    ) -> felt252;
    // External
    fn change_owner(
        ref self: TContractState, new_owner: felt252, signature_r: felt252, signature_s: felt252
    );
    fn change_guardian(ref self: TContractState, new_guardian: felt252);
    fn change_guardian_backup(ref self: TContractState, new_guardian_backup: felt252);
    fn trigger_escape_owner(ref self: TContractState, new_owner: felt252);
    fn trigger_escape_guardian(ref self: TContractState, new_guardian: felt252);
    fn escape_owner(ref self: TContractState);
    fn escape_guardian(ref self: TContractState);
    fn cancel_escape(ref self: TContractState);
    // Views
    fn get_owner(self: @TContractState) -> felt252;
    fn get_guardian(self: @TContractState) -> felt252;
    fn get_guardian_backup(self: @TContractState) -> felt252;
    fn get_escape(self: @TContractState) -> Escape;
    fn get_version(self: @TContractState) -> Version;
    fn get_name(self: @TContractState) -> felt252;
    fn get_guardian_escape_attempts(self: @TContractState) -> u32;
    fn get_owner_escape_attempts(self: @TContractState) -> u32;
    fn get_escape_and_status(self: @TContractState) -> (Escape, EscapeStatus);
}

/// Deprecated method for compatibility reasons
#[starknet::interface]
trait IOldArgentAccount<TContractState> {
    fn getVersion(self: @TContractState) -> felt252;
    fn getName(self: @TContractState) -> felt252;
    fn supportsInterface(self: @TContractState, interface_id: felt252) -> felt252;
    fn isValidSignature(
        self: @TContractState, hash: felt252, signatures: Array<felt252>
    ) -> felt252;
}

#[starknet::contract]
mod ArgentAccount {
    use array::{ArrayTrait, SpanTrait};
    use box::BoxTrait;
    use ecdsa::check_ecdsa_signature;
    use hash::{TupleSize4LegacyHash, LegacyHashFelt252};
    use traits::Into;
    use option::{OptionTrait, OptionTraitImpl};
    use serde::Serde;
    use starknet::{
        ClassHash, class_hash_const, ContractAddress, get_block_timestamp, get_caller_address,
        get_execution_info, get_contract_address, get_tx_info, VALIDATED,
        syscalls::replace_class_syscall, ContractAddressIntoFelt252
    };
    use starknet::account::{Call};
    use account::{Escape, EscapeStatus};
    use lib::{
        assert_correct_tx_version, assert_no_self_call, assert_caller_is_null, assert_only_self,
        execute_multicall, Version, IErc165LibraryDispatcher, IErc165DispatcherTrait,
        IErc1271DispatcherTrait, IAccountUpgrade, IAccountUpgradeLibraryDispatcher,
        IAccountUpgradeDispatcherTrait, OutsideExecution, hash_outside_execution_message,
        assert_correct_declare_version, ERC165_IERC165_INTERFACE_ID, ERC165_ACCOUNT_INTERFACE_ID,
        ERC165_ACCOUNT_INTERFACE_ID_OLD_1, ERC165_ACCOUNT_INTERFACE_ID_OLD_2, ERC1271_VALIDATED,
        IErc165, IErc1271, AccountContract,
    };

    const NAME: felt252 = 'ArgentAccount';


    /// Time it takes for the escape to become ready after being triggered
    const ESCAPE_SECURITY_PERIOD: u64 = 604800; // 7 * 24 * 60 * 60;  // 7 days
    ///  The escape will be ready and can be completed for this duration
    const ESCAPE_EXPIRY_PERIOD: u64 = 604800; // 7 * 24 * 60 * 60;  // 7 days
    const ESCAPE_TYPE_GUARDIAN: felt252 = 1;
    const ESCAPE_TYPE_OWNER: felt252 = 2;

    const TRIGGER_ESCAPE_GUARDIAN_SELECTOR: felt252 =
        73865429733192804476769961144708816295126306469589518371407068321865763651; // starknet_keccak('trigger_escape_guardian')
    const TRIGGER_ESCAPE_OWNER_SELECTOR: felt252 =
        1099763735485822105046709698985960101896351570185083824040512300972207240555; // starknet_keccak('trigger_escape_owner')
    const ESCAPE_GUARDIAN_SELECTOR: felt252 =
        1662889347576632967292303062205906116436469425870979472602094601074614456040; // starknet_keccak('escape_guardian')
    const ESCAPE_OWNER_SELECTOR: felt252 =
        1621457541430776841129472853859989177600163870003012244140335395142204209277; // starknet_keccak'(escape_owner')
    const EXECUTE_AFTER_UPGRADE_SELECTOR: felt252 =
        738349667340360233096752603318170676063569407717437256101137432051386874767; // starknet_keccak('execute_after_upgrade')
    const CHANGE_OWNER_SELECTOR: felt252 =
        658036363289841962501247229249022783727527757834043681434485756469236076608; // starknet_keccak('change_owner')

    /// Limit escape attempts by only one party
    const MAX_ESCAPE_ATTEMPTS: u32 = 5;
    /// Limits fee in escapes
    const MAX_ESCAPE_MAX_FEE: u128 = 50000000000000000; // 0.05 ETH

    ////////////////////////////////////////////////////////////////////////////////////////////////
    //                                           Storage                                          //
    ////////////////////////////////////////////////////////////////////////////////////////////////

    #[storage]
    struct Storage {
        _implementation: ClassHash, // This is deprecated and used to migrate cairo 0 accounts only
        _signer: felt252, /// Current account owner
        _guardian: felt252, /// Current account guardian
        _guardian_backup: felt252, /// Current account backup guardian
        _escape: Escape, /// The ongoing escape, if any
        /// Keeps track of used nonces for outside transactions (`execute_from_outside`)
        outside_nonces: LegacyMap<felt252, bool>,
        /// Keeps track of how many escaping tx the guardian has submitted. Used to limit the number of transactions the account will pay for
        /// It resets when an escape is completed or canceled
        guardian_escape_attempts: u32,
        /// Keeps track of how many escaping tx the owner has submitted. Used to limit the number of transactions the account will pay for
        /// It resets when an escape is completed or canceled
        owner_escape_attempts: u32
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////
    //                                           Events                                           //
    ////////////////////////////////////////////////////////////////////////////////////////////////
    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        AccountCreated: AccountCreated,
        TransactionExecuted: TransactionExecuted,
        EscapeOwnerTriggered: EscapeOwnerTriggered,
        EscapeGuardianTriggered: EscapeGuardianTriggered,
        OwnerEscaped: OwnerEscaped,
        GuardianEscaped: GuardianEscaped,
        EscapeCanceled: EscapeCanceled,
        OwnerChanged: OwnerChanged,
        GuardianChanged: GuardianChanged,
        GuardianBackupChanged: GuardianBackupChanged,
        AccountUpgraded: AccountUpgraded,
    }
    /// @notice Emitted exactly once when the account is initialized
    /// @param account The account address
    /// @param owner The owner address
    /// @param guardian The guardian address
    #[derive(Drop, starknet::Event)]
    struct AccountCreated {
        #[key]
        account: ContractAddress,
        #[key]
        owner: felt252,
        guardian: felt252
    }

    /// @notice Emitted when the account executes a transaction
    /// @param hash The transaction hash
    /// @param response The data returned by the methods called
    #[derive(Drop, starknet::Event)]
    struct TransactionExecuted {
        hash: felt252,
        response: Span<Span<felt252>>
    }

    /// @notice Owner escape was triggered by the guardian
    /// @param ready_at when the escape can be completed
    /// @param new_owner new owner address to be set after the security period
    #[derive(Drop, starknet::Event)]
    struct EscapeOwnerTriggered {
        ready_at: u64,
        new_owner: felt252
    }

    /// @notice Guardian escape was triggered by the owner
    /// @param ready_at when the escape can be completed
    /// @param new_guardian address of the new guardian to be set after the security period. O if the guardian will be removed
    #[derive(Drop, starknet::Event)]
    struct EscapeGuardianTriggered {
        ready_at: u64,
        new_guardian: felt252
    }

    /// @notice Owner escape was completed and there is a new account owner
    /// @param new_owner new owner address
    #[derive(Drop, starknet::Event)]
    struct OwnerEscaped {
        new_owner: felt252
    }

    /// @notice Guardian escape was completed and there is a new account guardian
    /// @param new_guardian address of the new guardian or 0 if it was removed
    #[derive(Drop, starknet::Event)]
    struct GuardianEscaped {
        new_guardian: felt252
    }

    /// An ongoing escape was canceled
    #[derive(Drop, starknet::Event)]
    struct EscapeCanceled {}

    /// @notice The account owner was changed
    /// @param new_owner new owner address
    #[derive(Drop, starknet::Event)]
    struct OwnerChanged {
        new_owner: felt252
    }

    /// @notice The account guardian was changed or removed
    /// @param new_guardian address of the new guardian or 0 if it was removed
    #[derive(Drop, starknet::Event)]
    struct GuardianChanged {
        new_guardian: felt252
    }

    /// @notice The account backup guardian was changed or removed
    /// @param new_guardian_backup address of the backup guardian or 0 if it was removed
    #[derive(Drop, starknet::Event)]
    struct GuardianBackupChanged {
        new_guardian_backup: felt252
    }

    /// @notice Emitted when the implementation of the account changes
    /// @param new_implementation The new implementation
    #[derive(Drop, starknet::Event)]
    struct AccountUpgraded {
        new_implementation: ClassHash
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////
    //                                        Constructor                                         //
    ////////////////////////////////////////////////////////////////////////////////////////////////

    #[constructor]
    fn constructor(ref self: ContractState, owner: felt252, guardian: felt252) {
        assert(owner != 0, 'argent/null-owner');

        self._signer.write(owner);
        self._guardian.write(guardian);
        self._guardian_backup.write(0);
        self
            .emit(
                Event::AccountCreated(
                    AccountCreated { account: get_contract_address(), owner, guardian }
                )
            );
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////
    //                                     External functions                                     //
    ////////////////////////////////////////////////////////////////////////////////////////////////

    #[external(v0)]
    impl AccountContractImpl of AccountContract<ContractState> {
        fn __validate__(ref self: ContractState, calls: Array<Call>) -> felt252 {
            assert_caller_is_null();
            let tx_info = get_tx_info().unbox();
            assert_valid_calls_and_signature(
                ref self,
                calls.span(),
                tx_info.transaction_hash,
                tx_info.signature,
                is_from_outside: false
            );
            VALIDATED
        }

        fn __validate_declare__(self: @ContractState, class_hash: felt252) -> felt252 {
            let tx_info = get_tx_info().unbox();
            assert_correct_declare_version(tx_info.version);
            assert_valid_span_signature(self, tx_info.transaction_hash, tx_info.signature);
            VALIDATED
        }

        fn __execute__(ref self: ContractState, calls: Array<Call>) -> Array<Span<felt252>> {
            assert_caller_is_null();
            let tx_info = get_tx_info().unbox();
            assert_correct_tx_version(tx_info.version);

            let retdata = execute_multicall(calls.span());
            self
                .emit(
                    Event::TransactionExecuted(
                        TransactionExecuted {
                            hash: tx_info.transaction_hash, response: retdata.span()
                        }
                    )
                );
            retdata
        }
    }

    #[external(v0)]
    impl ExecuteFromOutsideImpl of super::IExecuteFromOutside<ContractState> {
        /// @notice This method allows anyone to submit a transaction on behalf of the account as long as they have the relevant signatures
        /// @param outside_execution The parameters of the transaction to execute
        /// @param signature A valid signature on the Eip712 message encoding of `outside_execution`
        /// @notice This method allows reentrancy. A call to `__execute__` or `execute_from_outside` can trigger another nested transaction to `execute_from_outside`.
        fn execute_from_outside(
            ref self: ContractState, outside_execution: OutsideExecution, signature: Array<felt252>
        ) -> Array<Span<felt252>> {
            // Checks
            if (outside_execution.caller).into() != 'ANY_CALLER' {
                assert(get_caller_address() == outside_execution.caller, 'argent/invalid-caller');
            }

            let block_timestamp = get_block_timestamp();
            assert(
                outside_execution.execute_after < block_timestamp
                    && block_timestamp < outside_execution.execute_before,
                'argent/invalid-timestamp'
            );
            let nonce = outside_execution.nonce;
            assert(!self.outside_nonces.read(nonce), 'argent/duplicated-outside-nonce');

            let outside_tx_hash = hash_outside_execution_message(@outside_execution);

            let calls = outside_execution.calls;

            assert_valid_calls_and_signature(
                ref self, calls, outside_tx_hash, signature.span(), is_from_outside: true
            );

            // Effects
            self.outside_nonces.write(nonce, true);

            // Interactions
            let retdata = execute_multicall(calls);
            self
                .emit(
                    Event::TransactionExecuted(
                        TransactionExecuted { hash: outside_tx_hash, response: retdata.span() }
                    )
                );
            retdata
        }

        /// Get the message hash for some `OutsideExecution` following Eip712. Can be used to know what needs to be signed
        fn get_outside_execution_message_hash(
            self: @ContractState, outside_execution: OutsideExecution
        ) -> felt252 {
            return hash_outside_execution_message(@outside_execution);
        }
    }


    #[external(v0)]
    impl ArgentUpgradeAccountImpl of IAccountUpgrade<ContractState> {
        /// @notice Upgrades the implementation of the account
        /// @dev Also call `execute_after_upgrade` on the new implementation
        /// Must be called by the account and authorised by the owner and a guardian (if guardian is set).
        /// @param implementation The address of the new implementation
        /// @param calldata Data to pass to the the implementation in `execute_after_upgrade`
        /// @return retdata The data returned by `execute_after_upgrade`
        fn upgrade(
            ref self: ContractState, new_implementation: ClassHash, calldata: Array<felt252>
        ) -> Array<felt252> {
            assert_only_self();

            let supports_interface = IErc165LibraryDispatcher {
                class_hash: new_implementation
            }.supports_interface(ERC165_ACCOUNT_INTERFACE_ID);
            assert(supports_interface, 'argent/invalid-implementation');

            replace_class_syscall(new_implementation).unwrap_syscall();
            self.emit(Event::AccountUpgraded(AccountUpgraded { new_implementation }));

            IAccountUpgradeLibraryDispatcher {
                class_hash: new_implementation
            }.execute_after_upgrade(calldata)
        }

        /// @dev Logic to execute after an upgrade.
        /// Can only be called by the account after a call to `upgrade`.
        /// @param data Generic call data that can be passed to the method for future upgrade logic
        fn execute_after_upgrade(ref self: ContractState, data: Array<felt252>) -> Array<felt252> {
            assert_only_self();

            // Check basic invariants
            assert(self._signer.read() != 0, 'argent/null-owner');
            if self._guardian.read() == 0 {
                assert(self._guardian_backup.read() == 0, 'argent/backup-should-be-null');
            }

            let implementation = self._implementation.read();
            if implementation != class_hash_const::<0>() {
                replace_class_syscall(implementation).unwrap_syscall();
                self._implementation.write(class_hash_const::<0>());
            }

            if data.is_empty() {
                return ArrayTrait::new();
            }

            let mut data_span = data.span();
            let calls: Array<Call> = Serde::deserialize(ref data_span)
                .expect('argent/invalid-calls');
            assert(data_span.is_empty(), 'argent/invalid-calls');

            assert_no_self_call(calls.span(), get_contract_address());

            let multicall_return = execute_multicall(calls.span());
            let mut output = ArrayTrait::new();
            multicall_return.serialize(ref output);
            output
        }
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////
    //                                       View functions                                       //
    ////////////////////////////////////////////////////////////////////////////////////////////////

    #[external(v0)]
    impl ArgentAccountImpl of super::IArgentAccount<ContractState> {
        fn __validate_deploy__(
            self: @ContractState,
            class_hash: felt252,
            contract_address_salt: felt252,
            owner: felt252,
            guardian: felt252
        ) -> felt252 {
            let tx_info = get_tx_info().unbox();
            assert_correct_tx_version(tx_info.version);
            assert_valid_span_signature(self, tx_info.transaction_hash, tx_info.signature);
            VALIDATED
        }

        /// @notice Changes the owner
        /// Must be called by the account and authorised by the owner and a guardian (if guardian is set).
        /// @param new_owner New owner address
        /// @param signature_r Signature R from the new owner 
        /// @param signature_S Signature S from the new owner 
        /// Signature is required to prevent changing to an address which is not in control of the user
        /// Signature is the Signed Message of this hash:
        /// hash = pedersen(0, (change_owner selector, chainid, contract address, old_owner))
        fn change_owner(
            ref self: ContractState, new_owner: felt252, signature_r: felt252, signature_s: felt252
        ) {
            assert_only_self();
            assert_valid_new_owner(@self, new_owner, signature_r, signature_s);

            reset_escape(ref self);
            reset_escape_attempts(ref self);

            self._signer.write(new_owner);
            self.emit(Event::OwnerChanged(OwnerChanged { new_owner }));
        }

        /// @notice Changes the guardian
        /// Must be called by the account and authorised by the owner and a guardian (if guardian is set).
        /// @param new_guardian The address of the new guardian, or 0 to disable the guardian
        /// @dev can only be set to 0 if there is no guardian backup set
        fn change_guardian(ref self: ContractState, new_guardian: felt252) {
            assert_only_self();
            // There cannot be a guardian_backup when there is no guardian
            if new_guardian == 0 {
                assert(self._guardian_backup.read() == 0, 'argent/backup-should-be-null');
            }

            reset_escape(ref self);
            reset_escape_attempts(ref self);

            self._guardian.write(new_guardian);
            self.emit(Event::GuardianChanged(GuardianChanged { new_guardian }));
        }

        /// @notice Changes the backup guardian
        /// Must be called by the account and authorised by the owner and a guardian (if guardian is set).
        /// @param new_guardian_backup The address of the new backup guardian, or 0 to disable the backup guardian
        fn change_guardian_backup(ref self: ContractState, new_guardian_backup: felt252) {
            assert_only_self();
            assert_guardian_set(@self);

            reset_escape(ref self);
            reset_escape_attempts(ref self);

            self._guardian_backup.write(new_guardian_backup);
            self.emit(Event::GuardianBackupChanged(GuardianBackupChanged { new_guardian_backup }));
        }

        /// @notice Triggers the escape of the owner when it is lost or compromised.
        /// Must be called by the account and authorised by just a guardian.
        /// Cannot override an ongoing escape of the guardian.
        /// @param new_owner The new account owner if the escape completes
        /// @dev This method assumes that there is a guardian, and that `_newOwner` is not 0.
        /// This must be guaranteed before calling this method, usually when validating the transaction.
        fn trigger_escape_owner(ref self: ContractState, new_owner: felt252) {
            assert_only_self();

            // no escape if there is a guardian escape triggered by the owner in progress
            let current_escape = self._escape.read();
            if current_escape.escape_type == ESCAPE_TYPE_GUARDIAN {
                assert(
                    get_escape_status(current_escape.ready_at) == EscapeStatus::Expired(()),
                    'argent/cannot-override-escape'
                );
            }

            reset_escape(ref self);
            let ready_at = get_block_timestamp() + ESCAPE_SECURITY_PERIOD;
            self
                ._escape
                .write(Escape { ready_at, escape_type: ESCAPE_TYPE_OWNER, new_signer: new_owner });
            self.emit(Event::EscapeOwnerTriggered(EscapeOwnerTriggered { ready_at, new_owner }));
        }

        /// @notice Triggers the escape of the guardian when it is lost or compromised.
        /// Must be called by the account and authorised by the owner alone.
        /// Can override an ongoing escape of the owner.
        /// @param new_guardian The new account guardian if the escape completes
        /// @dev This method assumes that there is a guardian, and that `new_guardian` can only be 0
        /// if there is no guardian backup.
        /// This must be guaranteed before calling this method, usually when validating the transaction
        fn trigger_escape_guardian(ref self: ContractState, new_guardian: felt252) {
            assert_only_self();

            reset_escape(ref self);

            let ready_at = get_block_timestamp() + ESCAPE_SECURITY_PERIOD;
            self
                ._escape
                .write(
                    Escape { ready_at, escape_type: ESCAPE_TYPE_GUARDIAN, new_signer: new_guardian }
                );
            self
                .emit(
                    Event::EscapeGuardianTriggered(
                        EscapeGuardianTriggered { ready_at, new_guardian }
                    )
                );
        }

        /// @notice Completes the escape and changes the owner after the security period
        /// Must be called by the account and authorised by just a guardian
        /// @dev This method assumes that there is a guardian, and that the there is an escape for the owner.
        /// This must be guaranteed before calling this method, usually when validating the transaction.
        fn escape_owner(ref self: ContractState) {
            assert_only_self();

            let current_escape = self._escape.read();

            let current_escape_status = get_escape_status(current_escape.ready_at);
            assert(current_escape_status == EscapeStatus::Ready(()), 'argent/invalid-escape');

            reset_escape_attempts(ref self);

            // update owner
            self._signer.write(current_escape.new_signer);
            self.emit(Event::OwnerEscaped(OwnerEscaped { new_owner: current_escape.new_signer }));
            // clear escape
            self._escape.write(Escape { ready_at: 0, escape_type: 0, new_signer: 0 });
        }

        /// @notice Completes the escape and changes the guardian after the security period
        /// Must be called by the account and authorised by just the owner
        /// @dev This method assumes that there is a guardian, and that the there is an escape for the guardian.
        /// This must be guaranteed before calling this method. Usually when validating the transaction.
        fn escape_guardian(ref self: ContractState) {
            assert_only_self();

            let current_escape = self._escape.read();
            assert(
                get_escape_status(current_escape.ready_at) == EscapeStatus::Ready(()),
                'argent/invalid-escape'
            );

            reset_escape_attempts(ref self);

            //update guardian
            self._guardian.write(current_escape.new_signer);
            self
                .emit(
                    Event::GuardianEscaped(
                        GuardianEscaped { new_guardian: current_escape.new_signer }
                    )
                );
            // clear escape
            self._escape.write(Escape { ready_at: 0, escape_type: 0, new_signer: 0 });
        }

        /// @notice Cancels an ongoing escape if any.
        /// Must be called by the account and authorised by the owner and a guardian (if guardian is set).
        fn cancel_escape(ref self: ContractState) {
            assert_only_self();
            let current_escape = self._escape.read();
            let current_escape_status = get_escape_status(current_escape.ready_at);
            assert(current_escape_status != EscapeStatus::None(()), 'argent/invalid-escape');
            reset_escape(ref self);
            reset_escape_attempts(ref self);
        }


        fn get_owner(self: @ContractState) -> felt252 {
            self._signer.read()
        }

        fn get_guardian(self: @ContractState) -> felt252 {
            self._guardian.read()
        }

        fn get_guardian_backup(self: @ContractState) -> felt252 {
            self._guardian_backup.read()
        }

        fn get_escape(self: @ContractState) -> Escape {
            self._escape.read()
        }

        /// Semantic version of this contract
        fn get_version(self: @ContractState) -> Version {
            Version { major: 0, minor: 3, patch: 0 }
        }


        fn get_name(self: @ContractState) -> felt252 {
            get_name()
        }


        fn get_guardian_escape_attempts(self: @ContractState) -> u32 {
            self.guardian_escape_attempts.read()
        }

        fn get_owner_escape_attempts(self: @ContractState) -> u32 {
            self.owner_escape_attempts.read()
        }

        /// Current escape if any, and its status
        fn get_escape_and_status(self: @ContractState) -> (Escape, EscapeStatus) {
            let current_escape = self._escape.read();
            (current_escape, get_escape_status(current_escape.ready_at))
        }
    }

    #[external(v0)]
    impl OldArgentAccountImpl of super::IOldArgentAccount<ContractState> {
        fn getVersion(self: @ContractState) -> felt252 {
            '0.3.0'
        }
        fn getName(self: @ContractState) -> felt252 {
            get_name()
        }

        /// Deprecated method for compatibility reasons
        fn supportsInterface(self: @ContractState, interface_id: felt252) -> felt252 {
            if supports_interface(interface_id) {
                1
            } else {
                0
            }
        }
        /// Deprecated method for compatibility reasons
        #[view]
        fn isValidSignature(
            self: @ContractState, hash: felt252, signatures: Array<felt252>
        ) -> felt252 {
            is_valid_signature(self, hash, signatures)
        }
    }

    #[external(v0)]
    impl Erc165Impl of IErc165<ContractState> {
        fn supports_interface(self: @ContractState, interface_id: felt252) -> bool {
            supports_interface(interface_id)
        }
    }

    // ERC1271
    #[external(v0)]
    impl Erc1271Impl of IErc1271<ContractState> {
        fn is_valid_signature(
            self: @ContractState, hash: felt252, signatures: Array<felt252>
        ) -> felt252 {
            is_valid_signature(self, hash, signatures)
        }
    }


    ////////////////////////////////////////////////////////////////////////////////////////////////
    //                                          Internal                                          //
    ////////////////////////////////////////////////////////////////////////////////////////////////

    fn get_name() -> felt252 {
        NAME
    }

    fn supports_interface(interface_id: felt252) -> bool {
        if interface_id == ERC165_IERC165_INTERFACE_ID {
            true
        } else if interface_id == ERC165_ACCOUNT_INTERFACE_ID {
            true
        } else if interface_id == ERC165_ACCOUNT_INTERFACE_ID_OLD_1 {
            true
        } else if interface_id == ERC165_ACCOUNT_INTERFACE_ID_OLD_2 {
            true
        } else {
            false
        }
    }

    fn is_valid_signature(
        self: @ContractState, hash: felt252, signatures: Array<felt252>
    ) -> felt252 {
        if is_valid_span_signature(self, hash, signatures.span()) {
            ERC1271_VALIDATED
        } else {
            0
        }
    }

    fn assert_valid_calls_and_signature(
        ref self: ContractState,
        calls: Span<Call>,
        execution_hash: felt252,
        signature: Span<felt252>,
        is_from_outside: bool
    ) {
        let execution_info = get_execution_info().unbox();
        let account_address = execution_info.contract_address;
        let tx_info = execution_info.tx_info.unbox();
        assert_correct_tx_version(tx_info.version);

        if calls.len() == 1 {
            let call = calls.at(0);
            if *call.to == account_address {
                let selector = *call.selector;

                if selector == TRIGGER_ESCAPE_OWNER_SELECTOR {
                    if !is_from_outside {
                        let current_attempts = self.guardian_escape_attempts.read();
                        assert_valid_escape_parameters(current_attempts);
                        self.guardian_escape_attempts.write(current_attempts + 1);
                    }

                    let mut calldata: Span<felt252> = call.calldata.span();
                    let new_owner: felt252 = Serde::deserialize(ref calldata)
                        .expect('argent/invalid-calldata');
                    assert(calldata.is_empty(), 'argent/invalid-calldata');
                    assert(new_owner != 0, 'argent/null-owner');
                    assert_guardian_set(@self);

                    let is_valid = is_valid_guardian_signature(@self, execution_hash, signature);
                    assert(is_valid, 'argent/invalid-guardian-sig');
                    return (); // valid
                }
                if selector == ESCAPE_OWNER_SELECTOR {
                    if !is_from_outside {
                        let current_attempts = self.guardian_escape_attempts.read();
                        assert_valid_escape_parameters(current_attempts);
                        self.guardian_escape_attempts.write(current_attempts + 1);
                    }

                    assert(call.calldata.is_empty(), 'argent/invalid-calldata');
                    assert_guardian_set(@self);
                    let current_escape = self._escape.read();
                    assert(
                        current_escape.escape_type == ESCAPE_TYPE_OWNER, 'argent/invalid-escape'
                    );
                    // needed if user started escape in old cairo version and
                    // upgraded half way through,  then tries to finish the escape in new version
                    assert(current_escape.new_signer != 0, 'argent/null-owner');

                    let is_valid = is_valid_guardian_signature(@self, execution_hash, signature);
                    assert(is_valid, 'argent/invalid-guardian-sig');
                    return (); // valid
                }
                if selector == TRIGGER_ESCAPE_GUARDIAN_SELECTOR {
                    if !is_from_outside {
                        let current_attempts = self.owner_escape_attempts.read();
                        assert_valid_escape_parameters(current_attempts);
                        self.owner_escape_attempts.write(current_attempts + 1);
                    }
                    let mut calldata: Span<felt252> = call.calldata.span();
                    let new_guardian: felt252 = Serde::deserialize(ref calldata)
                        .expect('argent/invalid-calldata');
                    assert(calldata.is_empty(), 'argent/invalid-calldata');

                    if new_guardian == 0 {
                        assert(self._guardian_backup.read() == 0, 'argent/backup-should-be-null');
                    }
                    assert_guardian_set(@self);
                    let is_valid = is_valid_owner_signature(@self, execution_hash, signature);
                    assert(is_valid, 'argent/invalid-owner-sig');
                    return (); // valid
                }
                if selector == ESCAPE_GUARDIAN_SELECTOR {
                    if !is_from_outside {
                        let current_attempts = self.owner_escape_attempts.read();
                        assert_valid_escape_parameters(current_attempts);
                        self.owner_escape_attempts.write(current_attempts + 1);
                    }
                    assert(call.calldata.is_empty(), 'argent/invalid-calldata');
                    assert_guardian_set(@self);
                    let current_escape = self._escape.read();

                    assert(
                        current_escape.escape_type == ESCAPE_TYPE_GUARDIAN, 'argent/invalid-escape'
                    );

                    // needed if user started escape in old cairo version and
                    // upgraded half way through, then tries to finish the escape in new version
                    if current_escape.new_signer == 0 {
                        assert(self._guardian_backup.read() == 0, 'argent/backup-should-be-null');
                    }
                    let is_valid = is_valid_owner_signature(@self, execution_hash, signature);
                    assert(is_valid, 'argent/invalid-owner-sig');
                    return (); // valid
                }
                assert(selector != EXECUTE_AFTER_UPGRADE_SELECTOR, 'argent/forbidden-call');
            }
        } else {
            // make sure no call is to the account
            assert_no_self_call(calls, account_address);
        }

        assert_valid_span_signature(@self, execution_hash, signature);
    }

    fn assert_valid_escape_parameters(attempts: u32) {
        let tx_info = get_tx_info().unbox();
        assert(tx_info.max_fee <= MAX_ESCAPE_MAX_FEE, 'argent/max-fee-too-high');
        assert(attempts < MAX_ESCAPE_ATTEMPTS, 'argent/max-escape-attempts');
    }

    fn is_valid_span_signature(
        self: @ContractState, hash: felt252, signatures: Span<felt252>
    ) -> bool {
        let (owner_signature, guardian_signature) = split_signatures(signatures);
        let is_valid = is_valid_owner_signature(self, hash, owner_signature);
        if !is_valid {
            return false;
        }
        if self._guardian.read() == 0 {
            guardian_signature.is_empty()
        } else {
            is_valid_guardian_signature(self, hash, guardian_signature)
        }
    }

    fn assert_valid_span_signature(self: @ContractState, hash: felt252, signatures: Span<felt252>) {
        let (owner_signature, guardian_signature) = split_signatures(signatures);
        let is_valid = is_valid_owner_signature(self, hash, owner_signature);
        assert(is_valid, 'argent/invalid-owner-sig');

        if self._guardian.read() == 0 {
            assert(guardian_signature.is_empty(), 'argent/invalid-guardian-sig');
        } else {
            assert(
                is_valid_guardian_signature(self, hash, guardian_signature),
                'argent/invalid-guardian-sig'
            );
        }
    }

    fn is_valid_owner_signature(
        self: @ContractState, hash: felt252, signature: Span<felt252>
    ) -> bool {
        if signature.len() != 2 {
            return false;
        }
        let signature_r = *signature[0];
        let signature_s = *signature[1];
        check_ecdsa_signature(hash, self._signer.read(), signature_r, signature_s)
    }

    fn is_valid_guardian_signature(
        self: @ContractState, hash: felt252, signature: Span<felt252>
    ) -> bool {
        if signature.len() != 2 {
            return false;
        }
        let signature_r = *signature[0];
        let signature_s = *signature[1];
        let is_valid = check_ecdsa_signature(hash, self._guardian.read(), signature_r, signature_s);
        if is_valid {
            true
        } else {
            check_ecdsa_signature(hash, self._guardian_backup.read(), signature_r, signature_s)
        }
    }

    /// The signature is the result of signing the message hash with the new owner private key
    /// The message hash is the result of hashing the array:
    /// [change_owner selector, chainid, contract address, old_owner]
    /// as specified here: https://docs.starknet.io/documentation/architecture_and_concepts/Hashing/hash-functions/#array_hashing

    fn assert_valid_new_owner(
        self: @ContractState, new_owner: felt252, signature_r: felt252, signature_s: felt252
    ) {
        assert(new_owner != 0, 'argent/null-owner');
        let chain_id = get_tx_info().unbox().chain_id;
        let mut message_hash = TupleSize4LegacyHash::hash(
            0, (CHANGE_OWNER_SELECTOR, chain_id, get_contract_address(), self._signer.read())
        );
        // We now need to hash message_hash with the size of the array: (change_owner selector, chainid, contract address, old_owner)
        // https://github.com/starkware-libs/cairo-lang/blob/b614d1867c64f3fb2cf4a4879348cfcf87c3a5a7/src/starkware/cairo/common/hash_state.py#L6
        message_hash = LegacyHashFelt252::hash(message_hash, 4);
        let is_valid = check_ecdsa_signature(message_hash, new_owner, signature_r, signature_s);
        assert(is_valid, 'argent/invalid-owner-sig');
    }

    fn split_signatures(full_signature: Span<felt252>) -> (Span<felt252>, Span<felt252>) {
        if full_signature.len() == 2 {
            return (full_signature, ArrayTrait::new().span());
        }
        assert(full_signature.len() == 4, 'argent/invalid-signature-length');
        let mut owner_signature = ArrayTrait::new();
        owner_signature.append(*full_signature[0]);
        owner_signature.append(*full_signature[1]);
        let mut guardian_signature = ArrayTrait::new();
        guardian_signature.append(*full_signature[2]);
        guardian_signature.append(*full_signature[3]);
        (owner_signature.span(), guardian_signature.span())
    }

    fn get_escape_status(escape_ready_at: u64) -> EscapeStatus {
        if escape_ready_at == 0 {
            return EscapeStatus::None(());
        }

        let block_timestamp = get_block_timestamp();
        if block_timestamp < escape_ready_at {
            return EscapeStatus::NotReady(());
        }
        if escape_ready_at + ESCAPE_EXPIRY_PERIOD <= block_timestamp {
            return EscapeStatus::Expired(());
        }

        EscapeStatus::Ready(())
    }

    #[inline(always)]
    fn reset_escape(ref self: ContractState) {
        let current_escape_status = get_escape_status(self._escape.read().ready_at);
        if current_escape_status == EscapeStatus::None(()) {
            return ();
        }
        self._escape.write(Escape { ready_at: 0, escape_type: 0, new_signer: 0 });
        if current_escape_status != EscapeStatus::Expired(()) {
            self.emit(Event::EscapeCanceled(EscapeCanceled {}));
        }
    }

    #[inline(always)]
    fn assert_guardian_set(self: @ContractState) {
        assert(self._guardian.read() != 0, 'argent/guardian-required');
    }

    #[inline(always)]
    fn reset_escape_attempts(ref self: ContractState) {
        self.owner_escape_attempts.write(0);
        self.guardian_escape_attempts.write(0);
    }
}
