import FamilyStore
import FamilySync
import SwiftUI

/// The agreement, before the first invitation of a given kind goes out.
///
/// **A separate act on purpose, because the passcode is not this.** Guideline
/// 5.1.4 says a Kids-Category parental gate is generally not the same as securing
/// parental consent to collect a child's personal information — and a share is
/// exactly what creates the capability to hand that information to somebody else.
/// So the gate gets a parent here and this gets them past it, and what it leaves
/// behind is a row rather than a screenshot of a screen.
///
/// **It names the children.** The whole reason ``FamilyStore/Consent`` tracks
/// coverage per child is that "everything about Robin" is not the sentence a parent
/// agreed to once Sam exists, and a screen that said "your children" would hide the
/// difference it exists to surface.
///
/// **Dismissing is declining.** There is no path out of here that records an
/// agreement except the button that says what it agrees to, and the cancel is
/// worded as a deferral rather than a refusal because it is one — the invitation
/// simply does not get made.
///
/// The wording is the part a lawyer has to read. It is written to be plain and
/// factual and it is not a legal opinion; the spec's own note says the COPPA
/// position needs counsel, and nothing here settles that.
struct ConsentSheet: View {
    let role: ShareRole
    /// The children this invitation would expose that no agreement covers.
    let kids: [Kid]
    /// Who is agreeing, if this device knows.
    let actingGrownUp: String?
    let onAgree: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(headline).font(.headline)
                    Text(what)
                } header: {
                    Text("What you are agreeing to")
                }

                if !kids.isEmpty {
                    Section {
                        ForEach(kids, id: \.id) { kid in
                            Label(kid.name, systemImage: "person.fill")
                        }
                    } header: {
                        Text(kids.count == 1 ? "About this child" : "About these children")
                    } footer: {
                        // The load-bearing sentence. A parent who agreed last year
                        // agreed about the children they had then.
                        Text(
                            "If you add another child later, you will be asked again — this agreement is only about the children listed here."
                        )
                    }
                }

                Section {
                    ForEach(facts, id: \.self) { fact in
                        Label(fact, systemImage: "circle.fill")
                            .labelStyle(BulletLabel())
                    }
                } header: {
                    Text("What that means in practice")
                }

                Section {
                    Button(agreement) {
                        onAgree()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                } footer: {
                    Text(attribution)
                }
            }
            .navigationTitle("Before you share")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // "Not now" rather than "Cancel": nothing is being refused,
                    // the invitation just is not made.
                    Button("Not now") { dismiss() }
                }
            }
        }
    }

    // MARK: - The words

    private var isChildAccount: Bool {
        if case .child = role { return true }
        return false
    }

    private var headline: String {
        isChildAccount
            ? "This child will use their own Apple Account with this app."
            : "Another grown-up will see everything this app records about your children."
    }

    private var what: String {
        isChildAccount
            ? "Their Apple Account becomes part of where this family's records are kept, so that what they save on their own device reaches you."
            : "Whoever accepts your invitation will be able to read every song your children played, every search they typed, and everything that was blocked — as it happens, from their own phone."
    }

    private var facts: [String] {
        if isChildAccount {
            return [
                "They can keep their own favourites and playlists, and you will see them.",
                "They cannot change what they are allowed to reach, and they cannot see anything of a brother or sister's.",
                "Their records go to Apple, under your family's own iCloud storage. There is no server of ours, and we cannot read them.",
            ]
        }
        return [
            "There is no way to give somebody part of this. Everyone you invite sees every child.",
            "Removing them later stops them receiving anything new. Whatever already reached their device stays there — there is no reaching back for it.",
            "These records go to Apple, in your family's own iCloud storage. There is no server of ours, no analytics company, and we cannot read them.",
        ]
    }

    private var agreement: String {
        if isChildAccount {
            return kids.count == 1
                ? "I agree, and \(kids[0].name) is my child"
                : "I agree, and these are my children"
        }
        return "I agree to share my children's activity"
    }

    private var attribution: String {
        guard let actingGrownUp else {
            // Said out loud rather than hidden. A row that cannot name who agreed
            // is a weaker record, and the fix is one screen away.
            return
                "Recorded with the date and this app's version. Nobody is selected as the grown-up on this device, so this agreement will not carry a name — add yourself under Grown-ups if you would rather it did."
        }
        return
            "Recorded as \(actingGrownUp), with the date and this app's version."
    }
}

/// A bullet that stays a bullet at accessibility sizes, where a `•` in the string
/// would wrap under itself.
private struct BulletLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon
                .font(.system(size: 5))
                .foregroundStyle(.secondary)
            configuration.title
        }
    }
}
