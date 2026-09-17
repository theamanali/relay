// Row model for the host picker: which hosts appear, in which section and
// state, and how one list turns into the next so the table can animate only
// what changed. Pure Foundation so it is testable without AppKit.

import Foundation

enum PickerSection: Hashable {
    case paired
    case available

    var title: String {
        switch self {
        case .paired: return "Paired"
        case .available: return "Available"
        }
    }
}

enum HostPairState: Equatable {
    /// Remembered by its advertised key.
    case paired
    /// Remembered by name only; the key is checked when connecting.
    case pairedByName
    case unpaired
}

enum PickerRow {
    case header(PickerSection)
    case host(DiscoveredHost, state: HostPairState)

    enum ID: Hashable {
        case header(PickerSection)
        case host(String)
    }

    var id: ID {
        switch self {
        case .header(let s): return .header(s)
        case .host(let h, _): return .host(h.name)
        }
    }

    var host: DiscoveredHost? {
        if case .host(let h, _) = self { return h }
        return nil
    }

    var isHeader: Bool {
        if case .header = self { return true }
        return false
    }

    /// What the row displays; a change here means the cell must be redrawn.
    fileprivate var appearance: Appearance? {
        guard case .host(let h, let state) = self else { return nil }
        return Appearance(state: state, key: h.publicKey, link: h.linkDescription)
    }

    fileprivate struct Appearance: Equatable {
        let state: HostPairState
        let key: Data?
        let link: String
    }
}

struct PickerRowDiff: Equatable {
    /// Indexes into the old list.
    var removed = IndexSet()
    /// Indexes into the new list.
    var inserted = IndexSet()
    /// Indexes into the new list whose content changed.
    var reloaded = IndexSet()
    /// Surviving rows changed order (a host moved between sections): the
    /// table should reload rather than animate.
    var needsFullReload = false
}

enum PickerRows {
    /// Sections appear only when they have hosts.
    static func build(hosts: [DiscoveredHost], known: [Data: String]) -> [PickerRow] {
        let (paired, unpaired) = PairingClassifier.classify(hosts, known: known)
        var rows: [PickerRow] = []
        if !paired.isEmpty {
            rows.append(.header(.paired))
            rows += paired.map { .host($0.host, state: $0.byNameOnly ? .pairedByName : .paired) }
        }
        if !unpaired.isEmpty {
            rows.append(.header(.available))
            rows += unpaired.map { .host($0, state: .unpaired) }
        }
        return rows
    }

    static func diff(old: [PickerRow], new: [PickerRow]) -> PickerRowDiff {
        let oldIDs = old.map(\.id)
        let newIDs = new.map(\.id)
        let oldSet = Set(oldIDs)
        let newSet = Set(newIDs)
        var result = PickerRowDiff()
        if oldIDs.filter(newSet.contains) != newIDs.filter(oldSet.contains) {
            result.needsFullReload = true
            return result
        }
        for (i, id) in oldIDs.enumerated() where !newSet.contains(id) {
            result.removed.insert(i)
        }
        var oldByID: [PickerRow.ID: PickerRow] = [:]
        for row in old { oldByID[row.id] = row }
        for (i, row) in new.enumerated() {
            guard let previous = oldByID[row.id] else {
                result.inserted.insert(i)
                continue
            }
            if previous.appearance != row.appearance {
                result.reloaded.insert(i)
            }
        }
        return result
    }
}
