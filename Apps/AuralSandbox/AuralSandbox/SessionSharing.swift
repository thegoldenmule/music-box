import FamilyStore
import FamilySync
import Foundation

/// Joining a household, and saying which adult this account is.
///
/// **Separate from `Session` for the reason `SessionBinding.swift` is**: what is
/// left here is reading inputs and writing answers, while the rules live in
/// `FamilySync` and `FamilyStore` where `swift test` can reach them. There is no
/// app test target, so anything decided in this file is decided somewhere nothing
/// can check.
@MainActor
extension Session {

    // MARK: - Joining a household

    /// Accepts every invitation waiting in ``ShareAcceptance``.
    ///
    /// **The other half of the tapped link.** `CKSharingSupported` gets the app
    /// launched and ``ShareAcceptanceDelegate`` catches the metadata; without
    /// this, both of those happen and nothing joins anything.
    ///
    /// **It does not ask.** By the time a share reaches the delegate the system
    /// has already shown its own confirmation and the person tapped through it, so
    /// a second prompt of ours would be asking a question that has been answered.
    /// It also cannot ask: a link tapped on a shared iPad arrives while the kid's
    /// player is on screen, and nothing about the household's grown-ups belongs
    /// there. The outcome is recorded for the sharing screen to report instead.
    func acceptPendingShares() async {
        let waiting = ShareAcceptance.shared.drain()
        guard !waiting.isEmpty else { return }

        var joined = false
        // Nothing outbound for the length of this — see ``Session/isJoining``. A
        // push already in flight from a list edit would otherwise land on an
        // engine still addressing this device's own private zones.
        beginJoining()
        for metadata in waiting {
            do {
                try await sharing.accept(metadata: metadata)
                ShareAcceptance.shared.record(.joined)
                joined = true
            } catch {
                ShareAcceptance.shared.record(.failed(error.localizedDescription))
            }
        }
        endJoining()

        // Only on a real acceptance. Rebuilding after a failure would throw away
        // a working engine because a link was stale.
        guard joined else { return }
        await restartSyncEngine()
    }

    /// Accepts an invitation from a link somebody pasted.
    ///
    /// The same path as a tapped one from here on, which is the point: there is
    /// one way to join and two ways to arrive at it.
    func acceptInvitation(at url: URL) async -> String? {
        beginJoining()
        do {
            try await sharing.accept(url: url)
            endJoining()
            ShareAcceptance.shared.record(.joined)
            await restartSyncEngine()
            return nil
        } catch {
            endJoining()
            ShareAcceptance.shared.record(.failed(error.localizedDescription))
            return error.localizedDescription
        }
    }

    /// Puts everyone who has joined onto the zones their invitation link did not
    /// carry.
    ///
    /// **This is the step that used to keep sync manual.** A `CKShare` link
    /// carries exactly one zone, and a household is one zone plus two per child —
    /// so an invitation is an anchor plus a second step, and until that step runs
    /// a co-parent holds the roster and none of the children. Nothing calls back
    /// when somebody accepts; the owner's device finds out by looking. So it looks
    /// on every launch and every foreground rather than only when a parent happens
    /// to open the sharing screen.
    ///
    /// Returns 0 on a joined device and on a household nobody has invited into,
    /// both without writing — see ``FamilySync/FamilySharing/reconcileGrants(for:kids:)``.
    @discardableResult
    func reconcileOutstandingGrants() async -> Int {
        let kidIDs = kids.map(\.id)
        var changed = 0

        // Every role separately, because each has its own anchor and its own
        // outstanding set. A child's invitation is not covered by the co-parent's.
        changed += (try? await sharing.reconcileGrants(for: .coParent, kids: kidIDs)) ?? 0
        for id in kidIDs {
            changed += (try? await sharing.reconcileGrants(for: .child(id), kids: kidIDs)) ?? 0
        }
        return changed
    }

    // MARK: - Consent

    /// Whether an invitation for this role may be offered yet.
    ///
    /// **The passcode is not the answer.** Guideline 5.1.4 says a Kids-Category
    /// parental gate is generally not the same as securing consent to collect a
    /// child's personal information, and a share is what creates the capability to
    /// hand that information to somebody else. So the gate gets a parent to this
    /// screen and a separate, recorded act gets them past it — see
    /// ``FamilyStore/Consent``.
    func consentIsGiven(for role: ShareRole) -> Bool {
        Consent.isGiven(
            scope: Self.scope(for: role),
            householdKids: kids.map(\.id),
            subject: Self.subject(of: role),
            recorded: recordedConsent()
        )
    }

    /// The children an invitation for this role would expose that no agreement
    /// covers, in roster order.
    ///
    /// **What the consent screen has to name out loud.** "Everything about Robin
    /// *and Sam*" is a different sentence from the one a parent agreed to when they
    /// had one child, and this is the difference.
    func kidsNeedingConsent(for role: ShareRole) -> [Kid] {
        let missing = Consent.kidsNotCovered(
            scope: Self.scope(for: role),
            householdKids: kids.map(\.id),
            subject: Self.subject(of: role),
            recorded: recordedConsent()
        )
        return kids.filter { missing.contains($0.id) }
    }

    /// Files the agreement for this role.
    ///
    /// **Records the whole of what is knowable and no more.** The adult is
    /// identified two ways where both are available — the acting grown-up they
    /// selected behind the gate, and the opaque record name of the Apple Account
    /// signed in here — and either may be absent, which the record allows. That is
    /// the honest maximum: nothing in this app verifies that the person behind the
    /// passcode is a parent, and a row claiming otherwise would be worse than a row
    /// admitting it.
    ///
    /// The children are stored as the identifiers exposed *at this moment*, not
    /// derived later, because that is what makes the next child a new question.
    func recordConsent(for role: ShareRole) -> String? {
        let scope = Self.scope(for: role)
        let exposed = Consent.kidsExposed(
            by: scope, householdKids: kids.map(\.id), subject: Self.subject(of: role))

        let accountName: String? =
            if case .signedIn(let name) = signedInAccount { name } else { nil }

        return record(
            ConsentRecord(
                familyID: householdID,
                grownUpID: actingGrownUp?.id,
                accountRecordName: accountName,
                scope: scope,
                // Sorted so two devices filing the same agreement produce the same
                // bytes, which is one fewer thing for a merge to arbitrate.
                kidIDs: exposed.sorted { $0.uuidString < $1.uuidString },
                appVersion: Self.appVersion
            )
        )
    }

    private static func scope(for role: ShareRole) -> ConsentScope {
        switch role {
        case .coParent: .shareHousehold
        case .child: .childAccountParticipates
        }
    }

    private static func subject(of role: ShareRole) -> UUID? {
        switch role {
        case .coParent: nil
        case .child(let id): id
        }
    }

    /// Which build put the words in front of them.
    ///
    /// The wording will change, and a record of agreement to unknown wording is not
    /// much of a record. **Recorded, not compared:** re-asking on every update would
    /// train a parent to tap through it, which is the opposite of what a consent
    /// screen is for. If the wording changes materially, that is the moment to
    /// decide about re-asking, and it wants its own version rather than this one.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    // MARK: - Which adult this Apple Account is

    /// Records that the account signed in here belongs to the grown-up acting on
    /// this device.
    ///
    /// **This is the only moment the answer exists.** Nobody else can know it: a
    /// `CKShare.Participant` carries an opaque record name and — deliberately —
    /// we never ask for `nameComponents` or `lookupInfo`, because App Review 5.1.4
    /// names a persistent identifier *beside a minor's data* as the trigger and an
    /// email address next to a child's search history is exactly that. So the
    /// household roster can only put a name to a participant if somebody, on the
    /// device holding that account, said which of these adults they are.
    ///
    /// Saying so is what ``ActingGrownUp`` already is, behind the gate. This turns
    /// that device-local claim into a household fact, and the pairing is the
    /// upgrade ``FamilyStore/GrownUp/accountRecordName`` describes: a claim plus a
    /// matching signed-in account is something checkable, where either alone is
    /// not.
    ///
    /// **Never a permission.** It opens no gate and widens no reach. Called on
    /// every launch and on every change of acting grown-up; writes only when the
    /// answer is different — see ``FamilyStore/Family/claimAccount(_:for:at:)``.
    func claimAccountForActingGrownUp() {
        guard case .signedIn(let recordName) = signedInAccount else { return }
        guard let acting = actingGrownUp else { return }

        claimAccount(recordName, for: acting)
    }
}
