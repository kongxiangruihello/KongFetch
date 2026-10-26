import Foundation

/// Search-as-you-type over one index. When the new query only adds characters
/// or words to the previous one, every match must already be among the previous
/// matches, so only those are rescored instead of the whole index.
public final class SearchSession {
    public let index: NameIndex
    /// Whether the last search reused the previous result set.
    public private(set) var lastSearchNarrowed = false

    private var previousWords: [String] = []
    private var previousPrecision: MatchPrecision = .fuzzyName
    private var previousGeneration = -1
    private var previousHits: [SearchHit] = []

    public init(index: NameIndex) {
        self.index = index
    }

    public func search(_ rawWords: [String], precision: MatchPrecision = .fuzzyName) -> [SearchHit] {
        let words = rawWords.filter { !$0.isEmpty }
        var candidates: [Int32]?
        if previousGeneration == index.generation, previousPrecision == precision,
           Self.canNarrow(from: previousWords, to: words, precision: precision) {
            candidates = previousHits.map(\.id)
        }
        let hits = index.search(words, precision: precision, within: candidates)
        lastSearchNarrowed = candidates != nil
        previousWords = words
        previousPrecision = precision
        previousGeneration = index.generation
        previousHits = hits
        return hits
    }

    public func reset() {
        previousGeneration = -1
        previousHits = []
    }

    /// Matching is monotonic when each old word is a prefix of the new word in the
    /// same position and words are only added. Exceptions in 3.2's rules:
    /// exact-name mode (a longer name can match), and 1-character words, which
    /// skip folder-path matching that a 2-character word would allow.
    static func canNarrow(from old: [String], to new: [String], precision: MatchPrecision) -> Bool {
        guard precision != .exactName, !old.isEmpty, new.count >= old.count else { return false }
        for (oldWord, newWord) in zip(old, new) {
            let oldFolded = SearchText.fold(oldWord)
            guard oldWord.count >= 2, oldFolded.count >= 2,
                  newWord.hasPrefix(oldWord),
                  SearchText.fold(newWord).hasPrefix(oldFolded)
            else { return false }
        }
        return true
    }
}
