//go:build linux && arm64

package main

import (
	"fmt"
	"os"
	"syscall"
	"time"
	"unsafe"
)

const runTimeout = 5 * time.Second

type memRegion struct {
	slot          uint32
	flags         uint32
	guestPhysAddr uint64
	memorySize    uint64
	userspaceAddr uint64
}

type vcpuInit struct {
	target   uint32
	features [vcpuInitFeatLen]uint32
}

type oneReg struct {
	id   uint64
	addr uint64
}

type createDevice struct {
	typ   uint32
	fd    uint32
	flags uint32
}

// ioctlv calls ioctl with an integer argument.
func ioctlv(fd int, req uintptr, arg uintptr) (int, error) {
	r, _, e := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), req, arg)
	if e != 0 {
		return -1, e
	}
	return int(r), nil
}

// ioctlp calls ioctl with a pointer argument. The pointer conversion stays
// inside the Syscall expression so the GC keeps the object alive and valid.
func ioctlp(fd int, req uintptr, p unsafe.Pointer) (int, error) {
	r, _, e := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), req, uintptr(p))
	if e != 0 {
		return -1, e
	}
	return int(r), nil
}

func hasExt(kvm int, ext uintptr) int {
	v, err := ioctlv(kvm, kvmCheckExtension, ext)
	if err != nil {
		return 0
	}
	return v
}

func runProbe(r *report) {
	kvm, err := syscall.Open("/dev/kvm", syscall.O_RDWR|syscall.O_CLOEXEC, 0)
	if err != nil {
		r.fail("open /dev/kvm: %v", err)
		return
	}
	defer syscall.Close(kvm)
	r.ok("opened /dev/kvm")

	api, err := ioctlv(kvm, kvmGetAPIVersion, 0)
	switch {
	case err != nil:
		r.fail("KVM_GET_API_VERSION: %v", err)
		return
	case api != kvmAPIVersion:
		r.fail("KVM API version %d, expected %d", api, kvmAPIVersion)
		return
	}
	r.ok("KVM API version %d", api)

	probeCaps(r, kvm)
	probeGIC(r, kvm)
	bootGuest(r, kvm)
}

func probeCaps(r *report, kvm int) {
	type capCheck struct {
		id    uintptr
		name  string
		need  bool
		isNum bool
	}
	checks := []capCheck{
		{capUserMemory, "KVM_CAP_USER_MEMORY", true, false},
		{capOneReg, "KVM_CAP_ONE_REG", true, false},
		{capArmPSCI02, "KVM_CAP_ARM_PSCI_0_2", true, false},
		{capIOEventFD, "KVM_CAP_IOEVENTFD (virtio notify)", false, false},
		{capIRQFD, "KVM_CAP_IRQFD (virtio interrupts)", false, false},
		{capIRQRouting, "KVM_CAP_IRQ_ROUTING", false, false},
		{capArmPMUv3, "KVM_CAP_ARM_PMU_V3", false, false},
		{capNrVcpus, "KVM_CAP_NR_VCPUS (recommended)", false, true},
		{capMaxVcpus, "KVM_CAP_MAX_VCPUS", false, true},
		{capArmVMIPASize, "KVM_CAP_ARM_VM_IPA_SIZE (bits)", false, true},
	}
	for _, c := range checks {
		v := hasExt(kvm, c.id)
		switch {
		case c.isNum && v > 0:
			r.info("%s = %d", c.name, v)
		case c.isNum:
			r.info("%s not reported", c.name)
		case v > 0:
			r.ok("%s", c.name)
		case c.need:
			r.fail("%s missing", c.name)
		default:
			r.warn("%s missing", c.name)
		}
	}

	size, err := ioctlv(kvm, kvmGetVcpuMmapSize, 0)
	if err != nil || size <= 0 {
		r.fail("KVM_GET_VCPU_MMAP_SIZE: %v", err)
		return
	}
	r.info("vcpu mmap size %d bytes", size)
}

// probeGIC asks, on a throwaway VM, whether the kernel can create an
// in-kernel GIC. Linux in the guest needs one. TEST flag: nothing is created.
func probeGIC(r *report, kvm int) {
	vm, err := ioctlv(kvm, kvmCreateVM, 0)
	if err != nil {
		r.warn("GIC probe skipped, KVM_CREATE_VM: %v", err)
		return
	}
	defer syscall.Close(vm)

	v3, v2 := false, false
	for _, t := range []struct {
		typ  uint32
		name string
		flag *bool
	}{
		{devTypeVGICv3, "vGICv3", &v3},
		{devTypeVGICv2, "vGICv2", &v2},
	} {
		d := createDevice{typ: t.typ, flags: createDeviceTestFlag}
		if _, err := ioctlp(vm, kvmCreateDevice, unsafe.Pointer(&d)); err == nil {
			*t.flag = true
			r.ok("in-kernel %s supported", t.name)
		} else {
			r.info("in-kernel %s not supported: %v", t.name, err)
		}
	}
	if !v3 && !v2 {
		r.fail("no in-kernel GIC (v2 or v3): a Linux guest cannot take interrupts")
	}
}

// bootGuest runs the tiny guest program and checks its console output.
func bootGuest(r *report, kvm int) {
	timer := time.AfterFunc(runTimeout, func() {
		fmt.Fprintf(os.Stdout, "[FAIL] guest did not finish within %s (hung in KVM_RUN)\n", runTimeout)
		fmt.Fprintln(os.Stdout, "RESULT: FAIL - VM route not usable, see FAIL lines above")
		os.Exit(1)
	})
	defer timer.Stop()

	vm, err := ioctlv(kvm, kvmCreateVM, 0)
	if err != nil {
		r.fail("KVM_CREATE_VM: %v (ENODEV/EOPNOTSUPP usually means the kernel did not boot at EL2)", err)
		return
	}
	defer syscall.Close(vm)
	r.ok("KVM_CREATE_VM")

	mem, err := syscall.Mmap(-1, 0, guestRAMSize,
		syscall.PROT_READ|syscall.PROT_WRITE, syscall.MAP_ANON|syscall.MAP_PRIVATE)
	if err != nil {
		r.fail("mmap guest RAM: %v", err)
		return
	}
	defer syscall.Munmap(mem)
	copy(mem, guestProgram())

	region := memRegion{
		slot:          0,
		guestPhysAddr: guestRAMBase,
		memorySize:    guestRAMSize,
		userspaceAddr: uint64(uintptr(unsafe.Pointer(&mem[0]))),
	}
	if _, err := ioctlp(vm, kvmSetUserMemRegion, unsafe.Pointer(&region)); err != nil {
		r.fail("KVM_SET_USER_MEMORY_REGION: %v", err)
		return
	}
	r.ok("guest RAM mapped at 0x%x (%d KiB)", guestRAMBase, guestRAMSize>>10)

	vcpu, err := ioctlv(vm, kvmCreateVcpu, 0)
	if err != nil {
		r.fail("KVM_CREATE_VCPU: %v", err)
		return
	}
	defer syscall.Close(vcpu)

	var init vcpuInit
	if _, err := ioctlp(vm, kvmArmPreferredTarget, unsafe.Pointer(&init)); err != nil {
		r.fail("KVM_ARM_PREFERRED_TARGET: %v", err)
		return
	}
	r.info("preferred vcpu target %d", init.target)
	init.features[0] |= 1 << featPSCI02
	if _, err := ioctlp(vcpu, kvmArmVcpuInit, unsafe.Pointer(&init)); err != nil {
		r.fail("KVM_ARM_VCPU_INIT: %v", err)
		return
	}
	r.ok("vcpu initialised (PSCI 0.2)")

	pc := uint64(guestRAMBase)
	reg := oneReg{id: regPC, addr: uint64(uintptr(unsafe.Pointer(&pc)))}
	if _, err := ioctlp(vcpu, kvmSetOneReg, unsafe.Pointer(&reg)); err != nil {
		r.fail("KVM_SET_ONE_REG pc: %v", err)
		return
	}

	runSize, err := ioctlv(kvm, kvmGetVcpuMmapSize, 0)
	if err != nil || runSize <= 0 {
		r.fail("KVM_GET_VCPU_MMAP_SIZE: %v", err)
		return
	}
	run, err := syscall.Mmap(vcpu, 0, runSize,
		syscall.PROT_READ|syscall.PROT_WRITE, syscall.MAP_SHARED)
	if err != nil {
		r.fail("mmap kvm_run: %v", err)
		return
	}
	defer syscall.Munmap(run)

	var console []byte
	shutdown := false
	for i := 0; i < 32 && !shutdown; i++ {
		if _, err := ioctlv(vcpu, kvmRun, 0); err != nil {
			if err == syscall.EINTR {
				continue
			}
			r.fail("KVM_RUN: %v", err)
			return
		}
		reason := *(*uint32)(unsafe.Pointer(&run[runExitReasonOff]))
		switch reason {
		case exitMMIO:
			phys := *(*uint64)(unsafe.Pointer(&run[runMMIOPhysOff]))
			n := *(*uint32)(unsafe.Pointer(&run[runMMIOLenOff]))
			write := run[runMMIOWriteOff] != 0
			if phys == guestUART && write && n >= 1 && n <= 8 {
				console = append(console, run[runMMIODataOff:runMMIODataOff+int(n)]...)
			} else {
				r.warn("unexpected MMIO phys=0x%x len=%d write=%v", phys, n, write)
			}
		case exitSystemEvent:
			ev := *(*uint32)(unsafe.Pointer(&run[runSysEventType]))
			if ev == systemEventShutdown {
				shutdown = true
			} else {
				r.fail("unexpected system event type %d", ev)
				return
			}
		case exitFailEntry:
			hw := *(*uint64)(unsafe.Pointer(&run[runUnionOff]))
			r.fail("KVM_EXIT_FAIL_ENTRY hardware reason 0x%x", hw)
			return
		case exitInternalErr:
			sub := *(*uint32)(unsafe.Pointer(&run[runUnionOff]))
			r.fail("KVM_EXIT_INTERNAL_ERROR suberror %d", sub)
			return
		default:
			r.fail("unexpected KVM exit reason %d", reason)
			return
		}
	}

	if string(console) == guestExpectedOutput {
		r.ok("guest executed: console output %q", string(console))
	} else {
		r.fail("guest console output %q, expected %q", string(console), guestExpectedOutput)
	}
	if shutdown {
		r.ok("guest powered off through PSCI SYSTEM_OFF")
	} else {
		r.fail("guest did not reach PSCI SYSTEM_OFF")
	}
}
