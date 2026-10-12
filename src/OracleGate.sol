// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Verifies answers signed by the IdentityMD oracle (EIP-712, domain "IdentityMD Oracle" v2,
/// verifyingContract = this consumer). Same typed data as the CLAUS hook on Ethereum mainnet.
/// @dev IMD is a trusted attester: a signature authenticates the panel's answer to one fixed
/// question, nothing more. The question hash, panel size and quorum are fixed at deployment.
abstract contract OracleGate {
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant ATTESTATION_TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );
    /// @dev secp256k1n / 2: signatures with a higher s are malleable and refused.
    uint256 private constant HALF_N = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;
    /// @notice Answer type of a uint256 answer in the IMD oracle.
    uint8 public constant ANSWER_TYPE_UINT = 3;

    address public immutable oracleSigner;
    bytes32 public immutable questionHash;
    uint16 public immutable panelSize;
    uint16 public immutable quorum;

    struct Attestation {
        bytes32 requestId;
        uint256 chainId;
        bytes32 questionHash;
        uint8 answerType;
        bytes answer;
        uint256 figure;
        uint64 fromBlock;
        uint64 toBlock;
        bytes32 blockHash;
        bytes32 panelJobId;
        uint16 panelSize;
        uint16 quorum;
        uint16 agreed;
        uint64 issuedAt;
        uint64 expiresAt;
    }

    // All fields static: abi.encode(TYPEHASH, this tuple) is the EIP-712 struct encoding.
    struct HashedAttestation {
        bytes32 requestId;
        uint256 chainId;
        bytes32 questionHash;
        uint8 answerType;
        bytes32 answerHash;
        uint256 figure;
        uint64 fromBlock;
        uint64 toBlock;
        bytes32 blockHash;
        bytes32 panelJobId;
        uint16 panelSize;
        uint16 quorum;
        uint16 agreed;
        uint64 issuedAt;
        uint64 expiresAt;
    }

    error InvalidOracleConfig();
    error InvalidAttestation();
    error InvalidSigner();
    error BadSignature();

    constructor(address signer, bytes32 questionHash_, uint16 panelSize_, uint16 quorum_) {
        if (signer == address(0) || questionHash_ == bytes32(0) || quorum_ == 0 || quorum_ > panelSize_) {
            revert InvalidOracleConfig();
        }
        oracleSigner = signer;
        questionHash = questionHash_;
        panelSize = panelSize_;
        quorum = quorum_;
    }

    function attestationDigest(Attestation calldata a) public view returns (bytes32) {
        HashedAttestation memory h = HashedAttestation({
            requestId: a.requestId,
            chainId: a.chainId,
            questionHash: a.questionHash,
            answerType: a.answerType,
            answerHash: keccak256(a.answer),
            figure: a.figure,
            fromBlock: a.fromBlock,
            toBlock: a.toBlock,
            blockHash: a.blockHash,
            panelJobId: a.panelJobId,
            panelSize: a.panelSize,
            quorum: a.quorum,
            agreed: a.agreed,
            issuedAt: a.issuedAt,
            expiresAt: a.expiresAt
        });
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("IdentityMD Oracle"), keccak256("2"), block.chainid, address(this))
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, keccak256(abi.encode(ATTESTATION_TYPEHASH, h))));
    }

    /// @return answer The signed uint256 answer.
    function _verifyAttestation(Attestation calldata a, bytes calldata sig) internal view returns (uint256 answer) {
        if (
            a.chainId != block.chainid || a.questionHash != questionHash || a.answerType != ANSWER_TYPE_UINT
                || a.answer.length != 32 || a.panelSize != panelSize || a.quorum != quorum || a.agreed < quorum
                || a.agreed > panelSize || a.requestId == bytes32(0) || a.panelJobId == bytes32(0)
                || a.issuedAt > block.timestamp || a.expiresAt <= block.timestamp || a.expiresAt <= a.issuedAt
        ) revert InvalidAttestation();
        if (_recover(attestationDigest(a), sig) != oracleSigner) revert InvalidSigner();
        answer = abi.decode(a.answer, (uint256));
    }

    function _recover(bytes32 digest, bytes calldata sig) private pure returns (address signer) {
        if (sig.length != 65) revert BadSignature();
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        if (uint256(s) > HALF_N || (v != 27 && v != 28)) revert BadSignature();
        signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert BadSignature();
    }
}
