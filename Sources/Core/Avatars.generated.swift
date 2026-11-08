// Generated from webos-catalog/js/avatars.js by tools/export-avatars.js. Do not edit.
import SwiftUI

struct Avatar: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let group: String
    let top: UInt32
    let bottom: UInt32
}

enum Avatars {
    static let groups = ["Animals", "Characters"]

    static let all: [Avatar] = [
        Avatar(id: "fox", name: "Fox", group: "Animals", top: 0x4B5BD6, bottom: 0x7B8CFF),
        Avatar(id: "cat", name: "Cat", group: "Animals", top: 0xFF9A8B, bottom: 0xFF6A88),
        Avatar(id: "panda", name: "Panda", group: "Animals", top: 0x2ECC71, bottom: 0x16A085),
        Avatar(id: "owl", name: "Owl", group: "Animals", top: 0xA18CD1, bottom: 0xCFD9FF),
        Avatar(id: "bear", name: "Bear", group: "Animals", top: 0x2F80ED, bottom: 0x56CCF2),
        Avatar(id: "rabbit", name: "Rabbit", group: "Animals", top: 0xB24592, bottom: 0xF15F79),
        Avatar(id: "penguin", name: "Penguin", group: "Animals", top: 0xF9D423, bottom: 0xFF4E50),
        Avatar(id: "dino", name: "Dino", group: "Animals", top: 0xFC5C7D, bottom: 0x6A82FB),
        Avatar(id: "robot", name: "Robot", group: "Characters", top: 0x1E3C72, bottom: 0x2A5298),
        Avatar(id: "astronaut", name: "Astronaut", group: "Characters", top: 0xFF9966, bottom: 0xFF5E62),
        Avatar(id: "alien", name: "Alien", group: "Characters", top: 0x4776E6, bottom: 0x8E54E9),
        Avatar(id: "ghost", name: "Ghost", group: "Characters", top: 0xF7971E, bottom: 0xFFD200),
        Avatar(id: "ninja", name: "Ninja", group: "Characters", top: 0xF5AF19, bottom: 0xF12711),
        Avatar(id: "wizard", name: "Wizard", group: "Characters", top: 0x0F2027, bottom: 0x2C5364),
        Avatar(id: "smiley", name: "Cool", group: "Characters", top: 0x8360C3, bottom: 0x2EBF91),
        Avatar(id: "planet", name: "Planet", group: "Characters", top: 0x232526, bottom: 0x414345)
    ]

    static func find(_ id: String?) -> Avatar? { all.first { $0.id == id } }

    /// The first avatar nobody in `used` has.
    static func nextFree(_ used: [String]) -> String { all.first { !used.contains($0.id) }?.id ?? all[0].id }
}
