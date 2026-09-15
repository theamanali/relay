// macOS virtual key codes (Carbon kVK_*) -> USB HID Keyboard/Keypad usages.
// Virtual key codes describe physical positions on the Mac keyboard and HID
// usages describe physical positions on a PC keyboard, so this is layout-neutral.

import Foundation

enum ModifierMapping: String {
    /// ⌘→Ctrl, ⌥→Alt, ⌃→Win: Mac shortcuts keep working (⌘C copies).
    case mac
    /// Keys go where they physically sit: ⌘→Alt, ⌥→Win, ⌃→Ctrl.
    case physical
}

struct KeyMap {
    var modifiers: ModifierMapping = .mac

    /// HID usage for a key event, or nil for keys we don't forward.
    func hidUsage(forKeyCode code: UInt16) -> UInt16? {
        switch code {
        // Modifiers (left/right)
        case 55: return modifiers == .mac ? 0xE0 : 0xE2 // Command
        case 54: return modifiers == .mac ? 0xE4 : 0xE6 // Right Command
        case 58: return modifiers == .mac ? 0xE2 : 0xE3 // Option
        case 61: return modifiers == .mac ? 0xE6 : 0xE7 // Right Option
        case 59: return modifiers == .mac ? 0xE3 : 0xE0 // Control
        case 62: return modifiers == .mac ? 0xE7 : 0xE4 // Right Control
        case 56: return 0xE1 // Shift
        case 60: return 0xE5 // Right Shift
        case 57: return 0x39 // Caps Lock
        case 63: return nil  // Fn: handled by macOS
        default: return KeyMap.table[code]
        }
    }

    static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    private static let table: [UInt16: UInt16] = [
        0: 0x04,   // A
        1: 0x16,   // S
        2: 0x07,   // D
        3: 0x09,   // F
        4: 0x0B,   // H
        5: 0x0A,   // G
        6: 0x1D,   // Z
        7: 0x1B,   // X
        8: 0x06,   // C
        9: 0x19,   // V
        10: 0x64,  // ISO § key -> non-US backslash
        11: 0x05,  // B
        12: 0x14,  // Q
        13: 0x1A,  // W
        14: 0x08,  // E
        15: 0x15,  // R
        16: 0x1C,  // Y
        17: 0x17,  // T
        18: 0x1E,  // 1
        19: 0x1F,  // 2
        20: 0x20,  // 3
        21: 0x21,  // 4
        22: 0x23,  // 6
        23: 0x22,  // 5
        24: 0x2E,  // =
        25: 0x26,  // 9
        26: 0x24,  // 7
        27: 0x2D,  // -
        28: 0x25,  // 8
        29: 0x27,  // 0
        30: 0x30,  // ]
        31: 0x12,  // O
        32: 0x18,  // U
        33: 0x2F,  // [
        34: 0x0C,  // I
        35: 0x13,  // P
        36: 0x28,  // Return
        37: 0x0F,  // L
        38: 0x0D,  // J
        39: 0x34,  // '
        40: 0x0E,  // K
        41: 0x33,  // ;
        42: 0x31,  // backslash
        43: 0x36,  // ,
        44: 0x38,  // /
        45: 0x11,  // N
        46: 0x10,  // M
        47: 0x37,  // .
        48: 0x2B,  // Tab
        49: 0x2C,  // Space
        50: 0x35,  // `
        51: 0x2A,  // Delete (backspace)
        53: 0x29,  // Escape
        64: 0x6C,  // F17
        65: 0x63,  // Keypad .
        67: 0x55,  // Keypad *
        69: 0x57,  // Keypad +
        71: 0x53,  // Keypad Clear -> Num Lock
        75: 0x54,  // Keypad /
        76: 0x58,  // Keypad Enter
        78: 0x56,  // Keypad -
        79: 0x6D,  // F18
        80: 0x6E,  // F19
        81: 0x67,  // Keypad =
        82: 0x62,  // Keypad 0
        83: 0x59,  // Keypad 1
        84: 0x5A,  // Keypad 2
        85: 0x5B,  // Keypad 3
        86: 0x5C,  // Keypad 4
        87: 0x5D,  // Keypad 5
        88: 0x5E,  // Keypad 6
        89: 0x5F,  // Keypad 7
        90: 0x6F,  // F20
        91: 0x60,  // Keypad 8
        92: 0x61,  // Keypad 9
        96: 0x3E,  // F5
        97: 0x3F,  // F6
        98: 0x40,  // F7
        99: 0x3C,  // F3
        100: 0x41, // F8
        101: 0x42, // F9
        103: 0x44, // F11
        105: 0x68, // F13
        106: 0x6B, // F16
        107: 0x69, // F14
        109: 0x43, // F10
        111: 0x45, // F12
        113: 0x6A, // F15
        114: 0x49, // Help -> Insert
        115: 0x4A, // Home
        116: 0x4B, // Page Up
        117: 0x4C, // Forward Delete
        118: 0x3D, // F4
        119: 0x4D, // End
        120: 0x3B, // F2
        121: 0x4E, // Page Down
        122: 0x3A, // F1
        123: 0x50, // Left
        124: 0x4F, // Right
        125: 0x51, // Down
        126: 0x52, // Up
    ]
}
