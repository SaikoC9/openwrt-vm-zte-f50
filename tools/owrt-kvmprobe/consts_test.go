package main

import (
	"bytes"
	"encoding/binary"
	"testing"
)

func TestIoctlNumbers(t *testing.T) {
	// Values from include/uapi/linux/kvm.h on arm64.
	cases := []struct {
		name string
		got  uintptr
		want uintptr
	}{
		{"KVM_GET_API_VERSION", kvmGetAPIVersion, 0xAE00},
		{"KVM_CREATE_VM", kvmCreateVM, 0xAE01},
		{"KVM_CHECK_EXTENSION", kvmCheckExtension, 0xAE03},
		{"KVM_GET_VCPU_MMAP_SIZE", kvmGetVcpuMmapSize, 0xAE04},
		{"KVM_CREATE_VCPU", kvmCreateVcpu, 0xAE41},
		{"KVM_SET_USER_MEMORY_REGION", kvmSetUserMemRegion, 0x4020AE46},
		{"KVM_RUN", kvmRun, 0xAE80},
		{"KVM_ARM_PREFERRED_TARGET", kvmArmPreferredTarget, 0x8020AEAF},
		{"KVM_ARM_VCPU_INIT", kvmArmVcpuInit, 0x4020AEAE},
		{"KVM_SET_ONE_REG", kvmSetOneReg, 0x4010AEAC},
		{"KVM_CREATE_DEVICE", kvmCreateDevice, 0xC00CAEE0},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Errorf("%s = %#x, want %#x", c.name, c.got, c.want)
		}
	}
}

func TestCoreRegIDs(t *testing.T) {
	if regPC != 0x6030000000100040 {
		t.Errorf("regPC = %#x", regPC)
	}
	if regX0 != 0x6030000000100000 {
		t.Errorf("regX0 = %#x", regX0)
	}
}

func TestGuestProgram(t *testing.T) {
	p := guestProgram()
	if len(p)%4 != 0 || len(p) == 0 {
		t.Fatalf("bad program length %d", len(p))
	}
	if len(p) > guestRAMSize {
		t.Fatalf("program larger than guest RAM")
	}
	// First instruction: movz x1, #0x0900, lsl #16 (UART base).
	if w := binary.LittleEndian.Uint32(p[0:4]); w != 0xD2A12001 {
		t.Errorf("first word %#x", w)
	}
	// The three console bytes, in order, must be the immediates of the
	// movz w0 instructions (imm16 is bits 5..20).
	var got []byte
	for i := 0; i+4 <= len(p); i += 4 {
		w := binary.LittleEndian.Uint32(p[i:])
		if w&0xFFE0001F == 0x52800000 { // movz w0, #imm
			got = append(got, byte((w>>5)&0xFFFF))
		}
	}
	if !bytes.Equal(got, []byte(guestExpectedOutput)) {
		t.Errorf("program prints %q, want %q", got, guestExpectedOutput)
	}
	// PSCI SYSTEM_OFF id 0x84000008 is built from movz + movk.
	var x0 uint32
	for i := 0; i+4 <= len(p); i += 4 {
		w := binary.LittleEndian.Uint32(p[i:])
		switch {
		case w&0xFFE0001F == 0xD2800000: // movz x0, #imm
			x0 = (w >> 5) & 0xFFFF
		case w&0xFFE0001F == 0xF2A00000: // movk x0, #imm, lsl #16
			x0 |= ((w >> 5) & 0xFFFF) << 16
		}
	}
	if x0 != 0x84000008 {
		t.Errorf("PSCI function id %#x, want 0x84000008", x0)
	}
	// hvc #0 present, program ends with b .
	if w := binary.LittleEndian.Uint32(p[len(p)-4:]); w != 0x14000000 {
		t.Errorf("last word %#x, want b .", w)
	}
}

func TestStructSizes(t *testing.T) {
	if 4+4*vcpuInitFeatLen != sizeVcpuInit {
		t.Errorf("vcpu_init size constant inconsistent")
	}
}
