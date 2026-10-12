// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OracleGate} from "../src/OracleGate.sol";

contract GateHarness is OracleGate {
    constructor(address s, bytes32 q) OracleGate(s, q, 21, 15) {}

    function verify(Attestation calldata a, bytes calldata sig) external view returns (uint256) {
        return _verifyAttestation(a, sig);
    }
}

contract GateHarnessCfg is OracleGate {
    constructor(address s, bytes32 q, uint16 p, uint16 k) OracleGate(s, q, p, k) {}
}

contract OracleGateTest is Test {
    uint256 signerKey = 0xA11CE;
    address signer = vm.addr(signerKey);
    bytes32 constant Q = keccak256("question");
    GateHarness gate;

    function setUp() public {
        vm.warp(1_800_000_000);
        gate = new GateHarness(signer, Q);
    }

    function _att(uint256 answer) internal view returns (OracleGate.Attestation memory a) {
        a.requestId = keccak256("req");
        a.chainId = block.chainid;
        a.questionHash = Q;
        a.answerType = 3;
        a.answer = abi.encode(answer);
        a.panelJobId = keccak256("panel");
        a.panelSize = 21;
        a.quorum = 15;
        a.agreed = 17;
        a.issuedAt = uint64(block.timestamp - 10);
        a.expiresAt = uint64(block.timestamp + 1 hours);
    }

    function _sign(OracleGate.Attestation memory a, uint256 key) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, gate.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function test_validAttestationReturnsAnswer() public view {
        OracleGate.Attestation memory a = _att(7);
        assertEq(gate.verify(a, _sign(a, signerKey)), 7);
    }

    function test_wrongSignerReverts() public {
        OracleGate.Attestation memory a = _att(7);
        bytes memory sig = _sign(a, 0xB0B);
        vm.expectRevert(OracleGate.InvalidSigner.selector);
        gate.verify(a, sig);
    }

    function test_wrongQuestionReverts() public {
        OracleGate.Attestation memory a = _att(7);
        a.questionHash = keccak256("other");
        bytes memory sig = _sign(a, signerKey);
        vm.expectRevert(OracleGate.InvalidAttestation.selector);
        gate.verify(a, sig);
    }

    function test_belowQuorumReverts() public {
        OracleGate.Attestation memory a = _att(7);
        a.agreed = 14;
        bytes memory sig = _sign(a, signerKey);
        vm.expectRevert(OracleGate.InvalidAttestation.selector);
        gate.verify(a, sig);
    }

    function test_wrongPanelReverts() public {
        OracleGate.Attestation memory a = _att(7);
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 5;
        bytes memory sig = _sign(a, signerKey);
        vm.expectRevert(OracleGate.InvalidAttestation.selector);
        gate.verify(a, sig);
    }

    function test_expiredReverts() public {
        OracleGate.Attestation memory a = _att(7);
        bytes memory sig = _sign(a, signerKey);
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(OracleGate.InvalidAttestation.selector);
        gate.verify(a, sig);
    }

    function test_wrongChainReverts() public {
        OracleGate.Attestation memory a = _att(7);
        a.chainId = block.chainid + 1;
        bytes memory sig = _sign(a, signerKey);
        vm.expectRevert(OracleGate.InvalidAttestation.selector);
        gate.verify(a, sig);
    }

    function test_highSMalleableSignatureReverts() public {
        OracleGate.Attestation memory a = _att(7);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, gate.attestationDigest(a));
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes memory flipped = abi.encodePacked(r, bytes32(n - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        vm.expectRevert(OracleGate.BadSignature.selector);
        gate.verify(a, flipped);
    }

    /// @dev Real mainnet attestation fetched from GET https://api.imd.fun/oracle/requests/
    /// 73918afd-d039-4034-af9d-941f2f662a9f/attestation (EGLL weather question, panel 5/4, chain 1).
    /// Proves our digest equals the one IMD signed: ecrecover must give the API's signer.
    function test_realImdAttestationDigestMatches() public {
        address consumer = 0x37Bfb8AC7C960E558657871D41Ca70E07e7DbfFf;
        address imdSigner = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
        vm.chainId(1);
        GateHarness h = new GateHarness(imdSigner, keccak256("irrelevant"));
        vm.etch(consumer, address(h).code);

        OracleGate.Attestation memory a;
        a.requestId = 0x73918afdd0394034af9d941f2f662a9f00000000000000000000000000000000;
        a.chainId = 1;
        a.questionHash = 0x39eecf277118e4219d50e4352a2fcf943cf802239c546d54dd4baba53c72d787;
        a.answerType = 3;
        a.answer = hex"00000000000000000000000000000000000000000000000000000000d58a77a0";
        a.figure = 3582621600;
        a.fromBlock = 26122900;
        a.toBlock = 26122901;
        a.blockHash = 0x22cd78830715d67d27849123a084fe3b854a1af74b40cd7f73c727399eef3059;
        a.panelJobId = 0x2d65ddbf85244a2c8bbe493c9edb6f2e00000000000000000000000000000000;
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 4;
        a.issuedAt = 1791312386;
        a.expiresAt = 1791333986;
        bytes memory sig =
            hex"3a32adec2f4c692b9a60c2bd121b5ce2afbd4d8a18a68e5ee6f3654cf3efa3394d1158d0806fbe652895dee4ed0644c4fff093e9f8c6283cf9bb12233c8ac8321b";

        bytes32 digest = GateHarness(consumer).attestationDigest(a);
        bytes32 r;
        bytes32 s;
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
        }
        assertEq(ecrecover(digest, uint8(sig[64]), r, s), imdSigner);
    }

    // ---- negative paths

    function _expectInvalid(OracleGate.Attestation memory a) internal {
        bytes memory sig = _sign(a, signerKey);
        vm.expectRevert(OracleGate.InvalidAttestation.selector);
        gate.verify(a, sig);
    }

    function test_answerTypeNotUintReverts() public {
        OracleGate.Attestation memory a = _att(7);
        a.answerType = 1;
        _expectInvalid(a);
    }

    function test_answerLengthNot32Reverts() public {
        OracleGate.Attestation memory a = _att(7);
        a.answer = abi.encodePacked(uint128(7));
        _expectInvalid(a);
        a.answer = abi.encode(uint256(7), uint256(0));
        _expectInvalid(a);
    }

    function test_issuedInTheFutureReverts() public {
        OracleGate.Attestation memory a = _att(7);
        a.issuedAt = uint64(block.timestamp + 1);
        _expectInvalid(a);
    }

    function test_expiresNotAfterIssuedReverts() public {
        OracleGate.Attestation memory a = _att(7);
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp);
        _expectInvalid(a);
    }

    function test_sigLengthNot65Reverts() public {
        OracleGate.Attestation memory a = _att(7);
        bytes memory sig = _sign(a, signerKey);
        bytes memory short = new bytes(64);
        for (uint256 i = 0; i < 64; i++) {
            short[i] = sig[i];
        }
        vm.expectRevert(OracleGate.BadSignature.selector);
        gate.verify(a, short);
        vm.expectRevert(OracleGate.BadSignature.selector);
        gate.verify(a, abi.encodePacked(sig, uint8(0)));
    }

    function test_vNot27Or28Reverts() public {
        OracleGate.Attestation memory a = _att(7);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, gate.attestationDigest(a));
        vm.expectRevert(OracleGate.BadSignature.selector);
        gate.verify(a, abi.encodePacked(r, s, uint8(v - 27)));
        vm.expectRevert(OracleGate.BadSignature.selector);
        gate.verify(a, abi.encodePacked(r, s, uint8(29)));
    }

    function test_constructor_invalidConfigReverts() public {
        vm.expectRevert(OracleGate.InvalidOracleConfig.selector);
        new GateHarnessCfg(address(0), Q, 21, 15);
        vm.expectRevert(OracleGate.InvalidOracleConfig.selector);
        new GateHarnessCfg(signer, bytes32(0), 21, 15);
        vm.expectRevert(OracleGate.InvalidOracleConfig.selector);
        new GateHarnessCfg(signer, Q, 21, 0);
        vm.expectRevert(OracleGate.InvalidOracleConfig.selector);
        new GateHarnessCfg(signer, Q, 21, 22);
        new GateHarnessCfg(signer, Q, 21, 21); // quorum == panel is allowed
    }
}
