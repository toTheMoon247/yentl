//
//  ProfilePresets.swift
//  Yentl
//
//  Fixed preset lists for profile prompts and interests (MVP). Users pick
//  from these rather than typing free-form, for consistency. The chosen
//  prompt question text is stored alongside the answer, so editing this list
//  later doesn't break existing profiles.
//

enum ProfilePresets {
    /// Prompt questions a user can answer (pick up to `maxPrompts`).
    static let prompts: [String] = [
        "My ideal first date is…",
        "Two truths and a lie…",
        "The way to win me over is…",
        "I'm looking for…",
        "A perfect Sunday looks like…",
        "I geek out on…",
        "My most controversial opinion is…",
        "The best trip I've taken was…"
    ]

    /// Interests a user can select.
    static let interests: [String] = [
        "Travel", "Cooking", "Fitness", "Music", "Movies", "Reading",
        "Hiking", "Gaming", "Art", "Photography", "Coffee", "Wine",
        "Yoga", "Dancing", "Running", "Foodie", "Pets", "Tech",
        "Fashion", "Volunteering"
    ]

    static let maxPrompts = 3
}
