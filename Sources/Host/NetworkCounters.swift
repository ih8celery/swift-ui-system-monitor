import Darwin

/// One interface's cumulative byte counts since boot, from the kernel's 64-bit counters.
struct InterfaceCounters {
    let name: String
    let received: UInt64
    let sent: UInt64
}

/// The physical interfaces' counters from one read, by name. Rates are worked out per interface
/// (see `FastStatsSampler.rates`), so an interface that appears or disappears between two reads
/// adds or removes nothing, rather than its whole since-boot count at once.
struct NetworkCounters {
    let interfaces: [String: InterfaceCounters]

    /// Keeps only the physical interfaces of `all`.
    init(interfaces all: [InterfaceCounters]) {
        interfaces = Dictionary(
            all.filter { Self.isPhysical($0.name) }.map { ($0.name, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    /// The whole machine as one interface, for tests of the rate math.
    init(received: UInt64, sent: UInt64) {
        self.init(interfaces: [InterfaceCounters(name: "en0", received: received, sent: sent)])
    }

    /// Whether `name` carries the Mac's traffic to and from networks, counted once. Only `en*`
    /// does: Wi-Fi, Ethernet, Thunderbolt and USB adapters, and iPhone tethering. The rates mean
    /// network traffic, so the rest are left out, each for its own reason:
    /// - `lo` (loopback): the Mac talking to itself.
    /// - `utun` (VPNs, iCloud Private Relay, Tailscale and the like): a tunnel's traffic also
    ///   crosses `en*` encrypted, so counting both doubles a VPN download.
    /// - `awdl` (AirDrop, Sidecar, Continuity) and `llw` (its low-latency companion): Wi-Fi
    ///   peer links straight to nearby Apple devices. Their bytes are their own, not a copy of
    ///   `en*` traffic, but they are device-to-device transfers, not traffic to a network.
    /// - `bridge` (Thunderbolt Bridge, Internet Sharing): repeats its member `en*` interfaces.
    /// - `ap` (the access point Internet Sharing makes): repeats what it forwards.
    /// - `gif` and `stf` (IPv6-over-IPv4 tunnels): repeat what they carry over `en*`.
    /// - `anpi` (internal links on Apple silicon Macs): not user traffic.
    /// Anything new macOS adds is left out until it is known to be physical.
    static func isPhysical(_ name: String) -> Bool {
        name.hasPrefix("en")
    }
}

extension FastStatsSampler {
    /// Every interface's counters, each read with the `IFMIB_IFDATA` sysctl, which
    /// gives an app the exact 64-bit counts. The other two ways in give an app without Apple's
    /// private entitlement the counts cut to 32 bits and rounded down to a whole KiB, so they
    /// wrap every 4 GiB: `getifaddrs`, and the route table's `NET_RT_IFLIST2` (what Stats and
    /// the spec suggested). Measured on macOS 26 with en0 at 125 GB since boot: IFMIB_IFDATA and
    /// `netstat -ib` agreed to the byte, the other two read 0.46 GB. An interface that cannot be
    /// read is left out, which `rates` treats as absent. `NetworkCounters` keeps the physical ones.
    static func readInterfaceCounters() -> [InterfaceCounters] {
        guard let names = if_nameindex() else { return [] }
        defer { if_freenameindex(names) }
        var result: [InterfaceCounters] = []
        var entry = names
        while entry.pointee.if_index != 0, let cName = entry.pointee.if_name {
            let name = String(cString: cName)
            if let counters = interfaceCounters(name: name, index: entry.pointee.if_index) {
                result.append(counters)
            }
            entry += 1
        }
        return result
    }

    private static func interfaceCounters(name: String, index: UInt32) -> InterfaceCounters? {
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, Int32(bitPattern: index), IFDATA_GENERAL]
        var data = ifmibdata()
        var length = MemoryLayout<ifmibdata>.size
        guard sysctl(&mib, u_int(mib.count), &data, &length, nil, 0) == 0 else { return nil }
        return InterfaceCounters(name: name, received: data.ifmd_data.ifi_ibytes, sent: data.ifmd_data.ifi_obytes)
    }
}
