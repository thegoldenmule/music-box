import Foundation
import SwiftData
import Testing

import PolicyEngine

@testable import FamilyStore

// MARK: - Fixtures

private enum Fix {
    static let album = CatalogID(.album, "album-A")
    static let album2 = CatalogID(.album, "album-B")
    static let song = CatalogID(.song, "song-A")

    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    static let t1 = Date(timeIntervalSince1970: 1_700_086_400)
    static let t2 = Date(timeIntervalSince1970: 1_700_172_800)
}

@MainActor
private func newFamily(kids names: [String] = ["Robin"]) throws -> (ModelContext, Family, [Kid]) {
    let context = ModelContext(try FamilyStore.inMemoryContainer())
    let family = Family(at: Fix.t0)
    context.insert(family)
    var kids: [Kid] = []
    for name in names {
        let kid = Kid(name: name, mode: .denyPlusAuto, at: Fix.t0)
        context.insert(kid)
        family.addKid(kid, at: Fix.t0)
        kids.append(kid)
    }
    return (context, family, kids)
}

@MainActor
private func add(_ name: String, to family: Family, in context: ModelContext) -> GrownUp {
    let grownUp = GrownUp(name: name, at: Fix.t0)
    context.insert(grownUp)
    family.addGrownUp(grownUp, at: Fix.t0)
    return grownUp
}

// MARK: - The roster

@Suite("The grown-up roster")
@MainActor
struct GrownUpRoster {
    @Test("A family starts with nobody on it")
    func startsEmpty() throws {
        let (_, family, _) = try newFamily()
        #expect(family.grownUps.isEmpty)
    }

    @Test("A grown-up round-trips through storage")
    func roundTrips() throws {
        let (context, family, _) = try newFamily()
        let dad = add("Dad", to: family, in: context)
        try context.save()

        let stored = try #require(family.grownUp(dad.id))
        #expect(stored.name == "Dad")
        #expect(stored.attribution == dad.id.uuidString)
        #expect(stored.family?.id == family.id)
    }

    @Test("Adding and removing stamps the family")
    func stampsFamily() throws {
        let (context, family, _) = try newFamily()
        let dad = GrownUp(name: "Dad", at: Fix.t0)
        context.insert(dad)

        family.addGrownUp(dad, at: Fix.t1)
        #expect(family.modifiedAt == Fix.t1)

        family.removeGrownUp(dad, at: Fix.t2)
        #expect(family.modifiedAt == Fix.t2)
        #expect(family.grownUps.isEmpty)
    }

    @Test("Two grown-ups may share a name and are still two records")
    func sameNameStaysDistinct() throws {
        let (context, family, _) = try newFamily()
        let one = add("Dad", to: family, in: context)
        let two = add("Dad", to: family, in: context)

        #expect(family.grownUps.count == 2)
        #expect(one.attribution != two.attribution)
    }

    @Test("Deleting the family takes the roster with it")
    func cascades() throws {
        let (context, family, _) = try newFamily()
        add("Dad", to: family, in: context)
        try context.save()

        context.delete(family)
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<GrownUp>())
        #expect(remaining.isEmpty)
    }
}

// MARK: - Attribution on rows

@Suite("Attribution")
@MainActor
struct Attribution {
    @Test("A suggestion carries who made it, by id and by name")
    func suggestionCarriesAttribution() throws {
        let (context, family, kids) = try newFamily()
        let dad = add("Dad", to: family, in: context)
        kids[0].addSuggestion(
            target: .catalog(Fix.album),
            displayName: "An Album",
            addedBy: dad.attribution,
            addedByName: dad.name,
            at: Fix.t0
        )

        let row = try #require(kids[0].liveSuggestions.first)
        #expect(row.addedBy == dad.attribution)
        #expect(row.addedByName == "Dad")
    }

    @Test("A list entry carries who made it")
    func entryCarriesAttribution() throws {
        let (context, family, kids) = try newFamily()
        let dad = add("Dad", to: family, in: context)
        let record = kids[0].addEntry(
            kind: .allow,
            id: Fix.album,
            displayName: "An Album",
            addedBy: dad.attribution,
            addedByName: dad.name,
            at: Fix.t0
        )

        #expect(record.addedBy == dad.attribution)
        #expect(record.addedByName == "Dad")
    }

    @Test("Nobody on the roster leaves both columns nil")
    func unattributed() throws {
        let (_, _, kids) = try newFamily()
        kids[0].addSuggestion(target: .catalog(Fix.album), displayName: "An Album", at: Fix.t0)

        let row = try #require(kids[0].liveSuggestions.first)
        #expect(row.addedBy == nil)
        #expect(row.addedByName == nil)
    }

    @Test("Re-suggesting moves the row to whoever just suggested it")
    func upsertReassigns() throws {
        let (context, family, kids) = try newFamily()
        let dad = add("Dad", to: family, in: context)
        let mum = add("Mum", to: family, in: context)

        kids[0].addSuggestion(
            target: .catalog(Fix.album),
            displayName: "An Album",
            addedBy: dad.attribution,
            addedByName: dad.name,
            at: Fix.t0
        )
        kids[0].addSuggestion(
            target: .catalog(Fix.album),
            displayName: "An Album",
            addedBy: mum.attribution,
            addedByName: mum.name,
            at: Fix.t1
        )

        #expect(kids[0].suggestions.count == 1)
        let row = try #require(kids[0].liveSuggestions.first)
        #expect(row.addedBy == mum.attribution)
        #expect(row.addedByName == "Mum")
    }

    @Test("A dismissed row restored by someone else carries the new name")
    func restoreReassigns() throws {
        let (context, family, kids) = try newFamily()
        let dad = add("Dad", to: family, in: context)
        let mum = add("Mum", to: family, in: context)

        let record = kids[0].addSuggestion(
            target: .catalog(Fix.album),
            displayName: "An Album",
            addedBy: dad.attribution,
            addedByName: dad.name,
            at: Fix.t0
        )
        kids[0].dismissSuggestion(record, at: Fix.t1)

        kids[0].addSuggestion(
            target: .catalog(Fix.album),
            displayName: "An Album",
            addedBy: mum.attribution,
            addedByName: mum.name,
            at: Fix.t2
        )

        let row = try #require(kids[0].liveSuggestions.first)
        #expect(row.isDismissed == false)
        #expect(row.addedByName == "Mum")
    }

    @Test("A re-suggestion by nobody clears the attribution rather than keeping it")
    func upsertClears() throws {
        let (context, family, kids) = try newFamily()
        let dad = add("Dad", to: family, in: context)

        kids[0].addSuggestion(
            target: .catalog(Fix.album),
            displayName: "An Album",
            addedBy: dad.attribution,
            addedByName: dad.name,
            at: Fix.t0
        )
        kids[0].addSuggestion(target: .catalog(Fix.album), displayName: "An Album", at: Fix.t1)

        let row = try #require(kids[0].liveSuggestions.first)
        #expect(row.addedBy == nil)
        #expect(row.addedByName == nil)
    }
}

// MARK: - Renaming

@Suite("Renaming a grown-up")
@MainActor
struct RenamingAGrownUp {
    /// Dad and Mum each with a suggestion and a list entry, on two kids.
    @MainActor
    private struct Household {
        let context: ModelContext
        let family: Family
        let kids: [Kid]
        let dad: GrownUp
        let mum: GrownUp
    }

    @MainActor
    private static func household() throws -> Household {
        let (context, family, kids) = try newFamily(kids: ["Robin", "Sam"])
        let dad = add("Dad", to: family, in: context)
        let mum = add("Mum", to: family, in: context)

        for kid in kids {
            kid.addSuggestion(
                target: .catalog(Fix.album),
                displayName: "An Album",
                addedBy: dad.attribution,
                addedByName: dad.name,
                at: Fix.t0
            )
            kid.addSuggestion(
                target: .catalog(Fix.song),
                displayName: "A Song",
                addedBy: mum.attribution,
                addedByName: mum.name,
                at: Fix.t0
            )
            kid.addEntry(
                kind: .allow,
                id: Fix.album2,
                displayName: "Another Album",
                addedBy: dad.attribution,
                addedByName: dad.name,
                at: Fix.t0
            )
        }
        return Household(context: context, family: family, kids: kids, dad: dad, mum: mum)
    }

    @Test("Renaming rewrites the copies on every kid's suggestions")
    func rewritesSuggestions() throws {
        let house = try Self.household()
        house.family.renameGrownUp(house.dad, to: "Daddy", at: Fix.t1)

        for kid in house.kids {
            let names = kid.suggestions
                .filter { $0.addedBy == house.dad.attribution }
                .map(\.addedByName)
            #expect(names == ["Daddy"])
        }
    }

    @Test("Renaming rewrites the copies on list entries too")
    func rewritesEntries() throws {
        let house = try Self.household()
        house.family.renameGrownUp(house.dad, to: "Daddy", at: Fix.t1)

        for kid in house.kids {
            let names = kid.entries
                .filter { $0.addedBy == house.dad.attribution }
                .map(\.addedByName)
            #expect(names == ["Daddy"])
        }
    }

    @Test("Renaming one grown-up does not touch another's rows")
    func leavesOthersAlone() throws {
        let house = try Self.household()
        house.family.renameGrownUp(house.dad, to: "Daddy", at: Fix.t1)

        for kid in house.kids {
            let mums = kid.suggestions.filter { $0.addedBy == house.mum.attribution }
            #expect(mums.map(\.addedByName) == ["Mum"])
            #expect(mums.allSatisfy { $0.modifiedAt == Fix.t0 })
        }
    }

    @Test("Renaming stamps the rows it rewrote")
    func stampsRewrittenRows() throws {
        let house = try Self.household()
        house.family.renameGrownUp(house.dad, to: "Daddy", at: Fix.t1)

        let touched = house.kids[0].suggestions.filter { $0.addedBy == house.dad.attribution }
        #expect(touched.allSatisfy { $0.modifiedAt == Fix.t1 })
        #expect(house.dad.modifiedAt == Fix.t1)
    }

    @Test("Removing a grown-up leaves their rows and their names where they are")
    func removalKeepsRows() throws {
        let house = try Self.household()
        house.family.removeGrownUp(house.dad, at: Fix.t1)
        house.context.delete(house.dad)
        try house.context.save()

        #expect(house.family.grownUps.map(\.name) == ["Mum"])
        for kid in house.kids {
            let dads = kid.suggestions.filter { $0.addedByName == "Dad" }
            #expect(dads.count == 1)
        }
    }
}

// MARK: - Which Apple Account is which adult

@Suite("Claiming an Apple Account")
@MainActor
struct ClaimingAnAccount {
    @Test("An adult starts with no account against them")
    func startsUnclaimed() throws {
        let (context, family, _) = try newFamily()
        let dad = add("Dad", to: family, in: context)
        #expect(dad.accountRecordName == nil)
    }

    @Test("Claiming records the account and stamps the row")
    func claims() throws {
        let (context, family, _) = try newFamily()
        let dad = add("Dad", to: family, in: context)

        family.claimAccount("_acct-dad", for: dad, at: Fix.t1)

        #expect(dad.accountRecordName == "_acct-dad")
        #expect(dad.modifiedAt == Fix.t1)
    }

    /// The shared-iPad case: two holders would make roster lookup order-dependent.
    @Test("One account is held by exactly one adult, and a claim moves")
    func onlyOneHolder() throws {
        let (context, family, _) = try newFamily()
        let mum = add("Mum", to: family, in: context)
        let dad = add("Dad", to: family, in: context)

        family.claimAccount("_shared-ipad", for: mum, at: Fix.t1)
        family.claimAccount("_shared-ipad", for: dad, at: Fix.t2)

        #expect(mum.accountRecordName == nil)
        #expect(dad.accountRecordName == "_shared-ipad")
        #expect(family.grownUps.filter { $0.accountRecordName == "_shared-ipad" }.count == 1)
    }

    @Test("Claiming leaves an adult holding a different account alone")
    func leavesOthersAlone() throws {
        let (context, family, _) = try newFamily()
        let mum = add("Mum", to: family, in: context)
        let dad = add("Dad", to: family, in: context)

        family.claimAccount("_acct-mum", for: mum, at: Fix.t1)
        family.claimAccount("_acct-dad", for: dad, at: Fix.t2)

        #expect(mum.accountRecordName == "_acct-mum")
        #expect(dad.accountRecordName == "_acct-dad")
    }

    /// Runs every launch — a stamp each time would outbox the whole roster.
    @Test("Re-claiming the same account writes nothing")
    func idempotent() throws {
        let (context, family, _) = try newFamily()
        let dad = add("Dad", to: family, in: context)

        family.claimAccount("_acct-dad", for: dad, at: Fix.t1)
        family.claimAccount("_acct-dad", for: dad, at: Fix.t2)

        #expect(dad.modifiedAt == Fix.t1)
    }

    @Test("Un-claiming clears this adult and touches nobody else")
    func unclaims() throws {
        let (context, family, _) = try newFamily()
        let mum = add("Mum", to: family, in: context)
        let dad = add("Dad", to: family, in: context)
        family.claimAccount("_acct-mum", for: mum, at: Fix.t1)
        family.claimAccount("_acct-dad", for: dad, at: Fix.t1)

        family.claimAccount(nil, for: dad, at: Fix.t2)

        #expect(dad.accountRecordName == nil)
        #expect(mum.accountRecordName == "_acct-mum")
    }

    /// The column's whole purpose: an opaque participant id becomes a readable name.
    @Test("A participant identifier resolves to exactly one name")
    func namesAParticipant() throws {
        let (context, family, _) = try newFamily()
        let mum = add("Mum", to: family, in: context)
        _ = add("Dad", to: family, in: context)
        family.claimAccount("_acct-mum", for: mum, at: Fix.t1)

        let matches = family.orderedGrownUps.filter { $0.accountRecordName == "_acct-mum" }
        #expect(matches.count == 1)
        #expect(matches.first?.name == "Mum")
    }
}
