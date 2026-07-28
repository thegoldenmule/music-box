import SwiftUI

/// The one row a kid can always reach: the way back to the start, and the way to
/// look for something.
///
/// **A view rather than `searchable`, and that is the whole point of it.** A
/// `searchable` field belongs to the navigation container it is applied to and
/// shows up on the *root* screen of that container — so it was there on home and
/// gone the moment a kid opened an album, an artist, a playlist or their
/// library, which is most of the time they spend in the app. This is drawn
/// beneath the stack instead, so pushing a screen does not move it and there is
/// nowhere in the kid's app it is missing from.
///
/// The cost of leaving `searchable` behind is the system behaviour that came
/// with it: the field does not collapse into the toolbar, there is no scoped
/// search UI and no suggestions. None of those are things this app wanted — a
/// kid's search is one field, one prompt, and a keyboard.
///
/// **Home is to the left of the field on purpose.** They are the two halves of
/// the only navigation model a kid gets — one way further in, one way all the
/// way back — and a lost child cannot be asked to count how many backs they
/// need.
///
/// The field is absent, not empty, in level 1: an empty search box a kid is not
/// allowed to use is an invitation to keep trying. The home button stays.
struct KidSearchBar: View {
    let canSearch: Bool
    @Binding var term: String
    let onSubmit: () -> Void
    let onHome: () -> Void

    /// Held so submitting can put the keyboard away. A kid who pressed the
    /// search key is done typing, and leaving the keyboard up covers the
    /// results they just asked for.
    @FocusState private var isTyping: Bool

    private let height: CGFloat = 52

    var body: some View {
        HStack(spacing: 12) {
            Button(action: home) {
                Image(systemName: "house.fill")
                    .font(.title2)
                    .frame(width: height, height: height)
                    .background(.quaternary, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Home")

            if canSearch {
                field
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("What do you want to hear?", text: $term)
                .textFieldStyle(.plain)
                .font(.headline)
                .focused($isTyping)
                .submitLabel(.search)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.words)
                #endif
                .onSubmit {
                    isTyping = false
                    onSubmit()
                }

            // Only once there is something to clear. A permanent glyph beside
            // the prompt is one more thing to press that does nothing.
            if !term.isEmpty {
                Button {
                    term = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: height)
        .background(.quaternary, in: Capsule())
        // The capsule is the target, not the words inside it — a kid aiming at
        // a text field aims at the box.
        .contentShape(Capsule())
        .onTapGesture { isTyping = true }
    }

    /// Going home puts the keyboard away too. Otherwise the button lands the kid
    /// on their own shelves with half the screen still covered.
    private func home() {
        isTyping = false
        onHome()
    }
}
