// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts/proxy/Proxy.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./KeeperRegistryBase2_0.sol";
import {KeeperRegistryExecutableInterface, UpkeepInfo} from "./interfaces/KeeperRegistryInterface2_0.sol";
import "../../interfaces/MigratableKeeperRegistryInterface.sol";
import "../../interfaces/ERC677ReceiverInterface.sol";
import "./interfaces/OCR2Abstract.sol";

/**
 * @notice Registry for adding work for Chainlink Keepers to perform on client
 * contracts. Clients must support the Upkeep interface.
 */
contract KeeperRegistry2_0 is
  KeeperRegistryBase2_0,
  Proxy,
  OCR2Abstract,
  KeeperRegistryExecutableInterface,
  MigratableKeeperRegistryInterface,
  ERC677ReceiverInterface
{
  using Address for address;
  using EnumerableSet for EnumerableSet.UintSet;

  // Immutable address of logic contract where some functionality is delegated to
  address public immutable KEEPER_REGISTRY_LOGIC;

  /**
   * @notice versions:
   * - KeeperRegistry 2.0.0: implement OCR interface
   * - KeeperRegistry 1.3.0: split contract into Proxy and Logic
   *                       : account for Arbitrum and Optimism L1 gas fee
   *                       : allow users to configure upkeeps
   * - KeeperRegistry 1.2.0: allow funding within performUpkeep
   *                       : allow configurable registry maxPerformGas
   *                       : add function to let admin change upkeep gas limit
   *                       : add minUpkeepSpend requirement
   *                       : upgrade to solidity v0.8
   * - KeeperRegistry 1.1.0: added flatFeeMicroLink
   * - KeeperRegistry 1.0.0: initial release
   */
  string public constant override typeAndVersion = "KeeperRegistry 2.0.0";

  /**
   * @inheritdoc MigratableKeeperRegistryInterface
   */
  UpkeepFormat public constant override upkeepTranscoderVersion = UPKEEP_TRANSCODER_VERSION_BASE;

  /**
   * @param paymentModel one of Default, Arbitrum, and Optimism
   * @param link address of the LINK Token
   * @param linkNativeFeed address of the LINK/Native price feed
   * @param fastGasFeed address of the Fast Gas price feed
   * @param onChainConfig registry on chain config settings
   */
  constructor(
    PaymentModel paymentModel,
    address link,
    address linkNativeFeed,
    address fastGasFeed,
    address keeperRegistryLogic,
    OnChainConfig memory onChainConfig
  ) KeeperRegistryBase2_0(paymentModel, link, linkNativeFeed, fastGasFeed) {
    KEEPER_REGISTRY_LOGIC = keeperRegistryLogic;
    setOnChainConfig(onChainConfig);
  }

  ////////
  // ACTIONS
  ////////

  /**
   * @dev This struct is used to maintain run time information about an upkeep in transmit function
   * @member upkeep the upkeep struct
   * @member earlyChecksPassed whether the upkeep passed early checks before perform
   * @member paymentParams the paymentParams for this upkeep
   * @member performSuccess whether the perform was successful
   * @member gasUsed gasUsed by this upkeep in perform
   */
  struct UpkeepTransmitInfo {
    Upkeep upkeep;
    bool earlyChecksPassed;
    PerformPaymentParams paymentParams;
    bool performSuccess;
    uint256 gasUsed;
  }

  /**
   * @inheritdoc OCR2Abstract
   */
  function transmit(
    bytes32[3] calldata reportContext,
    bytes calldata report,
    bytes32[] calldata rs,
    bytes32[] calldata ss,
    bytes32 rawVs
  ) external override whenNotPaused {
    uint256 gasOverhead = gasleft();
    HotVars memory hotVars = s_hotVars;
    if (!s_transmitters[msg.sender].active) revert OnlyActiveTransmitters();
    _requireExpectedMsgDataLength(report, rs, ss);

    Report memory parsedReport = _decodeReport(report);
    UpkeepTransmitInfo[] memory upkeepTransmitInfo = new UpkeepTransmitInfo[](parsedReport.upkeepIds.length);

    uint16 numUpkeepsPassedChecks;
    for (uint256 i = 0; i < parsedReport.upkeepIds.length; i++) {
      upkeepTransmitInfo[i].upkeep = s_upkeep[parsedReport.upkeepIds[i]];
      if (upkeepTransmitInfo[i].upkeep.skipSigVerification != upkeepTransmitInfo[0].upkeep.skipSigVerification) {
        // We don't allow batches with a mix of sigVerification and skipSigVerification upkeeps
        revert InvalidReport();
      }

      upkeepTransmitInfo[i].paymentParams = _generatePerformPaymentParams(upkeepTransmitInfo[i].upkeep, hotVars, true);
      upkeepTransmitInfo[i].earlyChecksPassed = _prePerformChecks(
        parsedReport.upkeepIds[i],
        parsedReport.wrappedPerformDatas[i],
        upkeepTransmitInfo[i].upkeep,
        upkeepTransmitInfo[i].paymentParams
      );

      if (upkeepTransmitInfo[i].earlyChecksPassed) {
        numUpkeepsPassedChecks += 1;
      }
    }
    // No upkeeps to be performed in this report
    if (numUpkeepsPassedChecks == 0) revert StaleReport();

    uint8[] memory signerIndices;
    if (!upkeepTransmitInfo[0].upkeep.skipSigVerification) {
      if (hotVars.latestConfigDigest != reportContext[0]) revert ConfigDigestMismatch();
      if (rs.length != hotVars.f + 1 || rs.length != ss.length) revert IncorrectNumberOfSignatures();
      signerIndices = _verifyReportSignature(reportContext, report, rs, ss, rawVs);
    }

    for (uint256 i = 0; i < parsedReport.upkeepIds.length; i++) {
      if (upkeepTransmitInfo[i].earlyChecksPassed) {
        // Actually perform the target upkeep
        (upkeepTransmitInfo[i].performSuccess, upkeepTransmitInfo[i].gasUsed) = _performUpkeep(
          upkeepTransmitInfo[i].upkeep,
          parsedReport.wrappedPerformDatas[i].performData
        );

        // Deduct that gasUsed by upkeep from our running overhead counter
        gasOverhead -= upkeepTransmitInfo[i].gasUsed;
      }
    }

    // This is the overall gas overhead that will be split across performed upkeeps
    // Take upper bound of 16 gas per callData byte
    gasOverhead =
      (gasOverhead - gasleft() + 16 * msg.data.length + (ACCOUNTING_GAS_OVERHEAD * (hotVars.f + 1))) /
      numUpkeepsPassedChecks;
    // @dev We put cap on gasOverhead as we don't want it to increase it beyond which we did an
    // initial payment check to prevent a revert in payment processing.
    if (gasOverhead > REGISTRY_GAS_OVERHEAD + (VERIFY_SIG_GAS_OVERHEAD * (hotVars.f + 1))) {
      gasOverhead = REGISTRY_GAS_OVERHEAD + (VERIFY_SIG_GAS_OVERHEAD * (hotVars.f + 1));
    }
    if (upkeepTransmitInfo[0].upkeep.skipSigVerification && gasOverhead > REGISTRY_GAS_OVERHEAD) {
      gasOverhead = REGISTRY_GAS_OVERHEAD;
    }

    uint96 gasPayment;
    uint96 premiumPerSigner;
    uint96 totalGasPayment;
    uint96 totalPremiumPerSigner;
    for (uint256 i = 0; i < parsedReport.upkeepIds.length; i++) {
      (gasPayment, premiumPerSigner) = _postPerformUpkeep(
        hotVars,
        parsedReport.upkeepIds[i],
        uint96(signerIndices.length),
        parsedReport.wrappedPerformDatas[i].checkBlockNumber,
        gasOverhead,
        upkeepTransmitInfo[i]
      );
      totalGasPayment += gasPayment;
      totalPremiumPerSigner += premiumPerSigner;
    }

    // Reimburse totalGasPayment to transmitter
    s_transmitters[msg.sender].balance += totalGasPayment;
    if (upkeepTransmitInfo[0].upkeep.skipSigVerification) {
      // Pay all the premium to transmitter as there are no signers in case of skipSigVerification
      s_transmitters[msg.sender].balance += totalPremiumPerSigner * uint96(signerIndices.length);
    } else {
      // Split premium among signers
      address transmitterToPay;
      for (uint256 i = 0; i < signerIndices.length; i++) {
        transmitterToPay = s_transmittersList[signerIndices[i]];
        s_transmitters[transmitterToPay].balance += totalPremiumPerSigner;
      }
    }
  }

  /**
   * @notice simulates the upkeep with the perform data returned from
   * checkUpkeep
   * @param id identifier of the upkeep to execute the data with.
   * @param performData calldata parameter to be passed to the target upkeep.
   */
  function simulatePerformUpkeep(uint256 id, bytes calldata performData)
    external
    cannotExecute
    whenNotPaused
    returns (bool success, uint256 gasUsed)
  {
    Upkeep memory upkeep = s_upkeep[id];
    return _performUpkeep(upkeep, performData);
  }

  /**
   * @notice uses LINK's transferAndCall to LINK and add funding to an upkeep
   * @dev safe to cast uint256 to uint96 as total LINK supply is under UINT96MAX
   * @param sender the account which transferred the funds
   * @param amount number of LINK transfer
   */
  function onTokenTransfer(
    address sender,
    uint256 amount,
    bytes calldata data
  ) external override {
    if (msg.sender != address(i_link)) revert OnlyCallableByLINKToken();
    if (data.length != 32) revert InvalidDataLength();
    uint256 id = abi.decode(data, (uint256));
    if (s_upkeep[id].maxValidBlocknumber != UINT32_MAX) revert UpkeepCancelled();

    s_upkeep[id].balance = s_upkeep[id].balance + uint96(amount);
    s_storage.expectedLinkBalance = s_storage.expectedLinkBalance + amount;

    emit FundsAdded(id, sender, uint96(amount));
  }

  ////////
  // SETTERS
  ////////

  /**
   * @inheritdoc OCR2Abstract
   */
  function setConfig(
    address[] memory signers,
    address[] memory transmitters,
    uint8 f,
    bytes memory onchainConfig,
    uint64 offchainConfigVersion,
    bytes memory offchainConfig
  ) external override onlyOwner {
    if (signers.length > maxNumOracles) revert TooManyOracles();
    if (f == 0) revert IncorrectNumberOfFaultyOracles();
    if (signers.length != transmitters.length || signers.length <= 3 * f) revert IncorrectNumberOfSigners();
    if (onchainConfig.length != 0) revert OnchainConfigNonEmpty();

    // remove any old signer/transmitter addresses
    uint256 oldLength = s_signersList.length;
    address signer;
    address transmitter;
    for (uint256 i = 0; i < oldLength; i++) {
      signer = s_signersList[i];
      transmitter = s_transmittersList[i];
      delete s_signers[signer];
      // Do not delete the whole transmitter struct as it has balance information stored
      s_transmitters[transmitter].active = false;
    }
    delete s_signersList;
    delete s_transmittersList;

    // add new signer/transmitter addresses
    for (uint256 i = 0; i < signers.length; i++) {
      if (s_signers[signers[i]].active) revert RepeatedSigner();
      s_signers[signers[i]] = Signer({active: true, index: uint8(i)});

      if (s_transmitters[transmitters[i]].active) revert RepeatedTransmitter();
      s_transmitters[transmitters[i]].active = true;
      s_transmitters[transmitters[i]].index = uint8(i);
    }
    s_signersList = signers;
    s_transmittersList = transmitters;
    s_hotVars.f = f;
    s_offchainConfigVersion = offchainConfigVersion;
    s_offchainConfig = offchainConfig;

    _computeAndStoreConfigDigest(
      signers,
      transmitters,
      f,
      abi.encode(
        OnChainConfig({
          paymentPremiumPPB: s_hotVars.paymentPremiumPPB,
          flatFeeMicroLink: s_hotVars.flatFeeMicroLink,
          checkGasLimit: s_storage.checkGasLimit,
          stalenessSeconds: s_hotVars.stalenessSeconds,
          gasCeilingMultiplier: s_hotVars.gasCeilingMultiplier,
          minUpkeepSpend: s_storage.minUpkeepSpend,
          maxPerformGas: s_storage.maxPerformGas,
          maxCheckDataSize: s_storage.maxCheckDataSize,
          maxPerformDataSize: s_storage.maxPerformDataSize,
          fallbackGasPrice: s_storage.fallbackGasPrice,
          fallbackLinkPrice: s_storage.fallbackLinkPrice,
          transcoder: s_storage.transcoder,
          registrar: s_storage.registrar
        })
      ),
      offchainConfigVersion,
      offchainConfig
    );
  }

  /**
   * @notice updates the configuration of the registry
   * @param onChainConfig registry config fields
   */
  function setOnChainConfig(OnChainConfig memory onChainConfig) public onlyOwner {
    if (onChainConfig.maxPerformGas < s_storage.maxPerformGas) revert GasLimitCanOnlyIncrease();
    if (onChainConfig.maxCheckDataSize < s_storage.maxCheckDataSize) revert MaxCheckDataSizeCanOnlyIncrease();
    if (onChainConfig.maxPerformDataSize < s_storage.maxPerformDataSize) revert MaxPerformDataSizeCanOnlyIncrease();

    s_hotVars = HotVars({
      f: s_hotVars.f,
      latestConfigDigest: s_hotVars.latestConfigDigest,
      paymentPremiumPPB: onChainConfig.paymentPremiumPPB,
      flatFeeMicroLink: onChainConfig.flatFeeMicroLink,
      stalenessSeconds: onChainConfig.stalenessSeconds,
      gasCeilingMultiplier: onChainConfig.gasCeilingMultiplier
    });

    s_storage = Storage({
      checkGasLimit: onChainConfig.checkGasLimit,
      minUpkeepSpend: onChainConfig.minUpkeepSpend,
      maxPerformGas: onChainConfig.maxPerformGas,
      transcoder: onChainConfig.transcoder,
      registrar: onChainConfig.registrar,
      maxCheckDataSize: onChainConfig.maxCheckDataSize,
      maxPerformDataSize: onChainConfig.maxPerformDataSize,
      nonce: s_storage.nonce,
      configCount: s_storage.configCount,
      latestConfigBlockNumber: s_storage.latestConfigBlockNumber,
      ownerLinkBalance: s_storage.ownerLinkBalance,
      expectedLinkBalance: s_storage.expectedLinkBalance,
      fallbackGasPrice: onChainConfig.fallbackGasPrice,
      fallbackLinkPrice: onChainConfig.fallbackLinkPrice
    });

    _computeAndStoreConfigDigest(
      s_signersList,
      s_transmittersList,
      s_hotVars.f,
      abi.encode(onChainConfig),
      s_offchainConfigVersion,
      s_offchainConfig
    );
    emit OnChainConfigSet(onChainConfig);
  }

  ////////
  // GETTERS
  ////////

  /**
   * @notice read all of the details about an upkeep
   */
  function getUpkeep(uint256 id) external view override returns (UpkeepInfo memory upkeepInfo) {
    Upkeep memory reg = s_upkeep[id];
    upkeepInfo = UpkeepInfo({
      target: reg.target,
      executeGas: reg.executeGas,
      checkData: s_checkData[id],
      balance: reg.balance,
      admin: s_upkeepAdmin[id],
      maxValidBlocknumber: reg.maxValidBlocknumber,
      lastPerformBlockNumber: reg.lastPerformBlockNumber,
      amountSpent: reg.amountSpent,
      paused: reg.paused,
      skipSigVerification: reg.skipSigVerification
    });
    return upkeepInfo;
  }

  /**
   * @notice retrieve active upkeep IDs. Active upkeep is defined as an upkeep which is not paused and not canceled.
   * @param startIndex starting index in list
   * @param maxCount max count to retrieve (0 = unlimited)
   * @dev the order of IDs in the list is **not guaranteed**, therefore, if making successive calls, one
   * should consider keeping the blockheight constant to ensure a holistic picture of the contract state
   */
  function getActiveUpkeepIDs(uint256 startIndex, uint256 maxCount) external view override returns (uint256[] memory) {
    uint256 maxIdx = s_upkeepIDs.length();
    if (startIndex >= maxIdx) revert IndexOutOfRange();
    if (maxCount == 0) {
      maxCount = maxIdx - startIndex;
    }
    uint256[] memory ids = new uint256[](maxCount);
    for (uint256 idx = 0; idx < maxCount; idx++) {
      ids[idx] = s_upkeepIDs.at(startIndex + idx);
    }
    return ids;
  }

  /**
   * @notice read the current info about any transmitter address
   */
  function getTransmitterInfo(address query)
    external
    view
    override
    returns (
      bool active,
      uint8 index,
      uint96 balance,
      address payee
    )
  {
    Transmitter memory transmitter = s_transmitters[query];
    return (transmitter.active, transmitter.index, transmitter.balance, s_transmitterPayees[query]);
  }

  /**
   * @notice read the current info about any signer address
   */
  function getSignerInfo(address query) external view returns (bool active, uint8 index) {
    Signer memory signer = s_signers[query];
    return (signer.active, signer.index);
  }

  /**
   * @notice read the current state of the registry
   */
  function getState()
    external
    view
    override
    returns (
      State memory state,
      OnChainConfig memory config,
      address[] memory signers,
      address[] memory transmitters,
      uint8 f,
      uint64 offchainConfigVersion,
      bytes memory offchainConfig
    )
  {
    state = State({
      nonce: s_storage.nonce,
      ownerLinkBalance: s_storage.ownerLinkBalance,
      expectedLinkBalance: s_storage.expectedLinkBalance,
      numUpkeeps: s_upkeepIDs.length(),
      configCount: s_storage.configCount,
      latestConfigBlockNumber: s_storage.latestConfigBlockNumber,
      latestConfigDigest: s_hotVars.latestConfigDigest
    });

    config = OnChainConfig({
      paymentPremiumPPB: s_hotVars.paymentPremiumPPB,
      flatFeeMicroLink: s_hotVars.flatFeeMicroLink,
      checkGasLimit: s_storage.checkGasLimit,
      stalenessSeconds: s_hotVars.stalenessSeconds,
      gasCeilingMultiplier: s_hotVars.gasCeilingMultiplier,
      minUpkeepSpend: s_storage.minUpkeepSpend,
      maxPerformGas: s_storage.maxPerformGas,
      maxCheckDataSize: s_storage.maxCheckDataSize,
      maxPerformDataSize: s_storage.maxPerformDataSize,
      fallbackGasPrice: s_storage.fallbackGasPrice,
      fallbackLinkPrice: s_storage.fallbackLinkPrice,
      transcoder: s_storage.transcoder,
      registrar: s_storage.registrar
    });

    return (state, config, s_signersList, s_transmittersList, s_hotVars.f, s_offchainConfigVersion, s_offchainConfig);
  }

  /**
   * @notice calculates the minimum balance required for an upkeep to remain eligible
   * @param id the upkeep id to calculate minimum balance for
   */
  function getMinBalanceForUpkeep(uint256 id) external view returns (uint96 minBalance) {
    return getMaxPaymentForGas(s_upkeep[id].executeGas);
  }

  /**
   * @notice calculates the maximum payment for a given gas limit
   * @param gasLimit the gas to calculate payment for
   */
  function getMaxPaymentForGas(uint256 gasLimit) public view returns (uint96 maxPayment) {
    HotVars memory hotVars = s_hotVars;
    (uint256 fastGasWei, uint256 linkNative) = _getFeedData(hotVars);
    uint256 gasOverhead = REGISTRY_GAS_OVERHEAD + (VERIFY_SIG_GAS_OVERHEAD * (hotVars.f + 1));
    (uint96 gasPayment, uint96 premium) = _calculatePaymentAmount(
      hotVars,
      gasLimit,
      gasOverhead,
      fastGasWei,
      linkNative,
      false
    );
    return gasPayment + premium;
  }

  /**
   * @notice retrieves the migration permission for a peer registry
   */
  function getPeerRegistryMigrationPermission(address peer) external view returns (MigrationPermission) {
    return s_peerRegistryMigrationPermission[peer];
  }

  /**
   * @inheritdoc OCR2Abstract
   */
  function latestConfigDetails()
    external
    view
    override
    returns (
      uint32 configCount,
      uint32 blockNumber,
      bytes32 configDigest
    )
  {
    return (s_storage.configCount, s_storage.latestConfigBlockNumber, s_hotVars.latestConfigDigest);
  }

  /**
   * @inheritdoc OCR2Abstract
   */
  function latestConfigDigestAndEpoch()
    external
    view
    override
    returns (
      bool scanLogs,
      bytes32 configDigest,
      uint32 epoch
    )
  {
    return (true, configDigest, epoch);
  }

  ////////
  // INTERNAL FUNCTIONS
  ////////

  /**
   * @dev This is the address to which proxy functions are delegated to
   */
  function _implementation() internal view override returns (address) {
    return KEEPER_REGISTRY_LOGIC;
  }

  /**
   * @dev calls target address with exactly gasAmount gas and data as calldata
   * or reverts if at least gasAmount gas is not available
   */
  function _callWithExactGas(
    uint256 gasAmount,
    address target,
    bytes memory data
  ) private returns (bool success) {
    assembly {
      let g := gas()
      // Compute g -= PERFORM_GAS_CUSHION and check for underflow
      if lt(g, PERFORM_GAS_CUSHION) {
        revert(0, 0)
      }
      g := sub(g, PERFORM_GAS_CUSHION)
      // if g - g//64 <= gasAmount, revert
      // (we subtract g//64 because of EIP-150)
      if iszero(gt(sub(g, div(g, 64)), gasAmount)) {
        revert(0, 0)
      }
      // solidity calls check that a contract actually exists at the destination, so we do the same
      if iszero(extcodesize(target)) {
        revert(0, 0)
      }
      // call and return whether we succeeded. ignore return data
      success := call(gasAmount, target, 0, add(data, 0x20), mload(data), 0, 0)
    }
    return success;
  }

  /**
   * @dev Should be called on every config change, either OCR or onChainConfig
   * Recomputes the config digest and stores it
   */
  function _computeAndStoreConfigDigest(
    address[] memory signers,
    address[] memory transmitters,
    uint8 f,
    bytes memory onchainConfig,
    uint64 offchainConfigVersion,
    bytes memory offchainConfig
  ) internal {
    uint32 previousConfigBlockNumber = s_storage.latestConfigBlockNumber;
    s_storage.latestConfigBlockNumber = uint32(block.number);
    s_storage.configCount += 1;

    s_hotVars.latestConfigDigest = _configDigestFromConfigData(
      block.chainid,
      address(this),
      s_storage.configCount,
      signers,
      transmitters,
      f,
      onchainConfig,
      offchainConfigVersion,
      offchainConfig
    );

    emit ConfigSet(
      previousConfigBlockNumber,
      s_hotVars.latestConfigDigest,
      s_storage.configCount,
      signers,
      transmitters,
      f,
      onchainConfig,
      offchainConfigVersion,
      offchainConfig
    );
  }

  // The constant-length components of the msg.data sent to transmit.
  // See the "If we wanted to call sam" example on for example reasoning
  // https://solidity.readthedocs.io/en/v0.7.2/abi-spec.html
  uint256 private constant TRANSMIT_MSGDATA_CONSTANT_LENGTH_COMPONENT =
    4 + // function selector
      32 *
      3 + // 3 words containing reportContext
      32 + // word containing start location of abiencoded report value
      32 + // word containing location start of abiencoded rs value
      32 + // word containing start location of abiencoded ss value
      32 + // rawVs value
      32 + // word containing length of report
      32 + // word containing length rs
      32 + // word containing length of ss
      0; // placeholder

  // Make sure the calldata length matches the inputs. Otherwise, the
  // transmitter could append an arbitrarily long (up to gas-block limit)
  // string of 0 bytes, which we would reimburse at a rate of 16 gas/byte, but
  // which would only cost the transmitter 4 gas/byte.
  function _requireExpectedMsgDataLength(
    bytes calldata report,
    bytes32[] calldata rs,
    bytes32[] calldata ss
  ) private pure {
    // calldata will never be big enough to make this overflow
    uint256 expected = TRANSMIT_MSGDATA_CONSTANT_LENGTH_COMPONENT +
      report.length + // one byte pure entry in report
      rs.length *
      32 + // 32 bytes per entry in rs
      ss.length *
      32 + // 32 bytes per entry in ss
      0; // placeholder
    if (msg.data.length != expected) revert InvalidReport();
  }

  /**
   * @dev _decodeReport decodes a serialized report into a Report struct
   */
  function _decodeReport(bytes memory rawReport) internal pure returns (Report memory) {
    uint256[] memory upkeepIds;
    bytes[] memory rawBytes;
    PerformDataWrapper[] memory wrappedPerformDatas;

    (upkeepIds, rawBytes) = abi.decode(rawReport, (uint256[], bytes[]));
    if (upkeepIds.length != rawBytes.length) revert InvalidReport();

    wrappedPerformDatas = new PerformDataWrapper[](upkeepIds.length);
    for (uint256 i = 0; i < upkeepIds.length; i++) {
      wrappedPerformDatas[i] = abi.decode(rawBytes[i], (PerformDataWrapper));
    }

    return Report({upkeepIds: upkeepIds, wrappedPerformDatas: wrappedPerformDatas});
  }

  /**
   * @dev Does some early sanity checks before actually performing an upkeep
   */
  function _prePerformChecks(
    uint256 upkeepId,
    PerformDataWrapper memory wrappedPerformData,
    Upkeep memory upkeep,
    PerformPaymentParams memory paymentParams
  ) internal returns (bool) {
    if (wrappedPerformData.checkBlockNumber <= upkeep.lastPerformBlockNumber) {
      // Can happen when another report performed this upkeep after this report was generated
      emit StaleUpkeepReport(upkeepId);
      return false;
    }

    if (blockhash(wrappedPerformData.checkBlockNumber - 1) != wrappedPerformData.checkBlockhash) {
      // Can happen when the block on which report was generated got reorged
      // We will also revert if checkBlockNumber is older than 256 blocks. In this case we rely on a new transmission
      // with the latest checkBlockNumber
      emit ReorgedUpkeepReport(upkeepId);
      return false;
    }

    if (upkeep.maxValidBlocknumber <= block.number) {
      // Can happen when an upkeep got cancelled after report was generated.
      // However we have a CANCELLATION_DELAY of 50 blocks so shouldn't happen in practice
      emit CancelledUpkeepReport(upkeepId);
      return false;
    }

    if (upkeep.balance < paymentParams.maxLinkPayment) {
      // Can happen due to flucutations in gas / link prices
      emit InsufficientFundsUpkeepReport(upkeepId);
      return false;
    }

    return true;
  }

  function _verifyReportSignature(
    bytes32[3] calldata reportContext,
    bytes calldata report,
    bytes32[] calldata rs,
    bytes32[] calldata ss,
    bytes32 rawVs
  ) internal view returns (uint8[] memory) {
    uint8[] memory signerIndices = new uint8[](rs.length);
    // Verify signatures attached to report
    {
      bytes32 h = keccak256(abi.encodePacked(keccak256(report), reportContext));
      // i-th byte counts number of sigs made by i-th signer
      uint256 signedCount = 0;

      Signer memory signer;
      address signerAddress;
      for (uint256 i = 0; i < rs.length; i++) {
        signerAddress = ecrecover(h, uint8(rawVs[i]) + 27, rs[i], ss[i]);
        signer = s_signers[signerAddress];
        if (!signer.active) revert OnlyActiveSigners();
        unchecked {
          signedCount += 1 << (8 * signer.index);
        }
        signerIndices[i] = signer.index;
      }

      if (signedCount & ORACLE_MASK != signedCount) revert DuplicateSigners();
    }
    return signerIndices;
  }

  /**
   * @dev calls the Upkeep target with the performData param passed in by the
   * transmitter and the exact gas required by the Upkeep
   */
  function _performUpkeep(Upkeep memory upkeep, bytes memory performData)
    private
    nonReentrant
    returns (bool success, uint256 gasUsed)
  {
    gasUsed = gasleft();
    bytes memory callData = abi.encodeWithSelector(PERFORM_SELECTOR, performData);
    success = _callWithExactGas(upkeep.executeGas, upkeep.target, callData);
    gasUsed = gasUsed - gasleft();

    return (success, gasUsed);
  }

  /**
   * @dev does postPerform payment processing for an upkeep. Stores lastPerformBlock. Calculates
   * gasPayment and premiumPerSigner. Deducts upkeep's balance for the total payment
   */
  function _postPerformUpkeep(
    HotVars memory hotVars,
    uint256 upkeepId,
    uint96 numSigners,
    uint32 checkBlockNumber,
    uint256 gasOverhead,
    UpkeepTransmitInfo memory upkeepTransmitInfo
  ) internal returns (uint96, uint96) {
    s_upkeep[upkeepId].lastPerformBlockNumber = uint32(block.number);
    (uint96 gasPayment, uint96 premium) = _calculatePaymentAmount(
      hotVars,
      upkeepTransmitInfo.gasUsed,
      gasOverhead,
      upkeepTransmitInfo.paymentParams.fastGasWei,
      upkeepTransmitInfo.paymentParams.linkNative,
      true
    );
    uint96 premiumPerSigner = premium / numSigners;
    uint96 total = gasPayment + premiumPerSigner * numSigners;

    s_upkeep[upkeepId].balance -= total;
    s_upkeep[upkeepId].amountSpent += total;

    UpkeepPerformedLogFields memory upkeepPerformedLogFields = UpkeepPerformedLogFields({
      checkBlockNumber: checkBlockNumber,
      gasUsed: upkeepTransmitInfo.gasUsed,
      gasOverhead: gasOverhead,
      linkNative: upkeepTransmitInfo.paymentParams.linkNative,
      premiumPayment: premiumPerSigner * numSigners,
      totalPayment: total
    });
    emit UpkeepPerformed(upkeepId, upkeepTransmitInfo.performSuccess, upkeepPerformedLogFields);

    return (gasPayment, premiumPerSigner);
  }

  ////////
  // PROXY FUNCTIONS - EXECUTED THROUGH FALLBACK
  ////////

  /**
   * @notice adds a new upkeep
   * @param target address to perform upkeep on
   * @param gasLimit amount of gas to provide the target contract when
   * performing upkeep
   * @param admin address to cancel upkeep and withdraw remaining funds
   * @param checkData data passed to the contract when checking for upkeep
   * @param skipSigVerification whether to skip signature verification for low security low cost
   */
  function registerUpkeep(
    address target,
    uint32 gasLimit,
    address admin,
    bool skipSigVerification,
    bytes calldata checkData
  ) external override returns (uint256 id) {
    // Executed through logic contract
    _fallback();
  }

  /**
   * @notice simulated by keepers via eth_call to see if the upkeep needs to be
   * performed. It returns the success status / failure reason along with the perform data payload.
   * @param id identifier of the upkeep to check
   */
  function checkUpkeep(uint256 id)
    external
    override
    cannotExecute
    returns (
      bool upkeepNeeded,
      bytes memory performData,
      UpkeepFailureReason upkeepFailureReason,
      uint256 gasUsed
    )
  {
    // Executed through logic contract
    _fallback();
  }

  /**
   * @notice prevent an upkeep from being performed in the future
   * @param id upkeep to be canceled
   */
  function cancelUpkeep(uint256 id) external override {
    // Executed through logic contract
    _fallback();
  }

  /**
   * @notice pause an upkeep
   * @param id upkeep to be paused
   */
  function pauseUpkeep(uint256 id) external override {
    // Executed through logic contract
    _fallback();
  }

  /**
   * @notice unpause an upkeep
   * @param id upkeep to be resumed
   */
  function unpauseUpkeep(uint256 id) external override {
    // Executed through logic contract
    _fallback();
  }

  /**
   * @notice update the check data of an upkeep
   * @param id the id of the upkeep whose check data needs to be updated
   * @param newCheckData the new check data
   */
  function updateCheckData(uint256 id, bytes calldata newCheckData) external override {
    // Executed through logic contract
    _fallback();
  }

  /**
   * @notice adds LINK funding for an upkeep by transferring from the sender's
   * LINK balance
   * @param id upkeep to fund
   * @param amount number of LINK to transfer
   */
  function addFunds(uint256 id, uint96 amount) external override {
    // Executed through logic contract
    _fallback();
  }

  /**
   * @notice removes funding from a canceled upkeep
   * @param id upkeep to withdraw funds from
   * @param to destination address for sending remaining funds
   */
  /**
   * @dev nonRentrant as this is not callable from a user's performUpkeep
   */
  function withdrawFunds(uint256 id, address to) external nonReentrant {
    // Executed through logic contract
    _fallback();
  }

  /**
   * @notice allows the admin of an upkeep to modify gas limit
   * @param id upkeep to be change the gas limit for
   * @param gasLimit new gas limit for the upkeep
   */
  function setUpkeepGasLimit(uint256 id, uint32 gasLimit) external override {
    // Executed through logic contract
    _fallback();
  }

  /**
   * @notice withdraws a transmitter's payment, callable only by the transmitter's payee
   * @param from transmitter address
   * @param to address to send the payment to
   */
  function withdrawPayment(address from, address to) external {
    // Executed through logic contract
    _fallback();
  }

  /**
   * @notice proposes the safe transfer of a transmitter's payee to another address
   * @param transmitter address of the transmitter to transfer payee role
   * @param proposed address to nominate for next payeeship
   */
  function transferPayeeship(address transmitter, address proposed) external {
    // Executed through logic contract
    _fallback();
  }

  /**
   * @notice accepts the safe transfer of payee role for a transmitter
   * @param transmitter address to accept the payee role for
   */
  function acceptPayeeship(address transmitter) external {
    // Executed through logic contract
    _fallback();
  }

  /**
   * @notice proposes the safe transfer of an upkeep's admin role to another address
   * @param id the upkeep id to transfer admin
   * @param proposed address to nominate for the new upkeep admin
   */
  function transferUpkeepAdmin(uint256 id, address proposed) external override {
    // Executed through logic contract
    _fallback();
  }

  /**
   * @notice accepts the safe transfer of admin role for an upkeep
   * @param id the upkeep id
   */
  function acceptUpkeepAdmin(uint256 id) external override {
    // Executed through logic contract
    _fallback();
  }

  /**
   * @inheritdoc MigratableKeeperRegistryInterface
   */
  function migrateUpkeeps(uint256[] calldata ids, address destination) external override {
    // Executed through logic contract
    _fallback();
  }

  /**
   * @inheritdoc MigratableKeeperRegistryInterface
   */
  function receiveUpkeeps(bytes calldata encodedUpkeeps) external override {
    // Executed through logic contract
    _fallback();
  }

  ////////
  // OWNER RESTRICTED FUNCTIONS
  ////////

  /**
   * @notice recovers LINK funds improperly transferred to the registry
   * @dev In principle this function’s execution cost could exceed block
   * gas limit. However, in our anticipated deployment, the number of upkeeps and
   * transmitters will be low enough to avoid this problem.
   */
  function recoverFunds() external {
    // Executed through logic contract
    // Restricted to onlyOwner in logic contract
    _fallback();
  }

  /**
   * @notice withdraws LINK funds collected through cancellation fees
   */
  function withdrawOwnerFunds() external {
    // Executed through logic contract
    // Restricted to onlyOwner in logic contract
    _fallback();
  }

  /**
   * @notice update the list of payees corresponding to the transmitters
   * @param payees addresses corresponding to transmitters who are allowed to
   * move payments which have been accrued
   */
  function setPayees(address[] calldata payees) external {
    // Executed through logic contract
    // Restricted to onlyOwner in logic contract
    _fallback();
  }

  /**
   * @notice signals to transmitters that they should not perform upkeeps until the
   * contract has been unpaused
   */
  function pause() external {
    // Executed through logic contract
    // Restricted to onlyOwner in logic contract
    _fallback();
  }

  /**
   * @notice signals to transmitters that they can perform upkeeps once again after
   * having been paused
   */
  function unpause() external {
    // Executed through logic contract
    // Restricted to onlyOwner in logic contract
    _fallback();
  }

  /**
   * @notice sets the peer registry migration permission
   */
  function setPeerRegistryMigrationPermission(address peer, MigrationPermission permission) external {
    // Executed through logic contract
    // Restricted to onlyOwner in logic contract
    _fallback();
  }
}