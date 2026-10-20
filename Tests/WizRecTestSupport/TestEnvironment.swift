import Darwin

/// Facts about the machine running the tests.
public enum TestEnvironment {
    /// True inside a virtual machine (`kern.hv_vmm_present`), e.g. GitHub's macOS runners, whose
    /// paravirtual GPU and software VideoToolbox paths differ from Apple-silicon hardware.
    public static let isVirtualMachine: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 && value == 1
    }()
}
