package main

import "encoding/binary"

// Linux ioctl number encoding (arm64): dir<<30 | size<<16 | type<<8 | nr.
const (
	iocNone  = 0
	iocWrite = 1
	iocRead  = 2
)

func ioc(dir, typ, nr, size uint32) uintptr {
	return uintptr(dir<<30 | size<<16 | typ<<8 | nr)
}

const kvmIO = 0xAE

// Struct sizes from include/uapi/linux/kvm.h (arm64).
const (
	sizeMemRegion   = 32 // struct kvm_userspace_memory_region
	sizeVcpuInit    = 32 // struct kvm_vcpu_init
	sizeOneReg      = 16 // struct kvm_one_reg
	sizeCreateDev   = 12 // struct kvm_create_device
	vcpuInitFeatLen = 7
)

// KVM ioctl request numbers.
var (
	kvmGetAPIVersion      = ioc(iocNone, kvmIO, 0x00, 0)
	kvmCreateVM           = ioc(iocNone, kvmIO, 0x01, 0)
	kvmCheckExtension     = ioc(iocNone, kvmIO, 0x03, 0)
	kvmGetVcpuMmapSize    = ioc(iocNone, kvmIO, 0x04, 0)
	kvmCreateVcpu         = ioc(iocNone, kvmIO, 0x41, 0)
	kvmSetUserMemRegion   = ioc(iocWrite, kvmIO, 0x46, sizeMemRegion)
	kvmRun                = ioc(iocNone, kvmIO, 0x80, 0)
	kvmArmPreferredTarget = ioc(iocRead, kvmIO, 0xAF, sizeVcpuInit)
	kvmArmVcpuInit        = ioc(iocWrite, kvmIO, 0xAE, sizeVcpuInit)
	kvmSetOneReg          = ioc(iocWrite, kvmIO, 0xAC, sizeOneReg)
	kvmCreateDevice       = ioc(iocRead|iocWrite, kvmIO, 0xE0, sizeCreateDev)
)

const kvmAPIVersion = 12

// KVM capability numbers.
const (
	capUserMemory   = 3
	capIRQRouting   = 25
	capIRQFD        = 32
	capIOEventFD    = 36
	capNrVcpus      = 9
	capMaxVcpus     = 66
	capOneReg       = 70
	capArmPSCI02    = 102
	capArmPMUv3     = 126
	capArmVMIPASize = 165
)

// KVM_CREATE_DEVICE.
const (
	devTypeVGICv2        = 5
	devTypeVGICv3        = 7
	createDeviceTestFlag = 1
)

// vcpu init feature bits (index into features[0]).
const featPSCI02 = 2

// kvm_run exit reasons.
const (
	exitMMIO        = 6
	exitFailEntry   = 9
	exitInternalErr = 17
	exitSystemEvent = 24

	systemEventShutdown = 1
)

// Offsets inside the mmap'ed struct kvm_run.
const (
	runExitReasonOff = 8
	runUnionOff      = 32
	runMMIOPhysOff   = runUnionOff + 0
	runMMIODataOff   = runUnionOff + 8
	runMMIOLenOff    = runUnionOff + 16
	runMMIOWriteOff  = runUnionOff + 20
	runSysEventType  = runUnionOff + 0
)

// ONE_REG ids for arm64 core registers (u64 size, KVM_REG_ARM_CORE).
const (
	regArm64   = 0x6000000000000000
	regSizeU64 = 0x0030000000000000
	regArmCore = 0x0010 << 16
)

func coreReg(wordIndex uint64) uint64 {
	return regArm64 | regSizeU64 | regArmCore | wordIndex
}

var (
	regPC = coreReg(64) // offsetof(struct kvm_regs, regs.pc)/4
	regX0 = coreReg(0)
)

// Guest memory layout.
const (
	guestRAMBase = 0x40000000
	guestRAMSize = 2 << 20
	guestUART    = 0x09000000 // outside any memslot, so every access is a KVM_EXIT_MMIO
)

// guestProgram returns a tiny aarch64 program that writes "OK\n" to the
// UART address one byte at a time, then asks PSCI to power the system off.
//
//	movz x1, #0x0900, lsl #16      ; x1 = 0x09000000
//	movz w0, #'O' ; strb w0, [x1]
//	movz w0, #'K' ; strb w0, [x1]
//	movz w0, #'\n'; strb w0, [x1]
//	movz x0, #0x0008
//	movk x0, #0x8400, lsl #16      ; x0 = 0x84000008 (PSCI SYSTEM_OFF)
//	hvc  #0
//	b    .
func guestProgram() []byte {
	words := []uint32{
		0xD2A12001, // movz x1, #0x0900, lsl #16
		0x528009E0, // movz w0, #0x4F
		0x39000020, // strb w0, [x1]
		0x52800960, // movz w0, #0x4B
		0x39000020, // strb w0, [x1]
		0x52800140, // movz w0, #0x0A
		0x39000020, // strb w0, [x1]
		0xD2800100, // movz x0, #0x8
		0xF2B08000, // movk x0, #0x8400, lsl #16
		0xD4000002, // hvc #0
		0x14000000, // b .
	}
	b := make([]byte, 4*len(words))
	for i, w := range words {
		binary.LittleEndian.PutUint32(b[4*i:], w)
	}
	return b
}

const guestExpectedOutput = "OK\n"
