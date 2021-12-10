//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../state/Values.sol";
import "../state/Machines.sol";
import "../state/Modules.sol";
import "../state/Deserialize.sol";
import "./IOneStepProver.sol";

contract OneStepProver0 is IOneStepProver {
	function executeUnreachable(Machine memory mach, Module memory, Instruction calldata, bytes calldata) internal pure {
		mach.status = MachineStatus.ERRORED;
	}

	function executeNop(Machine memory mach, Module memory, Instruction calldata, bytes calldata) internal pure {
		// :)
	}

	function executeConstPush(Machine memory mach, Module memory, Instruction calldata inst, bytes calldata) internal pure {
		uint16 opcode = inst.opcode;
		ValueType ty;
		if (opcode == Instructions.I32_CONST) {
			ty = ValueType.I32;
		} else if (opcode == Instructions.I64_CONST) {
			ty = ValueType.I64;
		} else if (opcode == Instructions.F32_CONST) {
			ty = ValueType.F32;
		} else if (opcode == Instructions.F64_CONST) {
			ty = ValueType.F64;
		} else if (opcode == Instructions.PUSH_STACK_BOUNDARY) {
			ty = ValueType.STACK_BOUNDARY;
		} else {
			revert("CONST_PUSH_INVALID_OPCODE");
		}

		ValueStacks.push(mach.valueStack, Value({
			valueType: ty,
			contents: uint64(inst.argumentData)
		}));
	}

	function executeDrop(Machine memory mach, Module memory, Instruction calldata, bytes calldata) internal pure {
		ValueStacks.pop(mach.valueStack);
	}

	function executeSelect(Machine memory mach, Module memory, Instruction calldata, bytes calldata) internal pure {
		uint32 selector = Values.assumeI32(ValueStacks.pop(mach.valueStack));
		Value memory b = ValueStacks.pop(mach.valueStack);
		Value memory a = ValueStacks.pop(mach.valueStack);

		if (selector != 0) {
			ValueStacks.push(mach.valueStack, a);
		} else {
			ValueStacks.push(mach.valueStack, b);
		}
	}

	function executeBlock(Machine memory mach, Module memory, Instruction calldata inst, bytes calldata) internal pure {
		uint32 targetPc = uint32(inst.argumentData);
		require(targetPc == inst.argumentData, "BAD_BLOCK_PC");
		PcStacks.push(mach.blockStack, targetPc);
	}

	function executeBranch(Machine memory mach, Module memory, Instruction calldata, bytes calldata) internal pure {
		mach.functionPc = PcStacks.pop(mach.blockStack);
	}

	function executeBranchIf(Machine memory mach, Module memory, Instruction calldata, bytes calldata) internal pure {
		Value memory cond = ValueStacks.pop(mach.valueStack);
		if (cond.contents != 0) {
			// Jump to target
			mach.functionPc = PcStacks.pop(mach.blockStack);
		}
	}

	function executeReturn(Machine memory mach, Module memory, Instruction calldata, bytes calldata) internal pure {
		StackFrame memory frame = StackFrames.pop(mach.frameStack);
		if (frame.returnPc.valueType == ValueType.REF_NULL) {
			mach.status = MachineStatus.ERRORED;
			return;
		} else if (frame.returnPc.valueType != ValueType.INTERNAL_REF) {
			revert("INVALID_RETURN_PC_TYPE");
		}
		uint256 data = frame.returnPc.contents;
		uint32 pc = uint32(data);
		uint32 func = uint32(data >> 32);
		uint32 mod = uint32(data >> 64);
		require(data >> 96 == 0, "INVALID_RETURN_PC_DATA");
		mach.functionPc = pc;
		mach.functionIdx = func;
		mach.moduleIdx = mod;
	}

	function createReturnValue(Machine memory mach) internal pure returns (Value memory) {
		uint256 returnData = 0;
		returnData |= mach.functionPc;
		returnData |= uint256(mach.functionIdx) << 32;
		returnData |= uint256(mach.moduleIdx) << 64;
		return Value({
			valueType: ValueType.INTERNAL_REF,
			contents: returnData
		});
	}

	function executeCall(Machine memory mach, Module memory, Instruction calldata inst, bytes calldata) internal pure {
		// Push the return pc to the stack
		ValueStacks.push(mach.valueStack, createReturnValue(mach));

		// Push caller module info to the stack
		StackFrame memory frame = StackFrames.peek(mach.frameStack);
		ValueStacks.push(mach.valueStack, Values.newI32(frame.callerModule));
		ValueStacks.push(mach.valueStack, Values.newI32(frame.callerModuleInternals));

		// Jump to the target
		uint32 idx = uint32(inst.argumentData);
		require(idx == inst.argumentData, "BAD_CALL_DATA");
		mach.functionIdx = idx;
		mach.functionPc = 0;
	}

	function executeCrossModuleCall(Machine memory mach, Module memory mod, Instruction calldata inst, bytes calldata) internal pure {
		// Push the return pc to the stack
		ValueStacks.push(mach.valueStack, createReturnValue(mach));

		// Push caller module info to the stack
		ValueStacks.push(mach.valueStack, Values.newI32(mach.moduleIdx));
		ValueStacks.push(mach.valueStack, Values.newI32(mod.internalsOffset));

		// Jump to the target
		uint32 func = uint32(inst.argumentData);
		uint32 module = uint32(inst.argumentData >> 32);
		require(inst.argumentData >> 64 == 0, "BAD_CROSS_MODULE_CALL_DATA");
		mach.moduleIdx = module;
		mach.functionIdx = func;
		mach.functionPc = 0;
	}

	function executeCallerModuleInternalCall(Machine memory mach, Module memory mod, Instruction calldata inst, bytes calldata) internal pure {
		// Push the return pc to the stack
		ValueStacks.push(mach.valueStack, createReturnValue(mach));

		// Push caller module info to the stack
		ValueStacks.push(mach.valueStack, Values.newI32(mach.moduleIdx));
		ValueStacks.push(mach.valueStack, Values.newI32(mod.internalsOffset));

		StackFrame memory frame = StackFrames.peek(mach.frameStack);
		if (frame.callerModuleInternals == 0) {
			// The caller module has no internals
			mach.status = MachineStatus.ERRORED;
			return;
		}

		// Jump to the target
		uint32 offset = uint32(inst.argumentData);
		require(offset == inst.argumentData, "BAD_CALLER_INTERNAL_CALL_DATA");
		mach.moduleIdx = frame.callerModule;
		mach.functionIdx = frame.callerModuleInternals + offset;
		mach.functionPc = 0;
	}

	function executeCallIndirect(Machine memory mach, Module memory mod, Instruction calldata inst, bytes calldata proof) internal pure {
		uint32 funcIdx;
		{
			uint32 elementIdx = Values.assumeI32(ValueStacks.pop(mach.valueStack));

			// Prove metadata about the instruction and tables
			bytes32 elemsRoot;
			bytes32 wantedFuncTypeHash;
			uint256 offset = 0;
			{
				uint64 tableIdx;
				uint8 tableType;
				uint64 tableSize;
				MerkleProof memory tableMerkleProof;
				(tableIdx, offset) = Deserialize.u64(proof, offset);
				(wantedFuncTypeHash, offset) = Deserialize.b32(proof, offset);
				(tableType, offset) = Deserialize.u8(proof, offset);
				(tableSize, offset) = Deserialize.u64(proof, offset);
				(elemsRoot, offset) = Deserialize.b32(proof, offset);
				(tableMerkleProof, offset) = Deserialize.merkleProof(proof, offset);

				// Validate the information by recomputing known hashes
				bytes32 recomputed = keccak256(abi.encodePacked("Call indirect:", tableIdx, wantedFuncTypeHash));
				require(recomputed == bytes32(inst.argumentData), "BAD_CALL_INDIRECT_DATA");
				recomputed = MerkleProofs.computeRootFromTable(tableMerkleProof, tableIdx, tableType, tableSize, elemsRoot);
				require(recomputed == mod.tablesMerkleRoot, "BAD_TABLES_ROOT");

				// Check if the table access is out of bounds
				if (elementIdx >= tableSize) {
					mach.status = MachineStatus.ERRORED;
					return;
				}
			}

			bytes32 elemFuncTypeHash;
			Value memory functionPointer;
			MerkleProof memory elementMerkleProof;
			(elemFuncTypeHash, offset) = Deserialize.b32(proof, offset);
			(functionPointer, offset) = Deserialize.value(proof, offset);
			(elementMerkleProof, offset) = Deserialize.merkleProof(proof, offset);
			bytes32 recomputedElemRoot = MerkleProofs.computeRootFromElement(elementMerkleProof, elementIdx, elemFuncTypeHash, functionPointer);
			require(recomputedElemRoot == elemsRoot, "BAD_ELEMENTS_ROOT");

			if (elemFuncTypeHash != wantedFuncTypeHash) {
				mach.status = MachineStatus.ERRORED;
				return;
			}

			if (functionPointer.valueType == ValueType.REF_NULL) {
				mach.status = MachineStatus.ERRORED;
				return;
			} else if (functionPointer.valueType == ValueType.FUNC_REF) {
				funcIdx = uint32(functionPointer.contents);
				require(funcIdx == functionPointer.contents, "BAD_FUNC_REF_CONTENTS");
			} else {
				revert("BAD_ELEM_TYPE");
			}
		}

		// Push the return pc to the stack
		ValueStacks.push(mach.valueStack, createReturnValue(mach));

		// Push caller module info to the stack
		StackFrame memory frame = StackFrames.peek(mach.frameStack);
		ValueStacks.push(mach.valueStack, Values.newI32(frame.callerModule));
		ValueStacks.push(mach.valueStack, Values.newI32(frame.callerModuleInternals));

		// Jump to the target
		mach.functionIdx = funcIdx;
		mach.functionPc = 0;
	}

	function executeArbitraryJumpIf(Machine memory mach, Module memory, Instruction calldata inst, bytes calldata) internal pure {
		Value memory cond = ValueStacks.pop(mach.valueStack);
		if (cond.contents != 0) {
			// Jump to target
			uint32 pc = uint32(inst.argumentData);
			require(pc == inst.argumentData, "BAD_CALL_DATA");
			mach.functionPc = pc;
		}
	}

	function merkleProveGetValue(bytes32 merkleRoot, uint256 index, bytes calldata proof) internal pure returns (Value memory) {
		uint256 offset = 0;
		Value memory proposedVal;
		MerkleProof memory merkle;
		(proposedVal, offset) = Deserialize.value(proof, offset);
		(merkle, offset) = Deserialize.merkleProof(proof, offset);
		bytes32 recomputedRoot = MerkleProofs.computeRootFromValue(merkle, index, proposedVal);
		require(recomputedRoot == merkleRoot, "WRONG_MERKLE_ROOT");
		return proposedVal;
	}

	function merkleProveSetValue(bytes32 merkleRoot, uint256 index, Value memory newVal, bytes calldata proof) internal pure returns (bytes32) {
		Value memory oldVal;
		uint256 offset = 0;
		MerkleProof memory merkle;
		(oldVal, offset) = Deserialize.value(proof, offset);
		(merkle, offset) = Deserialize.merkleProof(proof, offset);
		bytes32 recomputedRoot = MerkleProofs.computeRootFromValue(merkle, index, oldVal);
		require(recomputedRoot == merkleRoot, "WRONG_MERKLE_ROOT");
		return MerkleProofs.computeRootFromValue(merkle, index, newVal);
	}

	function executeLocalGet(Machine memory mach, Module memory, Instruction calldata inst, bytes calldata proof) internal pure {
		StackFrame memory frame = StackFrames.peek(mach.frameStack);
		Value memory val = merkleProveGetValue(frame.localsMerkleRoot, inst.argumentData, proof);
		ValueStacks.push(mach.valueStack, val);
	}

	function executeLocalSet(Machine memory mach, Module memory, Instruction calldata inst, bytes calldata proof) internal pure {
		Value memory newVal = ValueStacks.pop(mach.valueStack);
		StackFrame memory frame = StackFrames.peek(mach.frameStack);
		frame.localsMerkleRoot = merkleProveSetValue(frame.localsMerkleRoot, inst.argumentData, newVal, proof);
	}

	function executeGlobalGet(Machine memory mach, Module memory mod, Instruction calldata inst, bytes calldata proof) internal pure {
		Value memory val = merkleProveGetValue(mod.globalsMerkleRoot, inst.argumentData, proof);
		ValueStacks.push(mach.valueStack, val);
	}

	function executeGlobalSet(Machine memory mach, Module memory mod, Instruction calldata inst, bytes calldata proof) internal pure {
		Value memory newVal = ValueStacks.pop(mach.valueStack);
		mod.globalsMerkleRoot = merkleProveSetValue(mod.globalsMerkleRoot, inst.argumentData, newVal, proof);
	}

	function executeEndBlock(Machine memory mach, Module memory, Instruction calldata, bytes calldata) internal pure {
		PcStacks.pop(mach.blockStack);
	}

	function executeEndBlockIf(Machine memory mach, Module memory, Instruction calldata, bytes calldata) internal pure {
		Value memory cond = ValueStacks.peek(mach.valueStack);
		if (cond.contents != 0) {
			PcStacks.pop(mach.blockStack);
		}
	}

	function executeInitFrame(Machine memory mach, Module memory, Instruction calldata inst, bytes calldata) internal pure {
		Value memory callerModuleInternals = ValueStacks.pop(mach.valueStack);
		Value memory callerModule = ValueStacks.pop(mach.valueStack);
		Value memory returnPc = ValueStacks.pop(mach.valueStack);
		StackFrame memory newFrame = StackFrame({
			returnPc: returnPc,
			localsMerkleRoot: bytes32(inst.argumentData),
			callerModule: Values.assumeI32(callerModule),
			callerModuleInternals: Values.assumeI32(callerModuleInternals)
		});
		StackFrames.push(mach.frameStack, newFrame);
	}

	function executeMoveInternal(Machine memory mach, Module memory, Instruction calldata inst, bytes calldata) internal pure {
		Value memory val;
		if (inst.opcode == Instructions.MOVE_FROM_STACK_TO_INTERNAL) {
			val = ValueStacks.pop(mach.valueStack);
			ValueStacks.push(mach.internalStack, val);
		} else if (inst.opcode == Instructions.MOVE_FROM_INTERNAL_TO_STACK) {
			val = ValueStacks.pop(mach.internalStack);
			ValueStacks.push(mach.valueStack, val);
		} else {
			revert("MOVE_INTERNAL_INVALID_OPCODE");
		}
	}

	function executeIsStackBoundary(Machine memory mach, Module memory, Instruction calldata, bytes calldata) internal pure {
		Value memory val = ValueStacks.pop(mach.valueStack);
		uint256 newContents = 0;
		if (val.valueType == ValueType.STACK_BOUNDARY) {
			newContents = 1;
		}
		ValueStacks.push(mach.valueStack, Value({
			valueType: ValueType.I32,
			contents: newContents
		}));
	}

	function executeDup(Machine memory mach, Module memory, Instruction calldata, bytes calldata) internal pure {
		Value memory val = ValueStacks.peek(mach.valueStack);
		ValueStacks.push(mach.valueStack, val);
	}

	function handleTrap(Machine memory mach) internal pure {
		mach.status = MachineStatus.ERRORED;
	}

	function executeOneStep(Machine calldata startMach, Module calldata startMod, Instruction calldata inst, bytes calldata proof) override pure external returns (Machine memory mach, Module memory mod) {
		mach = startMach;
		mod = startMod;

		uint16 opcode = inst.opcode;

		function(Machine memory, Module memory, Instruction calldata, bytes calldata) internal pure impl;
		if (opcode == Instructions.UNREACHABLE) {
			impl = executeUnreachable;
		} else if (opcode == Instructions.NOP) {
			impl = executeNop;
		} else if (opcode == Instructions.BLOCK) {
			impl = executeBlock;
		} else if (opcode == Instructions.BRANCH) {
			impl = executeBranch;
		} else if (opcode == Instructions.BRANCH_IF) {
			impl = executeBranchIf;
		} else if (opcode == Instructions.RETURN) {
			impl = executeReturn;
		} else if (opcode == Instructions.CALL) {
			impl = executeCall;
		} else if (opcode == Instructions.CROSS_MODULE_CALL) {
			impl = executeCrossModuleCall;
		} else if (opcode == Instructions.CALLER_MODULE_INTERNAL_CALL) {
			impl = executeCallerModuleInternalCall;
		} else if (opcode == Instructions.CALL_INDIRECT) {
			impl = executeCallIndirect;
		} else if (opcode == Instructions.END_BLOCK) {
			impl = executeEndBlock;
		} else if (opcode == Instructions.END_BLOCK_IF) {
			impl = executeEndBlockIf;
		} else if (opcode == Instructions.ARBITRARY_JUMP_IF) {
			impl = executeArbitraryJumpIf;
		} else if (opcode == Instructions.LOCAL_GET) {
			impl = executeLocalGet;
		} else if (opcode == Instructions.LOCAL_SET) {
			impl = executeLocalSet;
		} else if (opcode == Instructions.GLOBAL_GET) {
			impl = executeGlobalGet;
		} else if (opcode == Instructions.GLOBAL_SET) {
			impl = executeGlobalSet;
		} else if (opcode == Instructions.INIT_FRAME) {
			impl = executeInitFrame;
		} else if (opcode == Instructions.DROP) {
			impl = executeDrop;
		} else if (opcode == Instructions.SELECT) {
			impl = executeSelect;
		} else if (opcode >= Instructions.I32_CONST && opcode <= Instructions.F64_CONST || opcode == Instructions.PUSH_STACK_BOUNDARY) {
			impl = executeConstPush;
		} else if (opcode == Instructions.MOVE_FROM_STACK_TO_INTERNAL || opcode == Instructions.MOVE_FROM_INTERNAL_TO_STACK) {
			impl = executeMoveInternal;
		} else if (opcode == Instructions.IS_STACK_BOUNDARY) {
			impl = executeIsStackBoundary;
		} else if (opcode == Instructions.DUP) {
			impl = executeDup;
		} else {
			revert("INVALID_OPCODE");
		}

		impl(mach, mod, inst, proof);
	}
}