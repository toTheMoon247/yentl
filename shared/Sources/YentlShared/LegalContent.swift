//
//  LegalContent.swift
//  YentlShared
//
//  Phase 11 Slice 3: the Terms of Service and Privacy Policy shown in
//  onboarding (the consent step) and in Account & Privacy.
//
//  ⚠️ These are plain-language starter documents that reflect how the app
//  actually works (human matchmakers, AI screening via OpenAI, per-date Apple
//  IAP, the sub-processors, in-app export/deletion). They are NOT a substitute
//  for legal review — a lawyer must review both before App Store submission,
//  and the placeholders (company entity, address, governing law) must be
//  filled in. Tracked in docs/implementation-plan.md (Phase 11) and the PM log.
//
//  The App Store listing also needs a PUBLICLY HOSTED privacy-policy URL; this
//  in-app copy satisfies the in-app disclosure, not that hosting requirement.
//

import Foundation

/// A legal document rendered by `LegalDocumentView`. `body` is a lightweight
/// markdown subset: `## ` lines are section headings, `- ` lines are bullets,
/// blank lines separate paragraphs.
public struct LegalDocument: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let effectiveDate: String
    public let body: String

    public static let termsOfService = LegalDocument(
        id: "terms",
        title: "Terms of Service",
        effectiveDate: "July 23, 2026",
        body: """
        Welcome to Yentl. By creating an account you agree to these Terms. Please \
        read them alongside our Privacy Policy.

        ## 1. Who can use Yentl
        You must be at least 18 years old and legally able to enter a contract. \
        Yentl is for personal, non-commercial use to meet potential partners.

        ## 2. How Yentl works
        Yentl uses professional human matchmakers, not only algorithms, to decide \
        who is introduced. Being on Yentl does not guarantee a match, a date, or \
        any particular outcome. Matchmakers may decline, pause, or remove a \
        profile at their discretion.

        ## 3. Your account and conduct
        You agree to provide accurate information and to keep your profile honest. \
        You will not:
        - impersonate anyone or misrepresent your age or identity
        - harass, threaten, or abuse other people
        - post unlawful, hateful, or sexually explicit content
        - solicit money, advertise, or move people off-platform to defraud them
        - use Yentl if you are a convicted sex offender.

        ## 4. Profile review
        Profiles are screened by automated tools and by matchmakers before going \
        live. We may reject or ask you to change a profile — for example, a photo \
        that is not clearly a single real person, or a bio containing contact \
        details.

        ## 5. Fees and payments
        Yentl charges a fee to unlock the conversation with a match, purchased \
        through Apple in-app purchase. Apple's terms and pricing apply. Purchases \
        are generally non-refundable except where required by law or Apple's \
        policies. Each participant pays their own fee to open the conversation.

        ## 6. Your content
        You keep ownership of the photos and text you add. You grant Yentl a \
        limited licence to host, display, and process that content to operate the \
        service (including sharing your profile with matchmakers and potential \
        matches).

        ## 7. Suspension and termination
        We may suspend or ban an account that violates these Terms or puts others \
        at risk. You can delete your account at any time in Account & Privacy.

        ## 8. Safety disclaimer
        Yentl does not run criminal background checks on members. You are \
        responsible for your own safety — meet in public, tell a friend your \
        plans, and trust your instincts. Yentl is not responsible for the conduct \
        of any member, online or offline.

        ## 9. No warranties; limitation of liability
        The service is provided "as is" without warranties of any kind. To the \
        fullest extent permitted by law, Yentl is not liable for indirect or \
        consequential damages arising from your use of the service.

        ## 10. Changes
        We may update these Terms; we will update the effective date and, for \
        material changes, notify you in the app. Continued use means you accept \
        the updated Terms.

        ## 11. Contact
        Questions about these Terms? Email legal@yentl.app.
        """
    )

    public static let privacyPolicy = LegalDocument(
        id: "privacy",
        title: "Privacy Policy",
        effectiveDate: "July 23, 2026",
        body: """
        This policy explains what Yentl collects, how we use it, and the choices \
        you have. We do not sell your personal data.

        ## 1. What we collect
        - Profile information you provide: name, date of birth, gender, location, \
        bio, prompts, and photos.
        - Activity in the app: matches, messages, and moderation reports.
        - Payment status for the match-unlock fee (processed by Apple and our \
        payments provider — we do not store your card details).
        - Technical data needed to run the app, such as a push-notification token.

        ## 2. How we use it
        - To make matchmaker-led introductions and run the matching queue.
        - To screen profiles for safety, including automated moderation of text \
        and photos.
        - To process the match-unlock fee and open conversations.
        - To send you notifications you have allowed.

        ## 3. Who can see your information
        - Yentl's professional matchmakers, to make introductions.
        - People you are matched with see your profile.
        - Service providers who process data on our behalf under contract: \
        Supabase (hosting and database), Stream (chat), OneSignal (push \
        notifications), RevenueCat and Apple (payments), and OpenAI (automated \
        profile screening). We do not sell data to advertisers.

        ## 4. Automated screening
        To keep the community safe, profile text and photos are processed by an \
        automated moderation service (OpenAI) to detect explicit content, contact \
        details, and photos that are not a single real person. Flagged profiles \
        are reviewed by a human matchmaker.

        ## 5. Keeping and deleting your data
        You can export a copy of your data or permanently delete your account at \
        any time from Account & Privacy. Deleting your account erases your \
        profile, photos, matches, and messages from our systems. Some records may \
        be retained where required by law (for example, payment records).

        ## 6. Your rights
        Depending on where you live, you may have rights to access, correct, \
        export, or delete your personal data, and to object to certain \
        processing. The in-app export and delete tools cover the main ones; email \
        privacy@yentl.app for anything else.

        ## 7. Security
        We use industry-standard measures to protect your data, including \
        encryption in transit and access controls. No system is perfectly secure, \
        so we cannot guarantee absolute security.

        ## 8. Children
        Yentl is strictly for adults 18 and older. We do not knowingly collect \
        data from anyone under 18 and will delete such accounts.

        ## 9. International transfers
        Your data may be processed in countries other than your own. Where it is, \
        we take steps to ensure it remains protected.

        ## 10. Changes
        We may update this policy; we will update the effective date and notify \
        you of material changes in the app.

        ## 11. Contact
        Questions about your privacy? Email privacy@yentl.app.
        """
    )
}
