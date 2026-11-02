import Foundation

/// Kokoro voices grouped for fast listening. Ranked by clarity at 2.5× (Whisper
/// word error rate on WSOLA-sped speech, measured on an M4) and by naturalness
/// (Kokoro's published voice grades).
enum VoiceCatalog {
    struct Group {
        var title: String
        var detail: String
        var voices: [String]
    }

    static let groups: [Group] = [
        Group(title: "Best for fast listening", detail: "Most natural, and stay clear at 2–3×",
              voices: ["af_heart", "af_bella", "bf_emma", "af_sarah", "am_michael", "am_fenrir", "am_puck", "bf_isabella", "af_aoede", "af_kore"]),
        Group(title: "Clear", detail: "Easy to follow at speed, a little less natural",
              voices: ["af_alloy", "af_nova", "af_river", "am_echo", "am_liam", "am_adam", "am_eric", "am_onyx",
                       "bm_george", "bm_daniel", "bm_lewis", "bf_lily", "bf_alice", "af_nicole", "am_santa"]),
        Group(title: "Less clear when fast", detail: "Fine at normal speed",
              voices: ["bm_fable", "af_sky", "af_jessica"]),
    ]

    static func label(_ id: String) -> String {
        let parts = id.split(separator: "_")
        guard parts.count == 2, let tag = parts.first, tag.count == 2 else { return id }
        let accent = tag.first == "b" ? "British" : "American"
        let gender = tag.last == "f" ? "female" : "male"
        var name = parts[1].capitalized
        if id == "af_nicole" { name += " (soft, whispery)" }
        if id == "af_heart" { name += " — default" }
        return "\(name) · \(accent) \(gender)"
    }

    /// Voices the engine reports that aren't in a group yet still get listed.
    static func grouped(available: [String]) -> [Group] {
        let known = Set(groups.flatMap(\.voices))
        var out = groups.map { g in Group(title: g.title, detail: g.detail, voices: g.voices.filter { available.isEmpty || available.contains($0) }) }
        let extra = available.filter { !known.contains($0) }
        if !extra.isEmpty { out.append(Group(title: "Other", detail: "", voices: extra)) }
        return out.filter { !$0.voices.isEmpty }
    }
}
